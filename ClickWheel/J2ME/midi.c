// Plays the games' MIDI files with a small synthesizer: pulse, triangle and sine voices picked by
// the General MIDI program family, noise for drums. One clip plays at a time, as on the phones.
#include "jvm.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct {
    double time;     // seconds from the start
    uint8_t status, a, b;
} Event;

typedef struct Clip {
    Event *events;
    int nevents;
    double length;
    // Playback
    bool playing;
    int loops;       // left to play after this one; -1 forever
    int volume;      // 0..5
    double pos;
    int next;
    uint8_t program[16];
    uint8_t chvol[16];
    uint8_t expr[16];
    int16_t bend[16];
    struct Clip *link;
} Clip;

typedef struct {
    bool on, releasing;
    uint8_t ch, note, vel;
    int wave;          // 0 pulse, 1 triangle, 2 sine, 3 saw, 4 noise, 5 kick
    double phase, freq, env, decay;
    double age;
    uint32_t noise;
    Clip *clip;
} Voice;

#define NVOICES 24
static Voice voices[NVOICES];
static Clip *clips;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static uint32_t varlen(const uint8_t **p, const uint8_t *end) {
    uint32_t v = 0;
    while (*p < end) {
        uint8_t c = *(*p)++;
        v = v << 7 | (c & 0x7F);
        if (!(c & 0x80)) break;
    }
    return v;
}

typedef struct { uint32_t tick; int order; uint8_t status, a, b; uint32_t tempo; } Raw;

static int raw_cmp(const void *x, const void *y) {
    const Raw *a = x, *b = y;
    if (a->tick != b->tick) return a->tick < b->tick ? -1 : 1;
    return a->order - b->order;
}

void *midi_load(const uint8_t *data, int32_t size) {
    if (size < 14 || memcmp(data, "MThd", 4) != 0) return NULL;
    int ntracks = data[10] << 8 | data[11];
    int division = data[12] << 8 | data[13];
    if (division & 0x8000 || division == 0) return NULL;  // SMPTE timing is not used by these files
    const uint8_t *p = data + 8 + be32(data + 4), *end = data + size;
    Raw *raw = NULL;
    int nraw = 0, cap = 0, order = 0;
    for (int t = 0; t < ntracks && p + 8 <= end; t++) {
        if (memcmp(p, "MTrk", 4) != 0) break;
        const uint8_t *q = p + 8, *tend = p + 8 + be32(p + 4);
        if (tend > end) tend = end;
        p = tend;
        uint32_t tick = 0;
        uint8_t running = 0;
        while (q < tend) {
            tick += varlen(&q, tend);
            if (q >= tend) break;
            uint8_t status = *q;
            if (status & 0x80) q++;
            else status = running;
            Raw r = {tick, order++, status, 0, 0, 0};
            if (status == 0xFF) {
                if (q >= tend) break;
                uint8_t type = *q++;
                uint32_t len = varlen(&q, tend);
                if (type == 0x51 && len == 3 && q + 3 <= tend) {
                    r.tempo = q[0] << 16 | q[1] << 8 | q[2];
                } else {
                    q += len;
                    continue;
                }
                q += len;
            } else if (status == 0xF0 || status == 0xF7) {
                uint32_t len = varlen(&q, tend);
                q += len;
                continue;
            } else if (status >= 0x80) {
                running = status;
                int kind = status & 0xF0;
                r.a = q < tend ? *q++ & 0x7F : 0;
                if (kind != 0xC0 && kind != 0xD0) r.b = q < tend ? *q++ & 0x7F : 0;
            } else {
                break;  // data byte with no running status
            }
            if (nraw == cap) { cap = cap ? cap * 2 : 256; raw = realloc(raw, cap * sizeof(Raw)); }
            raw[nraw++] = r;
        }
    }
    qsort(raw, nraw, sizeof(Raw), raw_cmp);
    Clip *c = calloc(1, sizeof(Clip));
    c->events = malloc((nraw + 1) * sizeof(Event));
    double seconds = 0, per_tick = 0.5 / division;
    uint32_t last = 0;
    for (int i = 0; i < nraw; i++) {
        seconds += (raw[i].tick - last) * per_tick;
        last = raw[i].tick;
        if (raw[i].status == 0xFF) { per_tick = raw[i].tempo / 1e6 / division; continue; }
        c->events[c->nevents++] = (Event){seconds, raw[i].status, raw[i].a, raw[i].b};
    }
    c->length = seconds + 0.05;
    free(raw);
    return c;
}

static void stop_voices(Clip *c) {
    for (int i = 0; i < NVOICES; i++) if (voices[i].clip == c) voices[i].on = false;
}

void midi_stop(void *clip) {
    Clip *c = clip;
    if (!c->playing) return;
    c->playing = false;
    stop_voices(c);
    for (Clip **p = &clips; *p; p = &(*p)->link)
        if (*p == c) { *p = c->link; break; }
}

void midi_free(void *clip) {
    midi_stop(clip);
    Clip *c = clip;
    free(c->events);
    free(c);
}

static void reset_channels(Clip *c) {
    for (int ch = 0; ch < 16; ch++) { c->program[ch] = 0; c->chvol[ch] = 100; c->expr[ch] = 127; c->bend[ch] = 0; }
}

void midi_play(void *clip, int loops, int volume) {
    // A new sound takes over from whatever was playing.
    while (clips) midi_stop(clips);
    Clip *c = clip;
    c->playing = true;
    c->loops = loops <= 0 ? -1 : loops - 1;
    c->volume = volume < 0 ? 0 : volume > 5 ? 5 : volume;
    if (c->volume == 0) c->volume = 3;
    c->pos = 0;
    c->next = 0;
    reset_channels(c);
    c->link = clips;
    clips = c;
}

static int wave_for(int ch, int program) {
    if (ch == 9) return 4;
    if (program < 8) return 0;         // piano: pulse
    if (program < 16) return 2;        // chromatic percussion: sine (bells)
    if (program < 24) return 0;        // organ
    if (program < 32) return 3;        // guitar: saw
    if (program < 40) return 1;        // bass: triangle
    if (program < 56) return 3;        // strings, ensemble
    if (program < 80) return 2;        // brass, reed, pipe
    if (program < 96) return 0;        // synth lead, pad
    return 2;
}

static void note_on(Clip *c, int ch, int note, int vel) {
    int slot = -1;
    double oldest = -1;
    for (int i = 0; i < NVOICES; i++) {
        if (!voices[i].on) { slot = i; break; }
        double score = voices[i].age + (voices[i].releasing ? 100 : 0);
        if (score > oldest) { oldest = score; slot = i; }
    }
    Voice *v = &voices[slot];
    memset(v, 0, sizeof *v);
    v->on = true;
    v->ch = ch;
    v->note = note;
    v->vel = vel;
    v->clip = c;
    v->wave = wave_for(ch, c->program[ch]);
    v->noise = 0x12345 + note * 977;
    if (v->wave == 4) {
        if (note == 35 || note == 36) { v->wave = 5; v->freq = 120; v->decay = 18; }
        else v->decay = note == 42 || note == 44 ? 40 : note == 46 ? 8 : 14;
    } else {
        v->freq = 440.0 * pow(2.0, (note - 69) / 12.0);
        v->decay = v->wave == 2 ? 2.5 : v->wave == 0 ? 1.2 : 0.8;
    }
    v->env = 1;
}

static void note_off(Clip *c, int ch, int note) {
    for (int i = 0; i < NVOICES; i++)
        if (voices[i].on && voices[i].clip == c && voices[i].ch == ch && voices[i].note == note && !voices[i].releasing)
            voices[i].releasing = true;
}

static void dispatch(Clip *c, Event *e) {
    int ch = e->status & 0x0F;
    switch (e->status & 0xF0) {
    case 0x90: if (e->b) { note_on(c, ch, e->a, e->b); break; } /* fall through */
    case 0x80: note_off(c, ch, e->a); break;
    case 0xB0:
        if (e->a == 7) c->chvol[ch] = e->b;
        else if (e->a == 11) c->expr[ch] = e->b;
        else if (e->a == 120 || e->a == 123) for (int i = 0; i < NVOICES; i++) if (voices[i].clip == c && voices[i].ch == ch) voices[i].releasing = true;
        break;
    case 0xC0: c->program[ch] = e->a; break;
    case 0xE0: c->bend[ch] = (int16_t)((e->b << 7 | e->a) - 8192); break;
    }
}

void midi_render(int16_t *out, int frames, int rate) {
    memset(out, 0, (size_t)frames * 4);
    if (!clips) {
        bool any = false;
        for (int i = 0; i < NVOICES; i++) any |= voices[i].on;
        if (!any) return;
    }
    double dt = 1.0 / rate;
    for (int f = 0; f < frames; f++) {
        for (Clip *c = clips, *next; c; c = next) {
            next = c->link;
            while (c->next < c->nevents && c->events[c->next].time <= c->pos) dispatch(c, &c->events[c->next++]);
            c->pos += dt;
            if (c->pos >= c->length) {
                if (c->loops == 0) { midi_stop(c); continue; }
                if (c->loops > 0) c->loops--;
                c->pos = 0;
                c->next = 0;
                stop_voices(c);
                reset_channels(c);
            }
        }
        double mix = 0;
        for (int i = 0; i < NVOICES; i++) {
            Voice *v = &voices[i];
            if (!v->on) continue;
            Clip *c = v->clip;
            double amp = v->vel / 127.0 * c->chvol[v->ch] / 127.0 * c->expr[v->ch] / 127.0 * c->volume / 5.0;
            double attack = v->age < 0.004 ? v->age / 0.004 : 1;
            double s;
            double freq = v->freq * (v->wave < 4 ? pow(2.0, c->bend[v->ch] / 8192.0 * 2 / 12) : 1);
            switch (v->wave) {
            case 0: s = v->phase < 0.5 ? 0.5 : -0.5; break;
            case 1: s = (v->phase < 0.5 ? 4 * v->phase - 1 : 3 - 4 * v->phase) * 0.9; break;
            case 2: s = sin(v->phase * 2 * M_PI) * 0.8; break;
            case 3: s = (2 * v->phase - 1) * 0.45; break;
            case 4:
                v->noise ^= v->noise << 13; v->noise ^= v->noise >> 17; v->noise ^= v->noise << 5;
                s = ((v->noise & 0xFFFF) / 32768.0 - 1) * 0.5;
                break;
            default:
                s = sin(v->phase * 2 * M_PI) * 0.9;
                freq = 50 + 110 * v->env;
                break;
            }
            mix += s * amp * attack * v->env;
            v->phase += freq * dt;
            if (v->phase >= 1) v->phase -= floor(v->phase);
            v->age += dt;
            v->env *= 1 - dt * (v->releasing ? 14 : v->decay * 0.25 + (v->wave >= 4 ? v->decay : 0));
            if (v->env < 0.002 || (v->wave >= 4 && v->age > 1)) v->on = false;
        }
        int sample = (int)(mix * 0.22 * 32767);
        if (sample > 32767) sample = 32767;
        if (sample < -32768) sample = -32768;
        out[2 * f] = out[2 * f + 1] = (int16_t)sample;
    }
}
