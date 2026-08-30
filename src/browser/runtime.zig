const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const up = @import("unpolished-peas");
const protocol_game = @import("protocol-game");
const frame_timing = @import("frame-timing");

pub const target_triple = "wasm32-freestanding";

var frame_token: u32 = 0;
var game: protocol_game.Game = .{};
var input: up.input.Input = .{};
var game_context: up.core.GameContext = undefined;
var protocol: up.core.GameProtocol(protocol_game.Game) = undefined;
var protocol_failure: ?up.core.GameFailure = null;
var scheduler = frame_timing.Scheduler.init(frame_timing.default_fixed_hz);
var last_timestamp_ms: ?f64 = null;
var paused = false;
var game_canvas: up.graphics.Canvas = undefined;
var game_canvas_ready = false;
var renderer: up.graphics.Renderer2D = undefined;
var renderer_ready = false;
var render_status: i32 = @intFromEnum(contract.Status.ok);

const runtime_allocator = if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;

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
    if (game_canvas_ready) game_canvas.deinit();
    if (renderer_ready) renderer.deinit();
    game_canvas = up.graphics.Canvas.init(runtime_allocator, width, height) catch return @intFromEnum(contract.Status.rejected);
    game_canvas_ready = true;
    renderer = up.graphics.Renderer2D.init(runtime_allocator);
    renderer_ready = true;
    input = .{};
    game = .{};
    game_context = .withRenderer(&input, &game_canvas, &renderer);
    protocol = .bind(&game);
    protocol.init(&game_context) catch {
        protocol_failure = protocol.lastFailure();
        return @intFromEnum(contract.Status.rejected);
    };
    scheduler = .init(frame_timing.default_fixed_hz);
    last_timestamp_ms = null;
    protocol_failure = null;
    render_status = @intFromEnum(contract.Status.ok);
    frame_token = contract.scheduleFrame();
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_frame(timestamp_ms: f64) void {
    const timing = scheduler.frame(elapsedSeconds(timestamp_ms), paused);
    var step: u32 = 0;
    while (step < timing.update_steps) : (step += 1) {
        protocol.update(&game_context, timing.update_seconds) catch {
            protocol_failure = protocol.lastFailure();
            return;
        };
    }
    renderer.beginFrame();
    protocol.draw(&game_context, timing.alpha) catch {
        protocol_failure = protocol.lastFailure();
        return;
    };
    render_status = submitCanvas();
    if (render_status == @intFromEnum(contract.Status.ok)) render_status = submitRenderer();
    protocol_failure = null;
    frame_token = contract.scheduleFrame();
}

pub export fn up_browser_canvas_render_status() i32 {
    return render_status;
}

fn submitCanvas() i32 {
    if (!game_canvas_ready) return @intFromEnum(contract.Status.unavailable);
    const byte_len = std.math.cast(u32, std.mem.sliceAsBytes(game_canvas.pixels).len) orelse return @intFromEnum(contract.Status.rejected);
    return contract.uploadCanvas(game_canvas.width, game_canvas.height, @intCast(@intFromPtr(game_canvas.pixels.ptr)), byte_len);
}

fn submitRenderer() i32 {
    if (!renderer_ready) return @intFromEnum(contract.Status.unavailable);
    for (renderer.material_sprites.items) |draw| {
        const status = submitMaterialSprite(draw);
        if (status != @intFromEnum(contract.Status.ok)) return status;
    }
    for (renderer.particle_batches.items) |batch| {
        const instances = renderer.particle_instances.items[batch.first_instance..][0..batch.instance_count];
        const status = contract.drawParticles(@intCast(@intFromPtr(instances.ptr)), @intCast(instances.len), @intFromEnum(batch.blend));
        if (status != @intFromEnum(contract.Status.ok)) return status;
    }
    for (renderer.post_passes.items) |pass| {
        const status = submitPostPass(pass);
        if (status != @intFromEnum(contract.Status.ok)) return status;
    }
    return contract.present(0);
}

fn submitMaterialSprite(draw: up.graphics.Renderer2D.MaterialSprite) i32 {
    const status = beginMaterial(draw.material, 0);
    if (status != @intFromEnum(contract.Status.ok)) return status;
    const source_status = bindMaterialImage("source", draw.image);
    if (source_status != @intFromEnum(contract.Status.ok)) return source_status;
    const bindings_status = bindMaterialValues(draw.bindings, draw.uniforms);
    if (bindings_status != @intFromEnum(contract.Status.ok)) return bindings_status;
    return contract.materialDraw(draw.x, draw.y, draw.width, draw.height, packedColor(draw.tint));
}

fn submitPostPass(pass: up.graphics.Renderer2D.PostPass) i32 {
    const status = beginMaterial(pass.material, 1);
    if (status != @intFromEnum(contract.Status.ok)) return status;
    const bindings_status = bindMaterialValues(pass.bindings, pass.uniforms);
    if (bindings_status != @intFromEnum(contract.Status.ok)) return bindings_status;
    return contract.materialDraw(0, 0, @intCast(game_canvas.width), @intCast(game_canvas.height), packedColor(up.core.Color.white));
}

fn beginMaterial(material: *const up.graphics.Material, kind: u32) i32 {
    const stages = material.executableStages() catch return @intFromEnum(contract.Status.unavailable);
    const material_id = std.math.cast(u32, @intFromPtr(material)) orelse return @intFromEnum(contract.Status.rejected);
    return contract.materialBegin(material_id, material.revision, kind, pointer(stages.vertex.webgl2_glsl_es), length(stages.vertex.webgl2_glsl_es), pointer(stages.fragment.webgl2_glsl_es), length(stages.fragment.webgl2_glsl_es), pointer(stages.vertex.webgpu_wgsl), length(stages.vertex.webgpu_wgsl), pointer(stages.fragment.webgpu_wgsl), length(stages.fragment.webgpu_wgsl));
}

fn bindMaterialValues(bindings: []const up.graphics.MaterialBinding, legacy_settings: []const u8) i32 {
    for (bindings) |binding| {
        const status = switch (binding.value) {
            .texture => |texture| bindMaterialImage(binding.name, texture.image),
            .uniform => |bytes| contract.materialBindUniform(pointer(binding.name), length(binding.name), pointer(bytes), length(bytes)),
        };
        if (status != @intFromEnum(contract.Status.ok)) return status;
    }
    if (legacy_settings.len != 0) return contract.materialBindUniform(pointer("settings"), "settings".len, pointer(legacy_settings), length(legacy_settings));
    return @intFromEnum(contract.Status.ok);
}

fn bindMaterialImage(name: []const u8, image: *const up.assets.Image) i32 {
    const pixels = std.mem.sliceAsBytes(image.pixels);
    return contract.materialBindTexture(pointer(name), length(name), image.width, image.height, pointer(pixels), length(pixels));
}

fn pointer(bytes: []const u8) u32 {
    return @intCast(@intFromPtr(bytes.ptr));
}

fn length(bytes: []const u8) u32 {
    return std.math.cast(u32, bytes.len) orelse 0;
}

fn packedColor(color: up.core.Color) u32 {
    return @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24);
}

pub export fn up_browser_set_paused(value: u32) i32 {
    if (value > 1) return @intFromEnum(contract.Status.invalid_argument);
    paused = value == 1;
    last_timestamp_ms = null;
    return @intFromEnum(contract.Status.ok);
}

fn elapsedSeconds(timestamp_ms: f64) f32 {
    if (!std.math.isFinite(timestamp_ms)) return 0;
    const previous = last_timestamp_ms;
    last_timestamp_ms = timestamp_ms;
    if (previous == null) return scheduler.clock.step_seconds;
    if (timestamp_ms < previous.?) return 0;
    return @floatCast((timestamp_ms - previous.?) / 1000);
}

pub export fn up_browser_protocol_failure_phase() i32 {
    return if (protocol_failure) |current| @intFromEnum(current.phase) else -1;
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
    if (game_canvas_ready) {
        game_canvas.deinit();
        game_canvas_ready = false;
    }
    if (renderer_ready) {
        renderer.deinit();
        renderer_ready = false;
    }
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

test "browser runtime uses shared fixed-step timing and pause semantics" {
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.invalid_argument)), up_browser_set_paused(2));
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_set_paused(0));
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_init(64, 48));
    input.set(.right, true);
    up_browser_frame(0);
    up_browser_frame(250);
    try std.testing.expectEqual(@as(u32, 2), game.draw_calls);
    try std.testing.expect(std.math.approxEqAbs(f32, 28, game.position.x, 0.0001));
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_set_paused(1));
    up_browser_frame(1_000);
    try std.testing.expectEqual(@as(u32, 3), game.draw_calls);
    try std.testing.expect(std.math.approxEqAbs(f32, 28, game.position.x, 0.0001));
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_set_paused(0));
    up_browser_frame(2_000);
    try std.testing.expectEqual(@as(u32, 4), game.draw_calls);
    try std.testing.expect(std.math.approxEqAbs(f32, 28 + 40.0 / 60.0, game.position.x, 0.0001));
}
