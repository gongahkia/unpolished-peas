//! Explicit single-key format; transient combat is intentionally excluded.
const std = @import("std");
const world = @import("world.zig");
pub const key = "journey-v1";
pub const size = 40;
pub const Settings = struct { music: u8 = 50, effects: u8 = 70, shake: bool = false, flash: bool = false };
pub const Loaded = struct { state: world.World, settings: Settings };
fn checksum(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |b| h = (h ^ b) *% 16777619;
    return h;
}
pub fn encode(w: world.World, s: Settings) [size]u8 {
    var b = [_]u8{0} ** size;
    @memcpy(b[0..4], "ASH1");
    b[4] = 1;
    b[5] = w.checkpoint;
    b[6] = @intFromEnum(w.player.weapon);
    b[7] = w.upgrade;
    b[8] = w.vitality;
    for (w.bells, 0..) |bell, i| if (bell) {
        b[9] |= @as(u8, 1) << @intCast(i);
    };
    b[10] = @intFromBool(w.shortcut);
    b[11] = @intFromBool(w.reward);
    b[12] = @intFromBool(w.charm);
    b[13] = @intFromBool(w.boss_defeated);
    b[14] = @intFromBool(w.completed);
    b[15] = s.music;
    b[16] = s.effects;
    b[17] = @intFromBool(s.shake);
    b[18] = @intFromBool(s.flash);
    std.mem.writeInt(u32, b[20..24], w.embers, .little);
    std.mem.writeInt(u32, b[24..28], w.drop.amount, .little);
    b[28] = w.drop.room;
    std.mem.writeInt(u16, b[30..32], @intFromFloat(@round(w.drop.pos.x)), .little);
    std.mem.writeInt(u16, b[32..34], @intFromFloat(@round(w.drop.pos.y)), .little);
    std.mem.writeInt(u32, b[36..40], checksum(b[0..36]), .little);
    return b;
}
pub fn decode(b: []const u8) !Loaded {
    if (b.len != size or !std.mem.eql(u8, b[0..4], "ASH1") or b[4] != 1) return error.InvalidSave;
    if (std.mem.readInt(u32, b[36..40], .little) != checksum(b[0..36])) return error.InvalidSave;
    if (b[5] > 2 or b[6] > 1 or b[7] > 3 or b[8] > 3 or b[9] > 7 or b[15] > 100 or b[16] > 100 or b[28] > 2) return error.InvalidSave;
    for ([_]usize{ 10, 11, 12, 13, 14, 17, 18 }) |i| if (b[i] > 1) return error.InvalidSave;
    for ([_]usize{ 19, 29, 34, 35 }) |i| if (b[i] != 0) return error.InvalidSave;
    const x = std.mem.readInt(u16, b[30..32], .little);
    const y = std.mem.readInt(u16, b[32..34], .little);
    if (x > 960 or y > 540 or (b[12] == 1 and b[11] == 0) or (b[14] == 1 and (b[13] == 0 or b[9] != 7))) return error.InvalidSave;
    var w = world.World.init();
    w.checkpoint = b[5];
    w.player.weapon = @enumFromInt(b[6]);
    w.upgrade = b[7];
    w.vitality = b[8];
    for (&w.bells, 0..) |*bell, i| bell.* = b[9] & (@as(u8, 1) << @intCast(i)) != 0;
    w.shortcut = b[10] == 1;
    w.reward = b[11] == 1;
    w.charm = b[12] == 1;
    w.boss_defeated = b[13] == 1;
    w.completed = b[14] == 1;
    w.embers = std.mem.readInt(u32, b[20..24], .little);
    w.drop = .{ .amount = std.mem.readInt(u32, b[24..28], .little), .room = b[28], .pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) } };
    w.respawn(); // Last lantern, full resources, normal enemies reset, boss stays dead.
    return .{ .state = w, .settings = .{ .music = b[15], .effects = b[16], .shake = b[17] == 1, .flash = b[18] == 1 } };
}
test "save preserves progression and resets transient combat" {
    var w = world.World.init();
    w.room = 2;
    w.checkpoint = 2;
    w.bells = .{true} ** 3;
    w.shortcut = true;
    w.reward = true;
    w.charm = true;
    w.upgrade = 3;
    w.vitality = 2;
    w.embers = 123;
    w.boss_defeated = true;
    w.completed = true;
    w.drop = .{ .room = 1, .amount = 45, .pos = .{ .x = 300, .y = 400 } };
    w.player.weapon = .spear;
    w.player.hp = 1;
    w.player.action = .heavy;
    w.player.pending = .dodge;
    w.player.flasks = 0;
    const b = encode(w, .{ .music = 20, .effects = 80, .shake = true });
    const loaded = try decode(&b);
    try std.testing.expectEqualDeep(b, encode(loaded.state, loaded.settings));
    try std.testing.expectEqual(@as(u8, 130), loaded.state.player.hp);
    try std.testing.expectEqual(@as(u8, 125), loaded.state.player.stamina);
    try std.testing.expectEqual(@as(u8, 4), loaded.state.player.flasks);
    try std.testing.expectEqual(@as(u16, 0), loaded.state.enemies[4].hp);
    try std.testing.expectEqual(@as(f32, 70), loaded.state.pos.x);
    try std.testing.expect(loaded.state.player.pending == null);
}
test "save rejects truncation bit corruption and invalid fields even with checksum" {
    const original = encode(world.World.init(), .{});
    for (0..size) |i| {
        try std.testing.expectError(error.InvalidSave, decode(original[0..i]));
    }
    for (0..size) |i| {
        var b = original;
        b[i] ^= 1;
        try std.testing.expectError(error.InvalidSave, decode(&b));
    }
    var b = original;
    b[7] = 4;
    std.mem.writeInt(u32, b[36..40], checksum(b[0..36]), .little);
    try std.testing.expectError(error.InvalidSave, decode(&b));
}
