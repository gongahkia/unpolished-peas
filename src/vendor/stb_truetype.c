#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"

int up_bake_font(const unsigned char *data, int pixel_height, unsigned char *pixels, int width, int height, int first_codepoint, int count, stbtt_bakedchar *glyphs) {
    return stbtt_BakeFontBitmap(data, 0, (float)pixel_height, pixels, width, height, first_codepoint, count, glyphs);
}

int up_get_baked_quad(const stbtt_bakedchar *glyphs, int first_codepoint, int codepoint, float *x, float *y, stbtt_aligned_quad *quad) {
    if (codepoint < first_codepoint) return 0;
    stbtt_GetBakedQuad(glyphs, 0, 0, codepoint - first_codepoint, x, y, quad, 1);
    return 1;
}
