const std = @import("std");
const contract = @import("contract.zig");

pub const target_triple = "wasm32-freestanding";

var frame_token: u32 = 0;

pub const HostCallbacks = struct {
    context: *anyopaque,
    on_resize: *const fn (*anyopaque, u32, u32) void,
};

pub const Runtime = struct {
    host: HostCallbacks,
    width: u32,
    height: u32,

    pub fn init(host: HostCallbacks, width: u32, height: u32) !Runtime {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        return .{ .host = host, .width = width, .height = height };
    }

    pub fn resize(self: *Runtime, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        self.width = width;
        self.height = height;
        self.host.on_resize(self.host.context, width, height);
    }
};

pub export fn up_browser_abi_version() u32 {
    return contract.abi_version;
}

pub export fn up_browser_init(width: u32, height: u32) i32 {
    if (width == 0 or height == 0) return @intFromEnum(contract.Status.invalid_argument);
    frame_token = contract.scheduleFrame();
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_frame(_: f64) void {
    frame_token = contract.scheduleFrame();
}

pub export fn up_browser_resize(width: u32, height: u32) i32 {
    if (width == 0 or height == 0) return @intFromEnum(contract.Status.invalid_argument);
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_cancel_frame(token: u32) void {
    contract.cancelFrame(token);
    if (frame_token == token) frame_token = 0;
}

pub export fn up_browser_gl_context_create(width: u32, height: u32) i32 {
    return contract.createContext(width, height);
}

pub export fn up_browser_gl_context_destroy() void {
    contract.destroyContext();
}

pub export fn up_browser_gl_resource_create(kind: u32, byte_len: u32) u32 {
    const resource_kind = std.meta.intToEnum(contract.ResourceKind, kind) catch return 0;
    return contract.createResource(resource_kind, byte_len);
}

pub export fn up_browser_gl_resource_destroy(kind: u32, handle: u32) void {
    const resource_kind = std.meta.intToEnum(contract.ResourceKind, kind) catch return;
    contract.destroyResource(resource_kind, handle);
}

pub export fn up_browser_gl_context_lost() u32 {
    return @intFromBool(contract.contextLost());
}

pub export fn up_browser_clear(color: u32) i32 {
    return contract.clear(color);
}

pub export fn up_browser_draw_rect(x: i32, y: i32, width: i32, height: i32, color: u32) i32 {
    return contract.drawRect(x, y, width, height, color);
}

pub export fn up_browser_draw_line(x0: i32, y0: i32, x1: i32, y1: i32, color: u32) i32 {
    return contract.drawLine(x0, y0, x1, y1, color);
}

pub export fn up_browser_draw_circle(x: i32, y: i32, radius: i32, color: u32) i32 {
    return contract.drawCircle(x, y, radius, color);
}

pub export fn up_browser_draw_triangle(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, color: u32) i32 {
    return contract.drawTriangle(ax, ay, bx, by, cx, cy, color);
}

pub export fn up_browser_present(mode: u32) i32 {
    return contract.present(mode);
}

pub export fn up_browser_texture_upload(handle: u32, width: u32, height: u32, source: u32, byte_len: u32, sampling: u32) i32 {
    return contract.uploadTexture(handle, width, height, source, byte_len, sampling);
}

pub export fn up_browser_draw_sprite(handle: u32, source_x: u32, source_y: u32, source_width: u32, source_height: u32, x: i32, y: i32, width: i32, height: i32, color: u32, sampling: u32) i32 {
    return contract.drawSprite(handle, source_x, source_y, source_width, source_height, x, y, width, height, color, sampling);
}

pub export fn up_browser_flush_sprites() i32 {
    return contract.flushSprites();
}

pub export fn up_browser_draw_text(source: u32, byte_len: u32, x: i32, y: i32, color: u32) i32 {
    return contract.drawText(source, byte_len, x, y, color);
}

pub export fn up_browser_push_clip(x: i32, y: i32, width: i32, height: i32) i32 {
    return contract.pushClip(x, y, width, height);
}

pub export fn up_browser_pop_clip() i32 {
    return contract.popClip();
}

pub export fn up_browser_push_blend(mode: u32) i32 {
    return contract.pushBlend(mode);
}

pub export fn up_browser_pop_blend() i32 {
    return contract.popBlend();
}

pub export fn up_browser_set_camera(enabled: u32, x: f32, y: f32, zoom: f32, rotation: f32, viewport_x: f32, viewport_y: f32, viewport_width: f32, viewport_height: f32) i32 {
    return contract.setCamera(enabled, x, y, zoom, rotation, viewport_x, viewport_y, viewport_width, viewport_height);
}

pub export fn up_browser_input_poll() u32 {
    return contract.pollInput();
}

pub export fn up_browser_input_read(destination: u32, capacity: u32) u32 {
    return contract.readInput(destination, capacity);
}

pub export fn up_browser_audio_state() i32 {
    return contract.audioState();
}

pub export fn up_browser_audio_submit(source: u32, byte_len: u32) i32 {
    return contract.submitAudio(source, byte_len);
}

pub export fn up_browser_storage_read(key: u32, key_len: u32, destination: u32, capacity: u32) i32 {
    return contract.readStorage(key, key_len, destination, capacity);
}

pub export fn up_browser_storage_write(key: u32, key_len: u32, source: u32, byte_len: u32) i32 {
    return contract.writeStorage(key, key_len, source, byte_len);
}

pub export fn up_browser_storage_remove(key: u32, key_len: u32) i32 {
    return contract.removeStorage(key, key_len);
}

pub export fn up_browser_diagnostic_emit(source: u32, byte_len: u32) void {
    contract.emitDiagnostic(source, byte_len);
}

pub export fn up_browser_shutdown() void {
    if (frame_token != 0) contract.cancelFrame(frame_token);
    frame_token = 0;
    contract.teardown();
}

test "browser runtime boundary forwards validated resize state" {
    const State = struct {
        width: u32 = 0,
        height: u32 = 0,

        fn resized(context: *anyopaque, width: u32, height: u32) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.width = width;
            state.height = height;
        }
    };
    var state = State{};
    var runtime = try Runtime.init(.{ .context = &state, .on_resize = State.resized }, 64, 32);
    try runtime.resize(128, 72);
    try std.testing.expectEqual(@as(u32, 128), runtime.width);
    try std.testing.expectEqual(@as(u32, 128), state.width);
    try std.testing.expectEqual(@as(u32, 72), state.height);
    try std.testing.expectError(error.InvalidCanvasSize, runtime.resize(0, 72));
}
