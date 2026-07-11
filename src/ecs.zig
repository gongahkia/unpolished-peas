const std = @import("std");

pub const Entity = struct { index: u32, generation: u32 };

pub const World = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(u32) = .empty,

    const Slot = struct { generation: u32 = 1, live: bool = false };

    pub fn init(allocator: std.mem.Allocator) World {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *World) void {
        self.slots.deinit(self.allocator);
        self.free.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn create(self: *World) !Entity {
        if (self.free.pop()) |index| {
            self.slots.items[index].live = true;
            return .{ .index = index, .generation = self.slots.items[index].generation };
        }
        try self.slots.append(self.allocator, .{ .live = true });
        return .{ .index = @intCast(self.slots.items.len - 1), .generation = 1 };
    }
    pub fn destroy(self: *World, entity: Entity) !void {
        try self.validate(entity);
        var slot = &self.slots.items[entity.index];
        slot.live = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        try self.free.append(self.allocator, entity.index);
    }
    pub fn validate(self: *const World, entity: Entity) !void {
        if (entity.index >= self.slots.items.len) return error.StaleEntity;
        const slot = self.slots.items[entity.index];
        if (!slot.live or slot.generation != entity.generation) return error.StaleEntity;
    }
};

pub fn ComponentStore(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        dense_entities: std.ArrayList(Entity) = .empty,
        dense_values: std.ArrayList(T) = .empty,
        sparse: std.ArrayList(usize) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.dense_entities.deinit(self.allocator);
            self.dense_values.deinit(self.allocator);
            self.sparse.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn put(self: *Self, world: *const World, entity: Entity, value: T) !void {
            try world.validate(entity);
            try self.ensure(entity.index);
            const existing = self.sparse.items[entity.index];
            if (existing != invalid and self.dense_entities.items[existing].generation == entity.generation) {
                self.dense_values.items[existing] = value;
                return;
            }
            const index = self.dense_values.items.len;
            try self.dense_entities.append(self.allocator, entity);
            try self.dense_values.append(self.allocator, value);
            self.sparse.items[entity.index] = index;
        }
        pub fn get(self: *Self, world: *const World, entity: Entity) !*T {
            try world.validate(entity);
            if (entity.index >= self.sparse.items.len) return error.MissingComponent;
            const index = self.sparse.items[entity.index];
            if (index == invalid or self.dense_entities.items[index].generation != entity.generation) return error.MissingComponent;
            return &self.dense_values.items[index];
        }
        pub fn remove(self: *Self, world: *const World, entity: Entity) !void {
            try world.validate(entity);
            if (entity.index >= self.sparse.items.len) return error.MissingComponent;
            const index = self.sparse.items[entity.index];
            if (index == invalid or self.dense_entities.items[index].generation != entity.generation) return error.MissingComponent;
            const last = self.dense_values.items.len - 1;
            if (index != last) {
                self.dense_values.items[index] = self.dense_values.items[last];
                self.dense_entities.items[index] = self.dense_entities.items[last];
                self.sparse.items[self.dense_entities.items[index].index] = index;
            }
            _ = self.dense_values.pop();
            _ = self.dense_entities.pop();
            self.sparse.items[entity.index] = invalid;
        }
        const invalid = std.math.maxInt(usize);
        fn ensure(self: *Self, index: u32) !void {
            while (self.sparse.items.len <= index) try self.sparse.append(self.allocator, invalid);
        }
    };
}

test "ECS reuses entities and removes sparse components" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var positions = ComponentStore(i32).init(std.testing.allocator);
    defer positions.deinit();
    const first = try world.create();
    try positions.put(&world, first, 7);
    try std.testing.expectEqual(@as(i32, 7), (try positions.get(&world, first)).*);
    try positions.remove(&world, first);
    try std.testing.expectError(error.MissingComponent, positions.get(&world, first));
    try world.destroy(first);
    const replacement = try world.create();
    try std.testing.expectEqual(first.index, replacement.index);
    try std.testing.expect(replacement.generation != first.generation);
    try std.testing.expectError(error.StaleEntity, positions.put(&world, first, 1));
}
