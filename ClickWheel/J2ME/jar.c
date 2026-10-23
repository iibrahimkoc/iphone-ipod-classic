// Reads the game's .jar (a zip): its classes, resources and manifest.
#include "jvm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct {
    char *name;
    uint32_t offset, csize, size;
    uint16_t method;
} Entry;

static uint8_t *jar;
static long jar_size;
static Entry *entries;
static int nentries;
static char *manifest;

static uint16_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

bool jar_open(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    jar_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    jar = malloc(jar_size);
    if (fread(jar, 1, jar_size, f) != (size_t)jar_size) { fclose(f); return false; }
    fclose(f);
    // The end of central directory record, searched for from the end (it may have a comment).
    long eocd = -1;
    for (long p = jar_size - 22; p >= 0 && p >= jar_size - 65557; p--)
        if (rd32(jar + p) == 0x06054b50) { eocd = p; break; }
    if (eocd < 0) return false;
    int count = rd16(jar + eocd + 10);
    uint32_t dir = rd32(jar + eocd + 16);
    entries = calloc(count, sizeof(Entry));
    uint8_t *p = jar + dir;
    for (int i = 0; i < count && p + 46 <= jar + jar_size && rd32(p) == 0x02014b50; i++) {
        Entry *e = &entries[nentries++];
        e->method = rd16(p + 10);
        e->csize = rd32(p + 20);
        e->size = rd32(p + 24);
        int nlen = rd16(p + 28), xlen = rd16(p + 30), clen = rd16(p + 32);
        e->offset = rd32(p + 42);
        e->name = strndup((char *)p + 46, nlen);
        p += 46 + nlen + xlen + clen;
    }
    int32_t size;
    manifest = (char *)jar_read("META-INF/MANIFEST.MF", &size);
    if (manifest) {
        manifest = realloc(manifest, size + 1);
        manifest[size] = 0;
    }
    return nentries > 0;
}

void jar_close(void) {
    for (int i = 0; i < nentries; i++) free(entries[i].name);
    free(entries);
    free(jar);
    free(manifest);
    entries = NULL;
    jar = NULL;
    manifest = NULL;
    nentries = 0;
}

uint8_t *jar_read(const char *name, int32_t *size) {
    while (*name == '/') name++;
    for (int i = 0; i < nentries; i++) {
        Entry *e = &entries[i];
        if (strcmp(e->name, name) != 0) continue;
        uint8_t *local = jar + e->offset;
        if (e->offset + 30 > jar_size || rd32(local) != 0x04034b50) return NULL;
        uint8_t *data = local + 30 + rd16(local + 26) + rd16(local + 28);
        uint8_t *out = malloc(e->size ? e->size : 1);
        if (e->method == 0) {
            memcpy(out, data, e->size);
        } else if (e->method == 8) {
            z_stream z = {0};
            inflateInit2(&z, -15);
            z.next_in = data;
            z.avail_in = e->csize;
            z.next_out = out;
            z.avail_out = e->size;
            int r = inflate(&z, Z_FINISH);
            inflateEnd(&z);
            if (r != Z_STREAM_END) { free(out); return NULL; }
        } else {
            free(out);
            return NULL;
        }
        *size = (int32_t)e->size;
        return out;
    }
    return NULL;
}

const char *jar_manifest(const char *key) {
    static char value[256];
    if (!manifest) return NULL;
    size_t klen = strlen(key);
    for (char *line = manifest; *line; ) {
        char *end = strpbrk(line, "\r\n");
        size_t len = end ? (size_t)(end - line) : strlen(line);
        if (len > klen && strncmp(line, key, klen) == 0 && line[klen] == ':') {
            const char *v = line + klen + 1;
            while (*v == ' ') v++;
            size_t vlen = len - (v - line);
            if (vlen >= sizeof value) vlen = sizeof value - 1;
            memcpy(value, v, vlen);
            value[vlen] = 0;
            return value;
        }
        if (!end) break;
        line = end;
        while (*line == '\r' || *line == '\n') line++;
    }
    return NULL;
}
