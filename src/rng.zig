const std = @import("std");

/// Stable algorithm identifiers for deterministic Peas simulations.
///
/// An algorithm identifier is replay metadata, not a request to select an
/// implementation at runtime. Peas currently supports this one pinned
/// sequence only.
pub const Algorithm = enum(u32) {
    pcg32_xsh_rr_v1 = 1,
};

/// A small deterministic pseudo-random generator for game simulation.
///
/// This is PCG XSH-RR 64/32 with the fixed stream increment from the PCG
/// reference implementation. `init` uses the documented PCG two-step seed
/// sequence: advance zero state once, add the supplied `u64` seed, then
/// advance once more. That recurrence and the output permutation are Peas's
/// v1 random-sequence contract.
pub const DeterministicRng = struct {
    const Self = @This();
    const multiplier: u64 = 6_364_136_223_846_793_005;
    const increment: u64 = 1_442_695_040_888_963_407;

    state: u64,

    pub const algorithm = Algorithm.pcg32_xsh_rr_v1;

    pub fn init(seed: u64) Self {
        var result = Self{ .state = 0 };
        _ = result.nextU32();
        result.state +%= seed;
        _ = result.nextU32();
        return result;
    }

    /// Returns the next exactly specified 32-bit value in Peas's v1 sequence.
    pub fn nextU32(self: *Self) u32 {
        const old_state = self.state;
        self.state = old_state *% multiplier +% increment;
        const xorshifted: u32 = @truncate(((old_state >> 18) ^ old_state) >> 27);
        const rotation: u5 = @truncate(old_state >> 59);
        return (xorshifted >> rotation) | (xorshifted << ((0 -% rotation) & 31));
    }

    /// Combines two consecutive `nextU32` outputs with the first as the high
    /// half. It is stable as long as the v1 `nextU32` sequence is stable.
    pub fn nextU64(self: *Self) u64 {
        return (@as(u64, self.nextU32()) << 32) | self.nextU32();
    }

    /// Returns a uniform integer in the half-open interval `[0, upper)`.
    /// Rejection sampling avoids modulo bias. A zero upper bound is invalid.
    pub fn uintBelow(self: *Self, upper: u32) error{InvalidUpperBound}!u32 {
        if (upper == 0) return error.InvalidUpperBound;
        const threshold = (0 -% upper) % upper;
        while (true) {
            const value = self.nextU32();
            if (value >= threshold) return value % upper;
        }
    }

    /// Returns one of exactly 2^24 equally spaced `f32` values in `[0, 1)`.
    /// It uses the upper 24 bits of one `nextU32` output, so no platform RNG
    /// or floating-point rounding policy contributes to its construction.
    pub fn float01(self: *Self) f32 {
        const mantissa: u24 = @truncate(self.nextU32() >> 8);
        return @as(f32, @floatFromInt(mantissa)) * (1.0 / 16_777_216.0);
    }
};

test "PCG32 v1 golden vectors are stable" {
    const Vector = struct { seed: u64, outputs: [6]u32 };
    const vectors = [_]Vector{
        .{ .seed = 0, .outputs = .{ 0xe823a24e, 0x7a7ecbd9, 0x89fd6c06, 0xae646aa8, 0xcd3cf945, 0x6204b303 } },
        .{ .seed = 1, .outputs = .{ 0x54352d7f, 0x6ac20236, 0x0768dd4c, 0x75560a43, 0x4065d452, 0x99b2e260 } },
        .{ .seed = 42, .outputs = .{ 0xc2f57bd6, 0x6b07c4a9, 0x72b7b29b, 0x44215383, 0xf5af5ead, 0x68beb632 } },
        .{ .seed = std.math.maxInt(u64), .outputs = .{ 0xd9313036, 0xcd4b6992, 0x7b8ec69e, 0x999dd010, 0x5c4eb9ab, 0xb7673059 } },
    };
    for (vectors) |vector| {
        var rng = DeterministicRng.init(vector.seed);
        for (vector.outputs) |expected| try std.testing.expectEqual(expected, rng.nextU32());
    }

    var rng64 = DeterministicRng.init(42);
    try std.testing.expectEqual(@as(u64, 0xc2f57bd66b07c4a9), rng64.nextU64());
}

test "deterministic RNG instances and copied state have explicit behavior" {
    var first = DeterministicRng.init(42);
    var second = DeterministicRng.init(42);
    var different = DeterministicRng.init(43);
    const first_value = first.nextU32();
    try std.testing.expectEqual(first_value, second.nextU32());
    try std.testing.expect(first_value != different.nextU32());

    var copied = first;
    try std.testing.expectEqual(first.nextU64(), copied.nextU64());
}

test "deterministic RNG bounded and floating outputs have documented ranges" {
    var rng = DeterministicRng.init(0);
    try std.testing.expectError(error.InvalidUpperBound, rng.uintBelow(0));
    for (0..256) |_| {
        try std.testing.expect((try rng.uintBelow(7)) < 7);
        const value = rng.float01();
        try std.testing.expect(value >= 0 and value < 1);
    }
}
