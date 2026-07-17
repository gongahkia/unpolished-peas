const std = @import("std");
const actions = @import("actions.zig");
const assets = @import("assets.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const input = @import("input.zig");
const InspectorPanel = @import("inspector.zig").Panel;
const profiler = @import("profiler.zig");
const runtime_metrics = @import("runtime_metrics.zig");
const tile_collision = @import("tile_collision.zig");
const Vec2 = @import("math.zig").Vec2;

const panel_background = Color.rgba(12, 18, 28, 210);
const panel_border = Color.rgb(91, 123, 171);
const panel_title = Color.rgb(180, 220, 255);
const panel_text = Color.rgb(230, 235, 242);
const panel_warning = Color.rgb(255, 198, 74);

pub const ResourceHandle = union(enum) {
    text: assets.TextHandle,
    image: assets.ImageHandle,
    sound: assets.AudioHandle,
    font: assets.FontHandle,
    shader: assets.ShaderAssetHandle,
};

pub const Resource = struct {
    name: []const u8,
    handle: ResourceHandle,
};

pub const AssetPanel = struct {
    store: ?*const assets.AssetStore = null,
    resources: []const Resource = &.{},
    position: Vec2 = .{ .x = 4, .y = 96 },
    max_rows: usize = 8,

    pub fn panel(self: *AssetPanel) InspectorPanel {
        return .{ .name = "assets", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *AssetPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("ASSETS", .{}, panel_title);
        const store = self.store orelse {
            lines.line("store unavailable", .{}, panel_warning);
            return;
        };
        const stats = store.stats();
        lines.line("text={} image={} sound={}", .{ stats.texts, stats.images, stats.sounds }, panel_text);
        lines.line("font={} shader={} reload-events={}", .{ stats.fonts, stats.shaders, stats.reload_events }, panel_text);
        for (self.resources) |resource| {
            const state = resourceState(store, resource.handle);
            lines.line("{s}: {s}", .{ resource.name, state }, if (std.mem.eql(u8, state, "ready")) panel_text else panel_warning);
        }
    }
};

pub const InputPanel = struct {
    state: ?*const input.Input = null,
    action_map: ?*const actions.Map = null,
    position: Vec2 = .{ .x = 4, .y = 180 },
    max_rows: usize = 8,

    pub fn panel(self: *InputPanel) InspectorPanel {
        return .{ .name = "input", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *InputPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("INPUT", .{}, panel_title);
        const state = self.state orelse {
            lines.line("state unavailable", .{}, panel_warning);
            return;
        };
        if (state.pointer.canvas) |point| {
            lines.line("pointer {d:.0},{d:.0}", .{ point.x, point.y }, panel_text);
        } else lines.line("pointer unavailable", .{}, panel_warning);
        lines.line("buttons l={} m={} r={}", .{ state.pointerIsDown(.left), state.pointerIsDown(.middle), state.pointerIsDown(.right) }, panel_text);
        var gamepads: usize = 0;
        for (state.gamepads) |maybe| {
            if (maybe) |gamepad| {
                if (gamepad.connected) gamepads += 1;
            }
        }
        lines.line("gamepads={}", .{gamepads}, panel_text);
        inline for (@typeInfo(input.Key).@"enum".fields) |field| {
            const key: input.Key = @enumFromInt(field.value);
            if (state.isDown(key)) lines.line("key {s}", .{@tagName(key)}, panel_text);
        }
        const map = self.action_map orelse {
            lines.line("actions unavailable", .{}, panel_warning);
            return;
        };
        for (map.actions) |action| lines.line("{s}/{s} {d:.2}", .{ action.context, action.name, map.value(state.*, action.context, action.name) }, panel_text);
    }
};

pub const MetricsPanel = struct {
    metrics: ?*const runtime_metrics.Metrics = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 7,

    pub fn panel(self: *MetricsPanel) InspectorPanel {
        return .{ .name = "metrics", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *MetricsPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("METRICS", .{}, panel_title);
        const metrics = self.metrics orelse {
            lines.line("runtime unavailable", .{}, panel_warning);
            return;
        };
        if (metrics.gpu_frame_ns) |frame_ns| {
            const pass_ns: ?u64 = if (metrics.gpu_pass_ns) |value| value / std.time.ns_per_us else null;
            lines.line("gpu frame={}us pass={?}us", .{ frame_ns / std.time.ns_per_us, pass_ns }, panel_text);
        } else lines.line("gpu timing unavailable", .{}, panel_warning);
        lines.line("encoder={}us pass={} batch={}", .{ metrics.encoder_ns / std.time.ns_per_us, metrics.pass_count, metrics.batches }, panel_text);
        lines.line("textures={} {}KiB", .{ metrics.texture_count, metrics.texture_bytes / 1024 }, panel_text);
        if (metrics.audio_buffer_bytes) |buffer_bytes| {
            lines.line("audio={}KiB queued={}KiB", .{ buffer_bytes / 1024, (metrics.audio_queued_bytes orelse 0) / 1024 }, panel_text);
        } else lines.line("audio unavailable", .{}, panel_warning);
        lines.line("churn resource={} alloc={}KiB", .{ metrics.resource_churn, metrics.allocation_churn_bytes / 1024 }, panel_text);
    }
};

pub const RendererState = struct {
    requested: []const u8 = "unknown",
    selected: []const u8 = "none",
    gpu: []const u8 = "unknown",
    opengl: []const u8 = "unknown",
    effects: []const u8 = "unknown",
    recovery: []const u8 = "none",
    preflight: []const u8 = "none",
};

pub const RendererPanel = struct {
    state: ?*const RendererState = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 7,

    pub fn panel(self: *RendererPanel) InspectorPanel {
        return .{ .name = "renderer", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *RendererPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("RENDERER", .{}, panel_title);
        const state = self.state orelse {
            lines.line("state unavailable", .{}, panel_warning);
            return;
        };
        lines.line("requested={s} selected={s}", .{ state.requested, state.selected }, panel_text);
        lines.line("gpu={s} opengl={s}", .{ state.gpu, state.opengl }, panel_text);
        lines.line("effects={s} recovery={s}", .{ state.effects, state.recovery }, panel_text);
        lines.line("preflight={s}", .{state.preflight}, if (std.mem.eql(u8, state.preflight, "none")) panel_text else panel_warning);
    }
};

pub const ReloadPanel = struct {
    store: ?*const assets.AssetStore = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 6,

    pub fn panel(self: *ReloadPanel) InspectorPanel {
        return .{ .name = "asset-reload", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *ReloadPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("ASSET RELOAD", .{}, panel_title);
        const store = self.store orelse {
            lines.line("store unavailable", .{}, panel_warning);
            return;
        };
        lines.line("events={}", .{store.events.items.len}, panel_text);
        const event = store.events.getLastOrNull() orelse {
            lines.line("no reload events", .{}, panel_text);
            return;
        };
        lines.line("{s}: {s}", .{ event.path, @tagName(event.status) }, if (event.status == .changed) panel_text else panel_warning);
        lines.line("class={s} retained={}", .{ if (event.failure_class) |value| @tagName(value) else "none", event.retained_content }, panel_text);
        if (event.message.len != 0) lines.line("{s}", .{event.message}, panel_warning);
    }
};

pub const BindingsPanel = struct {
    action_map: ?*const actions.Map = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 8,

    pub fn panel(self: *BindingsPanel) InspectorPanel {
        return .{ .name = "bindings", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *BindingsPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("BINDINGS", .{}, panel_title);
        const map = self.action_map orelse {
            lines.line("actions unavailable", .{}, panel_warning);
            return;
        };
        for (map.actions) |action| lines.line("{s}/{s}: {s}", .{ action.context, action.name, bindingName(action.binding) }, panel_text);
    }
};

pub const ProfilePanel = struct {
    value: ?*const profiler.Profiler = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 8,

    pub fn panel(self: *ProfilePanel) InspectorPanel {
        return .{ .name = "profile", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *ProfilePanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("PROFILE", .{}, panel_title);
        const value = self.value orelse {
            lines.line("profiler unavailable", .{}, panel_warning);
            return;
        };
        const metrics = value.metrics();
        lines.line("frame={} samples={} dropped={}", .{ metrics.frame, metrics.samples, metrics.dropped_samples }, panel_text);
        inline for (@typeInfo(profiler.Scope).@"enum".fields) |field| {
            const scope: profiler.Scope = @enumFromInt(field.value);
            const item = metrics.scope(scope);
            lines.line("{s} {} {d}us", .{ @tagName(scope), item.calls, item.total_ns / std.time.ns_per_us }, panel_text);
        }
    }
};

pub const SubsystemState = struct {
    app_data_path: []const u8 = "",
    audio_ready: bool = false,
    audio_queued_bytes: ?u64 = null,
    renderer_ready: bool = false,
};

pub const SubsystemPanel = struct {
    state: ?*const SubsystemState = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 7,

    pub fn panel(self: *SubsystemPanel) InspectorPanel {
        return .{ .name = "subsystems", .context = self, .draw = draw };
    }

    pub fn copyableDiagnosticsPath(self: SubsystemPanel, allocator: std.mem.Allocator) !?[]u8 {
        const state = self.state orelse return null;
        if (state.app_data_path.len == 0) return null;
        return try std.fs.path.join(allocator, &.{ state.app_data_path, "diagnostics" });
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *SubsystemPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("SUBSYSTEMS", .{}, panel_title);
        const state = self.state orelse {
            lines.line("state unavailable", .{}, panel_warning);
            return;
        };
        lines.line("renderer={s} audio={s}", .{ if (state.renderer_ready) "ready" else "unavailable", if (state.audio_ready) "ready" else "unavailable" }, panel_text);
        if (state.audio_queued_bytes) |bytes| lines.line("audio queued={}KiB", .{bytes / 1024}, panel_text) else lines.line("audio queue unavailable", .{}, panel_warning);
        lines.line("app data {s}", .{state.app_data_path}, panel_text);
        lines.line("copy diagnostics path via panel API", .{}, panel_text);
    }
};

pub const CollisionPanel = struct {
    collider: ?*const tile_collision.TileCollider = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 5,

    pub fn panel(self: *CollisionPanel) InspectorPanel {
        return .{ .name = "collision", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *CollisionPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("COLLISION", .{}, panel_title);
        const collider = self.collider orelse {
            lines.line("collider unavailable", .{}, panel_warning);
            return;
        };
        var solids: usize = 0;
        var one_way: usize = 0;
        var slopes: usize = 0;
        for (collider.shapes.items) |shape| switch (shape) {
            .solid => solids += 1,
            .one_way => one_way += 1,
            .slope => slopes += 1,
        };
        lines.line("shapes={} solid={}", .{ collider.shapes.items.len, solids }, panel_text);
        lines.line("one-way={} slopes={}", .{ one_way, slopes }, panel_text);
    }
};

const Lines = struct {
    canvas: *Canvas,
    x: i32,
    y: i32,
    max_rows: usize,
    rows: usize = 0,

    fn init(canvas: *Canvas, position: Vec2, max_rows: usize) Lines {
        return .{
            .canvas = canvas,
            .x = @intFromFloat(@floor(position.x)),
            .y = @intFromFloat(@floor(position.y)),
            .max_rows = @max(1, max_rows),
        };
    }

    fn box(self: *Lines) void {
        const height: i32 = @intCast(self.max_rows * 8 + 6);
        self.canvas.fillRect(self.x, self.y, 280, height, panel_background);
        self.canvas.strokeRect(self.x, self.y, 280, height, panel_border);
        self.y += 3;
    }

    fn line(self: *Lines, comptime format: []const u8, args: anytype, color: Color) void {
        if (self.rows >= self.max_rows) return;
        var buffer: [192]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch "<format-error>";
        self.canvas.drawText(text, self.x + 4, self.y, color);
        self.y += 8;
        self.rows += 1;
    }
};

fn resourceState(store: *const assets.AssetStore, handle: ResourceHandle) []const u8 {
    return switch (handle) {
        .text => |value| if (store.tryText(value)) |_| "ready" else |_| "stale",
        .image => |value| if (store.tryImage(value)) |_| "ready" else |_| "stale",
        .sound => |value| if (store.trySound(value)) |_| "ready" else |_| "stale",
        .font => |value| if (store.tryFont(value)) |_| "ready" else |_| "stale",
        .shader => |value| if (store.tryShaderSource(value)) |_| "ready" else |_| "stale",
    };
}

fn bindingName(binding: actions.Binding) []const u8 {
    return switch (binding) {
        .key => |value| @tagName(value),
        .pointer_button => |value| @tagName(value),
        .gamepad_button => |value| @tagName(value),
        .gamepad_axis => |value| @tagName(value.axis),
    };
}

test "inspector panels render unavailable sources safely" {
    const test_support = @import("test_support.zig");
    var canvas = try Canvas.init(std.testing.allocator, 320, 256);
    defer canvas.deinit();
    var asset = AssetPanel{};
    var input_panel = InputPanel{};
    var metrics_panel = MetricsPanel{};
    var collision_panel = CollisionPanel{};
    try asset.panel().draw(asset.panel().context, &canvas);
    try input_panel.panel().draw(input_panel.panel().context, &canvas);
    try metrics_panel.panel().draw(metrics_panel.panel().context, &canvas);
    try collision_panel.panel().draw(collision_panel.panel().context, &canvas);
    const hash = test_support.canvasHash(canvas);
    try std.testing.expect(hash != 0);
}

test "diagnostic panels render deterministic read-only state" {
    var collider = tile_collision.TileCollider.init(std.testing.allocator);
    defer collider.deinit();
    try collider.addShape(.{ .solid = .{ .x = 0, .y = 0, .w = 8, .h = 8 } });
    try collider.addShape(.{ .one_way = .{ .x = 8, .y = 0, .w = 8, .h = 8 } });
    var collision_panel = CollisionPanel{ .collider = &collider };
    var first = try Canvas.init(std.testing.allocator, 320, 192);
    defer first.deinit();
    var second = try Canvas.init(std.testing.allocator, 320, 192);
    defer second.deinit();
    try collision_panel.panel().draw(collision_panel.panel().context, &first);
    try collision_panel.panel().draw(collision_panel.panel().context, &second);
    try std.testing.expectEqual(@import("test_support.zig").canvasHash(first), @import("test_support.zig").canvasHash(second));
    try std.testing.expectEqual(@as(usize, 2), collider.shapes.items.len);
}

test "metrics panel renders unavailable GPU timing and resource state" {
    var metrics = runtime_metrics.Metrics{};
    metrics.beginFrame(2);
    metrics.recordGpuSubmission(250, 3, 2, 4, 4096, 8192);
    metrics.recordAudio(1024, 256);
    var panel = MetricsPanel{ .metrics = &metrics };
    var canvas = try Canvas.init(std.testing.allocator, 320, 320);
    defer canvas.deinit();
    try panel.panel().draw(panel.panel().context, &canvas);
    try std.testing.expect(@import("test_support.zig").canvasHash(canvas) != 0);
}

test "extended diagnostic panels render navigable runtime state" {
    var store = assets.AssetStore.init(std.testing.allocator, std.fs.cwd());
    defer store.deinit();
    try store.events.append(std.testing.allocator, .{ .path = "sprite.png", .status = .failed, .failure_class = .decode, .retained_content = true, .message = "invalid image" });
    var action_map = try actions.Map.init(std.testing.allocator, &.{.{ .name = "jump", .binding = .{ .key = .action } }});
    defer action_map.deinit();
    var frame_profiler = profiler.Profiler.init(true);
    frame_profiler.beginFrame(9);
    frame_profiler.scope(.draw).end();
    const renderer_state = RendererState{ .requested = "auto", .selected = "opengl", .gpu = "unavailable", .opengl = "available", .effects = "available", .recovery = "none", .preflight = "none" };
    const subsystem_state = SubsystemState{ .app_data_path = "/tmp/peas", .audio_ready = true, .audio_queued_bytes = 2048, .renderer_ready = true };
    var renderer_panel = RendererPanel{ .state = &renderer_state };
    var reload_panel = ReloadPanel{ .store = &store };
    var bindings_panel = BindingsPanel{ .action_map = &action_map };
    var profile_panel = ProfilePanel{ .value = &frame_profiler };
    var subsystem_panel = SubsystemPanel{ .state = &subsystem_state };
    const diagnostics_path = try subsystem_panel.copyableDiagnosticsPath(std.testing.allocator);
    defer std.testing.allocator.free(diagnostics_path.?);
    try std.testing.expectEqualStrings("/tmp/peas/diagnostics", diagnostics_path.?);
    var canvas = try Canvas.init(std.testing.allocator, 320, 192);
    defer canvas.deinit();
    try renderer_panel.panel().draw(renderer_panel.panel().context, &canvas);
    try reload_panel.panel().draw(reload_panel.panel().context, &canvas);
    try bindings_panel.panel().draw(bindings_panel.panel().context, &canvas);
    try profile_panel.panel().draw(profile_panel.panel().context, &canvas);
    try subsystem_panel.panel().draw(subsystem_panel.panel().context, &canvas);
    try std.testing.expect(@import("test_support.zig").canvasHash(canvas) != 0);
}

test "core inspector panels expose bounded raw-asset input and frame state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "note.txt", .data = "ok" });
    var store = assets.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    _ = try store.loadText("note.txt");
    try store.events.append(std.testing.allocator, .{ .path = "user-metadata.json", .status = .failed, .failure_class = .decode, .message = "invalid metadata" });

    var state = input.Input{};
    state.set(.action, true);
    state.setPointerPosition(.{ .x = 10, .y = 20 }, .{ .x = 20, .y = 40 }, .{ .x = 5, .y = 10 });
    var action_map = try actions.Map.init(std.testing.allocator, &.{.{ .name = "jump", .binding = .{ .key = .action } }});
    defer action_map.deinit();
    action_map.update(state);
    var metrics = runtime_metrics.Metrics{};
    metrics.beginFrame(8);
    metrics.recordGpuSubmission(120, 2, 1, 3, 2048, 4096);
    metrics.recordAssetReloads(store.events.items.len);

    var asset_panel = AssetPanel{ .store = &store };
    var input_panel = InputPanel{ .state = &state, .action_map = &action_map };
    var metrics_panel = MetricsPanel{ .metrics = &metrics };
    var first = try Canvas.init(std.testing.allocator, 320, 256);
    defer first.deinit();
    try asset_panel.panel().draw(asset_panel.panel().context, &first);
    try input_panel.panel().draw(input_panel.panel().context, &first);
    try metrics_panel.panel().draw(metrics_panel.panel().context, &first);
    var second = try Canvas.init(std.testing.allocator, 320, 256);
    defer second.deinit();
    try asset_panel.panel().draw(asset_panel.panel().context, &second);
    try input_panel.panel().draw(input_panel.panel().context, &second);
    try metrics_panel.panel().draw(metrics_panel.panel().context, &second);
    try std.testing.expectEqual(@import("test_support.zig").canvasHash(first), @import("test_support.zig").canvasHash(second));
    try std.testing.expectEqual(@as(usize, 1), store.stats().reload_events);
    try std.testing.expectEqual(@as(f32, 1), action_map.value(state, "game", "jump"));
    try std.testing.expectEqual(@as(u64, 8), metrics.frame);
    try std.testing.expectEqual(@as(u32, 4), metrics.resource_churn);
}
