const std = @import("std");
const image = @import("image.zig");
const atlas = @import("atlas.zig");
const tilemap = @import("tilemap.zig");
const net_codec = @import("net_codec.zig");
const net_frame = @import("net_frame.zig");
const handshake = @import("net_handshake.zig");
const p2p = @import("net_p2p.zig");

pub fn run(input: []const u8) !void {
    var bounded_storage: [128 * 1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&bounded_storage);
    runWith(bounded.allocator(), input);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    runWith(gpa.allocator(), input);
}

fn runWith(allocator: std.mem.Allocator, input: []const u8) void {
    const bounded = input[0..@min(input.len, 4 * 1024)];
    if (image.Image.decode(allocator, bounded, .{ .max_input_bytes = 4 * 1024, .max_width = 128, .max_height = 128, .max_pixels = 16 * 1024 })) |decoded| {
        var value = decoded;
        value.deinit();
    } else |_| {}
    if (atlas.Atlas.decode(allocator, bounded, "fuzz.png", bounded)) |decoded| {
        var value = decoded;
        value.deinit();
    } else |_| {}
    if (tilemap.TileMap.decodeNative(allocator, bounded)) |decoded| {
        var value = decoded;
        value.deinit();
    } else |_| {}
    if (net_codec.decode(allocator, bounded)) |decoded| {
        var value = decoded;
        value.deinit(allocator);
    } else |_| {}
    _ = net_frame.decode(bounded) catch {};
    _ = handshake.decodeClientHello(bounded) catch {};
    _ = handshake.decodeServerReply(bounded) catch {};
    _ = p2p.decodeControl(bounded) catch {};
    p2p.fuzzState(allocator, bounded);
}

test "bounded decoder and protocol corpus is leak free" {
    const corpus = [_][]const u8{
        @embedFile("fuzz_corpus/asset/empty"),
        @embedFile("fuzz_corpus/asset/native-map-truncated"),
        @embedFile("fuzz_corpus/network/frame-truncated"),
        @embedFile("fuzz_corpus/network/oversized-length"),
    };
    for (corpus, 0..) |seed, seed_index| {
        try run(seed);
        var mutated: [256]u8 = undefined;
        const length = @min(seed.len, mutated.len);
        @memcpy(mutated[0..length], seed[0..length]);
        var index: usize = 0;
        while (index < 64) : (index += 1) {
            if (length > 0) mutated[index % length] = mutated[index % length] ^ @as(u8, @truncate(seed_index + index + 1));
            try run(mutated[0..length]);
        }
    }
}
