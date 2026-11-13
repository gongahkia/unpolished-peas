export const debugFontAssetDiagnostic = "asset_load_failed:debug_font_v1";
const requiredGlyphs = [..."0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-._:/?"].map((value) => value.codePointAt(0));

function fail() {
  throw new Error(debugFontAssetDiagnostic);
}

function upper(codepoint) {
  return codepoint >= 97 && codepoint <= 122 ? codepoint - 32 : codepoint;
}

export function createDebugFont(fixture) {
  if (!fixture || fixture.schema_version !== 1 || fixture.fixture_version !== "debug-5x7-v1" || fixture.glyph_width !== 5 || fixture.glyph_height !== 7 || fixture.advance !== 6 || fixture.line_height !== 8 || !Number.isInteger(fixture.fallback_codepoint) || !Array.isArray(fixture.glyphs) || fixture.glyphs.length === 0) fail();
  const glyphs = new Map();
  for (const glyph of fixture.glyphs) {
    if (!glyph || !Number.isInteger(glyph.codepoint) || glyph.codepoint < 33 || glyph.codepoint > 126 || !Array.isArray(glyph.rows) || glyph.rows.length !== fixture.glyph_height || !glyph.rows.every((row) => Number.isInteger(row) && row >= 0 && row < 32) || glyphs.has(glyph.codepoint)) fail();
    glyphs.set(glyph.codepoint, glyph.rows);
  }
  if (glyphs.size !== requiredGlyphs.length || !requiredGlyphs.every((codepoint) => glyphs.has(codepoint)) || !glyphs.has(fixture.fallback_codepoint)) fail();
  const columns = 16;
  const cellWidth = fixture.advance;
  const cellHeight = fixture.line_height;
  const width = columns * cellWidth;
  const height = Math.ceil(glyphs.size / columns) * cellHeight;
  const pixels = new Uint8Array(width * height * 4);
  const cells = new Map();
  let index = 0;
  for (const [codepoint, rows] of glyphs) {
    const x = (index % columns) * cellWidth;
    const y = Math.floor(index / columns) * cellHeight;
    cells.set(codepoint, {x, y, rows});
    for (let row = 0; row < fixture.glyph_height; row += 1) for (let column = 0; column < fixture.glyph_width; column += 1) if ((rows[row] & (1 << (fixture.glyph_width - 1 - column))) !== 0) {
      const offset = ((y + row) * width + x + column) * 4;
      pixels[offset] = 255; pixels[offset + 1] = 255; pixels[offset + 2] = 255; pixels[offset + 3] = 255;
    }
    index += 1;
  }
  return {advance: fixture.advance, lineHeight: fixture.line_height, glyphWidth: fixture.glyph_width, glyphHeight: fixture.glyph_height, fallback: fixture.fallback_codepoint, width, height, pixels, glyph(codepoint) { return cells.get(upper(codepoint)) ?? cells.get(fixture.fallback_codepoint); }};
}

export function forEachDebugFontGlyph(font, bytes, x, y, draw) {
  let cursorX = x;
  let cursorY = y;
  let index = 0;
  while (index < bytes.length) {
    const first = bytes[index];
    if (first < 0x80) {
      index += 1;
      if (first === 10) {
        cursorX = x;
        cursorY += font.lineHeight;
      } else if (first !== 32) {
        draw(font.glyph(first), cursorX, cursorY);
        cursorX += font.advance;
      } else cursorX += font.advance;
      continue;
    }
    const length = (first & 0xe0) === 0xc0 ? 2 : (first & 0xf0) === 0xe0 ? 3 : (first & 0xf8) === 0xf0 ? 4 : 1;
    let codepoint = 0xfffd;
    if (length > 1 && index + length <= bytes.length) {
      const minimum = length === 2 ? 0x80 : length === 3 ? 0x800 : 0x10000;
      codepoint = first & (0x7f >> length);
      let valid = true;
      for (let offset = 1; offset < length; offset += 1) {
        const value = bytes[index + offset];
        if ((value & 0xc0) !== 0x80) { valid = false; break; }
        codepoint = (codepoint << 6) | (value & 0x3f);
      }
      if (!valid) { codepoint = 0xfffd; index += 1; }
      else {
        index += length;
        if (codepoint < minimum || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff)) codepoint = 0xfffd;
      }
    } else index += 1;
    draw(font.glyph(codepoint), cursorX, cursorY);
    cursorX += font.advance;
  }
}
