// MIDP: the screen (Display, Canvas, GameCanvas), drawing (Graphics, Image, Font), the MIDlet
// lifecycle, RecordStore saves and sound (Samsung's AudioClip, MMAPI's Player), on CoreGraphics,
// ImageIO and CoreText.
#include "jvm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>

#define THIS (args[0].a)
#define ARG(n) (args[n])
#define RETI(x) (ret->j = (int32_t)(x))
#define RETA(x) (ret->a = (x))
#define NATIVE(fn) static void fn(Thread *t, Slot *args, Slot *ret)
#define NPE(o) do { if (!(o)) { vm_throw(t, "java/lang/NullPointerException", NULL); return; } } while (0)
#define UNUSED (void)t; (void)args; (void)ret

Obj *midp_canvas;
Obj *midp_midlet;
int midp_width = 240, midp_height = 320;
bool midp_repaint_pending;
bool midp_exit;
static Obj *display;
static Obj *screen;          // the Image that paint() draws on
static Obj *screen_graphics; // GameCanvas.getGraphics()
static uint32_t key_states;  // GameCanvas.getKeyStates()
static char save_dir[1024];

static Class *image_class, *graphics_class, *font_class;

// MARK: Images

static Obj *new_image(int w, int h, bool mutable_) {
    Obj *o = vm_alloc(image_class, K_IMAGE, 0);
    o->u.img.w = w;
    o->u.img.h = h;
    o->u.img.mutable_ = mutable_;
    o->u.img.pixels = malloc((size_t)w * h * 4);
    vm_allocated += (size_t)w * h * 4;
    return o;
}

static CGContextRef image_context(Obj *img) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(img->u.img.pixels, img->u.img.w, img->u.img.h, 8, img->u.img.w * 4, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return ctx;
}

static Obj *decode_image(const uint8_t *data, int32_t size) {
    CFDataRef cf = CFDataCreate(NULL, data, size);
    CGImageSourceRef src = CGImageSourceCreateWithData(cf, NULL);
    CFRelease(cf);
    if (!src) return NULL;
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) return NULL;
    Obj *img = new_image((int)CGImageGetWidth(cg), (int)CGImageGetHeight(cg), false);
    memset(img->u.img.pixels, 0, (size_t)img->u.img.w * img->u.img.h * 4);
    CGContextRef ctx = image_context(img);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, img->u.img.w, img->u.img.h), cg);
    CGContextRelease(ctx);
    CGImageRelease(cg);
    return img;
}

NATIVE(image_create_resource) {
    (void)ret;
    NPE(ARG(0).a);
    char *name = vm_cstring(ARG(0).a);
    int32_t size;
    uint8_t *data = jar_read(name, &size);
    Obj *img = data ? decode_image(data, size) : NULL;
    free(data);
    if (!img) {
        vm_throw(t, "java/io/IOException", name);
        free(name);
        return;
    }
    free(name);
    RETA(img);
}

NATIVE(image_create_mutable) {
    int w = ARG(0).i, h = ARG(1).i;
    if (w <= 0 || h <= 0) { vm_throw(t, "java/lang/IllegalArgumentException", NULL); return; }
    Obj *img = new_image(w, h, true);
    for (size_t i = 0; i < (size_t)w * h; i++) img->u.img.pixels[i] = 0xFFFFFFFF;  // MIDP: starts white
    RETA(img);
}

NATIVE(image_create_bytes) {
    Obj *b = ARG(0).a;
    NPE(b);
    int32_t off = ARG(1).i, len = ARG(2).i;
    if (off < 0 || len < 0 || off + len > b->length) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
    Obj *img = decode_image((uint8_t *)b->u.data + off, len);
    if (!img) { vm_throw(t, "java/lang/IllegalArgumentException", NULL); return; }
    RETA(img);
}

NATIVE(image_create_copy) {
    Obj *src = ARG(0).a;
    NPE(src);
    if (!src->u.img.mutable_) { RETA(src); return; }
    Obj *img = new_image(src->u.img.w, src->u.img.h, false);
    memcpy(img->u.img.pixels, src->u.img.pixels, (size_t)src->u.img.w * src->u.img.h * 4);
    RETA(img);
}

NATIVE(image_create_rgb) {
    Obj *rgb = ARG(0).a;
    NPE(rgb);
    int w = ARG(1).i, h = ARG(2).i;
    bool alpha = ARG(3).i;
    if (w <= 0 || h <= 0 || rgb->length < w * h) { vm_throw(t, "java/lang/IllegalArgumentException", NULL); return; }
    Obj *img = new_image(w, h, false);
    uint32_t *in = rgb->u.data;
    for (int i = 0; i < w * h; i++) {
        uint32_t p = in[i], a = alpha ? p >> 24 : 255;
        uint32_t r = ((p >> 16) & 255) * a / 255, g = ((p >> 8) & 255) * a / 255, bl = (p & 255) * a / 255;
        img->u.img.pixels[i] = a << 24 | r << 16 | g << 8 | bl;
    }
    RETA(img);
}

NATIVE(image_width) { (void)t; RETI(THIS->u.img.w); }
NATIVE(image_height) { (void)t; RETI(THIS->u.img.h); }
NATIVE(image_ismutable) { (void)t; RETI(THIS->u.img.mutable_); }

static Obj *new_graphics(Obj *img) {
    Obj *g = vm_alloc(graphics_class, K_GRAPHICS, 0);
    g->u.gfx.image = img;
    g->u.gfx.color = 0xFF000000;
    g->u.gfx.cw = img->u.img.w;
    g->u.gfx.ch = img->u.img.h;
    return g;
}

NATIVE(image_getgraphics) {
    if (!THIS->u.img.mutable_) { vm_throw(t, "java/lang/IllegalStateException", NULL); return; }
    RETA(new_graphics(THIS));
}

NATIVE(image_getrgb) {
    (void)ret;
    Obj *out = ARG(1).a;
    NPE(out);
    int off = ARG(2).i, scan = ARG(3).i, x0 = ARG(4).i, y0 = ARG(5).i, w = ARG(6).i, h = ARG(7).i;
    Obj *img = THIS;
    if (x0 < 0 || y0 < 0 || x0 + w > img->u.img.w || y0 + h > img->u.img.h) { vm_throw(t, "java/lang/IllegalArgumentException", NULL); return; }
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            int i = off + y * scan + x;
            if (i < 0 || i >= out->length) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
            uint32_t p = img->u.img.pixels[(y0 + y) * img->u.img.w + x0 + x], a = p >> 24;
            if (a && a < 255) {
                uint32_t r = ((p >> 16) & 255) * 255 / a, g = ((p >> 8) & 255) * 255 / a, b = (p & 255) * 255 / a;
                p = a << 24 | (r > 255 ? 255 : r) << 16 | (g > 255 ? 255 : g) << 8 | (b > 255 ? 255 : b);
            }
            ((uint32_t *)out->u.data)[i] = p;
        }
}

// MARK: Graphics

static inline void blend(uint32_t *d, uint32_t s) {
    uint32_t a = s >> 24;
    if (a == 255) { *d = s; return; }
    if (a == 0) return;
    uint32_t inv = 255 - a, p = *d;
    uint32_t r = (s >> 16 & 255) + ((p >> 16 & 255) * inv + 127) / 255;
    uint32_t g = (s >> 8 & 255) + ((p >> 8 & 255) * inv + 127) / 255;
    uint32_t b = (s & 255) + ((p & 255) * inv + 127) / 255;
    uint32_t da = a + ((p >> 24) * inv + 127) / 255;
    *d = da << 24 | (r > 255 ? 255 : r) << 16 | (g > 255 ? 255 : g) << 8 | (b > 255 ? 255 : b);
}

// The clip, in image coordinates, intersected with the image.
static void clip_rect(Obj *g, int *x0, int *y0, int *x1, int *y1) {
    Obj *img = g->u.gfx.image;
    *x0 = g->u.gfx.cx < 0 ? 0 : g->u.gfx.cx;
    *y0 = g->u.gfx.cy < 0 ? 0 : g->u.gfx.cy;
    *x1 = g->u.gfx.cx + g->u.gfx.cw;
    *y1 = g->u.gfx.cy + g->u.gfx.ch;
    if (*x1 > img->u.img.w) *x1 = img->u.img.w;
    if (*y1 > img->u.img.h) *y1 = img->u.img.h;
}

static void fill(Obj *g, int x, int y, int w, int h) {
    int cx0, cy0, cx1, cy1;
    clip_rect(g, &cx0, &cy0, &cx1, &cy1);
    x += g->u.gfx.tx;
    y += g->u.gfx.ty;
    int x0 = x < cx0 ? cx0 : x, y0 = y < cy0 ? cy0 : y;
    int x1 = x + w > cx1 ? cx1 : x + w, y1 = y + h > cy1 ? cy1 : y + h;
    Obj *img = g->u.gfx.image;
    uint32_t c = g->u.gfx.color;
    for (int yy = y0; yy < y1; yy++) {
        uint32_t *row = img->u.img.pixels + (size_t)yy * img->u.img.w;
        for (int xx = x0; xx < x1; xx++) row[xx] = c;
    }
}

static void plot(Obj *g, int x, int y) { fill(g, x, y, 1, 1); }

NATIVE(g_setcolor) { (void)t; (void)ret; THIS->u.gfx.color = 0xFF000000 | (ARG(1).i & 0xFFFFFF); }
NATIVE(g_setcolor_rgb) {
    (void)t; (void)ret;
    THIS->u.gfx.color = 0xFF000000 | (ARG(1).i & 255) << 16 | (ARG(2).i & 255) << 8 | (ARG(3).i & 255);
}
NATIVE(g_getcolor) { (void)t; RETI(THIS->u.gfx.color & 0xFFFFFF); }
NATIVE(g_setgray) { (void)t; (void)ret; int v = ARG(1).i & 255; THIS->u.gfx.color = 0xFF000000 | v << 16 | v << 8 | v; }
NATIVE(g_fillrect) { (void)t; (void)ret; if (ARG(3).i > 0 && ARG(4).i > 0) fill(THIS, ARG(1).i, ARG(2).i, ARG(3).i, ARG(4).i); }
NATIVE(g_drawrect) {
    (void)t; (void)ret;
    int x = ARG(1).i, y = ARG(2).i, w = ARG(3).i, h = ARG(4).i;
    if (w < 0 || h < 0) return;
    fill(THIS, x, y, w + 1, 1);
    fill(THIS, x, y + h, w + 1, 1);
    fill(THIS, x, y, 1, h + 1);
    fill(THIS, x + w, y, 1, h + 1);
}
NATIVE(g_drawline) {
    (void)t; (void)ret;
    int x0 = ARG(1).i, y0 = ARG(2).i, x1 = ARG(3).i, y1 = ARG(4).i;
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1, dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1, err = dx + dy;
    for (int n = 0; n < 4096; n++) {
        plot(THIS, x0, y0);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}
static void ellipse(Obj *g, int x, int y, int w, int h, bool filled) {
    if (w <= 0 || h <= 0) return;
    double rx = w / 2.0, ry = h / 2.0, cx = x + rx;
    for (int yy = 0; yy < h; yy++) {
        double dy = (yy + 0.5 - ry) / ry;
        double span = rx * __builtin_sqrt(1 - dy * dy > 0 ? 1 - dy * dy : 0);
        int a = (int)(cx - span + 0.5), b = (int)(cx + span + 0.5);
        if (filled) fill(g, a, y + yy, b - a, 1);
        else { plot(g, a, y + yy); plot(g, b - 1, y + yy); }
    }
}
NATIVE(g_fillarc) { (void)t; (void)ret; ellipse(THIS, ARG(1).i, ARG(2).i, ARG(3).i, ARG(4).i, true); }
NATIVE(g_drawarc) { (void)t; (void)ret; ellipse(THIS, ARG(1).i, ARG(2).i, ARG(3).i + 1, ARG(4).i + 1, false); }
NATIVE(g_fillroundrect) { (void)t; (void)ret; if (ARG(3).i > 0 && ARG(4).i > 0) fill(THIS, ARG(1).i, ARG(2).i, ARG(3).i, ARG(4).i); }
NATIVE(g_drawroundrect) { g_drawrect(t, args, ret); }
NATIVE(g_filltriangle) {
    (void)t; (void)ret;
    int x[3] = {ARG(1).i, ARG(3).i, ARG(5).i}, y[3] = {ARG(2).i, ARG(4).i, ARG(6).i};
    int ymin = y[0], ymax = y[0];
    for (int i = 1; i < 3; i++) { if (y[i] < ymin) ymin = y[i]; if (y[i] > ymax) ymax = y[i]; }
    for (int yy = ymin; yy <= ymax; yy++) {
        double lo = 1e9, hi = -1e9;
        for (int i = 0; i < 3; i++) {
            int j = (i + 1) % 3;
            if ((y[i] <= yy && y[j] >= yy) || (y[j] <= yy && y[i] >= yy)) {
                double xx = y[i] == y[j] ? x[i] : x[i] + (double)(yy - y[i]) * (x[j] - x[i]) / (y[j] - y[i]);
                if (xx < lo) lo = xx;
                if (xx > hi) hi = xx;
                if (y[i] == y[j]) { if (x[j] < lo) lo = x[j]; if (x[j] > hi) hi = x[j]; }
            }
        }
        if (hi >= lo) fill(THIS, (int)lo, yy, (int)hi - (int)lo + 1, 1);
    }
}

static void anchor_box(int anchor, int w, int h, int *x, int *y) {
    if (anchor & 1) *x -= w / 2;
    else if (anchor & 8) *x -= w;
    if (anchor & 2) *y -= h / 2;
    else if (anchor & 32) *y -= h;
}

// Draws a w×h region of src at (sx, sy), turned by a Sprite transform, with its top left at (x, y).
static void draw_region(Obj *g, Obj *src, int sx, int sy, int w, int h, int transform, int x, int y) {
    // Each transform maps destination (dx, dy) to a source offset.
    bool swap = transform >= 4;
    int dw = swap ? h : w, dh = swap ? w : h;
    int cx0, cy0, cx1, cy1;
    clip_rect(g, &cx0, &cy0, &cx1, &cy1);
    x += g->u.gfx.tx;
    y += g->u.gfx.ty;
    Obj *dst = g->u.gfx.image;
    int sw = src->u.img.w;
    for (int dy = 0; dy < dh; dy++) {
        int py = y + dy;
        if (py < cy0 || py >= cy1) continue;
        uint32_t *row = dst->u.img.pixels + (size_t)py * dst->u.img.w;
        for (int dx = 0; dx < dw; dx++) {
            int px = x + dx;
            if (px < cx0 || px >= cx1) continue;
            int ux, uy;
            switch (transform) {
            case 0: ux = dx; uy = dy; break;                    // NONE
            case 2: ux = w - 1 - dx; uy = dy; break;            // MIRROR
            case 1: ux = dx; uy = h - 1 - dy; break;            // MIRROR_ROT180
            case 3: ux = w - 1 - dx; uy = h - 1 - dy; break;    // ROT180
            case 5: ux = dy; uy = h - 1 - dx; break;            // ROT90
            case 6: ux = w - 1 - dy; uy = dx; break;            // ROT270
            case 4: ux = dy; uy = dx; break;                    // MIRROR_ROT270
            default: ux = w - 1 - dy; uy = h - 1 - dx; break;   // MIRROR_ROT90
            }
            blend(&row[px], src->u.img.pixels[(size_t)(sy + uy) * sw + sx + ux]);
        }
    }
}

NATIVE(g_drawimage) {
    (void)ret;
    Obj *img = ARG(1).a;
    NPE(img);
    int x = ARG(2).i, y = ARG(3).i;
    anchor_box(ARG(4).i, img->u.img.w, img->u.img.h, &x, &y);
    draw_region(THIS, img, 0, 0, img->u.img.w, img->u.img.h, 0, x, y);
}

NATIVE(g_drawregion) {
    (void)ret;
    Obj *img = ARG(1).a;
    NPE(img);
    int sx = ARG(2).i, sy = ARG(3).i, w = ARG(4).i, h = ARG(5).i, tr = ARG(6).i, x = ARG(7).i, y = ARG(8).i;
    if (sx < 0 || sy < 0 || w < 0 || h < 0 || sx + w > img->u.img.w || sy + h > img->u.img.h) {
        vm_throw(t, "java/lang/IllegalArgumentException", NULL);
        return;
    }
    anchor_box(ARG(9).i, tr >= 4 ? h : w, tr >= 4 ? w : h, &x, &y);
    draw_region(THIS, img, sx, sy, w, h, tr & 7, x, y);
}

NATIVE(g_drawrgb) {
    (void)ret;
    Obj *rgb = ARG(1).a;
    NPE(rgb);
    int off = ARG(2).i, scan = ARG(3).i, x = ARG(4).i, y = ARG(5).i, w = ARG(6).i, h = ARG(7).i;
    bool alpha = ARG(8).i;
    int cx0, cy0, cx1, cy1;
    clip_rect(THIS, &cx0, &cy0, &cx1, &cy1);
    x += THIS->u.gfx.tx;
    y += THIS->u.gfx.ty;
    Obj *dst = THIS->u.gfx.image;
    for (int dy = 0; dy < h; dy++) {
        if (y + dy < cy0 || y + dy >= cy1) continue;
        for (int dx = 0; dx < w; dx++) {
            if (x + dx < cx0 || x + dx >= cx1) continue;
            int i = off + dy * scan + dx;
            if (i < 0 || i >= rgb->length) continue;
            uint32_t p = ((uint32_t *)rgb->u.data)[i], a = alpha ? p >> 24 : 255;
            uint32_t s = a << 24 | (((p >> 16) & 255) * a / 255) << 16 | (((p >> 8) & 255) * a / 255) << 8 | ((p & 255) * a / 255);
            blend(&dst->u.img.pixels[(size_t)(y + dy) * dst->u.img.w + x + dx], s);
        }
    }
}

NATIVE(g_translate) { (void)t; (void)ret; THIS->u.gfx.tx += ARG(1).i; THIS->u.gfx.ty += ARG(2).i; }
NATIVE(g_gettx) { (void)t; RETI(THIS->u.gfx.tx); }
NATIVE(g_getty) { (void)t; RETI(THIS->u.gfx.ty); }
NATIVE(g_setclip) {
    (void)t; (void)ret;
    THIS->u.gfx.cx = ARG(1).i + THIS->u.gfx.tx;
    THIS->u.gfx.cy = ARG(2).i + THIS->u.gfx.ty;
    THIS->u.gfx.cw = ARG(3).i < 0 ? 0 : ARG(3).i;
    THIS->u.gfx.ch = ARG(4).i < 0 ? 0 : ARG(4).i;
}
NATIVE(g_cliprect) {
    (void)t; (void)ret;
    int x0 = ARG(1).i + THIS->u.gfx.tx, y0 = ARG(2).i + THIS->u.gfx.ty;
    int x1 = x0 + ARG(3).i, y1 = y0 + ARG(4).i;
    int cx1 = THIS->u.gfx.cx + THIS->u.gfx.cw, cy1 = THIS->u.gfx.cy + THIS->u.gfx.ch;
    if (x0 < THIS->u.gfx.cx) x0 = THIS->u.gfx.cx;
    if (y0 < THIS->u.gfx.cy) y0 = THIS->u.gfx.cy;
    if (x1 > cx1) x1 = cx1;
    if (y1 > cy1) y1 = cy1;
    THIS->u.gfx.cx = x0;
    THIS->u.gfx.cy = y0;
    THIS->u.gfx.cw = x1 > x0 ? x1 - x0 : 0;
    THIS->u.gfx.ch = y1 > y0 ? y1 - y0 : 0;
}
NATIVE(g_getclipx) { (void)t; RETI(THIS->u.gfx.cx - THIS->u.gfx.tx); }
NATIVE(g_getclipy) { (void)t; RETI(THIS->u.gfx.cy - THIS->u.gfx.ty); }
NATIVE(g_getclipw) { (void)t; RETI(THIS->u.gfx.cw); }
NATIVE(g_getcliph) { (void)t; RETI(THIS->u.gfx.ch); }

// MARK: Fonts and text

static Obj *default_font;

static CTFontRef ct_font(Obj *font) {
    static CTFontRef cache[3][4];
    int size = font ? font->u.font.size : 0, style = font ? font->u.font.style & 3 : 0;
    int si = size == 8 ? 0 : size == 16 ? 2 : 1;
    if (!cache[si][style]) {
        static const CGFloat px[3] = {11, 12, 15};
        CFStringRef name = style & 1 ? CFSTR("Helvetica-Bold") : CFSTR("Helvetica");
        CTFontRef base = CTFontCreateWithName(name, px[si], NULL);
        if (style & 2) {
            CTFontRef italic = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, kCTFontItalicTrait, kCTFontItalicTrait);
            if (italic) { CFRelease(base); base = italic; }
        }
        cache[si][style] = base;
    }
    return cache[si][style];
}

static int text_height(Obj *font) {
    CTFontRef f = ct_font(font);
    return (int)(CTFontGetAscent(f) + CTFontGetDescent(f) + 1.5);
}
static int text_baseline(Obj *font) { return (int)(CTFontGetAscent(ct_font(font)) + 0.5); }

static CTLineRef make_line(Obj *font, const uint16_t *chars, int32_t len, uint32_t color) {
    CFStringRef str = CFStringCreateWithCharacters(NULL, chars, len);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[4] = {(color >> 16 & 255) / 255.0, (color >> 8 & 255) / 255.0, (color & 255) / 255.0, 1};
    CGColorRef cg = CGColorCreate(space, comps);
    CGColorSpaceRelease(space);
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void *vals[] = {ct_font(font), cg};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(as);
    CFRelease(as);
    CFRelease(attrs);
    CGColorRelease(cg);
    CFRelease(str);
    return line;
}

static int text_width(Obj *font, const uint16_t *chars, int32_t len) {
    if (len <= 0) return 0;
    CTLineRef line = make_line(font, chars, len, 0);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return (int)(w + 0.5);
}

static void draw_text(Obj *g, const uint16_t *chars, int32_t len, int x, int y, int anchor) {
    if (len <= 0) return;
    Obj *font = g->u.gfx.font ? g->u.gfx.font : default_font;
    CTLineRef line = make_line(font, chars, len, g->u.gfx.color);
    int w = (int)(CTLineGetTypographicBounds(line, NULL, NULL, NULL) + 0.5);
    if (anchor == 0) anchor = 16 | 4;
    if (anchor & 1) x -= w / 2;
    else if (anchor & 8) x -= w;
    int baseline = y;
    if (anchor & 16) baseline = y + text_baseline(font);
    else if (anchor & 32) baseline = y - (text_height(font) - text_baseline(font));
    x += g->u.gfx.tx;
    baseline += g->u.gfx.ty;
    Obj *img = g->u.gfx.image;
    int cx0, cy0, cx1, cy1;
    clip_rect(g, &cx0, &cy0, &cx1, &cy1);
    if (cx1 <= cx0 || cy1 <= cy0) { CFRelease(line); return; }
    CGContextRef ctx = image_context(img);
    // CoreGraphics counts y from the bottom.
    CGContextClipToRect(ctx, CGRectMake(cx0, img->u.img.h - cy1, cx1 - cx0, cy1 - cy0));
    CGContextSetShouldSmoothFonts(ctx, false);
    CGContextSetTextPosition(ctx, x, img->u.img.h - baseline);
    CTLineDraw(line, ctx);
    CGContextRelease(ctx);
    CFRelease(line);
}

NATIVE(g_drawstring) {
    (void)ret;
    Obj *s = ARG(1).a;
    NPE(s);
    draw_text(THIS, s->u.data, s->length, ARG(2).i, ARG(3).i, ARG(4).i);
}
NATIVE(g_drawsubstring) {
    (void)ret;
    Obj *s = ARG(1).a;
    NPE(s);
    int off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > s->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    draw_text(THIS, (uint16_t *)s->u.data + off, len, ARG(4).i, ARG(5).i, ARG(6).i);
}
NATIVE(g_drawchar) {
    (void)t; (void)ret;
    uint16_t c = (uint16_t)ARG(1).i;
    draw_text(THIS, &c, 1, ARG(2).i, ARG(3).i, ARG(4).i);
}
NATIVE(g_drawchars) {
    (void)ret;
    Obj *a = ARG(1).a;
    NPE(a);
    int off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > a->length) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
    draw_text(THIS, (uint16_t *)a->u.data + off, len, ARG(4).i, ARG(5).i, ARG(6).i);
}
NATIVE(g_setfont) { (void)t; (void)ret; THIS->u.gfx.font = ARG(1).a; }
NATIVE(g_getfont) { (void)t; RETA(THIS->u.gfx.font ? THIS->u.gfx.font : default_font); }

static Obj *new_font(int face, int style, int size) {
    Obj *f = vm_alloc(font_class, K_FONT, 0);
    f->u.font.face = face;
    f->u.font.style = style;
    f->u.font.size = size;
    return f;
}
NATIVE(font_getdefault) { (void)t; (void)args; RETA(default_font); }
NATIVE(font_getfont) { (void)t; RETA(new_font(ARG(0).i, ARG(1).i, ARG(2).i)); }
NATIVE(font_height) { (void)t; RETI(text_height(THIS)); }
NATIVE(font_baseline) { (void)t; RETI(text_baseline(THIS)); }
NATIVE(font_stringwidth) { NPE(ARG(1).a); RETI(text_width(THIS, ARG(1).a->u.data, ARG(1).a->length)); }
NATIVE(font_substringwidth) {
    Obj *s = ARG(1).a;
    NPE(s);
    int off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > s->length) { vm_throw(t, "java/lang/StringIndexOutOfBoundsException", NULL); return; }
    RETI(text_width(THIS, (uint16_t *)s->u.data + off, len));
}
NATIVE(font_charwidth) { (void)t; uint16_t c = (uint16_t)ARG(1).i; RETI(text_width(THIS, &c, 1)); }
NATIVE(font_charswidth) {
    Obj *a = ARG(1).a;
    NPE(a);
    int off = ARG(2).i, len = ARG(3).i;
    if (off < 0 || len < 0 || off + len > a->length) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
    RETI(text_width(THIS, (uint16_t *)a->u.data + off, len));
}
NATIVE(font_getstyle) { (void)t; RETI(THIS->u.font.style); }
NATIVE(font_getsize) { (void)t; RETI(THIS->u.font.size); }
NATIVE(font_getface) { (void)t; RETI(THIS->u.font.face); }

// MARK: Display, Canvas, MIDlet

void midp_paint(void) {
    if (!midp_canvas || !midp_repaint_pending) return;
    midp_repaint_pending = false;
    Method *paint = vm_find_method(midp_canvas->cls, "paint", "(Ljavax/microedition/lcdui/Graphics;)V");
    if (!paint || paint->native) return;
    Obj *g = new_graphics(screen);
    Slot args[2] = {{.a = midp_canvas}, {.a = g}};
    vm_call(paint, args, NULL);
}

static void call_canvas(const char *name, int code) {
    if (!midp_canvas) return;
    Method *m = vm_find_method(midp_canvas->cls, name, "(I)V");
    if (!m || m->native) return;
    Slot args[2] = {{.a = midp_canvas}, {.j = code}};
    vm_call(m, args, NULL);
}

static int game_action(int code) {
    switch (code) {
    case -1: case '2': return 1;   // UP
    case -2: case '8': return 6;   // DOWN
    case -3: case '4': return 2;   // LEFT
    case -4: case '6': return 5;   // RIGHT
    case -5: case '5': return 8;   // FIRE
    case '1': return 9;            // GAME_A
    case '3': return 10;           // GAME_B
    case '7': return 11;           // GAME_C
    case '9': return 12;           // GAME_D
    default: return 0;
    }
}

void midp_key(int code, bool pressed) {
    int action = game_action(code);
    if (action) {
        if (pressed) key_states |= 1u << action;
        else key_states &= ~(1u << action);
    }
    call_canvas(pressed ? "keyPressed" : "keyReleased", code);
}

static void set_current(Obj *d) {
    if (!d || d == midp_canvas) return;
    if (midp_canvas) {
        Method *hide = vm_find_method(midp_canvas->cls, "hideNotify", "()V");
        if (hide && !hide->native) { Slot a = {.a = midp_canvas}; vm_call(hide, &a, NULL); }
    }
    midp_canvas = d;
    Method *show = vm_find_method(d->cls, "showNotify", "()V");
    if (show && !show->native) { Slot a = {.a = d}; vm_call(show, &a, NULL); }
    midp_repaint_pending = true;
}

NATIVE(display_get) { (void)t; (void)args; RETA(display); }
NATIVE(display_setcurrent) { (void)t; (void)ret; set_current(ARG(1).a); }
NATIVE(display_getcurrent) { (void)t; (void)args; RETA(midp_canvas); }
NATIVE(display_vibrate) { (void)t; (void)args; RETI(1); }
NATIVE(display_iscolor) { (void)t; (void)args; RETI(1); }
NATIVE(display_numcolors) { (void)t; (void)args; RETI(65536); }

NATIVE(nop) { UNUSED; }
NATIVE(canvas_repaint) { (void)t; (void)args; (void)ret; midp_repaint_pending = true; }
NATIVE(canvas_servicerepaints) { (void)t; (void)args; (void)ret; midp_paint(); }
NATIVE(canvas_width) { (void)t; (void)args; RETI(midp_width); }
NATIVE(canvas_height) { (void)t; (void)args; RETI(midp_height); }
NATIVE(canvas_true) { (void)t; (void)args; RETI(1); }
NATIVE(canvas_false) { (void)t; (void)args; RETI(0); }
NATIVE(canvas_gameaction) { (void)t; RETI(game_action(ARG(1).i)); }
NATIVE(canvas_keycode) {
    (void)t;
    static const int codes[] = {0, -1, -3, 0, 0, -4, -2, 0, -5, '1', '3', '7', '9'};
    int a = ARG(1).i;
    RETI(a >= 0 && a <= 12 ? codes[a] : 0);
}
NATIVE(canvas_keyname) { (void)t; char b[16]; snprintf(b, sizeof b, "%d", ARG(1).i); RETA(vm_string(b)); }
NATIVE(gamecanvas_init) { (void)t; (void)args; (void)ret; }
NATIVE(gamecanvas_graphics) {
    (void)t; (void)args;
    if (!screen_graphics) screen_graphics = new_graphics(screen);
    RETA(screen_graphics);
}
NATIVE(gamecanvas_keystates) { (void)t; (void)args; RETI(key_states); }

NATIVE(midlet_destroyed) { (void)t; (void)args; (void)ret; midp_exit = true; }
NATIVE(midlet_property) {
    (void)t;
    char *key = vm_cstring(ARG(1).a);
    const char *v = jar_manifest(key);
    free(key);
    RETA(v ? vm_string(v) : NULL);
}

// MARK: RecordStore: each store is a file of [id][length][bytes] records in the save folder.

typedef struct Store {
    char name[64];
    int nrecords, next_id;
    int *ids;
    int32_t *sizes;
    uint8_t **data;
    struct Store *next;
} Store;

static Store *stores;

static void store_path(const char *name, char *out, size_t size) {
    char safe[64];
    size_t i = 0;
    for (; name[i] && i < sizeof safe - 1; i++) safe[i] = (name[i] == '/' || name[i] == '.') ? '_' : name[i];
    safe[i] = 0;
    snprintf(out, size, "%s/%s.rms", save_dir, safe);
}

static void store_save(Store *s) {
    if (!save_dir[0]) return;
    char path[1200];
    store_path(s->name, path, sizeof path);
    char tmp[1210];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return;
    int32_t head[2] = {s->next_id, s->nrecords};
    fwrite(head, 4, 2, f);
    for (int i = 0; i < s->nrecords; i++) {
        int32_t rec[2] = {s->ids[i], s->sizes[i]};
        fwrite(rec, 4, 2, f);
        fwrite(s->data[i], 1, s->sizes[i], f);
    }
    fclose(f);
    rename(tmp, path);
}

static Store *store_find(const char *name, bool create) {
    for (Store *s = stores; s; s = s->next)
        if (strcmp(s->name, name) == 0) return s;
    char path[1200];
    store_path(name, path, sizeof path);
    FILE *f = save_dir[0] ? fopen(path, "rb") : NULL;
    if (!f && !create) return NULL;
    Store *s = calloc(1, sizeof(Store));
    snprintf(s->name, sizeof s->name, "%s", name);
    s->next_id = 1;
    if (f) {
        int32_t head[2];
        if (fread(head, 4, 2, f) == 2 && head[1] >= 0 && head[1] < 100000) {
            s->next_id = head[0];
            for (int i = 0; i < head[1]; i++) {
                int32_t rec[2];
                if (fread(rec, 4, 2, f) != 2 || rec[1] < 0 || rec[1] > (1 << 24)) break;
                uint8_t *d = malloc(rec[1] + 1);
                if (fread(d, 1, rec[1], f) != (size_t)rec[1]) { free(d); break; }
                s->ids = realloc(s->ids, (s->nrecords + 1) * sizeof(int));
                s->sizes = realloc(s->sizes, (s->nrecords + 1) * sizeof(int32_t));
                s->data = realloc(s->data, (s->nrecords + 1) * sizeof(uint8_t *));
                s->ids[s->nrecords] = rec[0];
                s->sizes[s->nrecords] = rec[1];
                s->data[s->nrecords] = d;
                s->nrecords++;
            }
        }
        fclose(f);
    } else {
        s->next = stores;
        stores = s;
        store_save(s);
        return s;
    }
    s->next = stores;
    stores = s;
    return s;
}

static Store *store_of(Thread *t, Obj *rs) {
    Store *s = rs && rs->u.rs.name ? store_find(rs->u.rs.name, false) : NULL;
    if (!s) vm_throw(t, "javax/microedition/rms/RecordStoreNotOpenException", NULL);
    return s;
}

static int record_index(Store *s, int id) {
    for (int i = 0; i < s->nrecords; i++) if (s->ids[i] == id) return i;
    return -1;
}

NATIVE(rs_open) {
    NPE(ARG(0).a);
    char *name = vm_cstring(ARG(0).a);
    Store *s = store_find(name, ARG(1).i);
    if (!s) {
        vm_throw(t, "javax/microedition/rms/RecordStoreNotFoundException", name);
        free(name);
        return;
    }
    Obj *o = vm_alloc(vm_class("javax/microedition/rms/RecordStore"), K_RECORDSTORE, 0);
    o->u.rs.name = name;
    RETA(o);
}
NATIVE(rs_close) { (void)t; (void)args; (void)ret; }
NATIVE(rs_delete) {
    (void)ret;
    NPE(ARG(0).a);
    char *name = vm_cstring(ARG(0).a);
    for (Store **p = &stores; *p; p = &(*p)->next)
        if (strcmp((*p)->name, name) == 0) {
            Store *s = *p;
            *p = s->next;
            for (int i = 0; i < s->nrecords; i++) free(s->data[i]);
            free(s->ids); free(s->sizes); free(s->data); free(s);
            break;
        }
    char path[1200];
    store_path(name, path, sizeof path);
    if (remove(path) != 0) vm_throw(t, "javax/microedition/rms/RecordStoreNotFoundException", name);
    free(name);
}
NATIVE(rs_numrecords) { Store *s = store_of(t, THIS); if (s) RETI(s->nrecords); }
NATIVE(rs_nextid) { Store *s = store_of(t, THIS); if (s) RETI(s->next_id); }
NATIVE(rs_size) {
    Store *s = store_of(t, THIS);
    if (!s) return;
    int32_t n = 0;
    for (int i = 0; i < s->nrecords; i++) n += s->sizes[i];
    RETI(n);
}
NATIVE(rs_available) { (void)t; (void)args; RETI(64 * 1024); }
NATIVE(rs_add) {
    Store *s = store_of(t, THIS);
    if (!s) return;
    Obj *b = ARG(1).a;
    int32_t off = ARG(2).i, len = ARG(3).i;
    if (b ? (off < 0 || len < 0 || off + len > b->length) : len != 0) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
    uint8_t *d = malloc(len + 1);
    if (len) memcpy(d, (uint8_t *)b->u.data + off, len);
    s->ids = realloc(s->ids, (s->nrecords + 1) * sizeof(int));
    s->sizes = realloc(s->sizes, (s->nrecords + 1) * sizeof(int32_t));
    s->data = realloc(s->data, (s->nrecords + 1) * sizeof(uint8_t *));
    s->ids[s->nrecords] = s->next_id;
    s->sizes[s->nrecords] = len;
    s->data[s->nrecords] = d;
    s->nrecords++;
    RETI(s->next_id++);
    store_save(s);
}
NATIVE(rs_set) {
    (void)ret;
    Store *s = store_of(t, THIS);
    if (!s) return;
    int i = record_index(s, ARG(1).i);
    if (i < 0) { vm_throw(t, "javax/microedition/rms/InvalidRecordIDException", NULL); return; }
    Obj *b = ARG(2).a;
    int32_t off = ARG(3).i, len = ARG(4).i;
    if (b ? (off < 0 || len < 0 || off + len > b->length) : len != 0) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
    free(s->data[i]);
    s->data[i] = malloc(len + 1);
    if (len) memcpy(s->data[i], (uint8_t *)b->u.data + off, len);
    s->sizes[i] = len;
    store_save(s);
}
NATIVE(rs_get) {
    Store *s = store_of(t, THIS);
    if (!s) return;
    int i = record_index(s, ARG(1).i);
    if (i < 0) { vm_throw(t, "javax/microedition/rms/InvalidRecordIDException", NULL); return; }
    Obj *a = vm_new_array(T_BYTE, s->sizes[i], NULL);
    memcpy(a->u.data, s->data[i], s->sizes[i]);
    RETA(s->sizes[i] ? a : NULL);
}
NATIVE(rs_get_into) {
    Store *s = store_of(t, THIS);
    if (!s) return;
    int i = record_index(s, ARG(1).i);
    if (i < 0) { vm_throw(t, "javax/microedition/rms/InvalidRecordIDException", NULL); return; }
    Obj *b = ARG(2).a;
    NPE(b);
    int32_t off = ARG(3).i;
    if (off < 0 || off + s->sizes[i] > b->length) { vm_throw(t, "java/lang/ArrayIndexOutOfBoundsException", NULL); return; }
    memcpy((uint8_t *)b->u.data + off, s->data[i], s->sizes[i]);
    RETI(s->sizes[i]);
}
NATIVE(rs_recordsize) {
    Store *s = store_of(t, THIS);
    if (!s) return;
    int i = record_index(s, ARG(1).i);
    if (i < 0) { vm_throw(t, "javax/microedition/rms/InvalidRecordIDException", NULL); return; }
    RETI(s->sizes[i]);
}
NATIVE(rs_deleterecord) {
    (void)ret;
    Store *s = store_of(t, THIS);
    if (!s) return;
    int i = record_index(s, ARG(1).i);
    if (i < 0) { vm_throw(t, "javax/microedition/rms/InvalidRecordIDException", NULL); return; }
    free(s->data[i]);
    for (int k = i; k < s->nrecords - 1; k++) {
        s->ids[k] = s->ids[k + 1];
        s->sizes[k] = s->sizes[k + 1];
        s->data[k] = s->data[k + 1];
    }
    s->nrecords--;
    store_save(s);
}

void midp_set_save_dir(const char *dir) {
    snprintf(save_dir, sizeof save_dir, "%s", dir);
    mkdir(save_dir, 0755);
}

// MARK: Sound

static Obj *audio_from_stream(Obj *stream) {
    Obj *a = vm_alloc(vm_class("javax/microedition/media/Player"), K_AUDIO, 0);
    while (stream && stream->u.st.inner) stream = stream->u.st.inner;
    if (stream && stream->u.st.bytes)
        a->u.au.clip = midi_load(stream->u.st.bytes + stream->u.st.pos, stream->u.st.size - stream->u.st.pos);
    return a;
}

NATIVE(audioclip_init) {
    (void)ret;
    NPE(ARG(2).a);
    char *name = vm_cstring(ARG(2).a);
    int32_t size;
    uint8_t *data = jar_read(name, &size);
    free(name);
    if (!data) { vm_throw(t, "java/io/IOException", NULL); return; }
    THIS->u.au.clip = midi_load(data, size);
    free(data);
}
NATIVE(audioclip_play) { (void)t; (void)ret; if (THIS->u.au.clip) midi_play(THIS->u.au.clip, ARG(1).i, ARG(2).i); }
NATIVE(audioclip_stop) { (void)t; (void)args; (void)ret; if (THIS->u.au.clip) midi_stop(THIS->u.au.clip); }
NATIVE(audioclip_supported) { (void)t; (void)args; RETI(1); }

static int player_loops(Obj *p) { return p->flags ? (p->flags == 255 ? 0 : p->flags) : 1; }
NATIVE(manager_createplayer) { (void)t; RETA(audio_from_stream(ARG(0).a)); }
NATIVE(player_start) { (void)t; (void)ret; (void)args; if (THIS->u.au.clip) midi_play(THIS->u.au.clip, player_loops(THIS), 5); }
NATIVE(player_stop) { (void)t; (void)args; (void)ret; if (THIS->u.au.clip) midi_stop(THIS->u.au.clip); }
NATIVE(player_setloop) { (void)t; (void)ret; THIS->flags = ARG(1).i < 0 ? 255 : ARG(1).i > 254 ? 254 : ARG(1).i; }
NATIVE(player_state) { (void)t; (void)args; RETI(300); }
NATIVE(player_null) { (void)t; (void)args; RETA(NULL); }

NATIVE(vibration_start) { UNUSED; }
NATIVE(vibration_supported) { (void)t; (void)args; RETI(0); }

// MARK: Registration

void midp_init(void) {
    midp_canvas = NULL;
    midp_midlet = NULL;
    midp_repaint_pending = false;
    midp_exit = false;
    key_states = 0;
    screen_graphics = NULL;
    stores = NULL;

    vm_native_class("javax/microedition/midlet/MIDlet", "java/lang/Object", K_PLAIN);
    vm_native_class("javax/microedition/lcdui/Display", "java/lang/Object", K_PLAIN);
    vm_native_class("javax/microedition/lcdui/Displayable", "java/lang/Object", K_PLAIN);
    vm_native_class("javax/microedition/lcdui/Canvas", "javax/microedition/lcdui/Displayable", K_PLAIN);
    vm_native_class("javax/microedition/lcdui/game/GameCanvas", "javax/microedition/lcdui/Canvas", K_PLAIN);
    image_class = vm_native_class("javax/microedition/lcdui/Image", "java/lang/Object", K_IMAGE);
    graphics_class = vm_native_class("javax/microedition/lcdui/Graphics", "java/lang/Object", K_GRAPHICS);
    font_class = vm_native_class("javax/microedition/lcdui/Font", "java/lang/Object", K_FONT);
    vm_native_class("javax/microedition/rms/RecordStore", "java/lang/Object", K_RECORDSTORE);
    vm_native_class("com/samsung/util/AudioClip", "java/lang/Object", K_AUDIO);
    vm_native_class("javax/microedition/media/Player", "java/lang/Object", K_AUDIO);

    display = vm_alloc(vm_class("javax/microedition/lcdui/Display"), K_PLAIN, 0);
    screen = new_image(midp_width, midp_height, true);
    memset(screen->u.img.pixels, 0, (size_t)midp_width * midp_height * 4);
    for (int i = 0; i < midp_width * midp_height; i++) screen->u.img.pixels[i] = 0xFF000000;
    default_font = new_font(0, 0, 0);
    vm_add_root(&midp_canvas);
    vm_add_root(&midp_midlet);
    vm_add_root(&display);
    vm_add_root(&screen);
    vm_add_root(&screen_graphics);
    vm_add_root(&default_font);

    const char *ML = "javax/microedition/midlet/MIDlet";
    vm_native(ML, "<init>", "()V", nop);
    vm_native(ML, "notifyDestroyed", "()V", midlet_destroyed);
    vm_native(ML, "notifyPaused", "()V", nop);
    vm_native(ML, "resumeRequest", "()V", nop);
    vm_native(ML, "getAppProperty", "(Ljava/lang/String;)Ljava/lang/String;", midlet_property);

    const char *D = "javax/microedition/lcdui/Display";
    vm_native_static(D, "getDisplay", "(Ljavax/microedition/midlet/MIDlet;)Ljavax/microedition/lcdui/Display;", display_get);
    vm_native(D, "setCurrent", "(Ljavax/microedition/lcdui/Displayable;)V", display_setcurrent);
    vm_native(D, "getCurrent", "()Ljavax/microedition/lcdui/Displayable;", display_getcurrent);
    vm_native(D, "vibrate", "(I)Z", display_vibrate);
    vm_native(D, "flashBacklight", "(I)Z", display_vibrate);
    vm_native(D, "isColor", "()Z", display_iscolor);
    vm_native(D, "numColors", "()I", display_numcolors);

    const char *DS = "javax/microedition/lcdui/Displayable";
    vm_native(DS, "getWidth", "()I", canvas_width);
    vm_native(DS, "getHeight", "()I", canvas_height);
    vm_native(DS, "isShown", "()Z", canvas_true);
    vm_native(DS, "addCommand", "(Ljavax/microedition/lcdui/Command;)V", nop);
    vm_native(DS, "removeCommand", "(Ljavax/microedition/lcdui/Command;)V", nop);
    vm_native(DS, "setCommandListener", "(Ljavax/microedition/lcdui/CommandListener;)V", nop);
    vm_native(DS, "setTitle", "(Ljava/lang/String;)V", nop);

    const char *C = "javax/microedition/lcdui/Canvas";
    vm_native(C, "<init>", "()V", nop);
    vm_native(C, "setFullScreenMode", "(Z)V", nop);
    vm_native(C, "repaint", "()V", canvas_repaint);
    vm_native(C, "repaint", "(IIII)V", canvas_repaint);
    vm_native(C, "serviceRepaints", "()V", canvas_servicerepaints);
    vm_native(C, "isDoubleBuffered", "()Z", canvas_true);
    vm_native(C, "hasPointerEvents", "()Z", canvas_false);
    vm_native(C, "hasPointerMotionEvents", "()Z", canvas_false);
    vm_native(C, "hasRepeatEvents", "()Z", canvas_false);
    vm_native(C, "getGameAction", "(I)I", canvas_gameaction);
    vm_native(C, "getKeyCode", "(I)I", canvas_keycode);
    vm_native(C, "getKeyName", "(I)Ljava/lang/String;", canvas_keyname);
    vm_native(C, "keyPressed", "(I)V", nop);
    vm_native(C, "keyReleased", "(I)V", nop);
    vm_native(C, "keyRepeated", "(I)V", nop);
    vm_native(C, "showNotify", "()V", nop);
    vm_native(C, "hideNotify", "()V", nop);
    vm_native(C, "paint", "(Ljavax/microedition/lcdui/Graphics;)V", nop);
    const char *GC = "javax/microedition/lcdui/game/GameCanvas";
    vm_native(GC, "<init>", "(Z)V", gamecanvas_init);
    vm_native(GC, "getGraphics", "()Ljavax/microedition/lcdui/Graphics;", gamecanvas_graphics);
    vm_native(GC, "flushGraphics", "()V", nop);
    vm_native(GC, "flushGraphics", "(IIII)V", nop);
    vm_native(GC, "getKeyStates", "()I", gamecanvas_keystates);

    const char *IM = "javax/microedition/lcdui/Image";
    vm_native_static(IM, "createImage", "(Ljava/lang/String;)Ljavax/microedition/lcdui/Image;", image_create_resource);
    vm_native_static(IM, "createImage", "(II)Ljavax/microedition/lcdui/Image;", image_create_mutable);
    vm_native_static(IM, "createImage", "([BII)Ljavax/microedition/lcdui/Image;", image_create_bytes);
    vm_native_static(IM, "createImage", "(Ljavax/microedition/lcdui/Image;)Ljavax/microedition/lcdui/Image;", image_create_copy);
    vm_native_static(IM, "createRGBImage", "([IIIZ)Ljavax/microedition/lcdui/Image;", image_create_rgb);
    vm_native(IM, "getGraphics", "()Ljavax/microedition/lcdui/Graphics;", image_getgraphics);
    vm_native(IM, "getWidth", "()I", image_width);
    vm_native(IM, "getHeight", "()I", image_height);
    vm_native(IM, "isMutable", "()Z", image_ismutable);
    vm_native(IM, "getRGB", "([IIIIIII)V", image_getrgb);

    const char *G = "javax/microedition/lcdui/Graphics";
    vm_native(G, "setColor", "(I)V", g_setcolor);
    vm_native(G, "setColor", "(III)V", g_setcolor_rgb);
    vm_native(G, "getColor", "()I", g_getcolor);
    vm_native(G, "setGrayScale", "(I)V", g_setgray);
    vm_native(G, "fillRect", "(IIII)V", g_fillrect);
    vm_native(G, "drawRect", "(IIII)V", g_drawrect);
    vm_native(G, "drawLine", "(IIII)V", g_drawline);
    vm_native(G, "fillArc", "(IIIIII)V", g_fillarc);
    vm_native(G, "drawArc", "(IIIIII)V", g_drawarc);
    vm_native(G, "fillRoundRect", "(IIIIII)V", g_fillroundrect);
    vm_native(G, "drawRoundRect", "(IIIIII)V", g_drawroundrect);
    vm_native(G, "fillTriangle", "(IIIIII)V", g_filltriangle);
    vm_native(G, "drawImage", "(Ljavax/microedition/lcdui/Image;III)V", g_drawimage);
    vm_native(G, "drawRegion", "(Ljavax/microedition/lcdui/Image;IIIIIIII)V", g_drawregion);
    vm_native(G, "drawRGB", "([IIIIIIIZ)V", g_drawrgb);
    vm_native(G, "drawString", "(Ljava/lang/String;III)V", g_drawstring);
    vm_native(G, "drawSubstring", "(Ljava/lang/String;IIIII)V", g_drawsubstring);
    vm_native(G, "drawChar", "(CIII)V", g_drawchar);
    vm_native(G, "drawChars", "([CIIIII)V", g_drawchars);
    vm_native(G, "setFont", "(Ljavax/microedition/lcdui/Font;)V", g_setfont);
    vm_native(G, "getFont", "()Ljavax/microedition/lcdui/Font;", g_getfont);
    vm_native(G, "translate", "(II)V", g_translate);
    vm_native(G, "getTranslateX", "()I", g_gettx);
    vm_native(G, "getTranslateY", "()I", g_getty);
    vm_native(G, "setClip", "(IIII)V", g_setclip);
    vm_native(G, "clipRect", "(IIII)V", g_cliprect);
    vm_native(G, "getClipX", "()I", g_getclipx);
    vm_native(G, "getClipY", "()I", g_getclipy);
    vm_native(G, "getClipWidth", "()I", g_getclipw);
    vm_native(G, "getClipHeight", "()I", g_getcliph);

    const char *F = "javax/microedition/lcdui/Font";
    vm_native_static(F, "getDefaultFont", "()Ljavax/microedition/lcdui/Font;", font_getdefault);
    vm_native_static(F, "getFont", "(III)Ljavax/microedition/lcdui/Font;", font_getfont);
    vm_native(F, "getHeight", "()I", font_height);
    vm_native(F, "getBaselinePosition", "()I", font_baseline);
    vm_native(F, "stringWidth", "(Ljava/lang/String;)I", font_stringwidth);
    vm_native(F, "substringWidth", "(Ljava/lang/String;II)I", font_substringwidth);
    vm_native(F, "charWidth", "(C)I", font_charwidth);
    vm_native(F, "charsWidth", "([CII)I", font_charswidth);
    vm_native(F, "getStyle", "()I", font_getstyle);
    vm_native(F, "getSize", "()I", font_getsize);
    vm_native(F, "getFace", "()I", font_getface);

    const char *RS = "javax/microedition/rms/RecordStore";
    vm_native_static(RS, "openRecordStore", "(Ljava/lang/String;Z)Ljavax/microedition/rms/RecordStore;", rs_open);
    vm_native_static(RS, "deleteRecordStore", "(Ljava/lang/String;)V", rs_delete);
    vm_native(RS, "closeRecordStore", "()V", rs_close);
    vm_native(RS, "getNumRecords", "()I", rs_numrecords);
    vm_native(RS, "getNextRecordID", "()I", rs_nextid);
    vm_native(RS, "getSize", "()I", rs_size);
    vm_native(RS, "getSizeAvailable", "()I", rs_available);
    vm_native(RS, "addRecord", "([BII)I", rs_add);
    vm_native(RS, "setRecord", "(I[BII)V", rs_set);
    vm_native(RS, "getRecord", "(I)[B", rs_get);
    vm_native(RS, "getRecord", "(I[BI)I", rs_get_into);
    vm_native(RS, "getRecordSize", "(I)I", rs_recordsize);
    vm_native(RS, "deleteRecord", "(I)V", rs_deleterecord);

    const char *AC = "com/samsung/util/AudioClip";
    vm_native(AC, "<init>", "(ILjava/lang/String;)V", audioclip_init);
    vm_native(AC, "play", "(II)V", audioclip_play);
    vm_native(AC, "stop", "()V", audioclip_stop);
    vm_native(AC, "pause", "()V", audioclip_stop);
    vm_native(AC, "resume", "()V", nop);
    vm_native_static(AC, "isSupported", "()Z", audioclip_supported);
    vm_native_static("com/samsung/util/Vibration", "start", "(II)V", vibration_start);
    vm_native_static("com/samsung/util/Vibration", "stop", "()V", vibration_start);
    vm_native_static("com/samsung/util/Vibration", "isSupported", "()Z", vibration_supported);

    const char *MM = "javax/microedition/media/Manager";
    vm_native_static(MM, "createPlayer", "(Ljava/io/InputStream;Ljava/lang/String;)Ljavax/microedition/media/Player;", manager_createplayer);
    const char *P = "javax/microedition/media/Player";
    vm_native(P, "realize", "()V", nop);
    vm_native(P, "prefetch", "()V", nop);
    vm_native(P, "start", "()V", player_start);
    vm_native(P, "stop", "()V", player_stop);
    vm_native(P, "close", "()V", player_stop);
    vm_native(P, "deallocate", "()V", player_stop);
    vm_native(P, "setLoopCount", "(I)V", player_setloop);
    vm_native(P, "getState", "()I", player_state);
    vm_native(P, "getControl", "(Ljava/lang/String;)Ljavax/microedition/media/Control;", player_null);
    vm_native(P, "addPlayerListener", "(Ljavax/microedition/media/PlayerListener;)V", nop);
}

uint32_t *midp_pixels(void) { return screen ? screen->u.img.pixels : NULL; }

void midp_shutdown(void) {
    while (stores) {
        Store *s = stores;
        stores = s->next;
        for (int i = 0; i < s->nrecords; i++) free(s->data[i]);
        free(s->ids); free(s->sizes); free(s->data); free(s);
    }
    midp_canvas = midp_midlet = display = screen = screen_graphics = default_font = NULL;
}
