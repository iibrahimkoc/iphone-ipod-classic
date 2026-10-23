// The CLDC classes the games use: java.lang (Object, String, StringBuffer, Integer, Math, System,
// Thread...), java.util.Random and the java.io byte streams.
#include "jvm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define THIS (args[0].a)
#define ARG(n) (args[n])
#define CHARS(s) ((uint16_t *)(s)->u.data)
#define RETI(x) (ret->j = (int32_t)(x))
#define RETA(x) (ret->a = (x))
#define NATIVE(fn) static void fn(Thread *t, Slot *args, Slot *ret)
#define NPE(o) do { if (!(o)) { vm_throw(t, "java/lang/NullPointerException", NULL); return; } } while (0)

static Obj *string_from(const char *s) { return vm_string(s); }

static Obj *string_of_int(int64_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", (long long)v);
    return string_from(buf);
}

// MARK: Object, Class, Throwable

NATIVE(object_init) { (void)t; (void)args; (void)ret; }
NATIVE(object_getclass) {
    (void)t;
    Class *c = THIS->cls;
    if (!c->classobj) {
        c->classobj = vm_alloc(vm_class("java/lang/Class"), K_CLASS, 0);
        c->classobj->u.klass.of = c;
    }
    RETA(c->classobj);
}
NATIVE(object_hashcode) { (void)t; RETI((int32_t)((uintptr_t)THIS >> 4)); }
NATIVE(object_equals) { (void)t; RETI(THIS == ARG(1).a); }
NATIVE(object_tostring) {
    (void)t;
    char buf[300];
    snprintf(buf, sizeof buf, "%s@%x", THIS->cls->name, (unsigned)((uintptr_t)THIS >> 4));
    RETA(string_from(buf));
}

NATIVE(class_getname) {
    (void)t;
    char *name = strdup(THIS->u.klass.of->name);
    for (char *p = name; *p; p++) if (*p == '/') *p = '.';
    RETA(string_from(name));
    free(name);
}

Obj *lib_resource_stream(const char *name);

NATIVE(class_getresourceasstream) {
    NPE(ARG(1).a);
    char *name = vm_cstring(ARG(1).a);
    RETA(lib_resource_stream(name));
    free(name);
}

NATIVE(throwable_init) { (void)t; (void)args; (void)ret; }
NATIVE(throwable_init_msg) { (void)t; (void)ret; THIS->u.ex.message = ARG(1).a; }
NATIVE(throwable_getmessage) { (void)t; RETA(THIS->kind == K_THROWABLE ? THIS->u.ex.message : NULL); }
NATIVE(throwable_tostring) {
    (void)t;
    char *msg = THIS->kind == K_THROWABLE && THIS->u.ex.message ? vm_cstring(THIS->u.ex.message) : NULL;
    char buf[512];
    snprintf(buf, sizeof buf, "%s%s%s", THIS->cls->name, msg ? ": " : "", msg ? msg : "");
    free(msg);
    for (char *p = buf; *p && *p != ':'; p++) if (*p == '/') *p = '.';
    RETA(string_from(buf));
}
NATIVE(throwable_print) {
    (void)t; (void)ret;
    char *msg = THIS->kind == K_THROWABLE && THIS->u.ex.message ? vm_cstring(THIS->u.ex.message) : NULL;
    vm_log("printStackTrace: %s %s", THIS->cls->name, msg ? msg : "");
    free(msg);
}

// MARK: String

static Obj *new_string(const uint16_t *chars, int32_t len) { return vm_string_chars(chars, len); }

// `new String(...)`: the object was made empty by `new`; its characters are put in place here.
static void set_chars(Obj *s, const uint16_t *chars, int32_t len) {
    free(s->u.data);
    s->u.data = calloc(len + 1, 2);
    if (chars) memcpy(s->u.data, chars, (size_t)len * 2);
    s->length = len;
    vm_allocated += (size_t)len * 2;
}

static void set_bytes(Obj *s, const int8_t *bytes, int32_t len) {
    // Treated as ISO-8859-1, which keeps ASCII text and the bytes the games stored.
    uint16_t *c = malloc((size_t)(len + 1) * 2);
    for (int32_t i = 0; i < len; i++) c[i] = (uint8_t)bytes[i];
    set_chars(s, c, len);
    free(c);
}

NATIVE(string_init) { (void)t; (void)ret; set_chars(THIS, NULL, 0); (void)args; }
NATIVE(string_init_string) { (void)ret; NPE(ARG(1).a); set_chars(THIS, CHARS(ARG(1).a), ARG(1).a->length); }
NATIVE(string_init_bytes) { (void)ret; NPE(ARG(1).a); set_bytes(THIS, ARG(1).a->u.data, ARG(1).a->length); }
NATIVE(string_init_bytes_range) {
    (void)ret;
    Obj *b = ARG(1).a;
    NPE(b);
    int32_t off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > b->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    set_bytes(THIS, (int8_t *)b->u.data + off, len);
}
NATIVE(string_init_bytes_enc) { (void)ret; NPE(ARG(1).a); set_bytes(THIS, ARG(1).a->u.data, ARG(1).a->length); }
NATIVE(string_init_chars) { (void)ret; NPE(ARG(1).a); set_chars(THIS, ARG(1).a->u.data, ARG(1).a->length); }
NATIVE(string_init_chars_range) {
    (void)ret;
    Obj *c = ARG(1).a;
    NPE(c);
    int32_t off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > c->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    set_chars(THIS, (uint16_t *)c->u.data + off, len);
}
NATIVE(string_length) { (void)t; RETI(THIS->length); }
NATIVE(string_charat) {
    int32_t i = ARG(1).i;
    if (i < 0 || i >= THIS->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    RETI(CHARS(THIS)[i]);
}
NATIVE(string_equals) {
    (void)t;
    Obj *o = ARG(1).a;
    RETI(o && o->kind == K_STRING && o->length == THIS->length && memcmp(o->u.data, THIS->u.data, (size_t)o->length * 2) == 0);
}
static uint16_t lower(uint16_t c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static uint16_t upper(uint16_t c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
NATIVE(string_equalsignorecase) {
    (void)t;
    Obj *o = ARG(1).a;
    bool eq = o && o->kind == K_STRING && o->length == THIS->length;
    for (int32_t i = 0; eq && i < o->length; i++) eq = lower(CHARS(o)[i]) == lower(CHARS(THIS)[i]);
    RETI(eq);
}
NATIVE(string_hashcode) {
    (void)t;
    int32_t h = 0;
    for (int32_t i = 0; i < THIS->length; i++) h = (int32_t)(31u * (uint32_t)h + CHARS(THIS)[i]);
    RETI(h);
}
NATIVE(string_compareto) {
    Obj *o = ARG(1).a;
    NPE(o);
    int32_t n = THIS->length < o->length ? THIS->length : o->length;
    for (int32_t i = 0; i < n; i++)
        if (CHARS(THIS)[i] != CHARS(o)[i]) { RETI(CHARS(THIS)[i] - CHARS(o)[i]); return; }
    RETI(THIS->length - o->length);
}
static int32_t index_of(Obj *s, Obj *sub, int32_t from) {
    if (from < 0) from = 0;
    for (int32_t i = from; i + sub->length <= s->length; i++)
        if (memcmp(CHARS(s) + i, CHARS(sub), (size_t)sub->length * 2) == 0) return i;
    return -1;
}
NATIVE(string_indexof_str) { NPE(ARG(1).a); RETI(index_of(THIS, ARG(1).a, 0)); }
NATIVE(string_indexof_str_from) { NPE(ARG(1).a); RETI(index_of(THIS, ARG(1).a, ARG(2).i)); }
NATIVE(string_indexof_char_from) {
    (void)t;
    int32_t from = ARG(2).i < 0 ? 0 : ARG(2).i;
    for (int32_t i = from; i < THIS->length; i++) if (CHARS(THIS)[i] == ARG(1).i) { RETI(i); return; }
    RETI(-1);
}
NATIVE(string_indexof_char) {
    (void)t;
    for (int32_t i = 0; i < THIS->length; i++) if (CHARS(THIS)[i] == ARG(1).i) { RETI(i); return; }
    RETI(-1);
}
NATIVE(string_lastindexof_char) {
    (void)t;
    for (int32_t i = THIS->length - 1; i >= 0; i--) if (CHARS(THIS)[i] == ARG(1).i) { RETI(i); return; }
    RETI(-1);
}
static void substring(Thread *t, Obj *s, int32_t b, int32_t e, Slot *ret) {
    if (b < 0 || e > s->length || b > e) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    RETA(new_string(CHARS(s) + b, e - b));
}
NATIVE(string_substring) { substring(t, THIS, ARG(1).i, THIS->length, ret); }
NATIVE(string_substring2) { substring(t, THIS, ARG(1).i, ARG(2).i, ret); }
NATIVE(string_tochararray) {
    (void)t;
    Obj *a = vm_new_array(T_CHAR, THIS->length, NULL);
    memcpy(a->u.data, THIS->u.data, (size_t)THIS->length * 2);
    RETA(a);
}
NATIVE(string_getbytes) {
    (void)t;
    Obj *a = vm_new_array(T_BYTE, THIS->length, NULL);
    for (int32_t i = 0; i < THIS->length; i++) ((int8_t *)a->u.data)[i] = (int8_t)CHARS(THIS)[i];
    RETA(a);
}
NATIVE(string_tostring) { (void)t; RETA(THIS); }
NATIVE(string_intern) { (void)t; RETA(vm_intern(THIS)); }
NATIVE(string_trim) {
    (void)t;
    int32_t b = 0, e = THIS->length;
    while (b < e && CHARS(THIS)[b] <= ' ') b++;
    while (e > b && CHARS(THIS)[e - 1] <= ' ') e--;
    RETA(b == 0 && e == THIS->length ? THIS : new_string(CHARS(THIS) + b, e - b));
}
NATIVE(string_tolower) {
    (void)t;
    Obj *s = new_string(CHARS(THIS), THIS->length);
    for (int32_t i = 0; i < s->length; i++) CHARS(s)[i] = lower(CHARS(s)[i]);
    RETA(s);
}
NATIVE(string_toupper) {
    (void)t;
    Obj *s = new_string(CHARS(THIS), THIS->length);
    for (int32_t i = 0; i < s->length; i++) CHARS(s)[i] = upper(CHARS(s)[i]);
    RETA(s);
}
NATIVE(string_startswith) {
    Obj *p = ARG(1).a;
    NPE(p);
    RETI(p->length <= THIS->length && memcmp(CHARS(THIS), CHARS(p), (size_t)p->length * 2) == 0);
}
NATIVE(string_endswith) {
    Obj *p = ARG(1).a;
    NPE(p);
    RETI(p->length <= THIS->length && memcmp(CHARS(THIS) + THIS->length - p->length, CHARS(p), (size_t)p->length * 2) == 0);
}
NATIVE(string_concat) {
    Obj *o = ARG(1).a;
    NPE(o);
    Obj *s = new_string(NULL, THIS->length + o->length);
    memcpy(CHARS(s), CHARS(THIS), (size_t)THIS->length * 2);
    memcpy(CHARS(s) + THIS->length, CHARS(o), (size_t)o->length * 2);
    RETA(s);
}
NATIVE(string_replace) {
    (void)t;
    Obj *s = new_string(CHARS(THIS), THIS->length);
    for (int32_t i = 0; i < s->length; i++) if (CHARS(s)[i] == (uint16_t)ARG(1).i) CHARS(s)[i] = (uint16_t)ARG(2).i;
    RETA(s);
}
NATIVE(string_valueof_int) { (void)t; RETA(string_of_int(ARG(0).i)); }
NATIVE(string_valueof_long) { (void)t; RETA(string_of_int(ARG(0).j)); }
NATIVE(string_valueof_char) { (void)t; uint16_t c = (uint16_t)ARG(0).i; RETA(new_string(&c, 1)); }
NATIVE(string_valueof_bool) { (void)t; RETA(string_from(ARG(0).i ? "true" : "false")); }
NATIVE(string_valueof_chars) { NPE(ARG(0).a); RETA(new_string(ARG(0).a->u.data, ARG(0).a->length)); }
static Obj *to_string(Thread *t, Obj *o) {
    if (!o) return string_from("null");
    if (o->kind == K_STRING) return o;
    Method *m = vm_find_method(o->cls, "toString", "()Ljava/lang/String;");
    Slot r = {0}, a = {.a = o};
    if (m) vm_call(m, &a, &r);
    (void)t;
    return r.a ? r.a : string_from("null");
}
NATIVE(string_valueof_object) { RETA(to_string(t, ARG(0).a)); }

// MARK: StringBuffer

static void sb_reserve(Obj *sb, int32_t extra) {
    int32_t need = sb->length + extra;
    if (need <= sb->u.sb.cap) return;
    int32_t cap = sb->u.sb.cap * 2 + 16;
    if (cap < need) cap = need;
    sb->u.sb.chars = realloc(sb->u.sb.chars, (size_t)cap * 2);
    sb->u.sb.cap = cap;
}
static void sb_append(Obj *sb, const uint16_t *c, int32_t n) {
    sb_reserve(sb, n);
    memcpy(sb->u.sb.chars + sb->length, c, (size_t)n * 2);
    sb->length += n;
}
static void sb_append_c(Obj *sb, const char *s) {
    for (; *s; s++) { uint16_t c = (uint8_t)*s; sb_append(sb, &c, 1); }
}
NATIVE(sb_init) { (void)t; (void)ret; THIS->length = 0; }
NATIVE(sb_init_string) { (void)ret; NPE(ARG(1).a); THIS->length = 0; sb_append(THIS, CHARS(ARG(1).a), ARG(1).a->length); }
NATIVE(sb_append_string) {
    (void)t;
    Obj *s = ARG(1).a;
    if (s) sb_append(THIS, CHARS(s), s->length);
    else sb_append_c(THIS, "null");
    RETA(THIS);
}
NATIVE(sb_append_object) { Obj *s = to_string(t, ARG(1).a); sb_append(THIS, CHARS(s), s->length); RETA(THIS); }
NATIVE(sb_append_int) { (void)t; char b[16]; snprintf(b, sizeof b, "%d", ARG(1).i); sb_append_c(THIS, b); RETA(THIS); }
NATIVE(sb_append_long) { (void)t; char b[32]; snprintf(b, sizeof b, "%lld", (long long)ARG(1).j); sb_append_c(THIS, b); RETA(THIS); }
NATIVE(sb_append_char) { (void)t; uint16_t c = (uint16_t)ARG(1).i; sb_append(THIS, &c, 1); RETA(THIS); }
NATIVE(sb_append_bool) { (void)t; sb_append_c(THIS, ARG(1).i ? "true" : "false"); RETA(THIS); }
NATIVE(sb_append_chars) { NPE(ARG(1).a); sb_append(THIS, ARG(1).a->u.data, ARG(1).a->length); RETA(THIS); }
NATIVE(sb_tostring) { (void)t; RETA(new_string(THIS->u.sb.chars, THIS->length)); }
NATIVE(sb_length) { (void)t; RETI(THIS->length); }
NATIVE(sb_charat) {
    if (ARG(1).i < 0 || ARG(1).i >= THIS->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    RETI(THIS->u.sb.chars[ARG(1).i]);
}
NATIVE(sb_setlength) {
    (void)t; (void)ret;
    int32_t n = ARG(1).i < 0 ? 0 : ARG(1).i;
    if (n > THIS->length) { sb_reserve(THIS, n - THIS->length); memset(THIS->u.sb.chars + THIS->length, 0, (size_t)(n - THIS->length) * 2); }
    THIS->length = n;
}
NATIVE(sb_deletecharat) {
    int32_t i = ARG(1).i;
    if (i < 0 || i >= THIS->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    memmove(THIS->u.sb.chars + i, THIS->u.sb.chars + i + 1, (size_t)(THIS->length - i - 1) * 2);
    THIS->length--;
    RETA(THIS);
}
NATIVE(sb_reverse) {
    (void)t;
    for (int32_t i = 0, j = THIS->length - 1; i < j; i++, j--) {
        uint16_t c = THIS->u.sb.chars[i];
        THIS->u.sb.chars[i] = THIS->u.sb.chars[j];
        THIS->u.sb.chars[j] = c;
    }
    RETA(THIS);
}

// MARK: Integer, Math, System, Runtime

static bool parse_int(Obj *s, int radix, int32_t *out) {
    if (!s || s->length == 0) return false;
    int64_t v = 0;
    int32_t i = 0;
    bool neg = false;
    if (CHARS(s)[0] == '-' || CHARS(s)[0] == '+') { neg = CHARS(s)[0] == '-'; i = 1; }
    if (i >= s->length) return false;
    for (; i < s->length; i++) {
        uint16_t c = CHARS(s)[i];
        int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'z' ? c - 'a' + 10 : c >= 'A' && c <= 'Z' ? c - 'A' + 10 : 99;
        if (d >= radix) return false;
        v = v * radix + d;
        if (v > 2147483648LL) return false;
    }
    if (neg) v = -v;
    if (v > INT32_MAX || v < INT32_MIN) return false;
    *out = (int32_t)v;
    return true;
}
NATIVE(integer_parseint) {
    int32_t v;
    if (!parse_int(ARG(0).a, 10, &v)) {
        char *s = vm_cstring(ARG(0).a);
        vm_throw(t, "java/lang/NumberFormatException", s);
        free(s);
        return;
    }
    RETI(v);
}
NATIVE(integer_parseint_radix) {
    int32_t v;
    if (!parse_int(ARG(0).a, ARG(1).i, &v)) { vm_throw(t, "java/lang/NumberFormatException", NULL); return; }
    RETI(v);
}
NATIVE(integer_tostring_static) { (void)t; RETA(string_of_int(ARG(0).i)); }
NATIVE(integer_tohex) { (void)t; char b[16]; snprintf(b, sizeof b, "%x", (unsigned)ARG(0).i); RETA(string_from(b)); }
NATIVE(integer_init) { (void)t; (void)ret; THIS->length = ARG(1).i; }  // the value lives in `length`
NATIVE(integer_intvalue) { (void)t; RETI(THIS->length); }
NATIVE(integer_tostring) { (void)t; RETA(string_of_int(THIS->length)); }
NATIVE(integer_valueof) {
    (void)t;
    Obj *o = vm_alloc(vm_class("java/lang/Integer"), K_PLAIN, 0);
    o->length = ARG(0).i;
    RETA(o);
}
NATIVE(math_abs) { (void)t; RETI(ARG(0).i < 0 ? (int32_t)(0u - (uint32_t)ARG(0).i) : ARG(0).i); }
NATIVE(math_absj) { (void)t; ret->j = ARG(0).j < 0 ? -ARG(0).j : ARG(0).j; }
NATIVE(math_min) { (void)t; RETI(ARG(0).i < ARG(1).i ? ARG(0).i : ARG(1).i); }
NATIVE(math_max) { (void)t; RETI(ARG(0).i > ARG(1).i ? ARG(0).i : ARG(1).i); }
NATIVE(math_minj) { (void)t; ret->j = ARG(0).j < ARG(2).j ? ARG(0).j : ARG(2).j; }
NATIVE(math_maxj) { (void)t; ret->j = ARG(0).j > ARG(2).j ? ARG(0).j : ARG(2).j; }

NATIVE(system_time) { (void)t; (void)args; ret->j = 1100000000000LL + vm_now; }
NATIVE(system_gc) { (void)t; (void)args; (void)ret; }
NATIVE(system_getproperty) {
    (void)t;
    char *key = vm_cstring(ARG(0).a);
    const char *v = strcmp(key, "microedition.platform") == 0 ? "SAMSUNG" : strcmp(key, "microedition.configuration") == 0 ? "CLDC-1.1"
                  : strcmp(key, "microedition.profiles") == 0 ? "MIDP-2.0" : strcmp(key, "microedition.encoding") == 0 ? "ISO-8859-1" : NULL;
    free(key);
    RETA(v ? string_from(v) : NULL);
}
NATIVE(system_arraycopy) {
    (void)ret;
    Obj *src = ARG(0).a, *dst = ARG(2).a;
    int32_t sp = ARG(1).i, dp = ARG(3).i, n = ARG(4).i;
    NPE(src);
    NPE(dst);
    if (src->kind != K_ARRAY || dst->kind != K_ARRAY || src->etype != dst->etype) { vm_throw(t, "java/lang/ArrayStoreException", NULL); return; }
    if (n < 0 || sp < 0 || dp < 0 || sp + n > src->length || dp + n > dst->length) {
        vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL);
        return;
    }
    size_t es = vm_elem_size(src->etype);
    memmove((uint8_t *)dst->u.data + dp * es, (uint8_t *)src->u.data + sp * es, n * es);
}
static Obj *runtime;
NATIVE(runtime_get) { (void)t; (void)args; if (!runtime) runtime = vm_alloc(vm_class("java/lang/Runtime"), K_PLAIN, 0); RETA(runtime); }
NATIVE(runtime_free) { (void)t; (void)args; ret->j = 4 * 1024 * 1024; }
NATIVE(runtime_total) { (void)t; (void)args; ret->j = 8 * 1024 * 1024; }

// MARK: Thread

NATIVE(thread_init) { (void)t; (void)ret; THIS->u.thr.runnable = NULL; (void)args; }
NATIVE(thread_init_runnable) { (void)t; (void)ret; THIS->u.thr.runnable = ARG(1).a; }
NATIVE(thread_start) {
    (void)t; (void)ret;
    Obj *runnable = THIS->kind == K_THREAD && THIS->u.thr.runnable ? THIS->u.thr.runnable : THIS;
    vm_spawn(runnable, THIS);
}
NATIVE(thread_sleep) {
    (void)ret;
    int64_t ms = ARG(0).j < 0 ? 0 : ARG(0).j;
    // The games were timed on phones that took tens of milliseconds to draw a screen, and they
    // sleep a fixed time on top of that (Forgotten Warrior 23 ms a step). Drawing here is
    // instant, so the time the phone would have spent on what was drawn is added to the sleep:
    // a full 240×320 screen is ~51 ms, which puts a Forgotten Warrior step at ~65 ms.
    ms += midp_drawn / PIXELS_PER_MS;
    midp_drawn = 0;
    // Rounded up to the next shown frame: the game's animation advances once per step, and
    // steps that each last the same number of frames walk evenly instead of 4, 4, 4, 3.
    int64_t frame = ((vm_now + ms) * J2ME_FPS + 999) / 1000;
    t->wake = frame * 1000 / J2ME_FPS;
    if (t->wake < vm_now) t->wake = vm_now;
    t->yield = true;
}
NATIVE(thread_yield) { (void)ret; (void)args; t->wake = vm_now; t->yield = true; }
NATIVE(thread_current) {
    (void)args;
    if (!t->obj) {
        t->obj = vm_alloc(vm_class("java/lang/Thread"), K_THREAD, 0);
    }
    RETA(t->obj);
}
NATIVE(thread_isalive) {
    (void)t;
    for (Thread *x = vm_threads; x; x = x->next) if (x->obj == THIS && !x->done) { RETI(1); return; }
    RETI(0);
}
NATIVE(thread_nop) { (void)t; (void)args; (void)ret; }

// MARK: Random (java.util.Random's own generator)

static void random_seed(Obj *r, int64_t seed) { r->u.rnd.seed = (seed ^ 0x5DEECE66DLL) & ((1LL << 48) - 1); }
static int32_t random_next(Obj *r, int bits) {
    r->u.rnd.seed = (r->u.rnd.seed * 0x5DEECE66DLL + 0xBLL) & ((1LL << 48) - 1);
    return (int32_t)(r->u.rnd.seed >> (48 - bits));
}
static int64_t seed_counter = 8682522807148012LL;
NATIVE(random_init) { (void)t; (void)ret; (void)args; seed_counter = (int64_t)((uint64_t)seed_counter * 181783497276652981ULL); random_seed(THIS, seed_counter ^ (int64_t)(uintptr_t)THIS ^ vm_now); }
NATIVE(random_init_seed) { (void)t; (void)ret; random_seed(THIS, ARG(1).j); }
NATIVE(random_setseed) { (void)t; (void)ret; random_seed(THIS, ARG(1).j); }
NATIVE(random_nextint) { (void)t; RETI(random_next(THIS, 32)); }
NATIVE(random_nextint_bound) {
    int32_t n = ARG(1).i;
    if (n <= 0) { vm_throw(t, "java/lang/IllegalArgumentException", NULL); return; }
    if ((n & -n) == n) { RETI((int32_t)(((int64_t)n * random_next(THIS, 31)) >> 31)); return; }
    int32_t bits, val;
    do { bits = random_next(THIS, 31); val = bits % n; } while (bits - val + (n - 1) < 0);
    RETI(val);
}
NATIVE(random_nextlong) { (void)t; ret->j = ((int64_t)random_next(THIS, 32) << 32) + random_next(THIS, 32); }

// MARK: Streams

Obj *lib_resource_stream(const char *name) {
    int32_t size;
    uint8_t *data = jar_read(name, &size);
    if (!data) return NULL;
    Obj *s = vm_alloc(vm_class("java/io/InputStream"), K_STREAM, 0);
    s->u.st.bytes = data;
    s->u.st.size = size;
    vm_allocated += size;
    return s;
}

// The stream that holds the bytes, under any DataInputStream wrappers.
static Obj *base_stream(Obj *s) {
    while (s && s->u.st.inner) s = s->u.st.inner;
    return s;
}
static int stream_read(Obj *s) {
    s = base_stream(s);
    if (!s || !s->u.st.bytes || s->u.st.pos >= s->u.st.size) return -1;
    return s->u.st.bytes[s->u.st.pos++];
}
static int32_t stream_read_into(Obj *s, uint8_t *out, int32_t n) {
    s = base_stream(s);
    if (!s || !s->u.st.bytes) return -1;
    int32_t left = s->u.st.size - s->u.st.pos;
    if (left <= 0) return n == 0 ? 0 : -1;
    if (n > left) n = left;
    memcpy(out, s->u.st.bytes + s->u.st.pos, n);
    s->u.st.pos += n;
    return n;
}
static void stream_write(Obj *s, const uint8_t *data, int32_t n) {
    s = base_stream(s);
    if (!s) return;
    if (s->u.st.pos + n > s->u.st.size) {
        int32_t cap = (s->u.st.pos + n) * 2 + 64;
        s->u.st.bytes = realloc(s->u.st.bytes, cap);
        s->u.st.size = cap;
    }
    memcpy(s->u.st.bytes + s->u.st.pos, data, n);
    s->u.st.pos += n;
}

NATIVE(bais_init) {
    (void)ret;
    NPE(ARG(1).a);
    THIS->u.st.backing = ARG(1).a;
    THIS->u.st.bytes = ARG(1).a->u.data;
    THIS->u.st.size = ARG(1).a->length;
    THIS->u.st.pos = 0;
}
NATIVE(bais_init_range) {
    (void)ret;
    NPE(ARG(1).a);
    THIS->u.st.backing = ARG(1).a;
    THIS->u.st.bytes = ARG(1).a->u.data;
    THIS->u.st.pos = ARG(2).i;
    THIS->u.st.size = ARG(2).i + ARG(3).i > ARG(1).a->length ? ARG(1).a->length : ARG(2).i + ARG(3).i;
}
NATIVE(wrapper_init) { (void)t; (void)ret; THIS->u.st.inner = ARG(1).a; }
NATIVE(in_read) { (void)t; RETI(stream_read(THIS)); }
NATIVE(in_read_array) { NPE(ARG(1).a); RETI(stream_read_into(THIS, ARG(1).a->u.data, ARG(1).a->length)); }
NATIVE(in_read_range) {
    Obj *b = ARG(1).a;
    NPE(b);
    int32_t off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > b->length) { vm_throw(t, "java/lang/IndexOutOfBoundsException", NULL); return; }
    RETI(stream_read_into(THIS, (uint8_t *)b->u.data + off, len));
}
NATIVE(in_available) {
    (void)t;
    Obj *s = base_stream(THIS);
    RETI(s && s->u.st.bytes ? s->u.st.size - s->u.st.pos : 0);
}
NATIVE(in_skip) {
    (void)t;
    Obj *s = base_stream(THIS);
    int64_t n = ARG(1).j;
    int32_t left = s ? s->u.st.size - s->u.st.pos : 0;
    if (n > left) n = left;
    if (n < 0) n = 0;
    if (s) s->u.st.pos += (int32_t)n;
    ret->j = n;
}
NATIVE(stream_nop) { (void)t; (void)args; (void)ret; }
NATIVE(in_reset) { (void)t; (void)ret; Obj *s = base_stream(THIS); if (s) s->u.st.pos = 0; }
NATIVE(in_marksupported) { (void)t; (void)args; RETI(0); }

static bool read_bytes(Thread *t, Obj *s, uint8_t *out, int n) {
    if (stream_read_into(s, out, n) != n) { vm_throw(t, "java/io/EOFException", NULL); return false; }
    return true;
}
NATIVE(din_readint) { uint8_t b[4]; if (read_bytes(t, THIS, b, 4)) RETI((int32_t)((uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3])); }
NATIVE(din_readshort) { uint8_t b[2]; if (read_bytes(t, THIS, b, 2)) RETI((int16_t)(b[0] << 8 | b[1])); }
NATIVE(din_readushort) { uint8_t b[2]; if (read_bytes(t, THIS, b, 2)) RETI(b[0] << 8 | b[1]); }
NATIVE(din_readchar) { uint8_t b[2]; if (read_bytes(t, THIS, b, 2)) RETI(b[0] << 8 | b[1]); }
NATIVE(din_readbyte) { uint8_t b[1]; if (read_bytes(t, THIS, b, 1)) RETI((int8_t)b[0]); }
NATIVE(din_readubyte) { uint8_t b[1]; if (read_bytes(t, THIS, b, 1)) RETI(b[0]); }
NATIVE(din_readbool) { uint8_t b[1]; if (read_bytes(t, THIS, b, 1)) RETI(b[0] != 0); }
NATIVE(din_readlong) {
    uint8_t b[8];
    if (!read_bytes(t, THIS, b, 8)) return;
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = v << 8 | b[i];
    ret->j = (int64_t)v;
}
NATIVE(din_readfully) {
    NPE(ARG(1).a);
    (void)ret;
    read_bytes(t, THIS, ARG(1).a->u.data, ARG(1).a->length);
}
NATIVE(din_readutf) {
    uint8_t b[2];
    if (!read_bytes(t, THIS, b, 2)) return;
    int n = b[0] << 8 | b[1];
    char *s = malloc(n + 1);
    if (!read_bytes(t, THIS, (uint8_t *)s, n)) { free(s); return; }
    s[n] = 0;
    RETA(vm_string(s));
    free(s);
}

NATIVE(baos_init) { (void)t; (void)ret; (void)args; THIS->u.st.output = true; }
NATIVE(out_write) { (void)t; (void)ret; uint8_t b = (uint8_t)ARG(1).i; stream_write(THIS, &b, 1); }
NATIVE(out_write_array) { (void)ret; NPE(ARG(1).a); stream_write(THIS, ARG(1).a->u.data, ARG(1).a->length); }
NATIVE(out_write_range) {
    (void)ret;
    Obj *b = ARG(1).a;
    NPE(b);
    int32_t off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > b->length) { vm_throw(t, "java/lang/IndexOutOfBoundsException", NULL); return; }
    stream_write(THIS, (uint8_t *)b->u.data + off, len);
}
NATIVE(dout_writeint) {
    (void)t; (void)ret;
    uint32_t v = (uint32_t)ARG(1).i;
    uint8_t b[4] = {v >> 24, v >> 16, v >> 8, v};
    stream_write(THIS, b, 4);
}
NATIVE(dout_writeshort) { (void)t; (void)ret; uint8_t b[2] = {(uint8_t)(ARG(1).i >> 8), (uint8_t)ARG(1).i}; stream_write(THIS, b, 2); }
NATIVE(dout_writelong) {
    (void)t; (void)ret;
    uint64_t v = (uint64_t)ARG(1).j;
    uint8_t b[8];
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (56 - 8 * i));
    stream_write(THIS, b, 8);
}
NATIVE(dout_writeutf) {
    (void)ret;
    NPE(ARG(1).a);
    char *s = vm_cstring(ARG(1).a);
    size_t n = strlen(s);
    uint8_t b[2] = {(uint8_t)(n >> 8), (uint8_t)n};
    stream_write(THIS, b, 2);
    stream_write(THIS, (uint8_t *)s, (int32_t)n);
    free(s);
}
NATIVE(baos_tobytearray) {
    (void)t;
    Obj *s = base_stream(THIS);
    int32_t n = s ? s->u.st.pos : 0;
    Obj *a = vm_new_array(T_BYTE, n, NULL);
    if (n) memcpy(a->u.data, s->u.st.bytes, n);
    RETA(a);
}
NATIVE(baos_size) { (void)t; Obj *s = base_stream(THIS); RETI(s ? s->u.st.pos : 0); }
NATIVE(baos_reset) { (void)t; (void)ret; Obj *s = base_stream(THIS); if (s) s->u.st.pos = 0; }

// MARK: Registration

void lib_init(void) {
    runtime = NULL;
    vm_native_class("java/lang/Object", NULL, K_PLAIN);
    vm_native_class("java/lang/String", "java/lang/Object", K_STRING);
    vm_native_class("java/lang/StringBuffer", "java/lang/Object", K_SBUF);
    vm_native_class("java/lang/Integer", "java/lang/Object", K_PLAIN);
    vm_native_class("java/lang/Thread", "java/lang/Object", K_THREAD);
    vm_native_class("java/lang/Class", "java/lang/Object", K_CLASS);
    vm_native_class("java/util/Random", "java/lang/Object", K_RANDOM);
    vm_native_class("java/lang/Runnable", "java/lang/Object", K_PLAIN);
    vm_native_class("java/lang/Throwable", "java/lang/Object", K_THROWABLE);
    static const char *exceptions[][2] = {
        {"java/lang/Exception", "java/lang/Throwable"},
        {"java/lang/Error", "java/lang/Throwable"},
        {"java/lang/RuntimeException", "java/lang/Exception"},
        {"java/lang/InterruptedException", "java/lang/Exception"},
        {"java/lang/ClassNotFoundException", "java/lang/Exception"},
        {"java/lang/InstantiationException", "java/lang/Exception"},
        {"java/lang/IllegalAccessException", "java/lang/Exception"},
        {"java/io/IOException", "java/lang/Exception"},
        {"java/io/EOFException", "java/io/IOException"},
        {"java/lang/NullPointerException", "java/lang/RuntimeException"},
        {"java/lang/ArithmeticException", "java/lang/RuntimeException"},
        {"java/lang/ClassCastException", "java/lang/RuntimeException"},
        {"java/lang/ArrayStoreException", "java/lang/RuntimeException"},
        {"java/lang/NegativeArraySizeException", "java/lang/RuntimeException"},
        {"java/lang/IllegalArgumentException", "java/lang/RuntimeException"},
        {"java/lang/IllegalStateException", "java/lang/RuntimeException"},
        {"java/lang/NumberFormatException", "java/lang/IllegalArgumentException"},
        {"java/lang/IndexOutOfBoundsException", "java/lang/RuntimeException"},
        {"java/lang/ArrayIndexOutOfBoundsException", "java/lang/IndexOutOfBoundsException"},
        {"java/lang/StringIndexOutOfBoundsException", "java/lang/IndexOutOfBoundsException"},
        {"java/lang/SecurityException", "java/lang/RuntimeException"},
        {"java/lang/OutOfMemoryError", "java/lang/Error"},
        {"java/lang/StackOverflowError", "java/lang/Error"},
        {"java/lang/NoSuchFieldError", "java/lang/Error"},
        {"java/lang/NoSuchMethodError", "java/lang/Error"},
        {"java/lang/AbstractMethodError", "java/lang/Error"},
        {"java/lang/VerifyError", "java/lang/Error"},
        {"javax/microedition/rms/RecordStoreException", "java/lang/Exception"},
        {"javax/microedition/rms/RecordStoreNotFoundException", "javax/microedition/rms/RecordStoreException"},
        {"javax/microedition/rms/InvalidRecordIDException", "javax/microedition/rms/RecordStoreException"},
        {"javax/microedition/rms/RecordStoreFullException", "javax/microedition/rms/RecordStoreException"},
        {"javax/microedition/rms/RecordStoreNotOpenException", "javax/microedition/rms/RecordStoreException"},
        {"javax/microedition/media/MediaException", "java/lang/Exception"},
        {"javax/microedition/midlet/MIDletStateChangeException", "java/lang/Exception"},
    };
    for (size_t i = 0; i < sizeof exceptions / sizeof *exceptions; i++)
        vm_native_class(exceptions[i][0], exceptions[i][1], K_THROWABLE);
    vm_native_class("java/io/InputStream", "java/lang/Object", K_STREAM);
    vm_native_class("java/io/ByteArrayInputStream", "java/io/InputStream", K_STREAM);
    vm_native_class("java/io/DataInputStream", "java/io/InputStream", K_STREAM);
    vm_native_class("java/io/OutputStream", "java/lang/Object", K_STREAM);
    vm_native_class("java/io/ByteArrayOutputStream", "java/io/OutputStream", K_STREAM);
    vm_native_class("java/io/DataOutputStream", "java/io/OutputStream", K_STREAM);

    const char *O = "java/lang/Object";
    vm_native(O, "<init>", "()V", object_init);
    vm_native(O, "getClass", "()Ljava/lang/Class;", object_getclass);
    vm_native(O, "hashCode", "()I", object_hashcode);
    vm_native(O, "equals", "(Ljava/lang/Object;)Z", object_equals);
    vm_native(O, "toString", "()Ljava/lang/String;", object_tostring);
    vm_native(O, "notify", "()V", thread_nop);
    vm_native(O, "notifyAll", "()V", thread_nop);
    vm_native(O, "wait", "()V", thread_yield);
    vm_native(O, "wait", "(J)V", thread_nop);

    vm_native("java/lang/Class", "getName", "()Ljava/lang/String;", class_getname);
    vm_native("java/lang/Class", "getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;", class_getresourceasstream);

    const char *T = "java/lang/Throwable";
    vm_native(T, "<init>", "()V", throwable_init);
    vm_native(T, "<init>", "(Ljava/lang/String;)V", throwable_init_msg);
    vm_native(T, "getMessage", "()Ljava/lang/String;", throwable_getmessage);
    vm_native(T, "toString", "()Ljava/lang/String;", throwable_tostring);
    vm_native(T, "printStackTrace", "()V", throwable_print);

    const char *S = "java/lang/String";
    vm_native(S, "<init>", "()V", string_init);
    vm_native(S, "<init>", "(Ljava/lang/String;)V", string_init_string);
    vm_native(S, "<init>", "([B)V", string_init_bytes);
    vm_native(S, "<init>", "([BII)V", string_init_bytes_range);
    vm_native(S, "<init>", "([BLjava/lang/String;)V", string_init_bytes_enc);
    vm_native(S, "<init>", "([C)V", string_init_chars);
    vm_native(S, "<init>", "([CII)V", string_init_chars_range);
    vm_native(S, "length", "()I", string_length);
    vm_native(S, "charAt", "(I)C", string_charat);
    vm_native(S, "equals", "(Ljava/lang/Object;)Z", string_equals);
    vm_native(S, "equalsIgnoreCase", "(Ljava/lang/String;)Z", string_equalsignorecase);
    vm_native(S, "hashCode", "()I", string_hashcode);
    vm_native(S, "compareTo", "(Ljava/lang/String;)I", string_compareto);
    vm_native(S, "indexOf", "(Ljava/lang/String;)I", string_indexof_str);
    vm_native(S, "indexOf", "(Ljava/lang/String;I)I", string_indexof_str_from);
    vm_native(S, "indexOf", "(I)I", string_indexof_char);
    vm_native(S, "indexOf", "(II)I", string_indexof_char_from);
    vm_native(S, "lastIndexOf", "(I)I", string_lastindexof_char);
    vm_native(S, "substring", "(I)Ljava/lang/String;", string_substring);
    vm_native(S, "substring", "(II)Ljava/lang/String;", string_substring2);
    vm_native(S, "toCharArray", "()[C", string_tochararray);
    vm_native(S, "getBytes", "()[B", string_getbytes);
    vm_native(S, "toString", "()Ljava/lang/String;", string_tostring);
    vm_native(S, "intern", "()Ljava/lang/String;", string_intern);
    vm_native(S, "trim", "()Ljava/lang/String;", string_trim);
    vm_native(S, "toLowerCase", "()Ljava/lang/String;", string_tolower);
    vm_native(S, "toUpperCase", "()Ljava/lang/String;", string_toupper);
    vm_native(S, "startsWith", "(Ljava/lang/String;)Z", string_startswith);
    vm_native(S, "endsWith", "(Ljava/lang/String;)Z", string_endswith);
    vm_native(S, "concat", "(Ljava/lang/String;)Ljava/lang/String;", string_concat);
    vm_native(S, "replace", "(CC)Ljava/lang/String;", string_replace);
    vm_native_static(S, "valueOf", "(I)Ljava/lang/String;", string_valueof_int);
    vm_native_static(S, "valueOf", "(J)Ljava/lang/String;", string_valueof_long);
    vm_native_static(S, "valueOf", "(C)Ljava/lang/String;", string_valueof_char);
    vm_native_static(S, "valueOf", "(Z)Ljava/lang/String;", string_valueof_bool);
    vm_native_static(S, "valueOf", "([C)Ljava/lang/String;", string_valueof_chars);
    vm_native_static(S, "valueOf", "(Ljava/lang/Object;)Ljava/lang/String;", string_valueof_object);

    const char *B = "java/lang/StringBuffer";
    vm_native(B, "<init>", "()V", sb_init);
    vm_native(B, "<init>", "(I)V", sb_init);
    vm_native(B, "<init>", "(Ljava/lang/String;)V", sb_init_string);
    vm_native(B, "append", "(Ljava/lang/String;)Ljava/lang/StringBuffer;", sb_append_string);
    vm_native(B, "append", "(Ljava/lang/Object;)Ljava/lang/StringBuffer;", sb_append_object);
    vm_native(B, "append", "(I)Ljava/lang/StringBuffer;", sb_append_int);
    vm_native(B, "append", "(J)Ljava/lang/StringBuffer;", sb_append_long);
    vm_native(B, "append", "(C)Ljava/lang/StringBuffer;", sb_append_char);
    vm_native(B, "append", "(Z)Ljava/lang/StringBuffer;", sb_append_bool);
    vm_native(B, "append", "([C)Ljava/lang/StringBuffer;", sb_append_chars);
    vm_native(B, "toString", "()Ljava/lang/String;", sb_tostring);
    vm_native(B, "length", "()I", sb_length);
    vm_native(B, "charAt", "(I)C", sb_charat);
    vm_native(B, "setLength", "(I)V", sb_setlength);
    vm_native(B, "deleteCharAt", "(I)Ljava/lang/StringBuffer;", sb_deletecharat);
    vm_native(B, "reverse", "()Ljava/lang/StringBuffer;", sb_reverse);

    const char *I = "java/lang/Integer";
    vm_native_static(I, "parseInt", "(Ljava/lang/String;)I", integer_parseint);
    vm_native_static(I, "parseInt", "(Ljava/lang/String;I)I", integer_parseint_radix);
    vm_native_static(I, "toString", "(I)Ljava/lang/String;", integer_tostring_static);
    vm_native_static(I, "toHexString", "(I)Ljava/lang/String;", integer_tohex);
    vm_native_static(I, "valueOf", "(I)Ljava/lang/Integer;", integer_valueof);
    vm_native(I, "<init>", "(I)V", integer_init);
    vm_native(I, "intValue", "()I", integer_intvalue);
    vm_native(I, "toString", "()Ljava/lang/String;", integer_tostring);

    const char *M = "java/lang/Math";
    vm_native_static(M, "abs", "(I)I", math_abs);
    vm_native_static(M, "abs", "(J)J", math_absj);
    vm_native_static(M, "min", "(II)I", math_min);
    vm_native_static(M, "max", "(II)I", math_max);
    vm_native_static(M, "min", "(JJ)J", math_minj);
    vm_native_static(M, "max", "(JJ)J", math_maxj);

    const char *Y = "java/lang/System";
    vm_native_static(Y, "currentTimeMillis", "()J", system_time);
    vm_native_static(Y, "gc", "()V", system_gc);
    vm_native_static(Y, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;", system_getproperty);
    vm_native_static(Y, "arraycopy", "(Ljava/lang/Object;ILjava/lang/Object;II)V", system_arraycopy);
    vm_native_static("java/lang/Runtime", "getRuntime", "()Ljava/lang/Runtime;", runtime_get);
    vm_native("java/lang/Runtime", "freeMemory", "()J", runtime_free);
    vm_native("java/lang/Runtime", "totalMemory", "()J", runtime_total);
    vm_native("java/lang/Runtime", "gc", "()V", thread_nop);
    vm_add_root(&runtime);

    const char *H = "java/lang/Thread";
    vm_native(H, "<init>", "()V", thread_init);
    vm_native(H, "<init>", "(Ljava/lang/Runnable;)V", thread_init_runnable);
    vm_native(H, "start", "()V", thread_start);
    vm_native(H, "isAlive", "()Z", thread_isalive);
    vm_native(H, "setPriority", "(I)V", thread_nop);
    vm_native(H, "interrupt", "()V", thread_nop);
    vm_native(H, "join", "()V", thread_yield);
    vm_native_static(H, "sleep", "(J)V", thread_sleep);
    vm_native_static(H, "yield", "()V", thread_yield);
    vm_native_static(H, "currentThread", "()Ljava/lang/Thread;", thread_current);

    const char *R = "java/util/Random";
    vm_native(R, "<init>", "()V", random_init);
    vm_native(R, "<init>", "(J)V", random_init_seed);
    vm_native(R, "setSeed", "(J)V", random_setseed);
    vm_native(R, "nextInt", "()I", random_nextint);
    vm_native(R, "nextInt", "(I)I", random_nextint_bound);
    vm_native(R, "nextLong", "()J", random_nextlong);

    const char *IS = "java/io/InputStream";
    vm_native(IS, "read", "()I", in_read);
    vm_native(IS, "read", "([B)I", in_read_array);
    vm_native(IS, "read", "([BII)I", in_read_range);
    vm_native(IS, "available", "()I", in_available);
    vm_native(IS, "skip", "(J)J", in_skip);
    vm_native(IS, "close", "()V", stream_nop);
    vm_native(IS, "reset", "()V", in_reset);
    vm_native(IS, "mark", "(I)V", stream_nop);
    vm_native(IS, "markSupported", "()Z", in_marksupported);
    vm_native("java/io/ByteArrayInputStream", "<init>", "([B)V", bais_init);
    vm_native("java/io/ByteArrayInputStream", "<init>", "([BII)V", bais_init_range);
    const char *DI = "java/io/DataInputStream";
    vm_native(DI, "<init>", "(Ljava/io/InputStream;)V", wrapper_init);
    vm_native(DI, "readInt", "()I", din_readint);
    vm_native(DI, "readShort", "()S", din_readshort);
    vm_native(DI, "readUnsignedShort", "()I", din_readushort);
    vm_native(DI, "readChar", "()C", din_readchar);
    vm_native(DI, "readByte", "()B", din_readbyte);
    vm_native(DI, "readUnsignedByte", "()I", din_readubyte);
    vm_native(DI, "readBoolean", "()Z", din_readbool);
    vm_native(DI, "readLong", "()J", din_readlong);
    vm_native(DI, "readFully", "([B)V", din_readfully);
    vm_native(DI, "readUTF", "()Ljava/lang/String;", din_readutf);

    const char *OS = "java/io/OutputStream";
    vm_native(OS, "write", "(I)V", out_write);
    vm_native(OS, "write", "([B)V", out_write_array);
    vm_native(OS, "write", "([BII)V", out_write_range);
    vm_native(OS, "flush", "()V", stream_nop);
    vm_native(OS, "close", "()V", stream_nop);
    const char *BO = "java/io/ByteArrayOutputStream";
    vm_native(BO, "<init>", "()V", baos_init);
    vm_native(BO, "<init>", "(I)V", baos_init);
    vm_native(BO, "toByteArray", "()[B", baos_tobytearray);
    vm_native(BO, "size", "()I", baos_size);
    vm_native(BO, "reset", "()V", baos_reset);
    const char *DO = "java/io/DataOutputStream";
    vm_native(DO, "<init>", "(Ljava/io/OutputStream;)V", wrapper_init);
    vm_native(DO, "writeInt", "(I)V", dout_writeint);
    vm_native(DO, "writeShort", "(I)V", dout_writeshort);
    vm_native(DO, "writeChar", "(I)V", dout_writeshort);
    vm_native(DO, "writeByte", "(I)V", out_write);
    vm_native(DO, "writeBoolean", "(Z)V", out_write);
    vm_native(DO, "writeLong", "(J)V", dout_writelong);
    vm_native(DO, "writeUTF", "(Ljava/lang/String;)V", dout_writeutf);
}
