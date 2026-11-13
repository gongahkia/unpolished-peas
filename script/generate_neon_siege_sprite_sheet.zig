const std = @import("std");

const width = 32;
const height = 16;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const white: Color = .{ .r = 255, .g = 255, .b = 255 };

    fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

const PixelSheet = struct {
    pixels: [width * height]Color = [_]Color{Color.transparent} ** (width * height),

    fn clear(self: *PixelSheet, color: Color) void {
        @memset(&self.pixels, color);
    }

    fn fillRect(self: *PixelSheet, x: i32, y: i32, rect_width: i32, rect_height: i32, color: Color) void {
        var py = y;
        while (py < y + rect_height) : (py += 1) {
            var px = x;
            while (px < x + rect_width) : (px += 1) {
                if (px < 0 or py < 0 or px >= width or py >= height) continue;
                self.pixels[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))] = color;
            }
        }
    }

    fn writePngFile(self: PixelSheet, path: []const u8) !void {
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
        try writePngChunk(out, "IHDR", &header);

        var raw: [height * (1 + width * 4)]u8 = undefined;
        var raw_index: usize = 0;
        for (self.pixels, 0..) |color, pixel_index| {
            if (pixel_index % width == 0) {
                raw[raw_index] = 0;
                raw_index += 1;
            }
            raw[raw_index..][0..4].* = .{ color.r, color.g, color.b, color.a };
            raw_index += 4;
        }
        var compressed: [2 + 5 + raw.len + 4]u8 = undefined;
        compressed[0..2].* = .{ 0x78, 0x01 };
        compressed[2] = 1;
        std.mem.writeInt(u16, compressed[3..5], raw.len, .little);
        std.mem.writeInt(u16, compressed[5..7], ~@as(u16, raw.len), .little);
        @memcpy(compressed[7 .. 7 + raw.len], &raw);
        std.mem.writeInt(u32, compressed[7 + raw.len ..][0..4], std.hash.Adler32.hash(&raw), .big);
        try writePngChunk(out, "IDAT", &compressed);
        try writePngChunk(out, "IEND", "");
        try out.flush();
    }
};

/// Rebuilds Neon Siege's tiny repository-authored PNG sprite sheet. The
/// generated source asset is intentionally simple pixel art so its provenance
/// stays clear and the dogfood game has two genuine player walk frames.
pub fn main() !void {
    var canvas = PixelSheet{};
    canvas.clear(Color.transparent);

    drawPlayer(&canvas, 0, false);
    drawPlayer(&canvas, 8, true);
    drawEnemy(&canvas, 16);
    drawProjectile(&canvas, 24);
    drawPickup(&canvas, 0, 8);

    const path = "dogfood/neon-siege/assets/neon-siege.png";
    try canvas.writePngFile(path);
}

fn drawPlayer(canvas: *PixelSheet, x: i32, stride: bool) void {
    const body = Color.rgb(83, 224, 255);
    const highlight = Color.rgb(211, 250, 255);
    const shadow = Color.rgb(32, 110, 191);
    canvas.fillRect(x + 2, 1, 4, 1, body);
    canvas.fillRect(x + 1, 2, 6, 4, body);
    canvas.fillRect(x + 2, 2, 4, 1, highlight);
    canvas.fillRect(x + 2, 3, 1, 1, shadow);
    canvas.fillRect(x + 5, 3, 1, 1, shadow);
    canvas.fillRect(x, 4, 1, 2, shadow);
    canvas.fillRect(x + 7, 4, 1, 2, shadow);
    canvas.fillRect(x + 2, 6, 4, 1, shadow);
    if (stride) {
        canvas.fillRect(x + 1, 7, 2, 1, shadow);
        canvas.fillRect(x + 5, 6, 2, 1, shadow);
    } else {
        canvas.fillRect(x + 2, 7, 1, 1, shadow);
        canvas.fillRect(x + 5, 7, 1, 1, shadow);
    }
}

fn drawEnemy(canvas: *PixelSheet, x: i32) void {
    const shell = Color.rgb(253, 102, 167);
    const core = Color.rgb(255, 208, 232);
    const shadow = Color.rgb(128, 34, 104);
    canvas.fillRect(x + 3, 0, 2, 1, shadow);
    canvas.fillRect(x + 2, 1, 4, 1, shell);
    canvas.fillRect(x + 1, 2, 6, 4, shell);
    canvas.fillRect(x + 2, 3, 4, 2, core);
    canvas.fillRect(x + 3, 2, 2, 1, shadow);
    canvas.fillRect(x + 2, 6, 4, 1, shell);
    canvas.fillRect(x + 3, 7, 2, 1, shadow);
}

fn drawProjectile(canvas: *PixelSheet, x: i32) void {
    canvas.fillRect(x + 1, 3, 6, 2, Color.rgb(73, 185, 255));
    canvas.fillRect(x + 2, 2, 4, 4, Color.rgb(139, 232, 255));
    canvas.fillRect(x + 3, 3, 3, 1, Color.white);
}

fn drawPickup(canvas: *PixelSheet, x: i32, y: i32) void {
    const gold = Color.rgb(255, 198, 74);
    const shine = Color.rgb(255, 239, 167);
    canvas.fillRect(x + 3, y, 2, 1, gold);
    canvas.fillRect(x + 2, y + 1, 4, 1, gold);
    canvas.fillRect(x + 1, y + 2, 6, 3, gold);
    canvas.fillRect(x + 2, y + 5, 4, 2, gold);
    canvas.fillRect(x + 3, y + 7, 2, 1, gold);
    canvas.fillRect(x + 3, y + 2, 2, 3, shine);
}

fn writePngChunk(out: *std.Io.Writer, kind: []const u8, data: []const u8) !void {
    var encoded_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded_length, @intCast(data.len), .big);
    try out.writeAll(&encoded_length);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try out.writeAll(&checksum);
}
