const std = @import("std");
const BlendMode = @import("canvas.zig").BlendMode;
const Color = @import("color.zig").Color;
const Vec2 = @import("math.zig").Vec2;
const PrimitiveBatch = @import("primitive_batch.zig").PrimitiveBatch;

pub const Config = struct {
    capacity: u32,
    seed: u64 = 1,
    origin: Vec2 = .{},
    velocity_min: Vec2 = .{},
    velocity_max: Vec2 = .{},
    acceleration: Vec2 = .{},
    lifetime_min_ticks: u32 = 1,
    lifetime_max_ticks: u32 = 1,
    emission_per_tick: u32 = 0,
    size: i32 = 1,
    color: Color = Color.white,
    blend: BlendMode = .additive,
};

pub const Metrics = struct {
    active: u32,
    emitted: u32,
    dropped: u32,
    vertices: u32,
    draws: u32,
};

const Particle = struct {
    position: Vec2,
    velocity: Vec2,
    age: u32 = 0,
    lifetime: u32,
    alive: bool = false,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    random: u64,
    particles: []Particle,
    running: bool = false,
    active: u32 = 0,
    emitted: u32 = 0,
    dropped: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Emitter {
        if (config.capacity == 0 or config.lifetime_min_ticks == 0 or config.lifetime_max_ticks < config.lifetime_min_ticks or config.size <= 0) return error.InvalidParticleConfig;
        const particles = try allocator.alloc(Particle, config.capacity);
        @memset(particles, .{ .position = .{}, .velocity = .{}, .lifetime = 0 });
        return .{ .allocator = allocator, .config = config, .random = config.seed, .particles = particles };
    }

    pub fn deinit(self: *Emitter) void {
        self.allocator.free(self.particles);
        self.* = undefined;
    }

    pub fn start(self: *Emitter) void {
        self.running = true;
    }

    pub fn stop(self: *Emitter) void {
        self.running = false;
    }

    pub fn emit(self: *Emitter, requested: u32) u32 {
        var emitted: u32 = 0;
        while (emitted < requested) : (emitted += 1) {
            const slot = self.findFree() orelse {
                self.dropped +%= requested - emitted;
                break;
            };
            self.particles[slot] = .{
                .position = self.config.origin,
                .velocity = .{
                    .x = self.randomRange(self.config.velocity_min.x, self.config.velocity_max.x),
                    .y = self.randomRange(self.config.velocity_min.y, self.config.velocity_max.y),
                },
                .lifetime = self.randomTicks(self.config.lifetime_min_ticks, self.config.lifetime_max_ticks),
                .alive = true,
            };
            self.active += 1;
            self.emitted +%= 1;
        }
        return emitted;
    }

    pub fn update(self: *Emitter, ticks: u32) void {
        if (self.running and self.config.emission_per_tick != 0) {
            var tick: u32 = 0;
            while (tick < ticks) : (tick += 1) _ = self.emit(self.config.emission_per_tick);
        }
        for (self.particles) |*particle| {
            if (!particle.alive) continue;
            const remaining = particle.lifetime - particle.age;
            if (ticks >= remaining) {
                particle.alive = false;
                self.active -= 1;
                continue;
            }
            const step: f32 = @floatFromInt(ticks);
            particle.velocity = particle.velocity.add(.{ .x = self.config.acceleration.x * step, .y = self.config.acceleration.y * step });
            particle.position = particle.position.add(.{ .x = particle.velocity.x * step, .y = particle.velocity.y * step });
            particle.age += ticks;
        }
    }

    pub fn draw(self: *const Emitter, batch: *PrimitiveBatch, canvas_width: u32, canvas_height: u32) !Metrics {
        const vertex_start: u32 = @intCast(batch.vertices.items.len);
        const draw_start = batch.draws.items.len;
        for (self.particles) |particle| {
            if (!particle.alive) continue;
            try batch.rect(canvas_width, canvas_height, @intFromFloat(@round(particle.position.x)), @intFromFloat(@round(particle.position.y)), self.config.size, self.config.size, self.config.color);
        }
        try batch.finishDraw(vertex_start, self.config.blend, null);
        return .{
            .active = self.active,
            .emitted = self.emitted,
            .dropped = self.dropped,
            .vertices = @intCast(batch.vertices.items.len - vertex_start),
            .draws = @intCast(batch.draws.items.len - draw_start),
        };
    }

    pub fn hash(self: Emitter) u64 {
        var result: u64 = 0;
        for (self.particles) |particle| {
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.position.x));
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.position.y));
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.velocity.x));
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.velocity.y));
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.age));
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.lifetime));
            result = std.hash.Wyhash.hash(result, std.mem.asBytes(&particle.alive));
        }
        return result;
    }

    fn findFree(self: *const Emitter) ?usize {
        for (self.particles, 0..) |particle, index| if (!particle.alive) return index;
        return null;
    }

    fn randomRange(self: *Emitter, min: f32, max: f32) f32 {
        if (min >= max) return min;
        return min + (max - min) * @as(f32, @floatFromInt(self.nextRandom() >> 40)) / @as(f32, @floatFromInt((@as(u32, 1) << 24) - 1));
    }

    fn randomTicks(self: *Emitter, min: u32, max: u32) u32 {
        if (min == max) return min;
        return min + @as(u32, @truncate(self.nextRandom())) % (max - min + 1);
    }

    fn nextRandom(self: *Emitter) u64 {
        var value = self.random;
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        self.random = value;
        return value;
    }
};

test "particle emitter enforces lifecycle and fixed capacity" {
    var emitter = try Emitter.init(std.testing.allocator, .{ .capacity = 2, .lifetime_min_ticks = 2, .lifetime_max_ticks = 2 });
    defer emitter.deinit();
    try std.testing.expectEqual(@as(u32, 2), emitter.emit(3));
    try std.testing.expectEqual(@as(u32, 2), emitter.active);
    try std.testing.expectEqual(@as(u32, 1), emitter.dropped);
    emitter.update(2);
    try std.testing.expectEqual(@as(u32, 0), emitter.active);
    emitter.start();
    emitter.config.emission_per_tick = 1;
    emitter.update(1);
    try std.testing.expectEqual(@as(u32, 1), emitter.active);
    const emitted = emitter.emitted;
    emitter.stop();
    emitter.update(1);
    try std.testing.expectEqual(emitted, emitter.emitted);
}

test "particle simulation hashes and batch metrics are deterministic" {
    const config = Config{
        .capacity = 8,
        .seed = 42,
        .velocity_min = .{ .x = -1, .y = 1 },
        .velocity_max = .{ .x = 1, .y = 3 },
        .lifetime_min_ticks = 3,
        .lifetime_max_ticks = 5,
        .emission_per_tick = 2,
    };
    var first = try Emitter.init(std.testing.allocator, config);
    defer first.deinit();
    var second = try Emitter.init(std.testing.allocator, config);
    defer second.deinit();
    first.start();
    second.start();
    first.update(3);
    second.update(3);
    try std.testing.expectEqual(first.hash(), second.hash());
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    const metrics = try first.draw(&batch, 32, 32);
    try std.testing.expectEqual(first.active, metrics.active);
    try std.testing.expectEqual(first.active * 6, metrics.vertices);
    try std.testing.expectEqual(@as(u32, 1), metrics.draws);
}
