const std = @import("std");
const Vec2 = @import("math.zig").Vec2;
const Rect = @import("math.zig").Rect;

pub const Sampling = enum { nearest, bilinear };

pub const PixelSnap = enum { off, nearest };

pub const CameraViewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32,
    h: f32,

    pub fn full(size: Vec2) CameraViewport {
        return .{ .w = size.x, .h = size.y };
    }

    pub fn rect(self: CameraViewport) Rect {
        return .init(self.x, self.y, self.w, self.h);
    }
};

pub const CameraBounds = struct {
    rect: Rect,

    pub fn contains(self: CameraBounds, point: Vec2) bool {
        return self.rect.contains(point);
    }
};

pub const CameraFollow = struct {
    target: ?Vec2 = null,
    dead_zone: ?Rect = null,
    look_ahead: Vec2 = .{},
    spring: f32 = 12,
};

pub const CameraShake = struct {
    amplitude: Vec2 = .{},
    frequency: f32 = 20,
    duration: f32 = 0,
    elapsed: f32 = 0,
    seed: u64 = 0,

    pub fn active(self: CameraShake) bool {
        return self.elapsed < self.duration and (self.amplitude.x != 0 or self.amplitude.y != 0);
    }
};

pub const Camera2D = struct {
    position: Vec2 = .{},
    zoom: f32 = 1,
    rotation: f32 = 0,
    min_zoom: f32 = 0.05,
    max_zoom: f32 = 64,
    viewport: ?CameraViewport = null,
    bounds: ?CameraBounds = null,
    sampling: Sampling = .nearest,
    pixel_snap: PixelSnap = .nearest,
    follow: CameraFollow = .{},
    shake: CameraShake = .{},

    pub fn setZoom(self: *Camera2D, value: f32) void {
        self.zoom = @max(self.min_zoom, @min(self.max_zoom, value));
    }

    pub fn zoomBy(self: *Camera2D, delta: f32) void {
        self.setZoom(self.zoom + delta);
    }

    pub fn setBounds(self: *Camera2D, bounds: ?CameraBounds, canvas_size: Vec2) void {
        self.bounds = bounds;
        self.clampToBounds(canvas_size);
    }

    pub fn setFollowTarget(self: *Camera2D, target: ?Vec2) void {
        self.follow.target = target;
    }

    pub fn startShake(self: *Camera2D, amplitude: Vec2, frequency: f32, duration: f32, seed: u64) void {
        self.shake = .{
            .amplitude = amplitude,
            .frequency = @max(0, frequency),
            .duration = @max(0, duration),
            .seed = seed,
        };
    }

    pub fn update(self: *Camera2D, dt: f32, canvas_size: Vec2) void {
        if (self.follow.target) |target| {
            var desired = target.add(self.follow.look_ahead);
            if (self.follow.dead_zone) |zone| {
                const screen = self.worldToCanvasUnsnapped(target, canvas_size);
                var delta = Vec2{};
                if (screen.x < zone.x) delta.x = screen.x - zone.x;
                if (screen.x > zone.x + zone.w) delta.x = screen.x - (zone.x + zone.w);
                if (screen.y < zone.y) delta.y = screen.y - zone.y;
                if (screen.y > zone.y + zone.h) delta.y = screen.y - (zone.y + zone.h);
                desired = self.position.add(rotate(delta.scale(1 / self.zoom), self.rotation));
            }
            const t = if (self.follow.spring <= 0) 1 else 1 - std.math.exp(-self.follow.spring * @max(0, dt));
            self.position = lerp(self.position, desired, t);
        }
        self.shake.elapsed = @min(self.shake.duration, self.shake.elapsed + @max(0, dt));
        self.clampToBounds(canvas_size);
    }

    pub fn canvasViewport(self: Camera2D, canvas_size: Vec2) CameraViewport {
        return self.viewport orelse CameraViewport.full(canvas_size);
    }

    pub fn worldToCanvas(self: Camera2D, point: Vec2, canvas_size: Vec2) Vec2 {
        const value = self.worldToCanvasUnsnapped(point, canvas_size);
        return switch (self.pixel_snap) {
            .off => value,
            .nearest => .{ .x = @round(value.x), .y = @round(value.y) },
        };
    }

    pub fn canvasToWorld(self: Camera2D, point: Vec2, canvas_size: Vec2) Vec2 {
        const viewport = self.canvasViewport(canvas_size);
        const local = point.sub(.{ .x = viewport.x + viewport.w / 2 + self.shakeOffset().x, .y = viewport.y + viewport.h / 2 + self.shakeOffset().y }).scale(1 / self.zoom);
        return self.position.add(rotate(local, self.rotation));
    }

    pub fn worldBounds(self: Camera2D, canvas_size: Vec2) Rect {
        const viewport = self.canvasViewport(canvas_size);
        const points = [_]Vec2{
            self.canvasToWorld(.{ .x = viewport.x, .y = viewport.y }, canvas_size),
            self.canvasToWorld(.{ .x = viewport.x + viewport.w, .y = viewport.y }, canvas_size),
            self.canvasToWorld(.{ .x = viewport.x, .y = viewport.y + viewport.h }, canvas_size),
            self.canvasToWorld(.{ .x = viewport.x + viewport.w, .y = viewport.y + viewport.h }, canvas_size),
        };
        var min = points[0];
        var max = points[0];
        for (points[1..]) |point| {
            min.x = @min(min.x, point.x);
            min.y = @min(min.y, point.y);
            max.x = @max(max.x, point.x);
            max.y = @max(max.y, point.y);
        }
        return .init(min.x, min.y, max.x - min.x, max.y - min.y);
    }

    pub fn isVisiblePoint(self: Camera2D, point: Vec2, canvas_size: Vec2) bool {
        return self.canvasViewport(canvas_size).rect().contains(self.worldToCanvasUnsnapped(point, canvas_size));
    }

    pub fn isVisibleRect(self: Camera2D, rect: Rect, canvas_size: Vec2) bool {
        return self.worldBounds(canvas_size).intersects(rect);
    }

    pub fn parallax(self: Camera2D, factor: Vec2) Camera2D {
        var result = self;
        result.position = .{ .x = self.position.x * factor.x, .y = self.position.y * factor.y };
        return result;
    }

    fn worldToCanvasUnsnapped(self: Camera2D, point: Vec2, canvas_size: Vec2) Vec2 {
        const viewport = self.canvasViewport(canvas_size);
        const local = rotate(point.sub(self.position), -self.rotation).scale(self.zoom);
        return .{
            .x = viewport.x + viewport.w / 2 + local.x + self.shakeOffset().x,
            .y = viewport.y + viewport.h / 2 + local.y + self.shakeOffset().y,
        };
    }

    fn clampToBounds(self: *Camera2D, canvas_size: Vec2) void {
        const bounds = self.bounds orelse return;
        const view = self.worldBounds(canvas_size);
        const half = Vec2.init(view.w / 2, view.h / 2);
        if (bounds.rect.w <= view.w) {
            self.position.x = bounds.rect.x + bounds.rect.w / 2;
        } else {
            self.position.x = @max(bounds.rect.x + half.x, @min(bounds.rect.x + bounds.rect.w - half.x, self.position.x));
        }
        if (bounds.rect.h <= view.h) {
            self.position.y = bounds.rect.y + bounds.rect.h / 2;
        } else {
            self.position.y = @max(bounds.rect.y + half.y, @min(bounds.rect.y + bounds.rect.h - half.y, self.position.y));
        }
    }

    fn shakeOffset(self: Camera2D) Vec2 {
        if (!self.shake.active()) return .{};
        const decay = 1 - self.shake.elapsed / self.shake.duration;
        const phase = self.shake.elapsed * self.shake.frequency;
        const sx = @sin(phase * 12.9898 + @as(f32, @floatFromInt(self.shake.seed & 0xffff)));
        const sy = @sin(phase * 78.233 + @as(f32, @floatFromInt((self.shake.seed >> 16) & 0xffff)));
        return .{ .x = sx * self.shake.amplitude.x * decay, .y = sy * self.shake.amplitude.y * decay };
    }
};

pub const CameraHandle = struct { // borrows a CameraRig slot; tryGet/tryRemove return error.StaleCamera after removal.
    index: u32,
    generation: u32,
};

const CameraSlot = struct {
    generation: u32 = 1,
    active: bool = false,
    camera: Camera2D = .{},
};

pub const CameraRig = struct { // owns camera slots allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(CameraSlot) = .{},

    pub fn init(allocator: std.mem.Allocator) CameraRig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CameraRig) void {
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *CameraRig, camera: Camera2D) !CameraHandle {
        for (self.slots.items, 0..) |*slot, index| {
            if (slot.active) continue;
            slot.active = true;
            slot.camera = camera;
            return .{ .index = @intCast(index), .generation = slot.generation };
        }
        try self.slots.append(self.allocator, .{ .active = true, .camera = camera });
        return .{ .index = @intCast(self.slots.items.len - 1), .generation = 1 };
    }

    pub fn tryRemove(self: *CameraRig, handle: CameraHandle) !void {
        const slot = try self.tryResolve(handle);
        slot.active = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    pub fn remove(self: *CameraRig, handle: CameraHandle) bool { // compatibility helper; false means error.StaleCamera.
        self.tryRemove(handle) catch return false;
        return true;
    }

    pub fn tryGet(self: *CameraRig, handle: CameraHandle) !*Camera2D {
        return &(try self.tryResolve(handle)).camera;
    }

    pub fn get(self: *CameraRig, handle: CameraHandle) ?*Camera2D { // compatibility helper; null means error.StaleCamera.
        return self.tryGet(handle) catch null;
    }

    pub fn tryGetConst(self: *const CameraRig, handle: CameraHandle) !*const Camera2D {
        if (handle.index >= self.slots.items.len) return error.StaleCamera;
        const slot = &self.slots.items[handle.index];
        if (!slot.active or slot.generation != handle.generation) return error.StaleCamera;
        return &slot.camera;
    }

    pub fn getConst(self: *const CameraRig, handle: CameraHandle) ?*const Camera2D { // compatibility helper; null means error.StaleCamera.
        return self.tryGetConst(handle) catch null;
    }

    pub fn update(self: *CameraRig, dt: f32, canvas_size: Vec2) void {
        for (self.slots.items) |*slot| if (slot.active) slot.camera.update(dt, canvas_size);
    }

    pub fn activeIterator(self: *CameraRig) ActiveIterator {
        return .{ .rig = self };
    }

    fn resolve(self: *CameraRig, handle: CameraHandle) ?*CameraSlot {
        if (handle.index >= self.slots.items.len) return null;
        const slot = &self.slots.items[handle.index];
        if (!slot.active or slot.generation != handle.generation) return null;
        return slot;
    }

    fn tryResolve(self: *CameraRig, handle: CameraHandle) !*CameraSlot {
        return self.resolve(handle) orelse error.StaleCamera;
    }

    pub const ActiveIterator = struct {
        rig: *CameraRig,
        index: usize = 0,

        pub fn next(self: *ActiveIterator) ?CameraHandle {
            while (self.index < self.rig.slots.items.len) : (self.index += 1) {
                const index = self.index;
                const slot = &self.rig.slots.items[index];
                if (!slot.active) continue;
                self.index += 1;
                return .{ .index = @intCast(index), .generation = slot.generation };
            }
            return null;
        }
    };
};

pub const Easing = enum { linear, ease_in_out };

pub const CameraShot = struct {
    camera: CameraHandle,
    position: Vec2,
    zoom: f32,
    rotation: f32,
    duration: f32,
    easing: Easing = .ease_in_out,
    cut: bool = false,
};

const ActiveShot = struct {
    shot: CameraShot,
    start_position: Vec2 = .{},
    start_zoom: f32 = 1,
    start_rotation: f32 = 0,
    elapsed: f32 = 0,
    started: bool = false,
};

pub const CameraDirector = struct { // owns queued shots allocated by init; stale shot handles are discarded during update.
    allocator: std.mem.Allocator,
    shots: std.ArrayListUnmanaged(ActiveShot) = .{},

    pub fn init(allocator: std.mem.Allocator) CameraDirector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CameraDirector) void {
        self.shots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn play(self: *CameraDirector, shot: CameraShot) !void {
        try self.shots.append(self.allocator, .{ .shot = shot });
    }

    pub fn update(self: *CameraDirector, rig: *CameraRig, dt: f32) void {
        var index: usize = 0;
        while (index < self.shots.items.len) {
            var active = &self.shots.items[index];
            const camera = rig.get(active.shot.camera) orelse {
                _ = self.shots.orderedRemove(index);
                continue;
            };
            if (!active.started) {
                active.started = true;
                active.start_position = camera.position;
                active.start_zoom = camera.zoom;
                active.start_rotation = camera.rotation;
                if (active.shot.cut or active.shot.duration <= 0) {
                    camera.position = active.shot.position;
                    camera.setZoom(active.shot.zoom);
                    camera.rotation = active.shot.rotation;
                    _ = self.shots.orderedRemove(index);
                    continue;
                }
            }
            active.elapsed += @max(0, dt);
            const raw = @min(1, active.elapsed / active.shot.duration);
            const t = switch (active.shot.easing) {
                .linear => raw,
                .ease_in_out => raw * raw * (3 - 2 * raw),
            };
            camera.position = lerp(active.start_position, active.shot.position, t);
            camera.setZoom(active.start_zoom + (active.shot.zoom - active.start_zoom) * t);
            camera.rotation = active.start_rotation + (active.shot.rotation - active.start_rotation) * t;
            if (raw >= 1) {
                _ = self.shots.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }
};

fn rotate(value: Vec2, radians: f32) Vec2 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ .x = value.x * c - value.y * s, .y = value.x * s + value.y * c };
}

fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

test "camera transform round trip" {
    var camera = Camera2D{ .position = .{ .x = 40, .y = 24 }, .zoom = 2, .rotation = 0.4, .pixel_snap = .off };
    const canvas_size = Vec2.init(160, 90);
    const point = Vec2.init(71, 13);
    const got = camera.canvasToWorld(camera.worldToCanvas(point, canvas_size), canvas_size);
    try std.testing.expectApproxEqAbs(point.x, got.x, 0.001);
    try std.testing.expectApproxEqAbs(point.y, got.y, 0.001);
}

test "camera bounds centers undersized world" {
    var camera = Camera2D{ .position = .{ .x = 999, .y = -999 }, .bounds = .{ .rect = .init(0, 0, 20, 20) } };
    camera.update(0, Vec2.init(160, 90));
    try std.testing.expectEqual(Vec2.init(10, 10), camera.position);
}

test "camera rig rejects stale handles" {
    var rig = CameraRig.init(std.testing.allocator);
    defer rig.deinit();
    const first = try rig.create(.{});
    try std.testing.expect(rig.remove(first));
    const second = try rig.create(.{});
    try std.testing.expect(first.index == second.index);
    try std.testing.expect(rig.get(first) == null);
    try std.testing.expectError(error.StaleCamera, rig.tryGet(first));
    try std.testing.expectError(error.StaleCamera, rig.tryRemove(first));
    try std.testing.expect(rig.get(second) != null);
    _ = try rig.tryGet(second);
}

test "camera director interpolates deterministic shot" {
    var rig = CameraRig.init(std.testing.allocator);
    defer rig.deinit();
    const handle = try rig.create(.{});
    var director = CameraDirector.init(std.testing.allocator);
    defer director.deinit();
    try director.play(.{ .camera = handle, .position = .{ .x = 20, .y = 10 }, .zoom = 2, .rotation = 1, .duration = 1, .easing = .linear });
    director.update(&rig, 0.5);
    const camera = rig.get(handle).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), camera.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), camera.zoom, 0.001);
}
