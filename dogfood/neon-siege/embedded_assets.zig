/// Compile-time embedded authored files. This root-level module intentionally
/// keeps `assets/` beside `src/` while allowing normal `@embedFile` paths.
pub const sprite_sheet_png = @embedFile("assets/neon-siege.png");
pub const ui_font_ttf = @embedFile("assets/neon-siege.ttf");
