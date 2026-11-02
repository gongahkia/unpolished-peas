#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"
#include <stdlib.h>

int up_bake_font(const unsigned char *data, int pixel_height, unsigned char *pixels, int width, int height, int first_codepoint, int count, stbtt_bakedchar *glyphs) {
    return stbtt_BakeFontBitmap(data, 0, (float)pixel_height, pixels, width, height, first_codepoint, count, glyphs);
}

typedef struct {
    int first_codepoint;
    int count;
    stbtt_packedchar *glyphs;
    unsigned char *present;
} up_font_range;

int up_pack_font_ranges(const unsigned char *data, int pixel_height, unsigned char *pixels, int width, int height, const up_font_range *ranges, int range_count) {
    stbtt_fontinfo font;
    stbtt_pack_context context;
    if (!stbtt_InitFont(&font, data, 0)) return 0;
    if (!stbtt_PackBegin(&context, pixels, width, height, 0, 1, NULL)) return 0;
    for (int range_index = 0; range_index < range_count; range_index++) {
        const up_font_range range = ranges[range_index];
        int present_count = 0;
        for (int glyph_index = 0; glyph_index < range.count; glyph_index++) {
            range.present[glyph_index] = stbtt_FindGlyphIndex(&font, range.first_codepoint + glyph_index) != 0;
            present_count += range.present[glyph_index];
        }
        if (present_count == 0) continue;
        int *codepoints = malloc((size_t)present_count * sizeof(*codepoints));
        stbtt_packedchar *packed = malloc((size_t)present_count * sizeof(*packed));
        if (codepoints == NULL || packed == NULL) {
            free(codepoints);
            free(packed);
            stbtt_PackEnd(&context);
            return 0;
        }
        int packed_index = 0;
        for (int glyph_index = 0; glyph_index < range.count; glyph_index++) {
            if (range.present[glyph_index]) codepoints[packed_index++] = range.first_codepoint + glyph_index;
        }
        stbtt_pack_range pack_range = {
            .font_size = (float)pixel_height,
            .first_unicode_codepoint_in_range = 0,
            .array_of_unicode_codepoints = codepoints,
            .num_chars = present_count,
            .chardata_for_range = packed,
        };
        const int packed_ok = stbtt_PackFontRanges(&context, data, 0, &pack_range, 1);
        packed_index = 0;
        for (int glyph_index = 0; glyph_index < range.count; glyph_index++) {
            if (range.present[glyph_index]) range.glyphs[glyph_index] = packed[packed_index++];
        }
        free(codepoints);
        free(packed);
        if (!packed_ok) {
            stbtt_PackEnd(&context);
            return 0;
        }
    }
    stbtt_PackEnd(&context);
    return 1;
}

int up_get_baked_quad(const stbtt_bakedchar *glyphs, int first_codepoint, int codepoint, float *x, float *y, stbtt_aligned_quad *quad) {
    if (codepoint < first_codepoint) return 0;
    stbtt_GetBakedQuad(glyphs, 0, 0, codepoint - first_codepoint, x, y, quad, 1);
    return 1;
}
