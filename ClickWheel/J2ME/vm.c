// The interpreter: loads the game's classes, runs their bytecode on green threads and collects
// garbage (mark and sweep; thread stacks are scanned conservatively).
#include "jvm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

int64_t vm_now;
Thread *vm_threads;
Thread *vm_current;
size_t vm_allocated;

static Class *classes;
static Obj *heap;
static Thread *event_thread;
static Obj **roots[64];
static int nroots;

void vm_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[j2me] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

// MARK: Object set, for the conservative stack scan

static Obj **objset;
static size_t objset_cap, objset_count;

static size_t ptr_hash(Obj *o) { return ((uintptr_t)o >> 4) * 0x9E3779B97F4A7C15ull; }

static void objset_insert(Obj *o);

static void objset_grow(void) {
    Obj **old = objset;
    size_t oldcap = objset_cap;
    objset_cap = objset_cap ? objset_cap * 2 : 4096;
    objset = calloc(objset_cap, sizeof(Obj *));
    objset_count = 0;
    for (size_t i = 0; i < oldcap; i++)
        if (old[i] && old[i] != (Obj *)1) objset_insert(old[i]);
    free(old);
}

static void objset_insert(Obj *o) {
    if ((objset_count + 1) * 2 > objset_cap) objset_grow();
    size_t mask = objset_cap - 1, i = ptr_hash(o) & mask;
    while (objset[i] && objset[i] != (Obj *)1) i = (i + 1) & mask;
    objset[i] = o;
    objset_count++;
}

static bool objset_contains(Obj *o) {
    if (!objset_cap || !o) return false;
    size_t mask = objset_cap - 1, i = ptr_hash(o) & mask;
    while (objset[i]) {
        if (objset[i] == o) return true;
        i = (i + 1) & mask;
    }
    return false;
}

static void objset_remove(Obj *o) {
    size_t mask = objset_cap - 1, i = ptr_hash(o) & mask;
    while (objset[i]) {
        if (objset[i] == o) { objset[i] = (Obj *)1; objset_count--; return; }  // a tombstone
        i = (i + 1) & mask;
    }
}

// MARK: Classes

static int desc_slots(const char *d, int *ret) {
    int n = 0;
    d++;
    while (*d != ')') {
        if (*d == 'J' || *d == 'D') { n += 2; d++; continue; }
        n++;
        while (*d == '[') d++;
        if (*d == 'L') d = strchr(d, ';');
        d++;
    }
    d++;
    if (ret) *ret = *d == 'V' ? 0 : (*d == 'J' || *d == 'D') ? 2 : 1;
    return n;
}

Class *vm_native_class(const char *name, const char *super, int kind) {
    for (Class *c = classes; c; c = c->next)
        if (strcmp(c->name, name) == 0) return c;
    Class *c = calloc(1, sizeof(Class));
    c->name = strdup(name);
    c->native_ = true;
    c->kind = kind;
    c->initialized = true;
    c->super = super ? vm_native_class(super, strcmp(super, "java/lang/Object") ? "java/lang/Object" : NULL, K_PLAIN) : NULL;
    c->next = classes;
    classes = c;
    return c;
}

static void add_native(const char *cls, const char *name, const char *desc, void (*fn)(Thread *, Slot *, Slot *), bool is_static) {
    Class *c = vm_native_class(cls, "java/lang/Object", K_PLAIN);
    c->methods = realloc(c->methods, (c->nmethods + 1) * sizeof(Method));
    Method *m = &c->methods[c->nmethods++];
    memset(m, 0, sizeof *m);
    m->cls = c;
    m->name = name;
    m->desc = desc;
    m->native = fn;
    m->access = is_static ? 8 : 0;
    m->arg_slots = desc_slots(desc, &m->ret) + (is_static ? 0 : 1);
}

void vm_native(const char *cls, const char *name, const char *desc, void (*fn)(Thread *, Slot *, Slot *)) {
    add_native(cls, name, desc, fn, false);
}

void vm_native_static(const char *cls, const char *name, const char *desc, void (*fn)(Thread *, Slot *, Slot *)) {
    add_native(cls, name, desc, fn, true);
}

static uint16_t be16(const uint8_t *p) { return p[0] << 8 | p[1]; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static Class *load_class(const char *name) {
    char path[512];
    snprintf(path, sizeof path, "%s.class", name);
    int32_t size;
    uint8_t *d = jar_read(path, &size);
    if (!d || size < 10 || be32(d) != 0xCAFEBABE) { free(d); return NULL; }
    Class *c = calloc(1, sizeof(Class));
    const uint8_t *p = d + 8;
    c->ncp = be16(p); p += 2;
    c->cp = calloc(c->ncp, sizeof(CPEntry));
    for (int i = 1; i < c->ncp; i++) {
        CPEntry *e = &c->cp[i];
        e->tag = *p++;
        switch (e->tag) {
        case 1: {
            int len = be16(p);
            e->v.utf8 = strndup((const char *)p + 2, len);
            p += 2 + len;
            break;
        }
        case 3: e->v.i = (int32_t)be32(p); p += 4; break;
        case 4: { uint32_t b = be32(p); memcpy(&e->v.f, &b, 4); p += 4; break; }
        case 5: case 6: {
            uint64_t b = (uint64_t)be32(p) << 32 | be32(p + 4);
            memcpy(&e->v.j, &b, 8);
            p += 8;
            i++;
            break;
        }
        case 7: case 8: e->v.ref.a = be16(p); p += 2; break;
        case 9: case 10: case 11: case 12: e->v.ref.a = be16(p); e->v.ref.b = be16(p + 2); p += 4; break;
        default:
            vm_log("bad constant tag %d in %s", e->tag, name);
            free(d);
            return NULL;
        }
    }
    p += 2;  // access
    c->name = strdup(c->cp[c->cp[be16(p)].v.ref.a].v.utf8); p += 2;
    uint16_t super = be16(p); p += 2;
    c->ninterfaces = be16(p); p += 2;
    c->interfaces = calloc(c->ninterfaces + 1, sizeof(char *));
    for (int i = 0; i < c->ninterfaces; i++, p += 2) c->interfaces[i] = c->cp[c->cp[be16(p)].v.ref.a].v.utf8;
    c->next = classes;
    classes = c;
    c->super = super ? vm_class(c->cp[c->cp[super].v.ref.a].v.utf8) : NULL;
    c->ninstance = c->super ? c->super->ninstance : 0;
    c->kind = c->super ? (c->super->native_ ? K_INSTANCE : c->super->kind) : K_INSTANCE;

    c->nfields = be16(p); p += 2;
    c->fields = calloc(c->nfields + 1, sizeof(Field));
    for (int i = 0; i < c->nfields; i++) {
        Field *f = &c->fields[i];
        f->access = be16(p);
        f->name = c->cp[be16(p + 2)].v.utf8;
        f->desc = c->cp[be16(p + 4)].v.utf8;
        f->ref = f->desc[0] == 'L' || f->desc[0] == '[';
        f->slot = (f->access & 8) ? c->nstatics++ : c->ninstance++;
        int nattr = be16(p + 6);
        p += 8;
        for (int a = 0; a < nattr; a++) p += 6 + be32(p + 2);
    }
    c->statics = calloc(c->nstatics + 1, sizeof(Slot));
    // ConstantValue attributes are rare in these games; statics start at zero and <clinit> sets them.

    c->nmethods = be16(p); p += 2;
    c->methods = calloc(c->nmethods + 1, sizeof(Method));
    for (int i = 0; i < c->nmethods; i++) {
        Method *m = &c->methods[i];
        m->cls = c;
        m->access = be16(p);
        m->name = c->cp[be16(p + 2)].v.utf8;
        m->desc = c->cp[be16(p + 4)].v.utf8;
        m->arg_slots = desc_slots(m->desc, &m->ret) + ((m->access & 8) ? 0 : 1);
        int nattr = be16(p + 6);
        p += 8;
        for (int a = 0; a < nattr; a++) {
            const char *aname = c->cp[be16(p)].v.utf8;
            uint32_t alen = be32(p + 2);
            const uint8_t *ab = p + 6;
            if (strcmp(aname, "Code") == 0) {
                m->max_stack = be16(ab);
                m->max_locals = be16(ab + 2);
                m->code_len = be32(ab + 4);
                m->code = malloc(m->code_len);
                memcpy(m->code, ab + 8, m->code_len);
                const uint8_t *h = ab + 8 + m->code_len;
                m->nhandlers = be16(h);
                m->handlers = calloc(m->nhandlers + 1, sizeof(Handler));
                for (int k = 0; k < m->nhandlers; k++) {
                    const uint8_t *q = h + 2 + k * 8;
                    m->handlers[k] = (Handler){be16(q), be16(q + 2), be16(q + 4), be16(q + 6)};
                }
            }
            p += 6 + alen;
        }
        if (m->max_locals < m->arg_slots) m->max_locals = m->arg_slots;
    }
    free(d);
    return c;
}

Class *vm_class(const char *name) {
    for (Class *c = classes; c; c = c->next)
        if (strcmp(c->name, name) == 0) return c;
    if (name[0] == '[') return vm_native_class(name, "java/lang/Object", K_ARRAY);
    Class *c = load_class(name);
    if (c) return c;
    vm_log("missing class %s", name);
    return vm_native_class(name, "java/lang/Object", K_PLAIN);
}

static void init_class(Class *c) {
    if (c->initialized) return;
    c->initialized = true;
    if (c->super) init_class(c->super);
    Method *clinit = NULL;
    for (int i = 0; i < c->nmethods; i++)
        if (strcmp(c->methods[i].name, "<clinit>") == 0) clinit = &c->methods[i];
    if (clinit) vm_call(clinit, NULL, NULL);
}

Method *vm_find_method(Class *c, const char *name, const char *desc) {
    for (; c; c = c->super)
        for (int i = 0; i < c->nmethods; i++) {
            Method *m = &c->methods[i];
            if (strcmp(m->name, name) == 0 && strcmp(m->desc, desc) == 0) return m;
        }
    return NULL;
}

bool vm_is_subclass(Class *c, const char *name) {
    for (; c; c = c->super) {
        if (strcmp(c->name, name) == 0) return true;
        for (int i = 0; i < c->ninterfaces; i++)
            if (strcmp(c->interfaces[i], name) == 0) return true;
    }
    return false;
}

static bool instance_of(Obj *o, const char *name) {
    if (strcmp(name, "java/lang/Object") == 0) return true;
    if (o->kind == K_ARRAY) return strcmp(o->cls->name, name) == 0;
    return vm_is_subclass(o->cls, name);
}

static Field *find_field(Class *c, const char *name, Class **owner) {
    for (; c; c = c->super)
        for (int i = 0; i < c->nfields; i++)
            if (strcmp(c->fields[i].name, name) == 0) { *owner = c; return &c->fields[i]; }
    return NULL;
}

// MARK: Allocation

Obj *vm_alloc(Class *c, int kind, size_t extra) {
    Obj *o = calloc(1, sizeof(Obj) + extra);
    o->cls = c;
    o->kind = kind;
    o->next = heap;
    heap = o;
    vm_allocated += sizeof(Obj) + extra;
    objset_insert(o);
    return o;
}

Obj *vm_new_instance(Class *c) {
    if (c->native_) return vm_alloc(c, c->kind, 0);
    Obj *o = vm_alloc(c, K_INSTANCE, c->ninstance * sizeof(Slot));
    o->u.fields = (Slot *)(o + 1);
    return o;
}

size_t vm_elem_size(int etype) {
    switch (etype) {
    case T_BOOLEAN: case T_BYTE: return 1;
    case T_CHAR: case T_SHORT: return 2;
    case T_INT: case T_FLOAT: return 4;
    case T_LONG: case T_DOUBLE: return 8;
    default: return sizeof(Obj *);
    }
}

static const char *array_name(int etype) {
    switch (etype) {
    case T_BOOLEAN: return "[Z";
    case T_CHAR: return "[C";
    case T_FLOAT: return "[F";
    case T_DOUBLE: return "[D";
    case T_BYTE: return "[B";
    case T_SHORT: return "[S";
    case T_INT: return "[I";
    case T_LONG: return "[J";
    default: return "[Ljava/lang/Object;";
    }
}

Obj *vm_new_array(int etype, int32_t length, Class *cls) {
    Obj *o = vm_alloc(cls ? cls : vm_class(array_name(etype)), K_ARRAY, (size_t)length * vm_elem_size(etype));
    o->etype = etype;
    o->length = length;
    o->u.data = o + 1;
    return o;
}

Obj *vm_string_chars(const uint16_t *chars, int32_t length) {
    static Class *string_class;
    if (!string_class) string_class = vm_class("java/lang/String");
    Obj *o = vm_alloc(string_class, K_STRING, 0);
    o->length = length;
    o->u.data = calloc(length + 1, 2);
    vm_allocated += (size_t)length * 2;
    if (chars) memcpy(o->u.data, chars, (size_t)length * 2);
    return o;
}

Obj *vm_string(const char *utf8) {
    // Modified UTF-8, as class files store it, decoded to UTF-16.
    size_t n = strlen(utf8);
    uint16_t *buf = malloc((n + 1) * 2);
    int32_t len = 0;
    const uint8_t *s = (const uint8_t *)utf8;
    while (*s) {
        if (*s < 0x80) buf[len++] = *s++;
        else if ((*s & 0xE0) == 0xC0 && s[1]) { buf[len++] = (*s & 0x1F) << 6 | (s[1] & 0x3F); s += 2; }
        else if ((*s & 0xF0) == 0xE0 && s[1] && s[2]) { buf[len++] = (*s & 0x0F) << 12 | (s[1] & 0x3F) << 6 | (s[2] & 0x3F); s += 3; }
        else buf[len++] = *s++;
    }
    Obj *o = vm_string_chars(buf, len);
    free(buf);
    return o;
}

static Obj **interned;
static int ninterned, interned_cap;

Obj *vm_intern(Obj *s) {
    for (int i = 0; i < ninterned; i++)
        if (interned[i]->length == s->length && memcmp(interned[i]->u.data, s->u.data, (size_t)s->length * 2) == 0)
            return interned[i];
    if (ninterned == interned_cap) {
        interned_cap = interned_cap ? interned_cap * 2 : 64;
        interned = realloc(interned, interned_cap * sizeof(Obj *));
    }
    interned[ninterned++] = s;
    return s;
}

char *vm_cstring(Obj *s) {
    if (!s) return strdup("null");
    char *out = malloc(s->length + 1);
    uint16_t *c = s->u.data;
    for (int i = 0; i < s->length; i++) out[i] = c[i] < 256 ? (char)c[i] : '?';
    out[s->length] = 0;
    return out;
}

void vm_add_root(Obj **root) {
    if (nroots < 64) roots[nroots++] = root;
}

// MARK: Exceptions

void vm_throw(Thread *t, const char *cls, const char *msg) {
    Class *c = vm_class(cls);
    Obj *e = vm_alloc(c, K_THROWABLE, 0);
    e->u.ex.message = msg ? vm_string(msg) : NULL;
    t->exception = e;
}

// MARK: Threads

static Thread *new_thread(void) {
    Thread *t = calloc(1, sizeof(Thread));
    return t;
}

static void push_frame(Thread *t, Method *m, Slot *args) {
    Frame *top = t->depth ? &t->frames[t->depth - 1] : NULL;
    Slot *locals = top ? top->sp : t->stack;
    if (args) memmove(locals, args, m->arg_slots * sizeof(Slot));
    Frame *f = &t->frames[t->depth++];
    f->m = m;
    f->pc = 0;
    f->locals = locals;
    memset(locals + m->arg_slots, 0, (m->max_locals - m->arg_slots) * sizeof(Slot));
    f->sp = locals + m->max_locals;
}

Thread *vm_spawn(Obj *runnable, Obj *threadobj) {
    Method *run = vm_find_method(runnable->cls, "run", "()V");
    if (!run || run->native) { vm_log("thread without run()"); return NULL; }
    Thread *t = new_thread();
    t->obj = threadobj;
    Slot self = {.a = runnable};
    push_frame(t, run, &self);
    t->base = 0;
    t->wake = vm_now;
    t->next = vm_threads;
    vm_threads = t;
    return t;
}

static int interp(Thread *t, int budget);

bool vm_call(Method *m, Slot *args, Slot *ret) {
    Thread *t = vm_current;
    if (!t) {
        if (!event_thread) event_thread = new_thread();
        t = event_thread;
    }
    Thread *saved = vm_current;
    vm_current = t;
    int saved_base = t->base;
    t->base = t->depth;
    if (m->native) {
        Slot r = {0};
        m->native(t, args, &r);
        if (ret) *ret = r;
    } else {
        Frame *top = t->depth ? &t->frames[t->depth - 1] : NULL;
        Slot *where = top ? top->sp : t->stack;
        push_frame(t, m, args);
        while (t->depth > t->base) {
            interp(t, 1 << 30);
            t->yield = false;  // a nested call can't be suspended, so a sleep in it returns at once
        }
        if (ret && m->ret) *ret = where[0];
    }
    t->base = saved_base;
    vm_current = saved;
    bool ok = true;
    if (t->exception) {
        char *msg = t->exception->u.ex.message && t->exception->kind == K_THROWABLE ? vm_cstring(t->exception->u.ex.message) : NULL;
        vm_log("uncaught %s in %s.%s: %s", t->exception->cls->name, m->cls->name, m->name, msg ? msg : "");
        free(msg);
        t->exception = NULL;
        ok = false;
    }
    return ok;
}

void vm_run_threads(int64_t until, int budget) {
    // Runs whichever thread wakes first, moving the clock to its wake time, until all of them
    // sleep past `until` or the budget is spent (a thread busy-waiting never sleeps).
    while (budget > 0) {
        Thread *next = NULL;
        for (Thread *t = vm_threads; t; t = t->next)
            if (!t->done && (!next || t->wake < next->wake)) next = t;
        if (!next || next->wake > until) break;
        if (next->wake > vm_now) vm_now = next->wake;
        vm_current = next;
        int slice = budget < 50000 ? budget : 50000;
        budget -= slice - interp(next, slice);
        vm_current = NULL;
        if (next->depth == 0 || next->exception) {
            if (next->exception) {
                char *msg = next->exception->kind == K_THROWABLE && next->exception->u.ex.message ? vm_cstring(next->exception->u.ex.message) : NULL;
                vm_log("thread died: %s %s", next->exception->cls->name, msg ? msg : "");
                free(msg);
                next->exception = NULL;
            }
            next->done = true;
        }
        if (next->yield) next->yield = false;
        else if (!next->done && next->wake <= vm_now) next->wake = vm_now;  // out of slice: others go first
    }
    if (vm_now < until) vm_now = until;
    // Finished threads are dropped.
    for (Thread **p = &vm_threads; *p; ) {
        if ((*p)->done) { Thread *d = *p; *p = d->next; free(d); }
        else p = &(*p)->next;
    }
}

// MARK: Interpreter

static Class *cp_class(Class *c, int index) {
    CPEntry *e = &c->cp[index];
    if (!e->resolved) e->resolved = vm_class(c->cp[e->v.ref.a].v.utf8);
    return e->resolved;
}

static void cp_member(Class *c, int index, const char **cls, const char **name, const char **desc) {
    CPEntry *e = &c->cp[index];
    *cls = c->cp[c->cp[e->v.ref.a].v.ref.a].v.utf8;
    CPEntry *nt = &c->cp[e->v.ref.b];
    *name = c->cp[nt->v.ref.a].v.utf8;
    *desc = c->cp[nt->v.ref.b].v.utf8;
}

static Obj *class_object(Class *c) {
    if (!c->classobj) {
        c->classobj = vm_alloc(vm_class("java/lang/Class"), K_CLASS, 0);
        c->classobj->u.klass.of = c;
    }
    return c->classobj;
}

static Obj *multi_array(Class *cls, int32_t *dims, int ndims) {
    const char *name = cls->name;
    if (ndims == 1) {
        char e = name[1];
        int etype = e == 'Z' ? T_BOOLEAN : e == 'C' ? T_CHAR : e == 'F' ? T_FLOAT : e == 'D' ? T_DOUBLE : e == 'B' ? T_BYTE
                  : e == 'S' ? T_SHORT : e == 'I' ? T_INT : e == 'J' ? T_LONG : T_REF;
        return vm_new_array(etype, dims[0], cls);
    }
    Obj *a = vm_new_array(T_REF, dims[0], cls);
    Class *sub = vm_class(name + 1);
    for (int i = 0; i < dims[0]; i++) ((Obj **)a->u.data)[i] = multi_array(sub, dims + 1, ndims - 1);
    return a;
}

static int32_t rd4(const uint8_t *p) { return (int32_t)((uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]); }

static int instr_len(const uint8_t *code, uint32_t pc) {
    switch (code[pc]) {
    case 0xb9: case 0xba: return 5;
    default: return 3;
    }
}

// Runs t until it returns below its base, yields, or the budget runs out; returns what is left.
static int interp(Thread *t, int budget) {
    Frame *f;
    Method *m;
    uint8_t *code;
    Slot *sp, *locals;
    uint32_t pc;
    CPEntry *cp;

#define LOAD_FRAME() do { f = &t->frames[t->depth - 1]; m = f->m; code = m->code; sp = f->sp; locals = f->locals; pc = f->pc; cp = m->cls->cp; } while (0)
#define SAVE_FRAME() do { f->sp = sp; f->pc = pc; } while (0)
#define U1(o) (code[pc + (o)])
#define S1(o) ((int8_t)code[pc + (o)])
#define U2(o) ((uint16_t)(code[pc + (o)] << 8 | code[pc + (o) + 1]))
#define S2(o) ((int16_t)U2(o))
#define S4(o) ((int32_t)((uint32_t)code[pc + (o)] << 24 | code[pc + (o) + 1] << 16 | code[pc + (o) + 2] << 8 | code[pc + (o) + 3]))
#define PUSHI(x) ((sp++)->j = (int32_t)(x))
#define PUSHA(x) ((sp++)->a = (x))
#define PUSHJ(x) do { sp->j = (x); sp += 2; } while (0)
#define POPI() ((--sp)->i)
#define POPA() ((--sp)->a)
#define POPJ() (sp -= 2, sp->j)
#define THROW(cls, msg) do { SAVE_FRAME(); vm_throw(t, cls, msg); goto exception; } while (0)
#define NULLCHECK(o) do { if (!(o)) THROW("java/lang/NullPointerException", NULL); } while (0)
#define ARRAYCHECK(a, i) do { NULLCHECK(a); if ((uint32_t)(i) >= (uint32_t)(a)->length) THROW("java/lang/ArrayIndexOutOfBoundsException", NULL); } while (0)

    if (t->depth <= t->base) return budget;
    LOAD_FRAME();
    if (t->exception) goto exception;

    while (budget-- > 0) {
        uint8_t op = code[pc];
        switch (op) {
        case 0x00: pc++; break;
        case 0x01: PUSHA(NULL); pc++; break;
        case 0x02: case 0x03: case 0x04: case 0x05: case 0x06: case 0x07: case 0x08: PUSHI(op - 0x03); pc++; break;
        case 0x09: case 0x0a: PUSHJ(op - 0x09); pc++; break;
        case 0x0b: case 0x0c: case 0x0d: sp->j = 0; (sp++)->f = (float)(op - 0x0b); pc++; break;
        case 0x0e: case 0x0f: sp->d = (double)(op - 0x0e); sp += 2; pc++; break;
        case 0x10: PUSHI(S1(1)); pc += 2; break;
        case 0x11: PUSHI(S2(1)); pc += 3; break;
        case 0x12: case 0x13: {
            int index = op == 0x12 ? U1(1) : U2(1);
            CPEntry *e = &cp[index];
            if (e->tag == 3) PUSHI(e->v.i);
            else if (e->tag == 4) { sp->j = 0; (sp++)->f = e->v.f; }
            else if (e->tag == 8) {
                if (!e->resolved) e->resolved = vm_intern(vm_string(cp[e->v.ref.a].v.utf8));
                PUSHA(e->resolved);
            } else if (e->tag == 7) PUSHA(class_object(cp_class(m->cls, index)));
            else PUSHA(NULL);
            pc += op == 0x12 ? 2 : 3;
            break;
        }
        case 0x14: { CPEntry *e = &cp[U2(1)]; sp->j = e->v.j; sp += 2; pc += 3; break; }
        case 0x15: case 0x17: case 0x19: *sp++ = locals[U1(1)]; pc += 2; break;
        case 0x16: case 0x18: sp[0] = locals[U1(1)]; sp += 2; pc += 2; break;
        case 0x1a: case 0x1b: case 0x1c: case 0x1d: *sp++ = locals[op - 0x1a]; pc++; break;
        case 0x1e: case 0x1f: case 0x20: case 0x21: sp[0] = locals[op - 0x1e]; sp += 2; pc++; break;
        case 0x22: case 0x23: case 0x24: case 0x25: *sp++ = locals[op - 0x22]; pc++; break;
        case 0x26: case 0x27: case 0x28: case 0x29: sp[0] = locals[op - 0x26]; sp += 2; pc++; break;
        case 0x2a: case 0x2b: case 0x2c: case 0x2d: *sp++ = locals[op - 0x2a]; pc++; break;
        case 0x2e: case 0x2f: case 0x30: case 0x31: case 0x32: case 0x33: case 0x34: case 0x35: {
            int32_t i = POPI();
            Obj *a = POPA();
            ARRAYCHECK(a, i);
            switch (op) {
            case 0x2e: PUSHI(((int32_t *)a->u.data)[i]); break;
            case 0x2f: PUSHJ(((int64_t *)a->u.data)[i]); break;
            case 0x30: sp->j = 0; (sp++)->f = ((float *)a->u.data)[i]; break;
            case 0x31: sp->d = ((double *)a->u.data)[i]; sp += 2; break;
            case 0x32: PUSHA(((Obj **)a->u.data)[i]); break;
            case 0x33: PUSHI(((int8_t *)a->u.data)[i]); break;
            case 0x34: PUSHI(((uint16_t *)a->u.data)[i]); break;
            case 0x35: PUSHI(((int16_t *)a->u.data)[i]); break;
            }
            pc++;
            break;
        }
        case 0x36: case 0x38: case 0x3a: locals[U1(1)] = *--sp; pc += 2; break;
        case 0x37: case 0x39: sp -= 2; locals[U1(1)] = sp[0]; pc += 2; break;
        case 0x3b: case 0x3c: case 0x3d: case 0x3e: locals[op - 0x3b] = *--sp; pc++; break;
        case 0x3f: case 0x40: case 0x41: case 0x42: sp -= 2; locals[op - 0x3f] = sp[0]; pc++; break;
        case 0x43: case 0x44: case 0x45: case 0x46: locals[op - 0x43] = *--sp; pc++; break;
        case 0x47: case 0x48: case 0x49: case 0x4a: sp -= 2; locals[op - 0x47] = sp[0]; pc++; break;
        case 0x4b: case 0x4c: case 0x4d: case 0x4e: locals[op - 0x4b] = *--sp; pc++; break;
        case 0x4f: case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: {
            Slot v;
            if (op == 0x50 || op == 0x52) { sp -= 2; v = sp[0]; } else v = *--sp;
            int32_t i = POPI();
            Obj *a = POPA();
            ARRAYCHECK(a, i);
            switch (op) {
            case 0x4f: ((int32_t *)a->u.data)[i] = v.i; break;
            case 0x50: ((int64_t *)a->u.data)[i] = v.j; break;
            case 0x51: ((float *)a->u.data)[i] = v.f; break;
            case 0x52: ((double *)a->u.data)[i] = v.d; break;
            case 0x53:
                if (v.a && a->etype == T_REF && a->cls->name[1] == 'L' && strcmp(a->cls->name, "[Ljava/lang/Object;") != 0) {
                    char want[256];
                    snprintf(want, sizeof want, "%.*s", (int)strlen(a->cls->name) - 3, a->cls->name + 2);
                    if (!instance_of(v.a, want)) THROW("java/lang/ArrayStoreException", NULL);
                }
                ((Obj **)a->u.data)[i] = v.a;
                break;
            case 0x54: ((int8_t *)a->u.data)[i] = (int8_t)v.i; break;
            case 0x55: ((uint16_t *)a->u.data)[i] = (uint16_t)v.i; break;
            case 0x56: ((int16_t *)a->u.data)[i] = (int16_t)v.i; break;
            }
            pc++;
            break;
        }
        case 0x57: sp--; pc++; break;
        case 0x58: sp -= 2; pc++; break;
        case 0x59: sp[0] = sp[-1]; sp++; pc++; break;
        case 0x5a: { Slot a = sp[-1], b = sp[-2]; sp[-2] = a; sp[-1] = b; sp[0] = a; sp++; pc++; break; }
        case 0x5b: { Slot a = sp[-1], b = sp[-2], c = sp[-3]; sp[-3] = a; sp[-2] = c; sp[-1] = b; sp[0] = a; sp++; pc++; break; }
        case 0x5c: sp[0] = sp[-2]; sp[1] = sp[-1]; sp += 2; pc++; break;
        case 0x5d: { Slot a = sp[-1], b = sp[-2], c = sp[-3]; sp[-3] = b; sp[-2] = a; sp[-1] = c; sp[0] = b; sp[1] = a; sp += 2; pc++; break; }
        case 0x5e: { Slot a = sp[-1], b = sp[-2], c = sp[-3], d = sp[-4]; sp[-4] = b; sp[-3] = a; sp[-2] = d; sp[-1] = c; sp[0] = b; sp[1] = a; sp += 2; pc++; break; }
        case 0x5f: { Slot a = sp[-1]; sp[-1] = sp[-2]; sp[-2] = a; pc++; break; }
        case 0x60: { int32_t b = POPI(), a = POPI(); PUSHI((int32_t)((uint32_t)a + (uint32_t)b)); pc++; break; }
        case 0x61: { int64_t b = POPJ(), a = POPJ(); PUSHJ((int64_t)((uint64_t)a + (uint64_t)b)); pc++; break; }
        case 0x62: { float b = (--sp)->f, a = (--sp)->f; sp->j = 0; (sp++)->f = a + b; pc++; break; }
        case 0x63: { sp -= 2; double b = sp->d; sp -= 2; double a = sp->d; sp->d = a + b; sp += 2; pc++; break; }
        case 0x64: { int32_t b = POPI(), a = POPI(); PUSHI((int32_t)((uint32_t)a - (uint32_t)b)); pc++; break; }
        case 0x65: { int64_t b = POPJ(), a = POPJ(); PUSHJ((int64_t)((uint64_t)a - (uint64_t)b)); pc++; break; }
        case 0x66: { float b = (--sp)->f, a = (--sp)->f; sp->j = 0; (sp++)->f = a - b; pc++; break; }
        case 0x67: { sp -= 2; double b = sp->d; sp -= 2; double a = sp->d; sp->d = a - b; sp += 2; pc++; break; }
        case 0x68: { int32_t b = POPI(), a = POPI(); PUSHI((int32_t)((uint32_t)a * (uint32_t)b)); pc++; break; }
        case 0x69: { int64_t b = POPJ(), a = POPJ(); PUSHJ((int64_t)((uint64_t)a * (uint64_t)b)); pc++; break; }
        case 0x6a: { float b = (--sp)->f, a = (--sp)->f; sp->j = 0; (sp++)->f = a * b; pc++; break; }
        case 0x6b: { sp -= 2; double b = sp->d; sp -= 2; double a = sp->d; sp->d = a * b; sp += 2; pc++; break; }
        case 0x6c: case 0x70: {
            int32_t b = POPI(), a = POPI();
            if (b == 0) THROW("java/lang/ArithmeticException", "/ by zero");
            if (b == -1) PUSHI(op == 0x6c ? (int32_t)(0u - (uint32_t)a) : 0);
            else PUSHI(op == 0x6c ? a / b : a % b);
            pc++;
            break;
        }
        case 0x6d: case 0x71: {
            int64_t b = POPJ(), a = POPJ();
            if (b == 0) THROW("java/lang/ArithmeticException", "/ by zero");
            if (b == -1) PUSHJ(op == 0x6d ? (int64_t)(0ull - (uint64_t)a) : 0);
            else PUSHJ(op == 0x6d ? a / b : a % b);
            pc++;
            break;
        }
        case 0x6e: { float b = (--sp)->f, a = (--sp)->f; sp->j = 0; (sp++)->f = a / b; pc++; break; }
        case 0x6f: { sp -= 2; double b = sp->d; sp -= 2; double a = sp->d; sp->d = a / b; sp += 2; pc++; break; }
        case 0x72: { float b = (--sp)->f, a = (--sp)->f; sp->j = 0; (sp++)->f = __builtin_fmodf(a, b); pc++; break; }
        case 0x73: { sp -= 2; double b = sp->d; sp -= 2; double a = sp->d; sp->d = __builtin_fmod(a, b); sp += 2; pc++; break; }
        case 0x74: sp[-1].j = (int32_t)(0u - (uint32_t)sp[-1].i); pc++; break;
        case 0x75: sp[-2].j = (int64_t)(0ull - (uint64_t)sp[-2].j); pc++; break;
        case 0x76: sp[-1].f = -sp[-1].f; pc++; break;
        case 0x77: sp[-2].d = -sp[-2].d; pc++; break;
        case 0x78: { int32_t b = POPI(), a = POPI(); PUSHI((int32_t)((uint32_t)a << (b & 31))); pc++; break; }
        case 0x79: { int32_t b = POPI(); int64_t a = POPJ(); PUSHJ((int64_t)((uint64_t)a << (b & 63))); pc++; break; }
        case 0x7a: { int32_t b = POPI(), a = POPI(); PUSHI(a >> (b & 31)); pc++; break; }
        case 0x7b: { int32_t b = POPI(); int64_t a = POPJ(); PUSHJ(a >> (b & 63)); pc++; break; }
        case 0x7c: { int32_t b = POPI(), a = POPI(); PUSHI((int32_t)((uint32_t)a >> (b & 31))); pc++; break; }
        case 0x7d: { int32_t b = POPI(); int64_t a = POPJ(); PUSHJ((int64_t)((uint64_t)a >> (b & 63))); pc++; break; }
        case 0x7e: { int32_t b = POPI(), a = POPI(); PUSHI(a & b); pc++; break; }
        case 0x7f: { int64_t b = POPJ(), a = POPJ(); PUSHJ(a & b); pc++; break; }
        case 0x80: { int32_t b = POPI(), a = POPI(); PUSHI(a | b); pc++; break; }
        case 0x81: { int64_t b = POPJ(), a = POPJ(); PUSHJ(a | b); pc++; break; }
        case 0x82: { int32_t b = POPI(), a = POPI(); PUSHI(a ^ b); pc++; break; }
        case 0x83: { int64_t b = POPJ(), a = POPJ(); PUSHJ(a ^ b); pc++; break; }
        case 0x84: locals[U1(1)].j = (int32_t)((uint32_t)locals[U1(1)].i + (uint32_t)S1(2)); pc += 3; break;
        case 0x85: { int32_t a = POPI(); PUSHJ(a); pc++; break; }
        case 0x86: { int32_t a = POPI(); sp->j = 0; (sp++)->f = (float)a; pc++; break; }
        case 0x87: { int32_t a = POPI(); sp->d = a; sp += 2; pc++; break; }
        case 0x88: { int64_t a = POPJ(); PUSHI((int32_t)a); pc++; break; }
        case 0x89: { int64_t a = POPJ(); sp->j = 0; (sp++)->f = (float)a; pc++; break; }
        case 0x8a: { int64_t a = POPJ(); sp->d = (double)a; sp += 2; pc++; break; }
        case 0x8b: case 0x8c: case 0x8d: {
            float a = (--sp)->f;
            double d = a;
            if (op == 0x8b) PUSHI(d != d ? 0 : d >= 2147483647.0 ? INT32_MAX : d <= -2147483648.0 ? INT32_MIN : (int32_t)d);
            else if (op == 0x8c) PUSHJ(d != d ? 0 : d >= 9.2233720368547758e18 ? INT64_MAX : d <= -9.2233720368547758e18 ? INT64_MIN : (int64_t)d);
            else { sp->d = d; sp += 2; }
            pc++;
            break;
        }
        case 0x8e: case 0x8f: case 0x90: {
            sp -= 2;
            double d = sp->d;
            if (op == 0x8e) PUSHI(d != d ? 0 : d >= 2147483647.0 ? INT32_MAX : d <= -2147483648.0 ? INT32_MIN : (int32_t)d);
            else if (op == 0x8f) PUSHJ(d != d ? 0 : d >= 9.2233720368547758e18 ? INT64_MAX : d <= -9.2233720368547758e18 ? INT64_MIN : (int64_t)d);
            else { sp->j = 0; (sp++)->f = (float)d; }
            pc++;
            break;
        }
        case 0x91: sp[-1].j = (int8_t)sp[-1].i; pc++; break;
        case 0x92: sp[-1].j = (uint16_t)sp[-1].i; pc++; break;
        case 0x93: sp[-1].j = (int16_t)sp[-1].i; pc++; break;
        case 0x94: { int64_t b = POPJ(), a = POPJ(); PUSHI(a < b ? -1 : a > b); pc++; break; }
        case 0x95: case 0x96: {
            float b = (--sp)->f, a = (--sp)->f;
            PUSHI(a < b ? -1 : a > b ? 1 : a == b ? 0 : op == 0x95 ? -1 : 1);
            pc++;
            break;
        }
        case 0x97: case 0x98: {
            sp -= 2; double b = sp->d; sp -= 2; double a = sp->d;
            PUSHI(a < b ? -1 : a > b ? 1 : a == b ? 0 : op == 0x97 ? -1 : 1);
            pc++;
            break;
        }
        case 0x99: case 0x9a: case 0x9b: case 0x9c: case 0x9d: case 0x9e: {
            int32_t a = POPI();
            bool jump = op == 0x99 ? a == 0 : op == 0x9a ? a != 0 : op == 0x9b ? a < 0 : op == 0x9c ? a >= 0 : op == 0x9d ? a > 0 : a <= 0;
            pc += jump ? S2(1) : 3;
            break;
        }
        case 0x9f: case 0xa0: case 0xa1: case 0xa2: case 0xa3: case 0xa4: {
            int32_t b = POPI(), a = POPI();
            bool jump = op == 0x9f ? a == b : op == 0xa0 ? a != b : op == 0xa1 ? a < b : op == 0xa2 ? a >= b : op == 0xa3 ? a > b : a <= b;
            pc += jump ? S2(1) : 3;
            break;
        }
        case 0xa5: case 0xa6: { Obj *b = POPA(), *a = POPA(); pc += ((a == b) == (op == 0xa5)) ? S2(1) : 3; break; }
        case 0xa7: pc += S2(1); break;
        case 0xa8: PUSHI(pc + 3); pc += S2(1); break;
        case 0xa9: pc = locals[U1(1)].i; break;
        case 0xaa: {
            uint32_t q = (pc + 4) & ~3u;
            int32_t def = rd4(code + q), lo = rd4(code + q + 4), hi = rd4(code + q + 8), key = POPI();
            pc += (key >= lo && key <= hi) ? rd4(code + q + 12 + (uint32_t)(key - lo) * 4) : def;
            break;
        }
        case 0xab: {
            uint32_t q = (pc + 4) & ~3u;
            int32_t target = rd4(code + q), n = rd4(code + q + 4), key = POPI();
            for (int32_t k = 0; k < n; k++)
                if (rd4(code + q + 8 + k * 8) == key) { target = rd4(code + q + 12 + k * 8); break; }
            pc += target;
            break;
        }
        case 0xac: case 0xad: case 0xae: case 0xaf: case 0xb0: case 0xb1: {
            int n = op == 0xb1 ? 0 : (op == 0xad || op == 0xaf) ? 2 : 1;
            Slot r0 = n ? sp[-n] : (Slot){0};
            Slot *dest = locals;
            t->depth--;
            if (n) dest[0] = r0;
            if (t->depth <= t->base) {
                if (t->depth > 0) t->frames[t->depth - 1].sp = dest + n;
                return budget;
            }
            LOAD_FRAME();
            sp = dest + n;
            pc += instr_len(code, pc);
            break;
        }
        case 0xb2: case 0xb3: {
            CPEntry *e = &cp[U2(1)];
            if (!e->resolved) {
                const char *cn, *fn, *fd;
                cp_member(m->cls, U2(1), &cn, &fn, &fd);
                Class *owner, *c = vm_class(cn);
                Field *fld = find_field(c, fn, &owner);
                if (!fld) THROW("java/lang/NoSuchFieldError", fn);
                SAVE_FRAME();
                init_class(owner);
                if (t->exception) goto exception;
                e->resolved = &owner->statics[fld->slot];
                e->resolved2 = (void *)(uintptr_t)(fd[0] == 'J' || fd[0] == 'D');
            }
            Slot *s = e->resolved;
            bool wide = e->resolved2 != NULL;
            if (op == 0xb2) { *sp = *s; sp += wide ? 2 : 1; }
            else { sp -= wide ? 2 : 1; *s = *sp; }
            pc += 3;
            break;
        }
        case 0xb4: case 0xb5: {
            CPEntry *e = &cp[U2(1)];
            if (!e->resolved) {
                const char *cn, *fn, *fd;
                cp_member(m->cls, U2(1), &cn, &fn, &fd);
                Class *owner;
                Field *fld = find_field(vm_class(cn), fn, &owner);
                if (!fld) THROW("java/lang/NoSuchFieldError", fn);
                e->resolved = (void *)(uintptr_t)(fld->slot + 1);
                e->resolved2 = (void *)(uintptr_t)(fd[0] == 'J' || fd[0] == 'D');
            }
            int slot = (int)(uintptr_t)e->resolved - 1;
            bool wide = e->resolved2 != NULL;
            if (op == 0xb4) {
                Obj *o = POPA();
                NULLCHECK(o);
                *sp = o->u.fields[slot];
                sp += wide ? 2 : 1;
            } else {
                sp -= wide ? 2 : 1;
                Slot v = *sp;
                Obj *o = POPA();
                NULLCHECK(o);
                o->u.fields[slot] = v;
            }
            pc += 3;
            break;
        }
        case 0xb6: case 0xb7: case 0xb8: case 0xb9: {
            int index = U2(1);
            CPEntry *e = &cp[index];
            Method *callee;
            if (!e->resolved) {
                const char *cn, *mn, *md;
                cp_member(m->cls, index, &cn, &mn, &md);
                Class *c = vm_class(cn);
                if (op == 0xb8) { SAVE_FRAME(); init_class(c); if (t->exception) goto exception; }
                Method *found = vm_find_method(c, mn, md);
                if (!found && (op == 0xb6 || op == 0xb9)) {
                    // Declared on an interface or found only on the receiver: keep the name to look it up per call.
                    static Method stub;
                    found = &stub;
                }
                if (!found) {
                    vm_log("missing method %s.%s%s", cn, mn, md);
                    THROW("java/lang/NoSuchMethodError", mn);
                }
                e->resolved = found;
            }
            callee = e->resolved;
            if (op == 0xb6 || op == 0xb9) {
                const char *cn, *mn, *md;
                int nargs;
                if (callee->name) { mn = callee->name; md = callee->desc; nargs = callee->arg_slots; }
                else { cp_member(m->cls, index, &cn, &mn, &md); nargs = desc_slots(md, NULL) + 1; }
                Obj *recv = sp[-nargs].a;
                NULLCHECK(recv);
                if (e->resolved2 == recv->cls) callee = e->resolved3;
                else {
                    Method *v = vm_find_method(recv->cls, mn, md);
                    if (!v) {
                        vm_log("missing method %s.%s%s", recv->cls->name, mn, md);
                        THROW("java/lang/AbstractMethodError", mn);
                    }
                    e->resolved2 = recv->cls;
                    e->resolved3 = v;
                    callee = v;
                }
            } else if (op == 0xb7) {
                NULLCHECK(sp[-callee->arg_slots].a);
            }
            Slot *args = sp - callee->arg_slots;
            if (callee->native) {
                SAVE_FRAME();
                f->sp = sp;
                Slot r = {0};
                callee->native(t, args, &r);
                if (t->exception) { f->sp = args; goto exception; }
                sp = args;
                if (callee->ret == 1) *sp++ = r;
                else if (callee->ret == 2) { *sp = r; sp += 2; }
                pc += op == 0xb9 ? 5 : 3;
                if (t->yield && t->depth > t->base) { SAVE_FRAME(); return budget; }
                if (midp_exit) { SAVE_FRAME(); return budget; }
                break;
            }
            if (!callee->code) THROW("java/lang/AbstractMethodError", callee->name);
            if (t->depth >= FRAME_MAX || args + callee->max_locals + callee->max_stack + 8 >= t->stack + 16384)
                THROW("java/lang/StackOverflowError", NULL);
            f->pc = pc;
            f->sp = args;
            Frame *nf = &t->frames[t->depth++];
            nf->m = callee;
            nf->pc = 0;
            nf->locals = args;
            memset(args + callee->arg_slots, 0, (callee->max_locals - callee->arg_slots) * sizeof(Slot));
            nf->sp = args + callee->max_locals;
            LOAD_FRAME();
            break;
        }
        case 0xbb: {
            Class *c = cp_class(m->cls, U2(1));
            SAVE_FRAME();
            init_class(c);
            if (t->exception) goto exception;
            PUSHA(vm_new_instance(c));
            pc += 3;
            break;
        }
        case 0xbc: {
            int32_t n = POPI();
            if (n < 0) THROW("java/lang/NegativeArraySizeException", NULL);
            PUSHA(vm_new_array(U1(1), n, NULL));
            pc += 2;
            break;
        }
        case 0xbd: {
            int32_t n = POPI();
            if (n < 0) THROW("java/lang/NegativeArraySizeException", NULL);
            Class *ec = cp_class(m->cls, U2(1));
            char name[512];
            if (ec->name[0] == '[') snprintf(name, sizeof name, "[%s", ec->name);
            else snprintf(name, sizeof name, "[L%s;", ec->name);
            PUSHA(vm_new_array(T_REF, n, vm_class(name)));
            pc += 3;
            break;
        }
        case 0xbe: { Obj *a = POPA(); NULLCHECK(a); PUSHI(a->length); pc++; break; }
        case 0xbf: {
            Obj *e = POPA();
            NULLCHECK(e);
            SAVE_FRAME();
            t->exception = e;
            goto exception;
        }
        case 0xc0: case 0xc1: {
            Obj *o = sp[-1].a;
            Class *c = cp_class(m->cls, U2(1));
            bool ok = o && instance_of(o, c->name);
            if (op == 0xc0) {
                if (o && !ok) THROW("java/lang/ClassCastException", c->name);
            } else sp[-1].j = ok;
            pc += 3;
            break;
        }
        case 0xc2: case 0xc3: sp--; pc++; break;
        case 0xc4: {
            uint8_t wop = U1(1);
            uint16_t index = U2(2);
            if (wop == 0x84) { locals[index].j = (int32_t)((uint32_t)locals[index].i + (uint32_t)S2(4)); pc += 6; break; }
            if (wop >= 0x15 && wop <= 0x19) { *sp = locals[index]; sp += (wop == 0x16 || wop == 0x18) ? 2 : 1; }
            else if (wop >= 0x36 && wop <= 0x3a) { sp -= (wop == 0x37 || wop == 0x39) ? 2 : 1; locals[index] = *sp; }
            else if (wop == 0xa9) { pc = locals[index].i; break; }
            pc += 4;
            break;
        }
        case 0xc5: {
            int nd = U1(3);
            int32_t dims[16];
            for (int k = nd - 1; k >= 0; k--) dims[k] = POPI();
            for (int k = 0; k < nd; k++) if (dims[k] < 0) THROW("java/lang/NegativeArraySizeException", NULL);
            PUSHA(multi_array(cp_class(m->cls, U2(1)), dims, nd));
            pc += 4;
            break;
        }
        case 0xc6: { Obj *a = POPA(); pc += !a ? S2(1) : 3; break; }
        case 0xc7: { Obj *a = POPA(); pc += a ? S2(1) : 3; break; }
        case 0xc8: pc += S4(1); break;
        case 0xc9: PUSHI(pc + 5); pc += S4(1); break;
        default:
            vm_log("unknown opcode 0x%02x in %s.%s", op, m->cls->name, m->name);
            THROW("java/lang/VerifyError", NULL);
        }
        continue;

    exception:
        // Unwinds to the nearest handler for t->exception.
        for (;;) {
            f = &t->frames[t->depth - 1];
            m = f->m;
            Obj *ex = t->exception;
            int found = -1;
            for (int k = 0; k < m->nhandlers; k++) {
                Handler *h = &m->handlers[k];
                if (f->pc < h->start || f->pc >= h->end) continue;
                if (h->type) {
                    Class *hc = cp_class(m->cls, h->type);
                    if (!vm_is_subclass(ex->cls, hc->name)) continue;
                }
                found = h->handler;
                break;
            }
            if (found >= 0) {
                t->exception = NULL;
                f->sp = f->locals + m->max_locals;
                f->sp->a = ex;
                f->sp++;
                f->pc = found;
                LOAD_FRAME();
                break;
            }
            t->depth--;
            if (t->depth <= t->base) return budget;
        }
    }
    SAVE_FRAME();
    return 0;
}

// MARK: Garbage collection

static Obj **mark_stack;
static size_t mark_top, mark_cap;

static void mark(Obj *o) {
    if (!o || o->marked) return;
    o->marked = 1;
    if (mark_top == mark_cap) {
        mark_cap = mark_cap ? mark_cap * 2 : 1024;
        mark_stack = realloc(mark_stack, mark_cap * sizeof(Obj *));
    }
    mark_stack[mark_top++] = o;
}

static void mark_class(Class *c) {
    for (Class *k = c; k; k = k->super) {
        for (int i = 0; i < k->nfields; i++)
            if ((k->fields[i].access & 8) && k->fields[i].ref) mark(k->statics[k->fields[i].slot].a);
        if (k->classobj) mark(k->classobj);
    }
}

static void scan(Obj *o) {
    switch (o->kind) {
    case K_INSTANCE:
        for (Class *c = o->cls; c; c = c->super)
            for (int i = 0; i < c->nfields; i++)
                if (!(c->fields[i].access & 8) && c->fields[i].ref) mark(o->u.fields[c->fields[i].slot].a);
        break;
    case K_ARRAY:
        if (o->etype == T_REF)
            for (int i = 0; i < o->length; i++) mark(((Obj **)o->u.data)[i]);
        break;
    case K_GRAPHICS: mark(o->u.gfx.image); mark(o->u.gfx.font); break;
    case K_STREAM: mark(o->u.st.backing); mark(o->u.st.inner); break;
    case K_THREAD: mark(o->u.thr.runnable); break;
    case K_THROWABLE: mark(o->u.ex.message); break;
    }
}

static void scan_thread(Thread *t) {
    if (t->exception) mark(t->exception);
    mark(t->obj);
    if (!t->depth) return;
    Slot *top = t->frames[t->depth - 1].sp;
    for (Slot *s = t->stack; s < top; s++)
        if (objset_contains(s->a)) mark(s->a);
}

static void free_obj(Obj *o) {
    switch (o->kind) {
    case K_STRING: free(o->u.data); break;
    case K_SBUF: free(o->u.sb.chars); break;
    case K_IMAGE: vm_allocated -= (size_t)o->u.img.w * o->u.img.h * 4; free(o->u.img.pixels); break;
    case K_STREAM: if (!o->u.st.backing) free(o->u.st.bytes); break;
    case K_RECORDSTORE: free(o->u.rs.name); break;
    case K_AUDIO: if (o->u.au.clip) midi_free(o->u.au.clip); break;
    }
    objset_remove(o);
    free(o);
}

void vm_gc(void) {
    for (Class *c = classes; c; c = c->next) mark_class(c);
    for (int i = 0; i < ninterned; i++) mark(interned[i]);
    for (int i = 0; i < nroots; i++) mark(*roots[i]);
    for (Thread *t = vm_threads; t; t = t->next) scan_thread(t);
    if (event_thread) scan_thread(event_thread);
    while (mark_top) scan(mark_stack[--mark_top]);
    size_t live = 0;
    for (Obj **p = &heap; *p; ) {
        Obj *o = *p;
        if (o->marked) {
            o->marked = 0;
            live++;
            p = &o->next;
        } else {
            *p = o->next;
            free_obj(o);
        }
    }
    vm_allocated = 0;
    for (Obj *o = heap; o; o = o->next) {
        vm_allocated += sizeof(Obj);
        if (o->kind == K_IMAGE) vm_allocated += (size_t)o->u.img.w * o->u.img.h * 4;
        else if (o->kind == K_ARRAY) vm_allocated += (size_t)o->length * vm_elem_size(o->etype);
        else if (o->kind == K_STRING) vm_allocated += (size_t)o->length * 2;
    }
    (void)live;
}

// Frees everything, for unloading the game.
void vm_shutdown(void) {
    while (heap) { Obj *o = heap; heap = o->next; free_obj(o); }
    while (vm_threads) { Thread *t = vm_threads; vm_threads = t->next; free(t); }
    free(event_thread);
    event_thread = NULL;
    while (classes) {
        Class *c = classes;
        classes = c->next;
        if (!c->native_) {
            for (int i = 1; i < c->ncp; i++) if (c->cp[i].tag == 1) free((void *)c->cp[i].v.utf8);
            for (int i = 0; i < c->nmethods; i++) { free(c->methods[i].code); free(c->methods[i].handlers); }
            free(c->cp);
            free(c->fields);
            free(c->statics);
            free(c->interfaces);
        }
        free(c->methods);
        free((void *)c->name);
        free(c);
    }
    free(interned);
    interned = NULL;
    ninterned = interned_cap = 0;
    free(objset);
    objset = NULL;
    objset_cap = objset_count = 0;
    nroots = 0;
    vm_allocated = 0;
    vm_now = 0;
    vm_current = NULL;
}
