const std = @import("std");
const ecs = @import("ecs.zig");

pub const header_bytes: usize = 13;
pub const Identity = struct { value: u64 };
const Operation = enum(u8) { spawn = 1, update = 2, despawn = 3 };

pub fn identity(entity: ecs.Entity) Identity {
    return .{ .value = (@as(u64, entity.generation) << 32) | entity.index };
}

pub fn ComponentSchema(comptime T: type) type {
    return struct {
        id: u16,
        max_encoded_bytes: usize,
        encode: *const fn (destination: []u8, value: T) anyerror![]u8,
        decode: *const fn (source: []const u8) anyerror!T,
    };
}

pub const Packet = struct {
    bytes: []u8,

    pub fn deinit(self: *Packet, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ApplyResult = union(enum) { spawned: ecs.Entity, updated: ecs.Entity, despawned: ecs.Entity };

pub fn Adapter(comptime T: type) type {
    const Schema = ComponentSchema(T);
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        schema: Schema,
        bindings: std.AutoHashMapUnmanaged(u64, ecs.Entity) = .{},

        pub fn init(allocator: std.mem.Allocator, schema: Schema) !Self {
            if (schema.id == 0 or schema.max_encoded_bytes == 0) return error.InvalidReplicationSchema;
            return .{ .allocator = allocator, .schema = schema };
        }

        pub fn deinit(self: *Self) void {
            self.bindings.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn encodeSpawn(self: *const Self, world: *const ecs.World, store: *ecs.ComponentStore(T), entity: ecs.Entity) !Packet {
            return self.encodeComponent(.spawn, world, store, entity);
        }

        pub fn encodeUpdate(self: *const Self, world: *const ecs.World, store: *ecs.ComponentStore(T), entity: ecs.Entity) !Packet {
            return self.encodeComponent(.update, world, store, entity);
        }

        pub fn encodeDespawn(self: *const Self, entity: ecs.Entity) !Packet {
            return self.encode(.despawn, entity, null);
        }

        pub fn apply(self: *Self, world: *ecs.World, store: *ecs.ComponentStore(T), bytes: []const u8) !ApplyResult {
            const decoded = try self.decode(bytes);
            return switch (decoded.operation) {
                .spawn => .{ .spawned = try self.spawn(world, store, decoded.identity, try self.schema.decode(decoded.payload)) },
                .update => .{ .updated = try self.update(world, store, decoded.identity, try self.schema.decode(decoded.payload)) },
                .despawn => .{ .despawned = try self.despawn(world, store, decoded.identity) },
            };
        }

        fn encodeComponent(self: *const Self, operation: Operation, world: *const ecs.World, store: *ecs.ComponentStore(T), entity: ecs.Entity) !Packet {
            const value = try store.get(world, entity);
            return self.encode(operation, entity, value.*);
        }

        fn encode(self: *const Self, operation: Operation, entity: ecs.Entity, value: ?T) !Packet {
            const capacity = header_bytes + if (value == null) @as(usize, 0) else self.schema.max_encoded_bytes;
            var bytes = try self.allocator.alloc(u8, capacity);
            errdefer self.allocator.free(bytes);
            const payload = if (value) |component| try self.schema.encode(bytes[header_bytes..], component) else bytes[header_bytes..header_bytes];
            if (payload.len > self.schema.max_encoded_bytes) return error.ComponentEncodingTooLarge;
            bytes[0] = @intFromEnum(operation);
            std.mem.writeInt(u16, bytes[1..3], self.schema.id, .little);
            std.mem.writeInt(u64, bytes[3..11], identity(entity).value, .little);
            std.mem.writeInt(u16, bytes[11..13], @intCast(payload.len), .little);
            bytes = try self.allocator.realloc(bytes, header_bytes + payload.len);
            return .{ .bytes = bytes };
        }

        fn decode(self: *const Self, bytes: []const u8) !struct { operation: Operation, identity: Identity, payload: []const u8 } {
            if (bytes.len < header_bytes) return error.MalformedReplicationPacket;
            const operation = std.meta.intToEnum(Operation, bytes[0]) catch return error.MalformedReplicationPacket;
            if (std.mem.readInt(u16, bytes[1..3], .little) != self.schema.id) return error.UnknownReplicationSchema;
            const payload_len: usize = std.mem.readInt(u16, bytes[11..13], .little);
            if (payload_len > self.schema.max_encoded_bytes or bytes.len != header_bytes + payload_len) return error.MalformedReplicationPacket;
            if (operation == .despawn and payload_len != 0) return error.MalformedReplicationPacket;
            if (operation != .despawn and payload_len == 0) return error.MalformedReplicationPacket;
            return .{ .operation = operation, .identity = .{ .value = std.mem.readInt(u64, bytes[3..11], .little) }, .payload = bytes[header_bytes..] };
        }

        fn spawn(self: *Self, world: *ecs.World, store: *ecs.ComponentStore(T), remote: Identity, value: T) !ecs.Entity {
            if (self.bindings.get(remote.value)) |local| {
                world.validate(local) catch {
                    _ = self.bindings.remove(remote.value);
                    return self.spawn(world, store, remote, value);
                };
                try store.put(world, local, value);
                return local;
            }
            const local = try world.create();
            errdefer world.destroy(local) catch {};
            try store.put(world, local, value);
            try self.bindings.put(self.allocator, remote.value, local);
            return local;
        }

        fn update(self: *Self, world: *ecs.World, store: *ecs.ComponentStore(T), remote: Identity, value: T) !ecs.Entity {
            const local = self.bindings.get(remote.value) orelse return error.StaleReplicationEntity;
            world.validate(local) catch {
                _ = self.bindings.remove(remote.value);
                return error.StaleReplicationEntity;
            };
            try store.put(world, local, value);
            return local;
        }

        fn despawn(self: *Self, world: *ecs.World, store: *ecs.ComponentStore(T), remote: Identity) !ecs.Entity {
            const local = self.bindings.get(remote.value) orelse return error.StaleReplicationEntity;
            try store.remove(world, local);
            try world.destroy(local);
            _ = self.bindings.remove(remote.value);
            return local;
        }
    };
}

test "ECS replication adapter spawns updates despawns and rejects stale identities" {
    const Position = struct { x: i32, y: i32 };
    const PositionAdapter = Adapter(Position);
    const schema = ComponentSchema(Position){ .id = 1, .max_encoded_bytes = 8, .encode = struct {
        fn call(destination: []u8, position: Position) ![]u8 {
            if (destination.len < 8) return error.BufferTooSmall;
            std.mem.writeInt(i32, destination[0..4], position.x, .little);
            std.mem.writeInt(i32, destination[4..8], position.y, .little);
            return destination[0..8];
        }
    }.call, .decode = struct {
        fn call(source: []const u8) !Position {
            if (source.len != 8) return error.InvalidPosition;
            return .{ .x = std.mem.readInt(i32, source[0..4], .little), .y = std.mem.readInt(i32, source[4..8], .little) };
        }
    }.call };
    var source_world = ecs.World.init(std.testing.allocator);
    defer source_world.deinit();
    var source_positions = ecs.ComponentStore(Position).init(std.testing.allocator);
    defer source_positions.deinit();
    var target_world = ecs.World.init(std.testing.allocator);
    defer target_world.deinit();
    var target_positions = ecs.ComponentStore(Position).init(std.testing.allocator);
    defer target_positions.deinit();
    var source = try PositionAdapter.init(std.testing.allocator, schema);
    defer source.deinit();
    var target = try PositionAdapter.init(std.testing.allocator, schema);
    defer target.deinit();

    const original = try source_world.create();
    try source_positions.put(&source_world, original, .{ .x = 1, .y = 2 });
    var spawn = try source.encodeSpawn(&source_world, &source_positions, original);
    defer spawn.deinit(std.testing.allocator);
    const spawned = try target.apply(&target_world, &target_positions, spawn.bytes);
    const local = spawned.spawned;
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, (try target_positions.get(&target_world, local)).*);

    try source_positions.put(&source_world, original, .{ .x = 3, .y = 4 });
    var update = try source.encodeUpdate(&source_world, &source_positions, original);
    defer update.deinit(std.testing.allocator);
    _ = try target.apply(&target_world, &target_positions, update.bytes);
    try std.testing.expectEqual(Position{ .x = 3, .y = 4 }, (try target_positions.get(&target_world, local)).*);

    var late_update = try source.encodeUpdate(&source_world, &source_positions, original);
    defer late_update.deinit(std.testing.allocator);
    var despawn = try source.encodeDespawn(original);
    defer despawn.deinit(std.testing.allocator);
    _ = try target.apply(&target_world, &target_positions, despawn.bytes);
    try std.testing.expectError(error.StaleReplicationEntity, target.apply(&target_world, &target_positions, late_update.bytes));
    try std.testing.expectError(error.StaleEntity, target_world.validate(local));

    try source_positions.remove(&source_world, original);
    try source_world.destroy(original);
    const replacement = try source_world.create();
    try std.testing.expectEqual(original.index, replacement.index);
    try std.testing.expect(replacement.generation != original.generation);
    try source_positions.put(&source_world, replacement, .{ .x = 5, .y = 6 });
    var replacement_spawn = try source.encodeSpawn(&source_world, &source_positions, replacement);
    defer replacement_spawn.deinit(std.testing.allocator);
    const recreated = try target.apply(&target_world, &target_positions, replacement_spawn.bytes);
    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, (try target_positions.get(&target_world, recreated.spawned)).*);
    try std.testing.expectError(error.StaleReplicationEntity, target.apply(&target_world, &target_positions, despawn.bytes));
}
