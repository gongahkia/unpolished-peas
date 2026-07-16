const builtin = @import("builtin");
const std = @import("std");

pub const abi_version: u32 = 1;

pub const Binding = struct {
    name: []const u8,
};

pub const imports = [_]Binding{
    .{ .name = "up_host_schedule_frame" },
    .{ .name = "up_host_cancel_frame" },
    .{ .name = "up_host_gl_context_create" },
    .{ .name = "up_host_gl_context_destroy" },
    .{ .name = "up_host_gl_resource_create" },
    .{ .name = "up_host_gl_resource_destroy" },
    .{ .name = "up_host_gl_context_lost" },
    .{ .name = "up_host_gl_clear" },
    .{ .name = "up_host_gl_draw_rect" },
    .{ .name = "up_host_gl_draw_line" },
    .{ .name = "up_host_gl_draw_circle" },
    .{ .name = "up_host_gl_draw_triangle" },
    .{ .name = "up_host_gl_present" },
    .{ .name = "up_host_gl_texture_upload" },
    .{ .name = "up_host_gl_draw_sprite" },
    .{ .name = "up_host_gl_flush_sprites" },
    .{ .name = "up_host_gl_draw_text" },
    .{ .name = "up_host_input_poll" },
    .{ .name = "up_host_input_read" },
    .{ .name = "up_host_audio_state" },
    .{ .name = "up_host_audio_submit" },
    .{ .name = "up_host_storage_read" },
    .{ .name = "up_host_storage_write" },
    .{ .name = "up_host_storage_remove" },
    .{ .name = "up_host_diagnostic_emit" },
    .{ .name = "up_host_teardown" },
};

pub const exports = [_]Binding{
    .{ .name = "up_browser_abi_version" },
    .{ .name = "up_browser_init" },
    .{ .name = "up_browser_frame" },
    .{ .name = "up_browser_resize" },
    .{ .name = "up_browser_cancel_frame" },
    .{ .name = "up_browser_gl_context_create" },
    .{ .name = "up_browser_gl_context_destroy" },
    .{ .name = "up_browser_gl_resource_create" },
    .{ .name = "up_browser_gl_resource_destroy" },
    .{ .name = "up_browser_gl_context_lost" },
    .{ .name = "up_browser_clear" },
    .{ .name = "up_browser_draw_rect" },
    .{ .name = "up_browser_draw_line" },
    .{ .name = "up_browser_draw_circle" },
    .{ .name = "up_browser_draw_triangle" },
    .{ .name = "up_browser_present" },
    .{ .name = "up_browser_texture_upload" },
    .{ .name = "up_browser_draw_sprite" },
    .{ .name = "up_browser_flush_sprites" },
    .{ .name = "up_browser_draw_text" },
    .{ .name = "up_browser_input_poll" },
    .{ .name = "up_browser_input_read" },
    .{ .name = "up_browser_audio_state" },
    .{ .name = "up_browser_audio_submit" },
    .{ .name = "up_browser_storage_read" },
    .{ .name = "up_browser_storage_write" },
    .{ .name = "up_browser_storage_remove" },
    .{ .name = "up_browser_diagnostic_emit" },
    .{ .name = "up_browser_shutdown" },
};

pub const ResourceKind = enum(u32) {
    buffer,
    texture,
    program,
    framebuffer,
};

pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = -1,
    unavailable = -2,
    rejected = -3,
};

const WasmHost = struct {
    extern "env" fn up_host_schedule_frame() u32;
    extern "env" fn up_host_cancel_frame(token: u32) void;
    extern "env" fn up_host_gl_context_create(width: u32, height: u32) i32;
    extern "env" fn up_host_gl_context_destroy() void;
    extern "env" fn up_host_gl_resource_create(kind: u32, byte_len: u32) u32;
    extern "env" fn up_host_gl_resource_destroy(kind: u32, handle: u32) void;
    extern "env" fn up_host_gl_context_lost() u32;
    extern "env" fn up_host_gl_clear(color: u32) i32;
    extern "env" fn up_host_gl_draw_rect(x: i32, y: i32, width: i32, height: i32, color: u32) i32;
    extern "env" fn up_host_gl_draw_line(x0: i32, y0: i32, x1: i32, y1: i32, color: u32) i32;
    extern "env" fn up_host_gl_draw_circle(x: i32, y: i32, radius: i32, color: u32) i32;
    extern "env" fn up_host_gl_draw_triangle(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, color: u32) i32;
    extern "env" fn up_host_gl_present(mode: u32) i32;
    extern "env" fn up_host_gl_texture_upload(handle: u32, width: u32, height: u32, source: u32, byte_len: u32, sampling: u32) i32;
    extern "env" fn up_host_gl_draw_sprite(handle: u32, source_x: u32, source_y: u32, source_width: u32, source_height: u32, x: i32, y: i32, width: i32, height: i32, color: u32, sampling: u32) i32;
    extern "env" fn up_host_gl_flush_sprites() i32;
    extern "env" fn up_host_gl_draw_text(source: u32, byte_len: u32, x: i32, y: i32, color: u32) i32;
    extern "env" fn up_host_input_poll() u32;
    extern "env" fn up_host_input_read(destination: u32, capacity: u32) u32;
    extern "env" fn up_host_audio_state() i32;
    extern "env" fn up_host_audio_submit(source: u32, byte_len: u32) i32;
    extern "env" fn up_host_storage_read(key: u32, key_len: u32, destination: u32, capacity: u32) i32;
    extern "env" fn up_host_storage_write(key: u32, key_len: u32, source: u32, byte_len: u32) i32;
    extern "env" fn up_host_storage_remove(key: u32, key_len: u32) i32;
    extern "env" fn up_host_diagnostic_emit(source: u32, byte_len: u32) void;
    extern "env" fn up_host_teardown() void;
};

const NativeHost = struct {
    fn up_host_schedule_frame() u32 {
        return 0;
    }

    fn up_host_cancel_frame(_: u32) void {}
    fn up_host_gl_context_create(_: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_context_destroy() void {}
    fn up_host_gl_resource_create(_: u32, _: u32) u32 {
        return 0;
    }

    fn up_host_gl_resource_destroy(_: u32, _: u32) void {}
    fn up_host_gl_context_lost() u32 {
        return 0;
    }

    fn up_host_gl_clear(_: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_draw_rect(_: i32, _: i32, _: i32, _: i32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_draw_line(_: i32, _: i32, _: i32, _: i32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_draw_circle(_: i32, _: i32, _: i32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_draw_triangle(_: f32, _: f32, _: f32, _: f32, _: f32, _: f32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_present(_: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_texture_upload(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_draw_sprite(_: u32, _: u32, _: u32, _: u32, _: u32, _: i32, _: i32, _: i32, _: i32, _: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_flush_sprites() i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_gl_draw_text(_: u32, _: u32, _: i32, _: i32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_input_poll() u32 {
        return 0;
    }

    fn up_host_input_read(_: u32, _: u32) u32 {
        return 0;
    }

    fn up_host_audio_state() i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_audio_submit(_: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_storage_read(_: u32, _: u32, _: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_storage_write(_: u32, _: u32, _: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_storage_remove(_: u32, _: u32) i32 {
        return @intFromEnum(Status.unavailable);
    }

    fn up_host_diagnostic_emit(_: u32, _: u32) void {}
    fn up_host_teardown() void {}
};

const host = if (builtin.target.cpu.arch == .wasm32) WasmHost else NativeHost;

pub fn scheduleFrame() u32 {
    return host.up_host_schedule_frame();
}

pub fn cancelFrame(token: u32) void {
    host.up_host_cancel_frame(token);
}

pub fn createContext(width: u32, height: u32) i32 {
    return host.up_host_gl_context_create(width, height);
}

pub fn destroyContext() void {
    host.up_host_gl_context_destroy();
}

pub fn createResource(kind: ResourceKind, byte_len: u32) u32 {
    return host.up_host_gl_resource_create(@intFromEnum(kind), byte_len);
}

pub fn destroyResource(kind: ResourceKind, handle: u32) void {
    host.up_host_gl_resource_destroy(@intFromEnum(kind), handle);
}

pub fn contextLost() bool {
    return host.up_host_gl_context_lost() != 0;
}

pub fn clear(color: u32) i32 {
    return host.up_host_gl_clear(color);
}

pub fn drawRect(x: i32, y: i32, width: i32, height: i32, color: u32) i32 {
    return host.up_host_gl_draw_rect(x, y, width, height, color);
}

pub fn drawLine(x0: i32, y0: i32, x1: i32, y1: i32, color: u32) i32 {
    return host.up_host_gl_draw_line(x0, y0, x1, y1, color);
}

pub fn drawCircle(x: i32, y: i32, radius: i32, color: u32) i32 {
    return host.up_host_gl_draw_circle(x, y, radius, color);
}

pub fn drawTriangle(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, color: u32) i32 {
    return host.up_host_gl_draw_triangle(ax, ay, bx, by, cx, cy, color);
}

pub fn present(mode: u32) i32 {
    return host.up_host_gl_present(mode);
}

pub fn uploadTexture(handle: u32, width: u32, height: u32, source: u32, byte_len: u32, sampling: u32) i32 {
    return host.up_host_gl_texture_upload(handle, width, height, source, byte_len, sampling);
}

pub fn drawSprite(handle: u32, source_x: u32, source_y: u32, source_width: u32, source_height: u32, x: i32, y: i32, width: i32, height: i32, color: u32, sampling: u32) i32 {
    return host.up_host_gl_draw_sprite(handle, source_x, source_y, source_width, source_height, x, y, width, height, color, sampling);
}

pub fn flushSprites() i32 {
    return host.up_host_gl_flush_sprites();
}

pub fn drawText(source: u32, byte_len: u32, x: i32, y: i32, color: u32) i32 {
    return host.up_host_gl_draw_text(source, byte_len, x, y, color);
}

pub fn pollInput() u32 {
    return host.up_host_input_poll();
}

pub fn readInput(destination: u32, capacity: u32) u32 {
    return host.up_host_input_read(destination, capacity);
}

pub fn audioState() i32 {
    return host.up_host_audio_state();
}

pub fn submitAudio(source: u32, byte_len: u32) i32 {
    return host.up_host_audio_submit(source, byte_len);
}

pub fn readStorage(key: u32, key_len: u32, destination: u32, capacity: u32) i32 {
    return host.up_host_storage_read(key, key_len, destination, capacity);
}

pub fn writeStorage(key: u32, key_len: u32, source: u32, byte_len: u32) i32 {
    return host.up_host_storage_write(key, key_len, source, byte_len);
}

pub fn removeStorage(key: u32, key_len: u32) i32 {
    return host.up_host_storage_remove(key, key_len);
}

pub fn emitDiagnostic(source: u32, byte_len: u32) void {
    host.up_host_diagnostic_emit(source, byte_len);
}

pub fn teardown() void {
    host.up_host_teardown();
}

test "browser host contract keeps versioned category coverage" {
    try std.testing.expectEqual(@as(u32, 1), abi_version);
    try std.testing.expectEqual(@as(usize, 26), imports.len);
    try std.testing.expectEqual(@as(usize, 29), exports.len);
    try std.testing.expectEqualStrings("up_host_gl_resource_create", imports[4].name);
    try std.testing.expectEqualStrings("up_browser_shutdown", exports[28].name);
    try std.testing.expectEqual(@as(u32, 0), scheduleFrame());
    try std.testing.expectEqual(@as(i32, -2), createContext(64, 32));
    try std.testing.expectEqual(@as(u32, 0), createResource(.texture, 16));
    try std.testing.expect(!contextLost());
    try std.testing.expectEqual(@as(i32, -2), drawRect(0, 0, 1, 1, 0));
    try std.testing.expectEqual(@as(i32, -2), uploadTexture(1, 1, 1, 0, 4, 0));
    try std.testing.expectEqual(@as(i32, -2), audioState());
    try std.testing.expectEqual(@as(i32, -2), writeStorage(0, 0, 0, 0));
}
