const std = @import("std");
const contract = @import("contract.zig");
const up = @import("unpolished-peas");
const game_mod = @import("platformer-game");
const frame_timing = @import("frame-timing");

const input_abi_version: u32 = 1;
const input_abi_bytes = 376;

var frame_token: u32 = 0;
var game: game_mod.Game = .{};
var input: up.input.Input = .{};
var input_bytes: [input_abi_bytes]u8 align(4) = undefined;
var scheduler = frame_timing.Scheduler.init(frame_timing.default_fixed_hz);
var last_timestamp_ms: ?f64 = null;
var paused = false;
var render_status: i32 = @intFromEnum(contract.Status.ok);

pub export fn up_browser_abi_version() u32 {
    return contract.abi_version;
}

pub export fn up_browser_init(width: u32, height: u32) i32 {
    if (width == 0 or height == 0) return @intFromEnum(contract.Status.invalid_argument);
    input = .{};
    game = .{};
    scheduler = .init(frame_timing.default_fixed_hz);
    last_timestamp_ms = null;
    paused = false;
    render_status = @intFromEnum(contract.Status.ok);
    frame_token = contract.scheduleFrame();
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_frame(timestamp_ms: f64) void {
    syncInput();
    const timing = scheduler.frame(elapsedSeconds(timestamp_ms), paused);
    var step: u32 = 0;
    while (step < timing.update_steps) : (step += 1) _ = game.step(input, scheduler.clock.step_seconds);
    render();
    frame_token = contract.scheduleFrame();
}

pub export fn up_browser_set_paused(value: u32) i32 {
    if (value > 1) return @intFromEnum(contract.Status.invalid_argument);
    paused = value == 1;
    last_timestamp_ms = null;
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_resize(width: u32, height: u32) i32 {
    if (width == 0 or height == 0) return @intFromEnum(contract.Status.invalid_argument);
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_cancel_frame(token: u32) void {
    contract.cancelFrame(token);
    if (frame_token == token) frame_token = 0;
}

pub export fn up_browser_platformer_player_x() f32 {
    return game.player.x;
}

pub export fn up_browser_platformer_player_y() f32 {
    return game.player.y;
}

pub export fn up_browser_platformer_grounded() u32 {
    return @intFromBool(game.grounded);
}

pub export fn up_browser_platformer_render_status() i32 {
    return render_status;
}

pub export fn up_browser_protocol_failure_phase() i32 {
    return -1;
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

fn elapsedSeconds(timestamp_ms: f64) f32 {
    if (!std.math.isFinite(timestamp_ms)) return 0;
    const previous = last_timestamp_ms;
    last_timestamp_ms = timestamp_ms;
    if (previous == null or timestamp_ms < previous.?) return scheduler.clock.step_seconds;
    return @floatCast((timestamp_ms - previous.?) / 1000);
}

fn syncInput() void {
    input.beginFrame();
    if (contract.pollInput() < input_abi_bytes) return;
    const written = contract.readInput(@intCast(@intFromPtr(&input_bytes)), input_abi_bytes);
    if (written != input_abi_bytes or readU32(0) != input_abi_version) return;
    const down = readU32(20);
    inline for (std.meta.fields(up.input.Key)) |field| {
        const key: up.input.Key = @enumFromInt(field.value);
        input.set(key, (down & (@as(u32, 1) << @intCast(field.value))) != 0);
    }
}

fn readU32(offset: usize) u32 {
    return std.mem.readInt(u32, input_bytes[offset..][0..4], .little);
}

fn render() void {
    render_status = contract.clear(rgba(15, 23, 38));
    if (render_status != @intFromEnum(contract.Status.ok)) return;
    for (game_mod.platforms) |platform| {
        submit(contract.drawRect(@intFromFloat(platform.x), @intFromFloat(platform.y), @intFromFloat(platform.w), @intFromFloat(platform.h), rgba(55, 100, 130)));
    }
    submit(contract.drawRect(149, 54, 2, 30, rgba(225, 232, 240)));
    submit(contract.drawRect(151, 54, 7, 6, rgba(255, 198, 74)));
    submit(contract.drawRect(@intFromFloat(game.player.x), @intFromFloat(game.player.y), game_mod.player_width, game_mod.player_height, rgba(255, 198, 74)));
    submit(contract.present(0));
}

fn submit(status: i32) void {
    if (render_status == @intFromEnum(contract.Status.ok) and status != @intFromEnum(contract.Status.ok)) render_status = status;
}

fn rgba(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, 255) << 24);
}
