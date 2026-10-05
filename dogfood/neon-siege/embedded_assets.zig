/// Compile-time embedded authored files. This root-level module intentionally
/// keeps `assets/` beside `src/` while allowing normal `@embedFile` paths.
pub const sprite_sheet_png = @embedFile("assets/neon-siege.png");
pub const ui_font_ttf = @embedFile("assets/neon-siege.ttf");
/// A repository-authored, synthesized three-tone Vorbis loop. The generator
/// lives in `script/generate_neon_siege_music.sh` for provenance.
pub const background_music_ogg = @embedFile("assets/neon-loop.ogg");
