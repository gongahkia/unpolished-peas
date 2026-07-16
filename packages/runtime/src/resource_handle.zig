const std = @import("std");

pub const HandleError = std.mem.Allocator.Error || error{ StaleHandle, HandleCapacityExhausted };
pub const ResourceHandle = opaque {};

pub const ResourceRegistry = struct {
    const Token = struct {
        slot: u32,
        generation: u32,
    };

    const Slot = struct {
        generation: u32 = 1,
        token: ?*Token = null,
    };

    allocator: std.mem.Allocator,
    slots: []Slot,
    tokens: std.ArrayListUnmanaged(*Token) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!ResourceRegistry {
        const slots = try allocator.alloc(Slot, capacity);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        for (self.tokens.items) |token| self.allocator.destroy(token);
        self.tokens.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn acquire(self: *ResourceRegistry) HandleError!*ResourceHandle {
        for (self.slots, 0..) |*slot, index| {
            if (slot.token != null) continue;
            const token = try self.allocator.create(Token);
            errdefer self.allocator.destroy(token);
            token.* = .{ .slot = @intCast(index), .generation = slot.generation };
            try self.tokens.append(self.allocator, token);
            slot.token = token;
            return @ptrCast(token);
        }
        return error.HandleCapacityExhausted;
    }

    pub fn validate(self: *const ResourceRegistry, handle: *const ResourceHandle) HandleError!void {
        const token: *const Token = @ptrCast(@alignCast(handle));
        if (token.slot >= self.slots.len) return error.StaleHandle;
        const slot = self.slots[token.slot];
        if (slot.token != token or slot.generation != token.generation) return error.StaleHandle;
    }

    pub fn release(self: *ResourceRegistry, handle: *ResourceHandle) HandleError!void {
        try self.validate(handle);
        const token: *Token = @ptrCast(@alignCast(handle));
        const slot = &self.slots[token.slot];
        slot.token = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }
};

test "released opaque handles become stale before their slot is reused" {
    var registry = try ResourceRegistry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const original = try registry.acquire();
    try registry.validate(original);
    try registry.release(original);
    try std.testing.expectError(error.StaleHandle, registry.validate(original));
    const replacement = try registry.acquire();
    try std.testing.expect(original != replacement);
    try std.testing.expectError(error.StaleHandle, registry.release(original));
    try registry.release(replacement);
}

test "registries reject exhausted capacity" {
    var registry = try ResourceRegistry.init(std.testing.allocator, 1);
    defer registry.deinit();
    _ = try registry.acquire();
    try std.testing.expectError(error.HandleCapacityExhausted, registry.acquire());
}
