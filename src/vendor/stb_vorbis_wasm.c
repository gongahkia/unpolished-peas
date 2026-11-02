/* The decoder is linked without libc. Accepted browser decoders always pass a
 * caller-owned stb_vorbis_alloc block, so malloc/realloc are only defensive
 * stubs. The numerical helpers are local so the module does not depend on a
 * libc math runtime. */
#define STB_VORBIS_NO_CRT
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_CUSTOM_CRT
#include <stddef.h>
#include <stdint.h>
#undef NULL
#define NULL ((void *) 0)
#define assert(value) ((void) 0)
#define alloca __builtin_alloca

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

static double local_floor(double value) {
    const long long truncated = (long long) value;
    return (double) (value < (double) truncated ? truncated - 1 : truncated);
}

static double local_ldexp(double value, int exponent) {
    while (exponent > 0) {
        value *= 2.0;
        exponent -= 1;
    }
    while (exponent < 0) {
        value *= 0.5;
        exponent += 1;
    }
    return value;
}

static double local_exp(double value) {
    const double ln2_high = 0.69314718036912381649;
    const double ln2_low = 1.90821492927058770002e-10;
    const double inverse_ln2 = 1.44269504088896340736;
    if (value > 709.0) return 1.0e308;
    if (value < -745.0) return 0.0;
    const int exponent = (int) local_floor(value * inverse_ln2 + (value >= 0.0 ? 0.5 : -0.5));
    const double reduced = value - exponent * ln2_high - exponent * ln2_low;
    const double square = reduced * reduced;
    const double polynomial = 1.0 + reduced + square * (0.5 + reduced * (1.0 / 6.0 + reduced * (1.0 / 24.0 + reduced * (1.0 / 120.0 + reduced * (1.0 / 720.0 + reduced * (1.0 / 5040.0 + reduced * (1.0 / 40320.0 + reduced * (1.0 / 362880.0 + reduced * (1.0 / 3628800.0 + reduced * (1.0 / 39916800.0))))))))));
    return local_ldexp(polynomial, exponent);
}

static double local_log(double value) {
    union { double value; uint64_t bits; } number;
    int exponent;
    double mantissa;
    double z;
    double square;
    if (value <= 0.0) return -1.0e308;
    number.value = value;
    exponent = (int) ((number.bits >> 52) & 0x7ff) - 1023;
    if (exponent == -1023) {
        value *= 4503599627370496.0;
        number.value = value;
        exponent = (int) ((number.bits >> 52) & 0x7ff) - 1023 - 52;
    }
    number.bits = (number.bits & UINT64_C(0x000fffffffffffff)) | UINT64_C(0x3ff0000000000000);
    mantissa = number.value;
    z = (mantissa - 1.0) / (mantissa + 1.0);
    square = z * z;
    return exponent * 0.69314718055994530942 + 2.0 * z * (1.0 + square * (1.0 / 3.0 + square * (1.0 / 5.0 + square * (1.0 / 7.0 + square * (1.0 / 9.0 + square * (1.0 / 11.0 + square * (1.0 / 13.0 + square * (1.0 / 15.0 + square * (1.0 / 17.0 + square * (1.0 / 19.0))))))))));
}

static double local_reduce_angle(double value) {
    const double two_pi = 6.28318530717958647693;
    const double inverse_two_pi = 0.15915494309189533577;
    return value - local_floor(value * inverse_two_pi + (value >= 0.0 ? 0.5 : -0.5)) * two_pi;
}

static double local_sin(double value) {
    value = local_reduce_angle(value);
    if (value > 1.57079632679489661923) value = 3.14159265358979323846 - value;
    if (value < -1.57079632679489661923) value = -3.14159265358979323846 - value;
    const double square = value * value;
    return value * (1.0 + square * (-1.0 / 6.0 + square * (1.0 / 120.0 + square * (-1.0 / 5040.0 + square * (1.0 / 362880.0 + square * (-1.0 / 39916800.0 + square * (1.0 / 6227020800.0)))))));
}

static double local_cos(double value) {
    return local_sin(value + 1.57079632679489661923);
}

double sin(double value) { return local_sin(value); }
double cos(double value) { return local_cos(value); }
double log(double value) { return local_log(value); }
double exp(double value) { return local_exp(value); }
double floor(double value) { return local_floor(value); }
double ldexp(double value, int exponent) { return local_ldexp(value, exponent); }
double pow(double base, double exponent) { return local_exp(local_log(base) * exponent); }

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
