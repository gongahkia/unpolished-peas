//! Bounded use of the existing texture ABI. Handles survive WebGL restoration;
//! every used source uploads its current pixels, including direct pixel writes.
const std = @import("std");
const up = @import("unpolished-peas");
const Scene = up.graphics.SurfaceCompositor;
pub fn Cache(comptime host: type) type {
    return struct {
        const Self = @This();
        owner: u64 = 0,
        handles: [Scene.max_layers + 1]u32 = .{0} ** (Scene.max_layers + 1),
        generations: [Scene.max_layers]u32 = .{0} ** Scene.max_layers,
        upload_bytes: u64 = 0,

        fn drop(self: *Self, index: usize) void {
            if (self.handles[index] != 0) host.destroyResource(.texture, self.handles[index]);
            self.handles[index] = 0;
        }
        pub fn release(self: *Self) void {
            for (0..self.handles.len) |i| self.drop(i);
            self.owner = 0;
            self.upload_bytes = 0;
        }
        pub fn submit(self: *Self, scene: *const Scene, canvas: *const up.graphics.Canvas) i32 {
            scene.validate(canvas) catch return -3;
            if (self.owner != scene.owner) {
                self.release();
                self.owner = scene.owner;
            }
            for (0..Scene.max_layers) |i| if (self.handles[i] != 0) {
                if (i >= scene.slots.len or scene.slots[i].source == null or scene.slots[i].generation != self.generations[i]) self.drop(i);
            };
            if (!scene.canvas_queued) self.drop(Scene.max_layers);
            var created = [_]bool{false} ** (Scene.max_layers + 1);
            var completed = false;
            defer if (!completed) {
                for (created, 0..) |value, i| if (value) self.drop(i);
            };
            var uploaded = [_]bool{false} ** (Scene.max_layers + 1);
            self.upload_bytes = 0;
            for (scene.commands()) |draw| {
                const index = if (draw.layer) |layer| layer.index else Scene.max_layers;
                if (uploaded[index]) continue;
                const source = if (draw.layer) |layer| &(scene.getSurface(layer) catch return -3).target else canvas;
                const bytes = std.mem.sliceAsBytes(source.pixels);
                if (bytes.len > std.math.maxInt(u32)) return -3;
                if (self.handles[index] == 0) {
                    self.handles[index] = host.createResource(.texture, @intCast(bytes.len));
                    if (self.handles[index] == 0) return -2;
                    created[index] = true;
                }
                if (draw.layer) |layer| self.generations[index] = layer.generation;
                const status = host.uploadTexture(self.handles[index], source.width, source.height, if (@import("builtin").cpu.arch == .wasm32) @intCast(@intFromPtr(bytes.ptr)) else 0, @intCast(bytes.len), 0);
                if (status != 0) return status;
                self.upload_bytes += bytes.len;
                uploaded[index] = true;
            }
            var status = host.clear(packedColor(scene.clear_color));
            if (status != 0) return status;
            status = host.setCamera(0, 0, 0, 1, 0, 0, 0, @floatFromInt(canvas.width), @floatFromInt(canvas.height));
            if (status != 0) return status;
            status = host.pushBlend(0);
            if (status != 0) return status;
            defer _ = host.popBlend();
            for (scene.commands()) |draw| {
                const index = if (draw.layer) |layer| layer.index else Scene.max_layers;
                const rect = if (draw.layer != null) draw.options.surface else up.graphics.SurfaceDrawOptions{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height };
                if (draw.options.clip) |clip| {
                    status = host.pushClip(clip.x, clip.y, clip.w, clip.h);
                    if (status != 0) return status;
                }
                status = host.drawSurface(self.handles[index], rect.x, rect.y, @intCast(rect.width), @intCast(rect.height), packedColor(rect.tint), @intFromEnum(rect.filter));
                if (draw.options.clip != null) {
                    const popped = host.popClip();
                    if (status == 0) status = popped;
                }
                if (status != 0) return status;
            }
            completed = true;
            return 0;
        }
    };
}
fn packedColor(color: up.core.Color) u32 {
    return @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24);
}
