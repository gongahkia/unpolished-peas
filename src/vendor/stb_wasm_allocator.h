#ifndef UNPOLISHED_PEAS_STB_WASM_ALLOCATOR_H
#define UNPOLISHED_PEAS_STB_WASM_ALLOCATOR_H

#include <stddef.h>

void *up_stb_malloc(size_t size);
void *up_stb_realloc(void *pointer, size_t size);
void up_stb_free(void *pointer);

static int up_stb_floor_to_int(float value) {
    const int integer = (int)value;
    return value < (float)integer ? integer - 1 : integer;
}

static int up_stb_ceil_to_int(float value) {
    const int integer = (int)value;
    return value > (float)integer ? integer + 1 : integer;
}

#define STBI_MALLOC(size) up_stb_malloc(size)
#define STBI_REALLOC(pointer, size) up_stb_realloc(pointer, size)
#define STBI_FREE(pointer) up_stb_free(pointer)

#define STBTT_malloc(size, userdata) ((void)(userdata), up_stb_malloc(size))
#define STBTT_free(pointer, userdata) ((void)(userdata), up_stb_free(pointer))
#define STBTT_ifloor(value) up_stb_floor_to_int(value)
#define STBTT_iceil(value) up_stb_ceil_to_int(value)
#define STBTT_sqrt(value) __builtin_sqrt(value)
#define STBTT_pow(left, right) __builtin_pow(left, right)
#define STBTT_fmod(left, right) __builtin_fmod(left, right)
#define STBTT_cos(value) __builtin_cos(value)
#define STBTT_acos(value) __builtin_acos(value)
#define STBTT_fabs(value) __builtin_fabs(value)
#define STBTT_assert(value) ((void)(value))
#define STBTT_strlen(value) __builtin_strlen(value)
#define STBTT_memcpy __builtin_memcpy
#define STBTT_memset __builtin_memset

#endif
