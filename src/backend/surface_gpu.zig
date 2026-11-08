//! Private, bounded SDL GPU cache. The surface fragment shader matches Canvas
//! nearest sampling; mutable surfaces never enter the immutable Image cache.
const std = @import("std");
const up = @import("api.zig");
const Scene = up.SurfaceCompositor;

pub fn Cache(comptime c: type) type {
    return struct {
        const Self = @This();
        const Texture = struct {
            texture: *c.SDL_GPUTexture,
            transfer: *c.SDL_GPUTransferBuffer,
            generation: u32,
            width: u32,
            height: u32,
        };
        owner: u64 = 0,
        textures: [Scene.max_layers]?Texture = .{null} ** Scene.max_layers,
        vertices: ?*c.SDL_GPUBuffer = null,
        transfer: ?*c.SDL_GPUTransferBuffer = null,
        vertex_capacity: u32 = 0,
        upload_bytes: u64 = 0,
        /// Used only by the native conformance test to exercise real rollback.
        fail_after: ?usize = null,

        fn checkpoint(self: *Self) !void {
            if (self.fail_after) |remaining| {
                if (remaining == 0) return error.InjectedCompositionAllocationFailure;
                self.fail_after = remaining - 1;
            }
        }
        fn drop(self: *Self, device: *c.SDL_GPUDevice, index: usize) void {
            if (self.textures[index]) |texture| {
                c.SDL_ReleaseGPUTransferBuffer(device, texture.transfer);
                c.SDL_ReleaseGPUTexture(device, texture.texture);
                self.textures[index] = null;
            }
        }
        pub fn releaseAll(self: *Self, device: *c.SDL_GPUDevice) void {
            for (0..self.textures.len) |i| self.drop(device, i);
            if (self.vertices) |value| c.SDL_ReleaseGPUBuffer(device, value);
            if (self.transfer) |value| c.SDL_ReleaseGPUTransferBuffer(device, value);
            self.vertices = null;
            self.transfer = null;
            self.vertex_capacity = 0;
            self.owner = 0;
            self.upload_bytes = 0;
        }
        pub fn count(self: *const Self) u32 {
            var result: u32 = 0;
            for (self.textures) |value| if (value != null) {
                result += 1;
            };
            return result;
        }
        pub fn bytes(self: *const Self) u64 {
            var result: u64 = 0;
            for (self.textures) |value| if (value) |texture| {
                result += @as(u64, texture.width) * texture.height * 4;
            };
            return result;
        }
        pub fn prepare(self: *Self, device: *c.SDL_GPUDevice, scene: *const Scene) !void {
            if (self.owner != scene.owner) {
                self.releaseAll(device);
                self.owner = scene.owner;
            }
            var created = [_]bool{false} ** Scene.max_layers;
            errdefer for (created, 0..) |value, i| {
                if (value) self.drop(device, i);
            };
            for (0..self.textures.len) |i| if (self.textures[i]) |texture| {
                if (i >= scene.slots.len or scene.slots[i].source == null or scene.slots[i].generation != texture.generation) self.drop(device, i);
            };
            for (scene.commands()) |draw| if (draw.layer) |layer| {
                if (self.textures[layer.index] != null) continue;
                const source = try scene.getSurface(layer);
                try self.checkpoint();
                const texture = c.SDL_CreateGPUTexture(device, &.{ .type = c.SDL_GPU_TEXTURETYPE_2D, .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER, .width = source.width(), .height = source.height(), .layer_count_or_depth = 1, .num_levels = 1, .sample_count = c.SDL_GPU_SAMPLECOUNT_1, .props = 0 }) orelse return error.CompositionTextureCreationFailed;
                errdefer c.SDL_ReleaseGPUTexture(device, texture);
                try self.checkpoint();
                const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = source.width() * source.height() * 4, .props = 0 }) orelse return error.CompositionTransferCreationFailed;
                self.textures[layer.index] = .{ .texture = texture, .transfer = transfer, .generation = layer.generation, .width = source.width(), .height = source.height() };
                created[layer.index] = true;
            };
            const needed: u32 = @intCast(scene.draws.len * 6 * @sizeOf(up.SpriteBatchVertex));
            if (self.vertex_capacity < needed) {
                try self.checkpoint();
                const vertices = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX, .size = needed, .props = 0 }) orelse return error.CompositionVertexCreationFailed;
                errdefer c.SDL_ReleaseGPUBuffer(device, vertices);
                try self.checkpoint();
                const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = needed, .props = 0 }) orelse return error.CompositionVertexTransferFailed;
                if (self.vertices) |old| c.SDL_ReleaseGPUBuffer(device, old);
                if (self.transfer) |old| c.SDL_ReleaseGPUTransferBuffer(device, old);
                self.vertices = vertices;
                self.transfer = transfer;
                self.vertex_capacity = needed;
            }
        }
        pub fn upload(self: *Self, device: *c.SDL_GPUDevice, pass: *c.SDL_GPUCopyPass, scene: *const Scene, width: u32, height: u32) !void {
            var uploaded = [_]bool{false} ** Scene.max_layers;
            self.upload_bytes = 0;
            for (scene.commands()) |draw| if (draw.layer) |layer| {
                if (uploaded[layer.index]) continue;
                const source = try scene.getSurface(layer);
                const texture = self.textures[layer.index].?;
                const pixels = std.mem.sliceAsBytes(source.target.pixels);
                const mapped = c.SDL_MapGPUTransferBuffer(device, texture.transfer, true) orelse return error.CompositionTransferMapFailed;
                const destination: [*]u8 = @ptrCast(mapped);
                @memcpy(destination[0..pixels.len], pixels);
                c.SDL_UnmapGPUTransferBuffer(device, texture.transfer);
                c.SDL_UploadToGPUTexture(pass, &.{ .transfer_buffer = texture.transfer, .offset = 0, .pixels_per_row = texture.width, .rows_per_layer = texture.height }, &.{ .texture = texture.texture, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = texture.width, .h = texture.height, .d = 1 }, true);
                self.upload_bytes += pixels.len;
                uploaded[layer.index] = true;
            };
            var quads: [Scene.max_draws * 6]up.SpriteBatchVertex = undefined;
            for (scene.commands(), 0..) |draw, i| {
                const rect = if (draw.layer != null) draw.options.surface else @import("unpolished-peas").graphics.SurfaceDrawOptions{ .x = 0, .y = 0, .width = width, .height = height };
                @memcpy(quads[i * 6 ..][0..6], &quad(width, height, rect));
            }
            const bytes_slice = std.mem.sliceAsBytes(quads[0 .. scene.count * 6]);
            if (bytes_slice.len == 0) return;
            const mapped = c.SDL_MapGPUTransferBuffer(device, self.transfer.?, true) orelse return error.CompositionVertexMapFailed;
            const destination: [*]u8 = @ptrCast(mapped);
            @memcpy(destination[0..bytes_slice.len], bytes_slice);
            c.SDL_UnmapGPUTransferBuffer(device, self.transfer.?);
            c.SDL_UploadToGPUBuffer(pass, &.{ .transfer_buffer = self.transfer.?, .offset = 0 }, &.{ .buffer = self.vertices.?, .offset = 0, .size = @intCast(bytes_slice.len) }, true);
        }
        pub fn render(self: *Self, command: *c.SDL_GPUCommandBuffer, scene: *const Scene, canvas_texture: *c.SDL_GPUTexture, target: c.SDL_GPUColorTargetInfo, pipeline: *c.SDL_GPUGraphicsPipeline, nearest: *c.SDL_GPUSampler, linear: *c.SDL_GPUSampler, width: u32, height: u32) !void {
            const pass = c.SDL_BeginGPURenderPass(command, &target, 1, null) orelse return error.CompositionRenderPassFailed;
            defer c.SDL_EndGPURenderPass(pass);
            c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
            for (scene.commands(), 0..) |draw, index| {
                const rect = if (draw.layer != null) draw.options.surface else @import("unpolished-peas").graphics.SurfaceDrawOptions{ .x = 0, .y = 0, .width = width, .height = height };
                const parameters = extern struct { rectangle: [4]i32, sampling: [4]u32 }{
                    .rectangle = .{ rect.x, rect.y, @intCast(rect.width), @intCast(rect.height) },
                    .sampling = .{ @intFromEnum(rect.filter), 0, 0, 0 },
                };
                c.SDL_PushGPUFragmentUniformData(command, 0, &parameters, @sizeOf(@TypeOf(parameters)));
                const texture = if (draw.layer) |layer| self.textures[layer.index].?.texture else canvas_texture;
                const sampler = if (draw.options.surface.filter == .linear) linear else nearest;
                const binding = c.SDL_GPUTextureSamplerBinding{ .texture = texture, .sampler = sampler };
                c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
                const clip = scissor(c, draw.options.clip, width, height);
                c.SDL_SetGPUScissor(pass, &clip);
                const buffer = c.SDL_GPUBufferBinding{ .buffer = self.vertices.?, .offset = @intCast(index * 6 * @sizeOf(up.SpriteBatchVertex)) };
                c.SDL_BindGPUVertexBuffers(pass, 0, &buffer, 1);
                c.SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
            }
        }
    };
}
fn quad(width: u32, height: u32, rect: @import("unpolished-peas").graphics.SurfaceDrawOptions) [6]up.SpriteBatchVertex {
    const x0 = @as(f32, @floatFromInt(rect.x)) * 2 / @as(f32, @floatFromInt(width)) - 1;
    const x1 = @as(f32, @floatFromInt(@as(i64, rect.x) + rect.width)) * 2 / @as(f32, @floatFromInt(width)) - 1;
    const y0 = 1 - @as(f32, @floatFromInt(rect.y)) * 2 / @as(f32, @floatFromInt(height));
    const y1 = 1 - @as(f32, @floatFromInt(@as(i64, rect.y) + rect.height)) * 2 / @as(f32, @floatFromInt(height));
    const tint = rect.tint;
    const color = [_]f32{ @as(f32, @floatFromInt(tint.r)) / 255, @as(f32, @floatFromInt(tint.g)) / 255, @as(f32, @floatFromInt(tint.b)) / 255, @as(f32, @floatFromInt(tint.a)) / 255 };
    const a = up.SpriteBatchVertex{ .x = x0, .y = y0, .u = 0, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
    const b = up.SpriteBatchVertex{ .x = x1, .y = y0, .u = 1, .v = 0, .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
    const d = up.SpriteBatchVertex{ .x = x0, .y = y1, .u = 0, .v = 1, .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
    const corner = up.SpriteBatchVertex{ .x = x1, .y = y1, .u = 1, .v = 1, .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
    return .{ a, b, corner, a, corner, d };
}
fn scissor(comptime c: type, value: ?up.ClipRect, width: u32, height: u32) c.SDL_Rect {
    const clip = value orelse return .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) };
    const x0 = std.math.clamp(@as(i64, clip.x), 0, width);
    const y0 = std.math.clamp(@as(i64, clip.y), 0, height);
    const x1 = std.math.clamp(@as(i64, clip.x) + clip.w, x0, width);
    const y1 = std.math.clamp(@as(i64, clip.y) + clip.h, y0, height);
    return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}
