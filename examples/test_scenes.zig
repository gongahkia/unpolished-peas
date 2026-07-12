const std = @import("std");
const up = @import("unpolished-peas");

const expected_hash: u64 = 0x3a157a05d10f355b;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const ball = try assets.loadPng("ball.png");

    var canvas = try up.Canvas.init(allocator, 64, 48);
    defer canvas.deinit();

    canvas.clear(up.Color.rgb(14, 18, 24));
    canvas.fillRect(4, 4, 12, 10, up.Color.rgb(255, 198, 74));
    canvas.drawImage(assets.image(ball), 24, 16);
    canvas.drawText("TEST", 4, 36, up.Color.white);
    const camera = up.Camera2D{ .position = .{ .x = 32, .y = 24 }, .zoom = 1.5, .rotation = 0.15, .pixel_snap = .off };
    const world = up.CameraCanvas.init(&canvas, &camera);
    world.fillRect(.init(20, 10, 14, 8), up.Color.rgb(91, 166, 210));
    world.fillCircle(.{ .x = 44, .y = 30 }, 4, up.Color.rgb(255, 112, 112));

    const got = hashCanvas(canvas);
    if (got != expected_hash) {
        try std.fs.cwd().makePath("zig-out");
        try canvas.writePpmFile("zig-out/scene-fail.ppm");
        var buffer: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buffer);
        const err = &writer.interface;
        try err.print("scene hash mismatch: expected 0x{x}, got 0x{x}\n", .{ expected_hash, got });
        try err.flush();
        return error.SceneHashMismatch;
    }
}

fn hashCanvas(canvas: up.Canvas) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    for (canvas.pixels) |p| {
        hasher.update(&.{ p.r, p.g, p.b, p.a });
    }
    return hasher.final();
}
