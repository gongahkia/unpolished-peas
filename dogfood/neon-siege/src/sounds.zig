/// Two tiny repository-authored PCM WAV clicks. They are intentionally short
/// effects rather than downloaded media, so their provenance and packaging
/// are unambiguous for this reference project.
pub const shot_wav = [_]u8{
    'R',  'I',  'F',  'F',  52, 0,    0,    0,    'W',  'A',  'V',  'E',
    'f',  'm',  't',  ' ',  16, 0,    0,    0,    1,    0,    1,    0,
    0x80, 0xbb, 0,    0,    0,  0x77, 1,    0,    2,    0,    16,   0,
    'd',  'a',  't',  'a',  16, 0,    0,    0,    0,    0,    0x58, 0x1b,
    0x48, 0xf4, 0xa0, 0x0f, 0,  0,    0x60, 0xf8, 0xd0, 0x07, 0,    0,
};

pub const pickup_wav = [_]u8{
    'R',  'I',  'F',  'F',  52, 0,    0,    0,    'W',  'A',  'V',  'E',
    'f',  'm',  't',  ' ',  16, 0,    0,    0,    1,    0,    1,    0,
    0x80, 0xbb, 0,    0,    0,  0x77, 1,    0,    2,    0,    16,   0,
    'd',  'a',  't',  'a',  16, 0,    0,    0,    0,    0,    0x70, 0x17,
    0x40, 0x2e, 0x60, 0x0f, 0,  0,    0xa0, 0xf8, 0xe8, 0x03, 0,    0,
};
