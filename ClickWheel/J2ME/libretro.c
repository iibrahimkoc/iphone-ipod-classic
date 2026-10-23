// The libretro side: loads the .jar's MIDlet, turns the pad into phone keys, and runs the Java
// threads for a frame's worth of virtual time each retro_run.
#include "jvm.h"
#include "libretro.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 32000
#define FPS 60

static retro_environment_t environ_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_batch_t audio_batch_cb;
static retro_input_poll_t input_poll_cb;
static retro_input_state_t input_state_cb;

static uint64_t frame_count;
static double audio_carry;
static int held[8];
static int nheld;
static bool loaded;
static bool exit_reported;
static uint32_t frame[240 * 320];

void retro_set_environment(retro_environment_t cb) { environ_cb = cb; }
void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_batch_cb = cb; }
void retro_set_input_poll(retro_input_poll_t cb) { input_poll_cb = cb; }
void retro_set_input_state(retro_input_state_t cb) { input_state_cb = cb; }
void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }

unsigned retro_api_version(void) { return RETRO_API_VERSION; }

void retro_get_system_info(struct retro_system_info *info) {
    memset(info, 0, sizeof *info);
    info->library_name = "J2ME";
    info->library_version = "1.0";
    info->valid_extensions = "jar";
    info->need_fullpath = true;
}

void retro_get_system_av_info(struct retro_system_av_info *info) {
    memset(info, 0, sizeof *info);
    info->geometry.base_width = midp_width;
    info->geometry.base_height = midp_height;
    info->geometry.max_width = midp_width;
    info->geometry.max_height = midp_height;
    info->geometry.aspect_ratio = (float)midp_width / midp_height;
    info->timing.fps = FPS;
    info->timing.sample_rate = RATE;
}

void retro_init(void) {}
void retro_deinit(void) {}
void retro_reset(void) {}

bool retro_load_game(const struct retro_game_info *game) {
    if (!game || !game->path || !jar_open(game->path)) return false;
    enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
    if (environ_cb) environ_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);

    // Saves (RecordStores) go in a hidden folder next to the game, named after it.
    const char *dir = NULL;
    if (environ_cb) environ_cb(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, &dir);
    const char *base = strrchr(game->path, '/');
    base = base ? base + 1 : game->path;
    char name[256], path[1024];
    snprintf(name, sizeof name, "%s", base);
    char *dot = strrchr(name, '.');
    if (dot) *dot = 0;
    if (dir) {
        snprintf(path, sizeof path, "%s/.%s.rms", dir, name);
    } else {
        snprintf(path, sizeof path, "%.*s.%s.rms", (int)(base - game->path), game->path, name);
    }

    lib_init();
    midp_init();
    midp_set_save_dir(path);

    // MIDlet-1: name, icon, class
    const char *midlet = jar_manifest("MIDlet-1");
    char cls[256] = "";
    if (midlet) {
        const char *c = strrchr(midlet, ',');
        c = c ? c + 1 : midlet;
        while (*c == ' ') c++;
        snprintf(cls, sizeof cls, "%s", c);
        for (char *p = cls + strlen(cls); p > cls && (p[-1] == ' ' || p[-1] == '\r'); ) *--p = 0;
        for (char *p = cls; *p; p++) if (*p == '.') *p = '/';
    }
    Class *c = cls[0] ? vm_class(cls) : NULL;
    if (!c || c->native_) {
        vm_log("no MIDlet class (%s)", cls);
        vm_shutdown();
        jar_close();
        return false;
    }
    Obj *app = vm_new_instance(c);
    midp_midlet = app;
    Method *init = vm_find_method(c, "<init>", "()V");
    Slot self = {.a = app};
    if (init) vm_call(init, &self, NULL);
    Method *start = vm_find_method(c, "startApp", "()V");
    if (start) vm_call(start, &self, NULL);
    frame_count = 0;
    audio_carry = 0;
    nheld = 0;
    exit_reported = false;
    loaded = true;
    return true;
}

bool retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) {
    (void)type; (void)info; (void)num;
    return false;
}

void retro_unload_game(void) {
    if (!loaded) return;
    midp_shutdown();
    vm_shutdown();
    jar_close();
    loaded = false;
}

// The phone keys the pad holds: the wheel's direction (up-left and up-right are the 1 and 3
// keys, a jump to that side in most games) and a key per button.
static int pad_keys(int *keys) {
    int n = 0;
    bool up = input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_UP);
    bool down = input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_DOWN);
    bool left = input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_LEFT);
    bool right = input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_RIGHT);
    if (up && left) keys[n++] = '1';
    else if (up && right) keys[n++] = '3';
    else if (up) keys[n++] = -1;
    else if (left) keys[n++] = -3;
    else if (right) keys[n++] = -4;
    else if (down) keys[n++] = -2;
    static const struct { int id, key; } buttons[] = {
        {RETRO_DEVICE_ID_JOYPAD_A, -5},
        {RETRO_DEVICE_ID_JOYPAD_B, '0'},
        {RETRO_DEVICE_ID_JOYPAD_X, '7'},
        {RETRO_DEVICE_ID_JOYPAD_Y, '9'},
        {RETRO_DEVICE_ID_JOYPAD_L, -6},
        {RETRO_DEVICE_ID_JOYPAD_SELECT, -6},
        {RETRO_DEVICE_ID_JOYPAD_R, -7},
        {RETRO_DEVICE_ID_JOYPAD_START, -7},
    };
    for (size_t i = 0; i < sizeof buttons / sizeof *buttons && n < 8; i++) {
        if (!input_state_cb(0, RETRO_DEVICE_JOYPAD, 0, buttons[i].id)) continue;
        bool dup = false;
        for (int k = 0; k < n; k++) dup |= keys[k] == buttons[i].key;
        if (!dup) keys[n++] = buttons[i].key;
    }
    return n;
}

static bool contains(const int *keys, int n, int key) {
    for (int i = 0; i < n; i++) if (keys[i] == key) return true;
    return false;
}

void retro_run(void) {
    if (!loaded) return;
    input_poll_cb();
    if (midp_exit && !exit_reported) {
        // The MIDlet quit (its Exit menu item): the frontend closes the game.
        exit_reported = true;
        if (environ_cb) environ_cb(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
    }
    if (!midp_exit) {
        int now[8];
        int n = pad_keys(now);
        for (int i = 0; i < nheld; i++) if (!contains(now, n, held[i])) midp_key(held[i], false);
        for (int i = 0; i < n; i++) if (!contains(held, nheld, now[i])) midp_key(now[i], true);
        memcpy(held, now, sizeof now);
        nheld = n;

        frame_count++;
        vm_run_threads((int64_t)(frame_count * 1000 / FPS), 2000000);
        midp_paint();
        if (vm_allocated > 24u << 20) vm_gc();
    }

    uint32_t *pixels = midp_pixels();
    if (pixels) {
        for (int i = 0; i < midp_width * midp_height; i++) frame[i] = pixels[i] | 0xFF000000;
        video_cb(frame, midp_width, midp_height, midp_width * 4);
    }
    audio_carry += (double)RATE / FPS;
    int samples = (int)audio_carry;
    audio_carry -= samples;
    static int16_t audio[2 * (RATE / FPS + 2)];
    midi_render(audio, samples, RATE);
    if (audio_batch_cb) audio_batch_cb(audio, samples);
}

size_t retro_serialize_size(void) { return 0; }
bool retro_serialize(void *data, size_t size) { (void)data; (void)size; return false; }
bool retro_unserialize(const void *data, size_t size) { (void)data; (void)size; return false; }
void retro_cheat_reset(void) {}
void retro_cheat_set(unsigned index, bool enabled, const char *code) { (void)index; (void)enabled; (void)code; }
unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
