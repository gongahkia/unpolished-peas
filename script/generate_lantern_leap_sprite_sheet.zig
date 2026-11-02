const std = @import("std");

const width = 64;
const height = 16;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

const Sheet = struct {
    pixels: [width * height]Color = [_]Color{Color.transparent} ** (width * height),

    fn fill(self: *Sheet, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        var py = y;
        while (py < y + h) : (py += 1) {
            var px = x;
            while (px < x + w) : (px += 1) {
                if (px >= 0 and py >= 0 and px < width and py < height) {
                    self.pixels[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))] = color;
                }
            }
        }
    }

    fn writePng(self: Sheet, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(&buffer);
        const out = &writer.interface;
        try out.writeAll("\x89PNG\r\n\x1a\n");
        var header: [13]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], width, .big);
        std.mem.writeInt(u32, header[4..8], height, .big);
        header[8..].* = .{ 8, 6, 0, 0, 0 };
        try writeChunk(out, "IHDR", &header);

        var raw: [height * (1 + width * 4)]u8 = undefined;
        var at: usize = 0;
        for (self.pixels, 0..) |pixel, index| {
            if (index % width == 0) {
                raw[at] = 0;
                at += 1;
            }
            raw[at..][0..4].* = .{ pixel.r, pixel.g, pixel.b, pixel.a };
            at += 4;
        }
        var compressed: [2 + 5 + raw.len + 4]u8 = undefined;
        compressed[0..2].* = .{ 0x78, 0x01 };
        compressed[2] = 1; // one uncompressed DEFLATE block
        std.mem.writeInt(u16, compressed[3..5], raw.len, .little);
        std.mem.writeInt(u16, compressed[5..7], ~@as(u16, raw.len), .little);
        @memcpy(compressed[7 .. 7 + raw.len], &raw);
        std.mem.writeInt(u32, compressed[7 + raw.len ..][0..4], std.hash.Adler32.hash(&raw), .big);
        try writeChunk(out, "IDAT", &compressed);
        try writeChunk(out, "IEND", "");
        try out.flush();
    }
};

/// Rebuilds Lantern Leap's small repository-authored PNG. It intentionally
/// remains obvious 8x8 pixel art: player idle/run/jump, a glow pickup,
/// checkpoint lantern, goal door, and spike hazard. The game embeds the
/// generated PNG; this generator documents provenance only.
pub fn main() !void {
    var sheet = Sheet{};
    drawPlayer(&sheet, 0, .idle);
    drawPlayer(&sheet, 8, .run_left);
    drawPlayer(&sheet, 16, .run_right);
    drawPlayer(&sheet, 24, .jump);
    drawGlow(&sheet, 32);
    drawLantern(&sheet, 40);
    drawDoor(&sheet, 48);
    drawSpike(&sheet, 56);
    try sheet.writePng("dogfood/lantern-leap/assets/lantern-leap.png");
}

const PlayerPose = enum { idle, run_left, run_right, jump };

fn drawPlayer(sheet: *Sheet, x: i32, pose: PlayerPose) void {
    const coat = Color.rgb(70, 171, 230);
    const trim = Color.rgb(185, 239, 255);
    const shadow = Color.rgb(30, 61, 116);
    const lantern = Color.rgb(255, 212, 98);
    sheet.fill(x + 3, 0, 2, 1, trim);
    sheet.fill(x + 2, 1, 4, 2, coat);
    sheet.fill(x + 2, 2, 1, 1, trim);
    sheet.fill(x + 1, 3, 6, 3, coat);
    sheet.fill(x + 1, 5, 1, 2, shadow);
    sheet.fill(x + 6, 5, 1, 2, shadow);
    sheet.fill(x + 3, 3, 2, 2, lantern);
    switch (pose) {
        .idle => {
            sheet.fill(x + 2, 7, 1, 1, shadow);
            sheet.fill(x + 5, 7, 1, 1, shadow);
        },
        .run_left => {
            sheet.fill(x + 1, 7, 2, 1, shadow);
            sheet.fill(x + 5, 6, 2, 1, shadow);
        },
        .run_right => {
            sheet.fill(x + 1, 6, 2, 1, shadow);
            sheet.fill(x + 5, 7, 2, 1, shadow);
        },
        .jump => {
            sheet.fill(x + 1, 6, 1, 1, shadow);
            sheet.fill(x + 6, 6, 1, 1, shadow);
        },
    }
}

fn drawGlow(sheet: *Sheet, x: i32) void {
    const glow = Color.rgb(255, 226, 116);
    const core = Color.rgb(255, 250, 210);
    sheet.fill(x + 3, 0, 2, 1, glow);
    sheet.fill(x + 2, 1, 4, 1, glow);
    sheet.fill(x + 1, 2, 6, 4, glow);
    sheet.fill(x + 2, 6, 4, 1, glow);
    sheet.fill(x + 3, 7, 2, 1, glow);
    sheet.fill(x + 3, 2, 2, 3, core);
}

fn drawLantern(sheet: *Sheet, x: i32) void {
    const post = Color.rgb(91, 63, 85);
    const glow = Color.rgb(255, 210, 93);
    sheet.fill(x + 3, 0, 2, 1, post);
    sheet.fill(x + 2, 1, 4, 1, post);
    sheet.fill(x + 2, 2, 4, 3, glow);
    sheet.fill(x + 3, 2, 2, 2, Color.rgb(255, 245, 196));
    sheet.fill(x + 3, 5, 2, 3, post);
}

fn drawDoor(sheet: *Sheet, x: i32) void {
    const stone = Color.rgb(85, 104, 143);
    const dark = Color.rgb(25, 33, 62);
    sheet.fill(x + 1, 1, 6, 7, stone);
    sheet.fill(x + 2, 2, 4, 6, dark);
    sheet.fill(x + 4, 5, 1, 1, Color.rgb(255, 219, 111));
}

fn drawSpike(sheet: *Sheet, x: i32) void {
    const edge = Color.rgb(228, 116, 136);
    sheet.fill(x, 7, 8, 1, Color.rgb(106, 50, 79));
    sheet.fill(x + 1, 5, 2, 2, edge);
    sheet.fill(x + 3, 3, 2, 4, edge);
    sheet.fill(x + 5, 5, 2, 2, edge);
}

fn writeChunk(out: *std.Io.Writer, kind: []const u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.writeAll(&length);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try out.writeAll(&checksum);
}
