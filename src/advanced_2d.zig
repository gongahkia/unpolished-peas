const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const BlendMode = @import("canvas.zig").BlendMode;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Vec2 = @import("math.zig").Vec2;

pub const max_shader_source_bytes = 256 * 1024;
pub const max_shader_bindings = 16;
pub const max_particles = 1_000_000;

pub const ShaderTarget = enum {
    native_hlsl,
    webgl2_glsl_es,
    webgpu_wgsl,
};

pub const ShaderBindingKind = enum {
    texture,
    uniform,
};

pub const ShaderBinding = struct {
    name: []const u8,
    kind: ShaderBindingKind,
};

/// All sources are required. The engine validates the common binding manifest
/// before a backend compiles its target-specific source at runtime.
pub const ShaderSourceBundle = struct {
    native_hlsl: []const u8,
    webgl2_glsl_es: []const u8,
    webgpu_wgsl: []const u8,
    bindings: []const ShaderBinding = &.{},

    pub fn source(self: ShaderSourceBundle, target: ShaderTarget) []const u8 {
        return switch (target) {
            .native_hlsl => self.native_hlsl,
            .webgl2_glsl_es => self.webgl2_glsl_es,
            .webgpu_wgsl => self.webgpu_wgsl,
        };
    }

    pub fn validate(self: ShaderSourceBundle) !void {
        if (self.bindings.len > max_shader_bindings) return error.TooManyShaderBindings;
        inline for ([_]ShaderTarget{ .native_hlsl, .webgl2_glsl_es, .webgpu_wgsl }) |target| {
            const value = self.source(target);
            if (value.len == 0) return error.MissingShaderSource;
            if (value.len > max_shader_source_bytes) return error.ShaderSourceTooLarge;
            if (std.mem.indexOf(u8, value, "main") == null) return error.ShaderEntryPointMissing;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidShaderSourceEncoding;
        }
        for (self.bindings, 0..) |binding, index| {
            if (!validBindingName(binding.name)) return error.InvalidShaderBindingName;
            for (self.bindings[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name, binding.name)) return error.DuplicateShaderBinding;
            }
        }
    }
};

pub const Material = struct {
    name: []const u8,
    sources: ShaderSourceBundle,

    pub fn init(name: []const u8, sources: ShaderSourceBundle) !Material {
        if (name.len == 0 or name.len > 96) return error.InvalidMaterialName;
        try sources.validate();
        return .{ .name = name, .sources = sources };
    }
};

/// Vertex and fragment programs use the same target-specific source contract.
/// The fixed renderer supplies only position, texture coordinates, and tint.
pub const MaterialStages = struct {
    vertex: ShaderSourceBundle,
    fragment: ShaderSourceBundle,

    pub fn validate(self: MaterialStages) !void {
        try self.vertex.validate();
        try self.fragment.validate();
    }
};

pub const GpuParticleInstance = extern struct {
    x: f32,
    y: f32,
    size: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const Renderer2D = struct {
    pub const MaterialSprite = struct {
        material: *const Material,
        image: *const Image,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        tint: Color = Color.white,
        uniforms: []const u8 = &.{},
    };

    pub const PostPass = struct {
        material: *const Material,
        uniforms: []const u8 = &.{},
    };

    allocator: std.mem.Allocator,
    material_sprites: std.ArrayListUnmanaged(MaterialSprite) = .{},
    particle_instances: std.ArrayListUnmanaged(GpuParticleInstance) = .{},
    post_passes: std.ArrayListUnmanaged(PostPass) = .{},

    pub fn init(allocator: std.mem.Allocator) Renderer2D {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer2D) void {
        self.material_sprites.deinit(self.allocator);
        self.particle_instances.deinit(self.allocator);
        self.post_passes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginFrame(self: *Renderer2D) void {
        self.material_sprites.clearRetainingCapacity();
        self.particle_instances.clearRetainingCapacity();
        self.post_passes.clearRetainingCapacity();
    }

    pub fn drawMaterialSprite(self: *Renderer2D, draw: MaterialSprite) !void {
        if (draw.width <= 0 or draw.height <= 0) return error.InvalidMaterialDraw;
        if (draw.uniforms.len > max_shader_source_bytes) return error.MaterialUniformsTooLarge;
        try draw.material.sources.validate();
        try self.material_sprites.append(self.allocator, draw);
    }

    pub fn addPostPass(self: *Renderer2D, pass: PostPass) !void {
        if (pass.uniforms.len > max_shader_source_bytes) return error.MaterialUniformsTooLarge;
        try pass.material.sources.validate();
        try self.post_passes.append(self.allocator, pass);
    }

    pub fn appendParticle(self: *Renderer2D, particle: GpuParticleInstance) !void {
        try self.particle_instances.append(self.allocator, particle);
    }
};

pub const MaterialDiagnostic = struct {
    target: ShaderTarget,
    stage: enum { validation, compilation, linking },
    message: []const u8,
};

pub const CrtOptions = struct {
    scanline_strength: u8 = 32,
    vignette_strength: u8 = 24,
};

pub const PostEffect = union(enum) {
    tint: Color,
    grayscale,
    pixelate: u32,
    blur: u8,
    crt: CrtOptions,
};

pub const PostProcessChain = struct {
    allocator: std.mem.Allocator,
    effects: []PostEffect,
    scratch: []Color = &.{},

    pub fn init(allocator: std.mem.Allocator, effects: []const PostEffect) !PostProcessChain {
        for (effects) |effect| try validateEffect(effect);
        return .{ .allocator = allocator, .effects = try allocator.dupe(PostEffect, effects) };
    }

    pub fn deinit(self: *PostProcessChain) void {
        if (self.scratch.len != 0) self.allocator.free(self.scratch);
        self.allocator.free(self.effects);
        self.* = undefined;
    }

    pub fn apply(self: *PostProcessChain, canvas: *Canvas) !void {
        for (self.effects) |effect| {
            try validateEffect(effect);
            switch (effect) {
                .blur => |radius| try self.applyBlur(canvas, radius),
                else => try applyEffect(canvas, effect),
            }
        }
    }

    fn applyBlur(self: *PostProcessChain, canvas: *Canvas, radius: u8) !void {
        if (self.scratch.len != canvas.pixels.len) {
            if (self.scratch.len != 0) self.allocator.free(self.scratch);
            self.scratch = try self.allocator.alloc(Color, canvas.pixels.len);
        }
        @memcpy(self.scratch, canvas.pixels);
        blur(canvas, self.scratch, radius);
    }
};

pub const Particle = struct {
    position: Vec2,
    velocity: Vec2,
    age_seconds: f32 = 0,
    lifetime_seconds: f32,
    size: f32,
    start_color: Color,
    end_color: Color,
};

pub const ParticleInstance = struct {
    position: Vec2,
    size: f32,
    color: Color,
};

pub const ParticleEmitterConfig = struct {
    max_particles: usize = 256,
    seed: u64 = 1,
    spawn_rate: f32 = 0,
    lifetime_min_seconds: f32 = 0.5,
    lifetime_max_seconds: f32 = 1,
    speed_min: f32 = 8,
    speed_max: f32 = 24,
    size_min: f32 = 1,
    size_max: f32 = 2,
    position: Vec2 = .zero,
    direction: Vec2 = .{ .x = 0, .y = -1 },
    spread_radians: f32 = @as(f32, std.math.pi) / 4,
    gravity: Vec2 = .zero,
    start_color: Color = Color.white,
    end_color: Color = Color.transparent,
    blend: BlendMode = .alpha,
};

/// cpu simulation is authoritative. Backends may consume particleInstances as
/// one instanced sprite draw, while headless rendering uses draw for the same state.
pub const ParticleSystem = struct {
    allocator: std.mem.Allocator,
    config: ParticleEmitterConfig,
    particles: std.ArrayListUnmanaged(Particle) = .{},
    spawn_remainder: f32 = 0,
    random_state: u64,

    pub fn init(allocator: std.mem.Allocator, config: ParticleEmitterConfig) !ParticleSystem {
        try validateEmitterConfig(config);
        var system = ParticleSystem{ .allocator = allocator, .config = config, .random_state = if (config.seed == 0) 1 else config.seed };
        errdefer system.particles.deinit(allocator);
        try system.particles.ensureTotalCapacity(allocator, config.max_particles);
        return system;
    }

    pub fn deinit(self: *ParticleSystem) void {
        self.particles.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn activeCount(self: ParticleSystem) usize {
        return self.particles.items.len;
    }

    pub fn emit(self: *ParticleSystem, requested: usize) !usize {
        const available = self.config.max_particles - self.particles.items.len;
        const count = @min(requested, available);
        try self.particles.ensureUnusedCapacity(self.allocator, count);
        var index: usize = 0;
        while (index < count) : (index += 1) self.particles.appendAssumeCapacity(self.nextParticle());
        return count;
    }

    pub fn update(self: *ParticleSystem, elapsed_seconds: f32) !void {
        if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds < 0) return error.InvalidParticleDelta;
        if (elapsed_seconds == 0) return;
        if (self.config.spawn_rate > 0) {
            self.spawn_remainder += self.config.spawn_rate * elapsed_seconds;
            const requested: usize = @intFromFloat(@floor(self.spawn_remainder));
            self.spawn_remainder -= @as(f32, @floatFromInt(requested));
            _ = try self.emit(requested);
        }
        var index: usize = 0;
        while (index < self.particles.items.len) {
            var particle = &self.particles.items[index];
            particle.age_seconds += elapsed_seconds;
            if (particle.age_seconds >= particle.lifetime_seconds) {
                _ = self.particles.swapRemove(index);
                continue;
            }
            particle.velocity = particle.velocity.add(self.config.gravity.scale(elapsed_seconds));
            particle.position = particle.position.add(particle.velocity.scale(elapsed_seconds));
            index += 1;
        }
    }

    pub fn particleInstances(self: *const ParticleSystem, destination: []ParticleInstance) usize {
        const count = @min(destination.len, self.particles.items.len);
        for (self.particles.items[0..count], 0..) |particle, index| {
            destination[index] = .{
                .position = particle.position,
                .size = particle.size,
                .color = interpolateColor(particle.start_color, particle.end_color, particle.age_seconds / particle.lifetime_seconds),
            };
        }
        return count;
    }

    pub fn submit(self: *const ParticleSystem, renderer: *Renderer2D) !void {
        try renderer.particle_instances.ensureUnusedCapacity(renderer.allocator, self.particles.items.len);
        for (self.particles.items) |particle| {
            const color = interpolateColor(particle.start_color, particle.end_color, particle.age_seconds / particle.lifetime_seconds);
            renderer.particle_instances.appendAssumeCapacity(.{
                .x = particle.position.x,
                .y = particle.position.y,
                .size = particle.size,
                .r = @as(f32, @floatFromInt(color.r)) / 255,
                .g = @as(f32, @floatFromInt(color.g)) / 255,
                .b = @as(f32, @floatFromInt(color.b)) / 255,
                .a = @as(f32, @floatFromInt(color.a)) / 255,
            });
        }
    }

    pub fn draw(self: *const ParticleSystem, canvas: *Canvas) void {
        const previous_blend = canvas.setBlend(self.config.blend);
        defer canvas.blend = previous_blend;
        for (self.particles.items) |particle| {
            const size = @max(@as(i32, 1), @as(i32, @intFromFloat(@round(particle.size))));
            const color = interpolateColor(particle.start_color, particle.end_color, particle.age_seconds / particle.lifetime_seconds);
            canvas.fillRect(@as(i32, @intFromFloat(@round(particle.position.x))) - @divTrunc(size, 2), @as(i32, @intFromFloat(@round(particle.position.y))) - @divTrunc(size, 2), size, size, color);
        }
    }

    fn nextParticle(self: *ParticleSystem) Particle {
        const unit_direction = self.config.direction.normalized();
        const base_angle = std.math.atan2(unit_direction.y, unit_direction.x);
        const angle = base_angle + (self.randomUnit() * 2 - 1) * self.config.spread_radians;
        const speed = interpolate(self.config.speed_min, self.config.speed_max, self.randomUnit());
        return .{
            .position = self.config.position,
            .velocity = .{ .x = @cos(angle) * speed, .y = @sin(angle) * speed },
            .lifetime_seconds = interpolate(self.config.lifetime_min_seconds, self.config.lifetime_max_seconds, self.randomUnit()),
            .size = interpolate(self.config.size_min, self.config.size_max, self.randomUnit()),
            .start_color = self.config.start_color,
            .end_color = self.config.end_color,
        };
    }

    fn randomUnit(self: *ParticleSystem) f32 {
        self.random_state ^= self.random_state << 13;
        self.random_state ^= self.random_state >> 7;
        self.random_state ^= self.random_state << 17;
        const value: u32 = @truncate(self.random_state >> 32);
        return @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
    }
};

fn validBindingName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value, 0..) |byte, index| {
        if ((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_' or (index != 0 and byte >= '0' and byte <= '9')) continue;
        return false;
    }
    return true;
}

fn validateEffect(effect: PostEffect) !void {
    switch (effect) {
        .pixelate => |size| if (size == 0) return error.InvalidPixelationSize,
        .blur => |radius| if (radius == 0 or radius > 32) return error.InvalidBlurRadius,
        .crt => |options| if (options.scanline_strength > 255 or options.vignette_strength > 255) return error.InvalidCrtOptions,
        else => {},
    }
}

fn validateEmitterConfig(config: ParticleEmitterConfig) !void {
    if (config.max_particles == 0 or config.max_particles > max_particles) return error.InvalidParticleCapacity;
    if (!std.math.isFinite(config.spawn_rate) or config.spawn_rate < 0) return error.InvalidParticleSpawnRate;
    inline for ([_]f32{ config.lifetime_min_seconds, config.lifetime_max_seconds, config.speed_min, config.speed_max, config.size_min, config.size_max, config.spread_radians }) |value| if (!std.math.isFinite(value)) return error.InvalidParticleConfig;
    if (config.lifetime_min_seconds <= 0 or config.lifetime_max_seconds < config.lifetime_min_seconds or config.speed_min < 0 or config.speed_max < config.speed_min or config.size_min <= 0 or config.size_max < config.size_min or config.spread_radians < 0) return error.InvalidParticleConfig;
    if (config.direction.lenSq() == 0) return error.InvalidParticleDirection;
}

fn applyEffect(canvas: *Canvas, effect: PostEffect) !void {
    try validateEffect(effect);
    switch (effect) {
        .tint => |color| {
            for (canvas.pixels) |*pixel| pixel.* = multiplyColor(pixel.*, color);
        },
        .grayscale => {
            for (canvas.pixels) |*pixel| pixel.* = grayscale(pixel.*);
        },
        .pixelate => |size| pixelate(canvas, size),
        .blur => return error.PostProcessScratchUnavailable,
        .crt => |options| crt(canvas, options),
    }
}

fn pixelate(canvas: *Canvas, size: u32) void {
    var y: u32 = 0;
    while (y < canvas.height) : (y += size) {
        var x: u32 = 0;
        while (x < canvas.width) : (x += size) {
            const color = canvas.pixels[@as(usize, y) * canvas.width + x];
            const end_y = @min(canvas.height, y + size);
            const end_x = @min(canvas.width, x + size);
            var py = y;
            while (py < end_y) : (py += 1) {
                var px = x;
                while (px < end_x) : (px += 1) canvas.pixels[@as(usize, py) * canvas.width + px] = color;
            }
        }
    }
}

fn blur(canvas: *Canvas, scratch: []const Color, radius: u8) void {
    const r: i32 = radius;
    var y: i32 = 0;
    while (y < @as(i32, @intCast(canvas.height))) : (y += 1) {
        var x: i32 = 0;
        while (x < @as(i32, @intCast(canvas.width))) : (x += 1) {
            var red: u64 = 0;
            var green: u64 = 0;
            var blue: u64 = 0;
            var alpha: u64 = 0;
            var count: u64 = 0;
            var sample_y = @max(0, y - r);
            while (sample_y <= @min(@as(i32, @intCast(canvas.height)) - 1, y + r)) : (sample_y += 1) {
                var sample_x = @max(0, x - r);
                while (sample_x <= @min(@as(i32, @intCast(canvas.width)) - 1, x + r)) : (sample_x += 1) {
                    const pixel = scratch[@as(usize, @intCast(sample_y)) * canvas.width + @as(usize, @intCast(sample_x))];
                    red += pixel.r;
                    green += pixel.g;
                    blue += pixel.b;
                    alpha += pixel.a;
                    count += 1;
                }
            }
            canvas.pixels[@as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x))] = .{ .r = @intCast(red / count), .g = @intCast(green / count), .b = @intCast(blue / count), .a = @intCast(alpha / count) };
        }
    }
}

fn crt(canvas: *Canvas, options: CrtOptions) void {
    const half_width = @as(f32, @floatFromInt(canvas.width)) / 2;
    const half_height = @as(f32, @floatFromInt(canvas.height)) / 2;
    for (canvas.pixels, 0..) |*pixel, index| {
        const x = @as(f32, @floatFromInt(index % canvas.width));
        const y = @as(f32, @floatFromInt(index / canvas.width));
        const distance = @min(1, @max(@abs(x - half_width) / @max(half_width, 1), @abs(y - half_height) / @max(half_height, 1)));
        const scanline = if (@as(u32, @intCast(index / canvas.width)) % 2 == 0) @as(u16, 255) - options.scanline_strength else 255;
        const vignette = @as(u16, 255) - @as(u16, @intFromFloat(distance * @as(f32, @floatFromInt(options.vignette_strength))));
        const gain = scanline * vignette / 255;
        pixel.* = .{ .r = @intCast(@as(u16, pixel.r) * gain / 255), .g = @intCast(@as(u16, pixel.g) * gain / 255), .b = @intCast(@as(u16, pixel.b) * gain / 255), .a = pixel.a };
    }
}

fn multiplyColor(value: Color, tint: Color) Color {
    return .{ .r = @intCast(@as(u16, value.r) * tint.r / 255), .g = @intCast(@as(u16, value.g) * tint.g / 255), .b = @intCast(@as(u16, value.b) * tint.b / 255), .a = @intCast(@as(u16, value.a) * tint.a / 255) };
}

fn grayscale(value: Color) Color {
    const luminance: u16 = (@as(u16, value.r) * 54 + @as(u16, value.g) * 183 + @as(u16, value.b) * 19) / 256;
    return .{ .r = @intCast(luminance), .g = @intCast(luminance), .b = @intCast(luminance), .a = value.a };
}

fn interpolate(from: f32, to: f32, amount: f32) f32 {
    return from + (to - from) * std.math.clamp(amount, 0, 1);
}

fn interpolateColor(from: Color, to: Color, amount: f32) Color {
    const t = std.math.clamp(amount, 0, 1);
    return .{ .r = @intFromFloat(@round(interpolate(@floatFromInt(from.r), @floatFromInt(to.r), t))), .g = @intFromFloat(@round(interpolate(@floatFromInt(from.g), @floatFromInt(to.g), t))), .b = @intFromFloat(@round(interpolate(@floatFromInt(from.b), @floatFromInt(to.b), t))), .a = @intFromFloat(@round(interpolate(@floatFromInt(from.a), @floatFromInt(to.a), t))) };
}

test "shader bundles require every portable source and a consistent manifest" {
    const valid = ShaderSourceBundle{ .native_hlsl = "float4 main() : SV_Target { return 0; }", .webgl2_glsl_es = "void main() {}", .webgpu_wgsl = "@fragment fn main() {}", .bindings = &.{ .{ .name = "source_texture", .kind = .texture }, .{ .name = "settings", .kind = .uniform } } };
    try valid.validate();
    try std.testing.expectEqualStrings(valid.webgpu_wgsl, valid.source(.webgpu_wgsl));
    try std.testing.expectError(error.DuplicateShaderBinding, (ShaderSourceBundle{ .native_hlsl = valid.native_hlsl, .webgl2_glsl_es = valid.webgl2_glsl_es, .webgpu_wgsl = valid.webgpu_wgsl, .bindings = &.{ .{ .name = "same", .kind = .texture }, .{ .name = "same", .kind = .uniform } } }).validate());
    try std.testing.expectError(error.MissingShaderSource, (ShaderSourceBundle{ .native_hlsl = "", .webgl2_glsl_es = valid.webgl2_glsl_es, .webgpu_wgsl = valid.webgpu_wgsl }).validate());
}

test "post process chain has deterministic CPU reference output" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 2);
    defer canvas.deinit();
    canvas.pixels[0] = Color.rgb(255, 0, 0);
    canvas.pixels[1] = Color.rgb(0, 255, 0);
    var chain = try PostProcessChain.init(std.testing.allocator, &.{ .grayscale, .{ .tint = Color.rgba(255, 128, 128, 255) } });
    defer chain.deinit();
    try chain.apply(&canvas);
    try std.testing.expect(canvas.pixels[0].r > canvas.pixels[0].g);
    try std.testing.expectEqual(canvas.pixels[0].g, canvas.pixels[0].b);
    try std.testing.expectError(error.InvalidBlurRadius, PostProcessChain.init(std.testing.allocator, &.{.{ .blur = 0 }}));
}

test "post process blur reuses its frame scratch allocation" {
    var canvas = try Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    canvas.clear(Color.white);
    var chain = try PostProcessChain.init(std.testing.allocator, &.{.{ .blur = 1 }});
    defer chain.deinit();
    try chain.apply(&canvas);
    const first = chain.scratch.ptr;
    try chain.apply(&canvas);
    try std.testing.expect(first == chain.scratch.ptr);
}

test "advanced frame storage is retained after setup" {
    const config = ParticleEmitterConfig{ .seed = 7, .max_particles = 8, .spawn_rate = 8, .lifetime_min_seconds = 2, .lifetime_max_seconds = 2, .speed_min = 1, .speed_max = 1, .size_min = 1, .size_max = 1 };
    var particles = try ParticleSystem.init(std.testing.allocator, config);
    defer particles.deinit();
    try std.testing.expect(particles.particles.capacity >= config.max_particles);
    const particle_capacity = particles.particles.capacity;

    var canvas = try Canvas.init(std.testing.allocator, 8, 8);
    defer canvas.deinit();
    var chain = try PostProcessChain.init(std.testing.allocator, &.{.{ .blur = 1 }});
    defer chain.deinit();
    try chain.apply(&canvas);
    const scratch = chain.scratch.ptr;

    try particles.update(1.0);
    particles.draw(&canvas);
    try chain.apply(&canvas);
    try std.testing.expectEqual(particle_capacity, particles.particles.capacity);
    try std.testing.expect(scratch == chain.scratch.ptr);
}

test "particle simulation is deterministic and produces portable instances" {
    const config = ParticleEmitterConfig{ .seed = 99, .max_particles = 8, .spawn_rate = 4, .lifetime_min_seconds = 1, .lifetime_max_seconds = 1, .speed_min = 2, .speed_max = 2, .size_min = 2, .size_max = 2, .position = .{ .x = 8, .y = 8 } };
    var first = try ParticleSystem.init(std.testing.allocator, config);
    defer first.deinit();
    var second = try ParticleSystem.init(std.testing.allocator, config);
    defer second.deinit();
    try first.update(0.5);
    try second.update(0.5);
    try std.testing.expectEqual(first.activeCount(), second.activeCount());
    try std.testing.expectEqual(first.particles.items[0], second.particles.items[0]);
    var instances: [4]ParticleInstance = undefined;
    try std.testing.expectEqual(@as(usize, 2), first.particleInstances(&instances));
    var canvas = try Canvas.init(std.testing.allocator, 16, 16);
    defer canvas.deinit();
    first.draw(&canvas);
    var visible: usize = 0;
    for (canvas.pixels) |pixel| {
        if (pixel.a != 0) visible += 1;
    }
    try std.testing.expect(visible != 0);
}

test "renderer queue retains GPU particle instance storage" {
    var renderer = Renderer2D.init(std.testing.allocator);
    defer renderer.deinit();
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .max_particles = 4, .lifetime_min_seconds = 1, .lifetime_max_seconds = 1, .speed_min = 1, .speed_max = 1, .size_min = 1, .size_max = 1 });
    defer particles.deinit();
    _ = try particles.emit(2);
    try particles.submit(&renderer);
    try std.testing.expectEqual(@as(usize, 2), renderer.particle_instances.items.len);
    const capacity = renderer.particle_instances.capacity;
    renderer.beginFrame();
    try particles.submit(&renderer);
    try std.testing.expectEqual(capacity, renderer.particle_instances.capacity);
}
