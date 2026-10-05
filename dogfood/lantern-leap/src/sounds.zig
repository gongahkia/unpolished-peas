/// Three tiny repository-authored PCM WAV effects. They are deliberately
/// short logical cues, not third-party media, and are loaded once per host.
pub const jump_wav = [_]u8{
    'R',  'I',  'F',  'F',  52, 0,    0,    0,    'W', 'A', 'V',  'E',
    'f',  'm',  't',  ' ',  16, 0,    0,    0,    1,   0,   1,    0,
    0x80, 0xbb, 0,    0,    0,  0x77, 1,    0,    2,   0,   16,   0,
    'd',  'a',  't',  'a',  16, 0,    0,    0,    0,   0,   0x40, 0x19,
    0x30, 0x2e, 0x50, 0x13, 0,  0,    0xb0, 0xf4, 0,   0,   0,    0,
};

pub const collect_wav = [_]u8{
    'R',  'I',  'F',  'F',  52, 0,    0,    0,    'W', 'A', 'V',  'E',
    'f',  'm',  't',  ' ',  16, 0,    0,    0,    1,   0,   1,    0,
    0x80, 0xbb, 0,    0,    0,  0x77, 1,    0,    2,   0,   16,   0,
    'd',  'a',  't',  'a',  16, 0,    0,    0,    0,   0,   0x60, 0x16,
    0x10, 0x2f, 0x20, 0x1c, 0,  0,    0x10, 0xef, 0,   0,   0,    0,
};

pub const reset_wav = [_]u8{
    'R',  'I',  'F',  'F',  52, 0,    0,    0,    'W', 'A', 'V',  'E',
    'f',  'm',  't',  ' ',  16, 0,    0,    0,    1,   0,   1,    0,
    0x80, 0xbb, 0,    0,    0,  0x77, 1,    0,    2,   0,   16,   0,
    'd',  'a',  't',  'a',  16, 0,    0,    0,    0,   0,   0x80, 0xee,
    0x30, 0xd8, 0x10, 0xf3, 0,  0,    0x30, 0x10, 0,   0,   0,    0,
};
