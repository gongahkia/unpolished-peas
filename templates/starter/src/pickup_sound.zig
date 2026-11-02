/// A tiny repository-authored PCM WAV click. It is embedded into the starter
/// executable/Wasm module so the same sound-loading path works before a game
/// adopts a larger asset pipeline.
pub const wav = [_]u8{
    'R',  'I',  'F', 'F', 40,   0,    0,    0, 'W', 'A', 'V',  'E',
    'f',  'm',  't', ' ', 16,   0,    0,    0, 1,   0,   1,    0,
    0x80, 0xbb, 0,   0,   0x00, 0x77, 0x01, 0, 2,   0,   16,   0,
    'd',  'a',  't', 'a', 4,    0,    0,    0, 0,   0,   0xff, 0x7f,
};
