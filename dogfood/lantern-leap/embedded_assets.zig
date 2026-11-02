/// Ordinary authored assets embedded into both native and browser builds.
/// The source files remain beside the project for authoring and native dev
/// reload; release packages do not need an `assets/` directory at runtime.
pub const sprite_sheet_png = @embedFile("assets/lantern-leap.png");
pub const ui_font_ttf = @embedFile("assets/lantern-leap.ttf");
pub const background_music_ogg = @embedFile("assets/lantern-loop.ogg");
