// A small Java virtual machine for MIDP 1/2 phone games (J2ME), wrapped as a libretro core.
// It runs the game's own classes from the .jar and provides, in C, the parts of CLDC/MIDP the
// games call: java.lang/io/util basics, lcdui (Canvas, Graphics, Image), rms and Samsung's
// AudioClip/Vibration. Java threads are green threads, switched when they sleep or yield.
#ifndef JVM_H
#define JVM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct Obj Obj;
typedef struct Class Class;
typedef struct Method Method;
typedef struct Thread Thread;

typedef union {
    int32_t i;
    int64_t j;
    float f;
    double d;
    Obj *a;
} Slot;

// Object kinds. Instances of the game's classes are K_INSTANCE whatever their native base is.
enum {
    K_INSTANCE, K_ARRAY, K_STRING, K_SBUF, K_IMAGE, K_GRAPHICS, K_STREAM, K_RANDOM, K_THREAD,
    K_RECORDSTORE, K_AUDIO, K_THROWABLE, K_CLASS, K_PLAIN, K_FONT,
};

// Array element types, as newarray codes, plus references.
enum { T_BOOLEAN = 4, T_CHAR = 5, T_FLOAT = 6, T_DOUBLE = 7, T_BYTE = 8, T_SHORT = 9, T_INT = 10, T_LONG = 11, T_REF = 12 };

struct Obj {
    Class *cls;
    Obj *next;           // every object, for the sweep
    uint8_t kind;
    uint8_t marked;
    uint8_t etype;       // arrays
    uint8_t flags;
    int32_t length;      // arrays, strings
    union {
        Slot *fields;                                   // K_INSTANCE (inline after the header)
        void *data;                                     // K_ARRAY elements, K_STRING uint16_t chars
        struct { uint16_t *chars; int32_t cap; } sb;    // K_SBUF (length is the count)
        struct { uint32_t *pixels; int w, h; bool mutable_; } img;
        struct { Obj *image; uint32_t color; int tx, ty, cx, cy, cw, ch; Obj *font; } gfx;
        struct { uint8_t *bytes; int32_t pos, size; Obj *backing; Obj *inner; bool output; } st;
        struct { int64_t seed; } rnd;
        struct { Obj *runnable; Thread *thread; } thr;
        struct { char *name; } rs;
        struct { void *clip; } au;
        struct { Obj *message; } ex;
        struct { Class *of; } klass;
        struct { int face, style, size; } font;
    } u;
};

typedef struct {
    uint16_t start, end, handler, type;
} Handler;

struct Method {
    Class *cls;
    const char *name, *desc;
    uint16_t access;
    uint16_t max_stack, max_locals;
    int arg_slots;            // including this
    int ret;                  // 0 void, 1 one slot, 2 two slots
    uint8_t *code;
    uint32_t code_len;
    Handler *handlers;
    int nhandlers;
    // Native: called with the arguments, returns the result in *ret.
    void (*native)(Thread *t, Slot *args, Slot *ret);
};

typedef struct {
    uint8_t tag;
    union {
        int32_t i;
        int64_t j;
        float f;
        double d;
        struct { uint16_t a, b; } ref;
        const char *utf8;
    } v;
    void *resolved;   // cache: Class*, Method*, field slot (+1), interned string
    void *resolved2;  // virtual call cache: last receiver class
    void *resolved3;  //                     and the method it found
} CPEntry;

typedef struct {
    const char *name, *desc;
    uint16_t access;
    int slot;            // instance: index into fields; static: index into statics
    bool ref;
} Field;

struct Class {
    const char *name;
    Class *super;
    bool native_;             // provided by the VM (java/lang/Object, Canvas...)
    uint8_t kind;             // native classes: what `new` makes
    CPEntry *cp;
    int ncp;
    Field *fields;
    int nfields;
    int ninstance;            // instance slots including supers
    Slot *statics;
    int nstatics;
    Method *methods;
    int nmethods;
    const char **interfaces;
    int ninterfaces;
    bool initialized;
    Obj *classobj;
    Class *next;
};

#define FRAME_MAX 256

typedef struct {
    Method *m;
    uint32_t pc;
    Slot *locals;
    Slot *sp;   // next free operand slot
} Frame;

struct Thread {
    Slot stack[16384];
    Frame frames[FRAME_MAX];
    int depth;
    int base;              // nested calls stop when depth falls back to this
    Obj *exception;        // pending, being thrown
    int64_t wake;          // virtual ms it sleeps until
    bool yield;            // a native asked to switch threads
    bool done;
    Obj *obj;              // its java.lang.Thread
    Thread *next;
};

// vm.c
extern int64_t vm_now;            // virtual milliseconds
extern Thread *vm_threads;
extern Thread *vm_current;
Class *vm_class(const char *name);  // loads a game class or finds a native one
Class *vm_native_class(const char *name, const char *super, int kind);
void vm_native(const char *cls, const char *name, const char *desc, void (*fn)(Thread *, Slot *, Slot *));
void vm_native_static(const char *cls, const char *name, const char *desc, void (*fn)(Thread *, Slot *, Slot *));
void vm_shutdown(void);
Method *vm_find_method(Class *c, const char *name, const char *desc);
bool vm_is_subclass(Class *c, const char *name);
Obj *vm_alloc(Class *c, int kind, size_t extra);
Obj *vm_new_instance(Class *c);
Obj *vm_new_array(int etype, int32_t length, Class *cls);
Obj *vm_string(const char *utf8);
Obj *vm_string_chars(const uint16_t *chars, int32_t length);
Obj *vm_intern(Obj *s);
char *vm_cstring(Obj *s);  // malloc'd, ASCII/Latin-1
void vm_throw(Thread *t, const char *cls, const char *msg);
Thread *vm_spawn(Obj *runnable, Obj *threadobj);
bool vm_call(Method *m, Slot *args, Slot *ret);   // runs to completion on a fresh nested thread
void vm_run_threads(int64_t until, int budget);
void vm_gc(void);
void vm_add_root(Obj **root);
size_t vm_elem_size(int etype);
void vm_log(const char *fmt, ...);
extern size_t vm_allocated;

// jar.c
bool jar_open(const char *path);
void jar_close(void);
uint8_t *jar_read(const char *name, int32_t *size);  // malloc'd, NULL if missing
const char *jar_manifest(const char *key);           // MIDlet-1 etc., static buffer

// lib.c / midp.c
void lib_init(void);
void midp_init(void);
extern Obj *midp_canvas;      // the Displayable on screen
extern Obj *midp_midlet;
uint32_t *midp_pixels(void);
extern int midp_width, midp_height;
extern bool midp_repaint_pending;
extern bool midp_exit;
void midp_paint(void);
void midp_key(int code, bool pressed);
void midp_set_save_dir(const char *dir);
void midp_shutdown(void);

// midi.c
void *midi_load(const uint8_t *data, int32_t size);
void midi_free(void *clip);
void midi_play(void *clip, int loops, int volume);
void midi_stop(void *clip);
void midi_render(int16_t *out, int frames, int rate);  // stereo, mixes every playing clip

#endif
