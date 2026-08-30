/* The decoder is linked without libc. Accepted browser decoders always pass a
 * caller-owned stb_vorbis_alloc block, so malloc/realloc are only defensive
 * stubs. Math operations delegate to the Zig Wasm module. */
#define STB_VORBIS_NO_CRT
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_CUSTOM_CRT
#include <stddef.h>
#undef NULL
#define NULL ((void *) 0)
#define assert(value) ((void) 0)
#define alloca __builtin_alloca

extern double up_vorbis_sin(double value);
extern double up_vorbis_cos(double value);
extern double up_vorbis_log(double value);
extern double up_vorbis_exp(double value);
extern double up_vorbis_floor(double value);
extern double up_vorbis_ldexp(double value, int exponent);

void *memcpy(void *destination, const void *source, size_t len) {
    unsigned char *out = (unsigned char *) destination;
    const unsigned char *in = (const unsigned char *) source;
    for (size_t index = 0; index < len; index += 1) out[index] = in[index];
    return destination;
}

void *memset(void *destination, int value, size_t len) {
    unsigned char *out = (unsigned char *) destination;
    for (size_t index = 0; index < len; index += 1) out[index] = (unsigned char) value;
    return destination;
}

int memcmp(const void *left, const void *right, size_t len) {
    const unsigned char *a = (const unsigned char *) left;
    const unsigned char *b = (const unsigned char *) right;
    for (size_t index = 0; index < len; index += 1) {
        if (a[index] != b[index]) return a[index] < b[index] ? -1 : 1;
    }
    return 0;
}

void *malloc(size_t size) { (void) size; return 0; }
void free(void *value) { (void) value; }
void *realloc(void *value, size_t size) { (void) value; (void) size; return 0; }
int abs(int value) { return value < 0 ? -value : value; }
double sin(double value) { return up_vorbis_sin(value); }
double cos(double value) { return up_vorbis_cos(value); }
double log(double value) { return up_vorbis_log(value); }
double exp(double value) { return up_vorbis_exp(value); }
double floor(double value) { return up_vorbis_floor(value); }
double ldexp(double value, int exponent) { return up_vorbis_ldexp(value, exponent); }
double pow(double base, double exponent) { return up_vorbis_exp(up_vorbis_log(base) * exponent); }

static void byte_swap(unsigned char *left, unsigned char *right, size_t width) {
    while (width != 0) {
        const unsigned char value = *left;
        *left++ = *right;
        *right++ = value;
        width -= 1;
    }
}

void qsort(void *base, size_t count, size_t width, int (*compare)(const void *, const void *)) {
    unsigned char *items = (unsigned char *) base;
    for (size_t outer = 1; outer < count; outer += 1) {
        size_t inner = outer;
        while (inner != 0 && compare(items + (inner - 1) * width, items + inner * width) > 0) {
            byte_swap(items + (inner - 1) * width, items + inner * width, width);
            inner -= 1;
        }
    }
}

#include "../../vendor/stb/stb_vorbis.c"
