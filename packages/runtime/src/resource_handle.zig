const std = @import("std");

const owner_bits = 16;
const generation_bits = 24;
const slot_bits = 24;
const owner_shift = generation_bits + slot_bits;
const generation_shift = slot_bits;
const slot_mask: usize = (@as(usize, 1) << slot_bits) - 1;
const max_registry_owners: u32 = (@as(u32, 1) << owner_bits) - 1;

var next_registry_owner = std.atomic.Value(u32).init(1);

pub const max_resource_slots: usize = @as(usize, 1) << slot_bits;
pub const ResourceKind = enum(u8) { generic, session, channel, route, listener, service, connection, peer, stream };
pub const HandleError = std.mem.Allocator.Error || error{ StaleHandle, WrongResourceKind, HandleCapacityExhausted, InvalidCapacity, RegistryIdentityExhausted };
pub const ResourceHandle = opaque {};

pub const ResourceRegistry = struct {
    const Slot = struct {
        generation: u24 = 1,
        kind: ?ResourceKind = null,
    };

    allocator: std.mem.Allocator,
    owner: u16,
    slots: []Slot,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) HandleError!ResourceRegistry {
        if (capacity == 0 or capacity > max_resource_slots) return error.InvalidCapacity;
        const owner_value = next_registry_owner.fetchAdd(1, .monotonic);
        if (owner_value == 0 or owner_value > max_registry_owners) return error.RegistryIdentityExhausted;
        const slots = try allocator.alloc(Slot, capacity);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .owner = @intCast(owner_value), .slots = slots };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn acquire(self: *ResourceRegistry) HandleError!*ResourceHandle {
        return self.acquire_kind(.generic);
    }

    pub fn acquire_kind(self: *ResourceRegistry, kind: ResourceKind) HandleError!*ResourceHandle {
        for (self.slots, 0..) |*slot, index| {
            if (slot.kind != null) continue;
            slot.kind = kind;
            return self.encode(index, slot.generation);
        }
        return error.HandleCapacityExhausted;
    }

    pub fn validate(self: *const ResourceRegistry, handle: *const ResourceHandle) HandleError!void {
        return self.validate_kind(handle, null);
    }

    pub fn validate_kind(self: *const ResourceRegistry, handle: *const ResourceHandle, expected_kind: ?ResourceKind) HandleError!void {
        const decoded = self.decode(handle) orelse return error.StaleHandle;
        const slot = self.slots[decoded.slot];
        if (slot.kind == null or slot.generation != decoded.generation) return error.StaleHandle;
        if (expected_kind) |kind| if (slot.kind.? != kind) return error.WrongResourceKind;
    }

    pub fn release(self: *ResourceRegistry, handle: *ResourceHandle) HandleError!void {
        return self.release_kind(handle, null);
    }

    pub fn release_kind(self: *ResourceRegistry, handle: *ResourceHandle, expected_kind: ?ResourceKind) HandleError!void {
        try self.validate_kind(handle, expected_kind);
        const decoded = self.decode(handle) orelse return error.StaleHandle;
        const slot = &self.slots[decoded.slot];
        slot.kind = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn encode(self: ResourceRegistry, slot: usize, generation: u24) *ResourceHandle {
        const raw = (@as(usize, self.owner) << owner_shift) | (@as(usize, generation) << generation_shift) | slot;
        return @ptrFromInt(raw);
    }

    fn decode(self: ResourceRegistry, handle: *const ResourceHandle) ?struct { slot: usize, generation: u24 } {
        const raw = @intFromPtr(handle);
        const owner: u16 = @truncate(raw >> owner_shift);
        if (owner != self.owner) return null;
        const slot = raw & slot_mask;
        if (slot >= self.slots.len) return null;
        return .{ .slot = slot, .generation = @truncate(raw >> generation_shift) };
    }
};

test "released generation handles stay stale after slot reuse" {
    var registry = try ResourceRegistry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const original = try registry.acquire_kind(.session);
    try registry.validate_kind(original, .session);
    try registry.release_kind(original, .session);
    try std.testing.expectError(error.StaleHandle, registry.validate_kind(original, .session));
    const replacement = try registry.acquire_kind(.session);
    try std.testing.expect(original != replacement);
    try std.testing.expectError(error.StaleHandle, registry.release_kind(original, .session));
    try registry.release_kind(replacement, .session);
}

test "generation handles reject cross-runtime kinds and capacity without dereferencing input" {
    var first = try ResourceRegistry.init(std.testing.allocator, 1);
    defer first.deinit();
    var second = try ResourceRegistry.init(std.testing.allocator, 1);
    defer second.deinit();
    const handle = try first.acquire_kind(.connection);
    try std.testing.expectError(error.StaleHandle, second.validate_kind(handle, .connection));
    try std.testing.expectError(error.WrongResourceKind, first.validate_kind(handle, .channel));
    try std.testing.expectError(error.HandleCapacityExhausted, first.acquire_kind(.connection));
}

test "retired runtime handles are rejected without reading retired storage" {
    var retired = try ResourceRegistry.init(std.testing.allocator, 1);
    const stale = try retired.acquire_kind(.service);
    retired.deinit();
    var active = try ResourceRegistry.init(std.testing.allocator, 1);
    defer active.deinit();
    try std.testing.expectError(error.StaleHandle, active.validate_kind(stale, .service));
}

test "resource registries reject zero and unrepresentable capacity" {
    try std.testing.expectError(error.InvalidCapacity, ResourceRegistry.init(std.testing.allocator, 0));
    try std.testing.expectError(error.InvalidCapacity, ResourceRegistry.init(std.testing.allocator, max_resource_slots + 1));
}
