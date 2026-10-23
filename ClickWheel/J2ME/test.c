// Runs a game on the Mac without the app: `test game.jar frames [frame:buttons ...]` presses the
// named buttons (u d l r a b x y L R s) from that frame on and writes a PNG of the screen at
// each `frame:shot`.
#include "libretro.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

static const uint32_t *last;
static unsigned lw, lh;
static uint32_t buttons;
static const char *savedir = "/tmp";

static bool env(unsigned cmd, void *data) {
    if (cmd == RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY) { *(const char **)data = savedir; return true; }
    return cmd == RETRO_ENVIRONMENT_SET_PIXEL_FORMAT;
}
static void video(const void *d, unsigned w, unsigned h, size_t pitch) { (void)pitch; last = d; lw = w; lh = h; }
static size_t audio(const int16_t *d, size_t n) { static FILE *f; if (!f) f = fopen(getenv("AUDIO") ? getenv("AUDIO") : "/dev/null", "wb"); fwrite(d, 4, n, f); return n; }
static void poll(void) {}
static int16_t state(unsigned port, unsigned dev, unsigned idx, unsigned id) { (void)port; (void)dev; (void)idx; return (buttons >> id) & 1; }

static void shot(const char *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate((void *)last, lw, lh, 8, lw * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst); CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    if (getenv("SAVEDIR")) savedir = getenv("SAVEDIR");
    retro_set_environment(env);
    retro_set_video_refresh(video);
    retro_set_audio_sample_batch(audio);
    retro_set_input_poll(poll);
    retro_set_input_state(state);
    retro_init();
    struct retro_game_info info = {argv[1], NULL, 0, NULL};
    if (!retro_load_game(&info)) { fprintf(stderr, "load failed\n"); return 1; }
    int frames = atoi(argv[2]);
    if (getenv("FUZZ")) srand(atoi(getenv("FUZZ")));
    for (int f = 0; f < frames; f++) {
        for (int i = 3; i < argc; i++) {
            int at = atoi(argv[i]);
            const char *what = strchr(argv[i], ':');
            if (at != f || !what) continue;
            what++;
            if (strncmp(what, "shot", 4) == 0) continue;
            buttons = 0;
            for (const char *c = what; *c; c++) {
                const char *keys = "udlraxyLRsS", *k = strchr(keys, *c);
                static const int ids[] = {RETRO_DEVICE_ID_JOYPAD_UP, RETRO_DEVICE_ID_JOYPAD_DOWN, RETRO_DEVICE_ID_JOYPAD_LEFT,
                    RETRO_DEVICE_ID_JOYPAD_RIGHT, RETRO_DEVICE_ID_JOYPAD_A, RETRO_DEVICE_ID_JOYPAD_X, RETRO_DEVICE_ID_JOYPAD_Y,
                    RETRO_DEVICE_ID_JOYPAD_L, RETRO_DEVICE_ID_JOYPAD_R, RETRO_DEVICE_ID_JOYPAD_SELECT, RETRO_DEVICE_ID_JOYPAD_START};
                if (*c == 'b') buttons |= 1u << RETRO_DEVICE_ID_JOYPAD_B;
                else if (k) buttons |= 1u << ids[k - keys];
            }
        }
        if (getenv("FUZZ") && f % 7 == 0) {
            buttons = (uint32_t)rand();
            buttons &= (1u << RETRO_DEVICE_ID_JOYPAD_UP) | (1u << RETRO_DEVICE_ID_JOYPAD_DOWN) | (1u << RETRO_DEVICE_ID_JOYPAD_LEFT)
                     | (1u << RETRO_DEVICE_ID_JOYPAD_RIGHT) | (1u << RETRO_DEVICE_ID_JOYPAD_A) | (1u << RETRO_DEVICE_ID_JOYPAD_B)
                     | (1u << RETRO_DEVICE_ID_JOYPAD_X) | (1u << RETRO_DEVICE_ID_JOYPAD_Y) | (1u << RETRO_DEVICE_ID_JOYPAD_L)
                     | (1u << RETRO_DEVICE_ID_JOYPAD_R);
            if (rand() % 3) buttons &= ~((1u << RETRO_DEVICE_ID_JOYPAD_L) | (1u << RETRO_DEVICE_ID_JOYPAD_R));
        }
        retro_run();
        for (int i = 3; i < argc; i++) {
            const char *what = strchr(argv[i], ':');
            if (atoi(argv[i]) == f && what && strncmp(what + 1, "shot", 4) == 0) {
                char path[256];
                snprintf(path, sizeof path, "%s/shot%05d.png", getenv("SHOTS") ? getenv("SHOTS") : ".", f);
                shot(path);
            }
        }
    }
    retro_unload_game();
    return 0;
}
