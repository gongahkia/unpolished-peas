//! Explicit v2 run record; the original three-byte record remains readable.
const std = @import("std");
pub const key = "progress.v2";
pub const size = 8;
pub const Record = struct { best: u8 = 0, finished: bool = false, audio: bool = true, mask: u8 = 0, checkpoint: u8 = 0, started: bool = false, completed: bool = false };
fn check(b: []const u8) u8 {
    var value: u8 = 0xa7;
    for (b) |byte| value ^= byte;
    return value;
}
pub fn encode(r: Record) [size]u8 {
    var b = [_]u8{ 2, r.best, @intFromBool(r.finished), @intFromBool(r.audio), r.mask, r.checkpoint, @as(u8, @intFromBool(r.started)) | (@as(u8, @intFromBool(r.completed)) << 1), 0 };
    b[7] = check(b[0..7]);
    return b;
}
pub fn decode(b: []const u8) !Record {
    if (b.len != size or b[0] != 2 or b[1] > 6 or b[2] > 1 or b[3] > 1 or b[4] > 63 or b[5] > 1 or b[6] > 3 or check(b[0..7]) != b[7]) return error.InvalidProgress;
    const r = Record{ .best = b[1], .finished = b[2] == 1, .audio = b[3] == 1, .mask = b[4], .checkpoint = b[5], .started = b[6] & 1 != 0, .completed = b[6] & 2 != 0 };
    if (r.best < @popCount(r.mask) or (!r.started and (r.mask != 0 or r.checkpoint != 0 or r.completed)) or (r.completed and !r.finished)) return error.InvalidProgress;
    return r;
}
pub fn legacy(b: []const u8) !Record {
    if (b.len != 3 or b[0] != 1 or b[1] > 6 or b[2] > 1) return error.InvalidProgress;
    return .{ .best = b[1], .finished = b[2] == 1 };
}
test "v1 records migrate without inventing current-run progress; v2 rejects malformed state" {
    const old = try legacy(&.{ 1, 4, 1 });
    try std.testing.expect(old.finished and old.best == 4 and !old.started and old.audio);
    const expected = Record{ .best = 6, .finished = true, .audio = false, .mask = 63, .checkpoint = 1, .started = true, .completed = true };
    const bytes = encode(expected);
    try std.testing.expectEqualDeep(expected, try decode(&bytes));
    var bad = bytes;
    bad[4] = 64;
    bad[7] = check(bad[0..7]);
    try std.testing.expectError(error.InvalidProgress, decode(&bad));
    bad = bytes;
    bad[7] ^= 1;
    try std.testing.expectError(error.InvalidProgress, decode(&bad));
    bad = encode(.{ .mask = 1 });
    try std.testing.expectError(error.InvalidProgress, decode(&bad));
    try std.testing.expectError(error.InvalidProgress, legacy(&.{ 1, 7, 0 }));
}
