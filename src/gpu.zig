const std = @import("std");

pub const ResourceKind = enum { texture, render_target, shader, pipeline };

pub const Handle = struct {
    index: u32,
    generation: u32,
};

pub const TextureHandle = Handle;
pub const RenderTargetHandle = Handle;
pub const ShaderHandle = Handle;
pub const PipelineHandle = Handle;

pub const Resources = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(u32) = .empty,

    const Slot = struct { generation: u32 = 1, kind: ResourceKind, live: bool = true };

    pub fn init(allocator: std.mem.Allocator) Resources {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Resources) void {
        self.slots.deinit(self.allocator);
        self.free.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createTexture(self: *Resources) !TextureHandle {
        return self.create(.texture);
    }
    pub fn createRenderTarget(self: *Resources) !RenderTargetHandle {
        return self.create(.render_target);
    }
    pub fn createShader(self: *Resources) !ShaderHandle {
        return self.create(.shader);
    }
    pub fn createPipeline(self: *Resources) !PipelineHandle {
        return self.create(.pipeline);
    }
    pub fn destroyTexture(self: *Resources, handle: TextureHandle) !void {
        try self.destroy(.texture, handle);
    }
    pub fn destroyRenderTarget(self: *Resources, handle: RenderTargetHandle) !void {
        try self.destroy(.render_target, handle);
    }
    pub fn destroyShader(self: *Resources, handle: ShaderHandle) !void {
        try self.destroy(.shader, handle);
    }
    pub fn destroyPipeline(self: *Resources, handle: PipelineHandle) !void {
        try self.destroy(.pipeline, handle);
    }
    pub fn texture(self: *Resources, handle: TextureHandle) !void {
        try self.validate(.texture, handle);
    }
    pub fn renderTarget(self: *Resources, handle: RenderTargetHandle) !void {
        try self.validate(.render_target, handle);
    }
    pub fn shader(self: *Resources, handle: ShaderHandle) !void {
        try self.validate(.shader, handle);
    }
    pub fn pipeline(self: *Resources, handle: PipelineHandle) !void {
        try self.validate(.pipeline, handle);
    }

    fn create(self: *Resources, kind: ResourceKind) !Handle {
        if (self.free.pop()) |index| {
            var slot = &self.slots.items[index];
            slot.kind = kind;
            slot.live = true;
            return .{ .index = index, .generation = slot.generation };
        }
        try self.slots.append(self.allocator, .{ .kind = kind });
        return .{ .index = @intCast(self.slots.items.len - 1), .generation = 1 };
    }

    fn destroy(self: *Resources, kind: ResourceKind, handle: Handle) !void {
        try self.validate(kind, handle);
        var slot = &self.slots.items[handle.index];
        slot.live = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        try self.free.append(self.allocator, handle.index);
    }

    fn validate(self: *Resources, kind: ResourceKind, handle: Handle) !void {
        if (handle.index >= self.slots.items.len) return error.StaleHandle;
        const slot = self.slots.items[handle.index];
        if (!slot.live or slot.kind != kind or slot.generation != handle.generation) return error.StaleHandle;
    }
};

test "GPU resource handles reject stale access" {
    var resources = Resources.init(std.testing.allocator);
    defer resources.deinit();
    const texture = try resources.createTexture();
    try resources.texture(texture);
    try resources.destroyTexture(texture);
    try std.testing.expectError(error.StaleHandle, resources.texture(texture));
    const replacement = try resources.createTexture();
    try std.testing.expect(replacement.index == texture.index);
    try std.testing.expect(replacement.generation != texture.generation);
    try resources.texture(replacement);
}
