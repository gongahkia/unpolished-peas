const std = @import("std");
const actions = @import("actions.zig");
const assets = @import("assets.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const input = @import("input.zig");
const InspectorPanel = @import("inspector.zig").Panel;
const runtime_metrics = @import("runtime_metrics.zig");
const Vec2 = @import("math.zig").Vec2;
const scene_runtime = @import("scene_runtime.zig");

const panel_background = Color.rgba(12, 18, 28, 210);
const panel_border = Color.rgb(91, 123, 171);
const panel_title = Color.rgb(180, 220, 255);
const panel_text = Color.rgb(230, 235, 242);
const panel_warning = Color.rgb(255, 198, 74);

pub const ResourceHandle = union(enum) {
    text: assets.TextHandle,
    image: assets.ImageHandle,
    sound: assets.AudioHandle,
    atlas: assets.AtlasHandle,
    font: assets.FontHandle,
    shader: assets.ShaderAssetHandle,
    tile_map: assets.TileMapHandle,
};

pub const Resource = struct {
    name: []const u8,
    handle: ResourceHandle,
};

pub const ScenePanel = struct {
    runtime: ?*const scene_runtime.Runtime = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 9,

    pub fn panel(self: *ScenePanel) InspectorPanel {
        return .{ .name = "scene", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *ScenePanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("SCENE", .{}, panel_title);
        const runtime = self.runtime orelse {
            lines.line("runtime unavailable", .{}, panel_warning);
            return;
        };
        lines.line("{s} entities={} {s}", .{ runtime.source.metadata.name, runtime.source.entities.len, if (runtime.unloaded) "unloaded" else "loaded" }, panel_text);
        for (runtime.source.entities) |entity| {
            const state = entityState(runtime, entity.id);
            lines.line("{s} {s} bind={s}", .{ entity.id, state, entity.binding orelse "-" }, if (std.mem.eql(u8, state, "live")) panel_text else panel_warning);
            for (entity.components) |component| lines.line("  component {s}", .{component.kind}, panel_text);
            for (entity.references) |reference| lines.line("  ref {s}->{s}", .{ reference.name, reference.target }, panel_text);
        }
    }
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
        lines.line("atlas={} font={} shader={}", .{ stats.atlases, stats.fonts, stats.shaders }, panel_text);
        lines.line("map={} reload-events={}", .{ stats.tile_maps, stats.reload_events }, panel_text);
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

fn entityState(runtime: *const scene_runtime.Runtime, id: []const u8) []const u8 {
    const entity = runtime.entity(id) orelse return "missing";
    runtime.world.validate(entity) catch return "stale";
    return "live";
}

fn resourceState(store: *const assets.AssetStore, handle: ResourceHandle) []const u8 {
    return switch (handle) {
        .text => |value| if (store.tryText(value)) |_| "ready" else |_| "stale",
        .image => |value| if (store.tryImage(value)) |_| "ready" else |_| "stale",
        .sound => |value| if (store.trySound(value)) |_| "ready" else |_| "stale",
        .atlas => |value| if (store.tryAtlas(value)) |_| "ready" else |_| "stale",
        .font => |value| if (store.tryFont(value)) |_| "ready" else |_| "stale",
        .shader => |value| if (store.tryShader(value)) |_| "ready" else |_| "stale",
        .tile_map => |value| if (store.tryTileMap(value)) |_| "ready" else |_| "stale",
    };
}

test "inspector panels render unavailable sources safely" {
    const test_support = @import("test_support.zig");
    var canvas = try Canvas.init(std.testing.allocator, 320, 256);
    defer canvas.deinit();
    var scene = ScenePanel{};
    var asset = AssetPanel{};
    var input_panel = InputPanel{};
    var metrics_panel = MetricsPanel{};
    try scene.panel().draw(scene.panel().context, &canvas);
    try asset.panel().draw(asset.panel().context, &canvas);
    try input_panel.panel().draw(input_panel.panel().context, &canvas);
    try metrics_panel.panel().draw(metrics_panel.panel().context, &canvas);
    const hash = test_support.canvasHash(canvas);
    try std.testing.expect(hash != 0);
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

test "inspector panels match representative runtime state" {
    const test_support = @import("test_support.zig");
    const source =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{
        \\        .{ .id = "camera", .name = "Camera", .components = .{ .{ .kind = "camera" } }, .references = .{} },
        \\        .{ .id = "player", .name = "Player", .binding = "player", .components = .{ .{ .kind = "sprite" } }, .references = .{ .{ .name = "target", .target = "camera" } } },
        \\    },
        \\}
    ;
    const Callback = struct {
        fn load(_: *anyopaque, _: *const scene_runtime.Runtime, _: @import("ecs.zig").Entity, _: @import("scene.zig").Entity) !void {}
    };
    var world = @import("ecs.zig").World.init(std.testing.allocator);
    defer world.deinit();
    var diagnostic = scene_runtime.Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    var callback: u8 = 0;
    var runtime = try scene_runtime.loadSource(std.testing.allocator, &world, source, &.{.{ .name = "player", .context = &callback, .on_load = Callback.load }}, &diagnostic);
    defer {
        runtime.unload() catch unreachable;
        runtime.deinit();
    }
    var store = assets.AssetStore.init(std.testing.allocator, std.fs.cwd());
    defer store.deinit();
    const text = try store.loadText("README.md");
    var state = input.Input{};
    state.set(.action, true);
    state.setPointerPosition(.{ .x = 10, .y = 20 }, .{ .x = 20, .y = 40 }, .{ .x = 5, .y = 10 });
    var action_map = try actions.Map.init(std.testing.allocator, &.{.{ .name = "jump", .binding = .{ .key = .action } }});
    defer action_map.deinit();
    action_map.update(state);
    const resources = [_]Resource{
        .{ .name = "readme", .handle = .{ .text = text } },
        .{ .name = "missing", .handle = .{ .text = .{ .index = 99, .generation = 1 } } },
    };
    var scene = ScenePanel{ .runtime = &runtime };
    var asset = AssetPanel{ .store = &store, .resources = &resources };
    var input_panel = InputPanel{ .state = &state, .action_map = &action_map };
    var canvas = try Canvas.init(std.testing.allocator, 320, 256);
    defer canvas.deinit();
    canvas.clear(Color.rgb(14, 18, 24));
    try scene.panel().draw(scene.panel().context, &canvas);
    try asset.panel().draw(asset.panel().context, &canvas);
    try input_panel.panel().draw(input_panel.panel().context, &canvas);
    const fixture = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/inspector/representative.png", 1024 * 1024);
    defer std.testing.allocator.free(fixture);
    var expected = try @import("image.zig").Image.decodePng(std.testing.allocator, fixture);
    defer expected.deinit();
    try test_support.assertGolden(std.testing.allocator, canvas, expected, .{ .expected_hash = 0x47457b9ec6f65bdf, .diagnostics_path = "zig-out/inspector" });
    try std.testing.expectEqualStrings("live", entityState(&runtime, "player"));
    try std.testing.expectEqualStrings("ready", resourceState(&store, .{ .text = text }));
    try std.testing.expectEqualStrings("stale", resourceState(&store, .{ .text = .{ .index = 99, .generation = 1 } }));
    try std.testing.expectEqual(@as(f32, 1), action_map.value(state, "game", "jump"));
}
