const std = @import("std");
const actions = @import("actions.zig");
const assets = @import("assets.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const input = @import("input.zig");
const InspectorPanel = @import("inspector.zig").Panel;
const net_channel = @import("net_channel.zig");
const net_fault = @import("net_fault.zig");
const net_session = @import("net_session.zig");
const net_snapshot = @import("net_snapshot.zig");
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
    atlas: assets.AtlasHandle,
    font: assets.FontHandle,
    shader: assets.ShaderAssetHandle,
    tile_map: assets.TileMapHandle,
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

pub const PhysicsState = struct {
    bodies: u32 = 0,
    fixtures: u32 = 0,
    joints: u32 = 0,
    contact_begins: u32 = 0,
    contact_ends: u32 = 0,
    contact_hits: u32 = 0,
    sensor_begins: u32 = 0,
    sensor_ends: u32 = 0,
};

pub const PhysicsPanel = struct {
    state: ?*const PhysicsState = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 5,

    pub fn panel(self: *PhysicsPanel) InspectorPanel {
        return .{ .name = "physics", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *PhysicsPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("BOX2D", .{}, panel_title);
        const state = self.state orelse {
            lines.line("module unavailable", .{}, panel_warning);
            return;
        };
        lines.line("bodies={} fixtures={} joints={}", .{ state.bodies, state.fixtures, state.joints }, panel_text);
        lines.line("contacts +{} -{} hit={}", .{ state.contact_begins, state.contact_ends, state.contact_hits }, panel_text);
        lines.line("sensors +{} -{}", .{ state.sensor_begins, state.sensor_ends }, panel_text);
    }
};

pub const NetworkPanel = struct {
    host: ?*const net_session.Host = null,
    client: ?*const net_session.Client = null,
    channel: ?*const net_channel.Channel = null,
    snapshot_publisher: ?*const net_snapshot.Publisher = null,
    snapshot_client: ?*const net_snapshot.Client = null,
    fault_network: ?*const net_fault.Network = null,
    position: Vec2 = .{ .x = 4, .y = 4 },
    max_rows: usize = 8,

    pub fn panel(self: *NetworkPanel) InspectorPanel {
        return .{ .name = "network", .context = self, .draw = draw };
    }

    fn draw(context: *anyopaque, canvas: *Canvas) !void {
        const self: *NetworkPanel = @ptrCast(@alignCast(context));
        var lines = Lines.init(canvas, self.position, self.max_rows);
        lines.box();
        lines.line("NETWORK", .{}, panel_title);
        if (self.host == null and self.client == null and self.channel == null and self.snapshot_publisher == null and self.snapshot_client == null and self.fault_network == null) {
            lines.line("state unavailable", .{}, panel_warning);
            return;
        }
        if (self.host) |host| lines.line("host={s} peers={} events={}", .{ @tagName(host.role), host.peers.peers.items.len, host.peers.events.items.len }, panel_text);
        if (self.client) |client| lines.line("client={s} sequence={}", .{ @tagName(client.handshake_client.state), client.next_sequence }, panel_text);
        if (self.channel) |channel| lines.line("channel out={} reorder={} recv={}", .{ channel.outgoing.items.len, channel.reordered.items.len, channel.received.items.len }, panel_text);
        if (self.snapshot_publisher) |publisher| lines.line("snapshot pub next={} history={}", .{ publisher.next_id, publisher.history.items.len }, panel_text);
        if (self.snapshot_client) |client| lines.line("snapshot client id={?} recovery={}", .{ client.current_id, client.recovery_required }, if (client.recovery_required) panel_warning else panel_text);
        if (self.fault_network) |network| lines.line("fault now={} flights={}", .{ network.now_ms, network.flights.items.len }, panel_text);
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
        .atlas => |value| if (store.tryAtlas(value)) |_| "ready" else |_| "stale",
        .font => |value| if (store.tryFont(value)) |_| "ready" else |_| "stale",
        .shader => |value| if (store.tryShaderSource(value)) |_| "ready" else |_| "stale",
        .tile_map => |value| if (store.tryTileMap(value)) |_| "ready" else |_| "stale",
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
    var physics_panel = PhysicsPanel{};
    var network_panel = NetworkPanel{};
    try asset.panel().draw(asset.panel().context, &canvas);
    try input_panel.panel().draw(input_panel.panel().context, &canvas);
    try metrics_panel.panel().draw(metrics_panel.panel().context, &canvas);
    try collision_panel.panel().draw(collision_panel.panel().context, &canvas);
    try physics_panel.panel().draw(physics_panel.panel().context, &canvas);
    try network_panel.panel().draw(network_panel.panel().context, &canvas);
    const hash = test_support.canvasHash(canvas);
    try std.testing.expect(hash != 0);
}

test "diagnostic panels render deterministic read-only state" {
    const net_transport = @import("net_transport.zig");
    var collider = tile_collision.TileCollider.init(std.testing.allocator);
    defer collider.deinit();
    try collider.addShape(.{ .solid = .{ .x = 0, .y = 0, .w = 8, .h = 8 } });
    try collider.addShape(.{ .one_way = .{ .x = 8, .y = 0, .w = 8, .h = 8 } });
    const physics = PhysicsState{ .bodies = 2, .fixtures = 3, .joints = 1, .contact_begins = 4, .sensor_ends = 1 };
    var client_endpoint = net_transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var host_endpoint = net_transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer host_endpoint.deinit();
    net_transport.Loopback.pair(&client_endpoint, &host_endpoint);
    var host = try net_session.Host.init(std.testing.allocator, host_endpoint.transport(), .{ .role = .listen });
    defer host.deinit();
    var client = try net_session.Client.init(std.testing.allocator, client_endpoint.transport(), .{});
    var channel = try net_channel.Channel.init(std.testing.allocator, .{ .id = 2 }, .{});
    defer channel.deinit();
    var publisher = try net_snapshot.Publisher.init(std.testing.allocator, .{});
    defer publisher.deinit();
    var snapshot_client = try net_snapshot.Client.init(std.testing.allocator, .{});
    defer snapshot_client.deinit();
    var fault_network = try net_fault.Network.init(std.testing.allocator, .{ .seed = 7 });
    defer fault_network.deinit();
    var collision_panel = CollisionPanel{ .collider = &collider };
    var physics_panel = PhysicsPanel{ .state = &physics };
    var network_panel = NetworkPanel{ .host = &host, .client = &client, .channel = &channel, .snapshot_publisher = &publisher, .snapshot_client = &snapshot_client, .fault_network = &fault_network };
    var first = try Canvas.init(std.testing.allocator, 320, 192);
    defer first.deinit();
    var second = try Canvas.init(std.testing.allocator, 320, 192);
    defer second.deinit();
    try collision_panel.panel().draw(collision_panel.panel().context, &first);
    try physics_panel.panel().draw(physics_panel.panel().context, &first);
    try network_panel.panel().draw(network_panel.panel().context, &first);
    try collision_panel.panel().draw(collision_panel.panel().context, &second);
    try physics_panel.panel().draw(physics_panel.panel().context, &second);
    try network_panel.panel().draw(network_panel.panel().context, &second);
    try std.testing.expectEqual(@import("test_support.zig").canvasHash(first), @import("test_support.zig").canvasHash(second));
    try std.testing.expectEqual(@as(usize, 2), collider.shapes.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.peers.peers.items.len);
    try std.testing.expectEqual(@as(u32, 0), client.next_sequence);
    try std.testing.expectEqual(@as(usize, 0), channel.outgoing.items.len);
    try std.testing.expectEqual(@as(u32, 1), publisher.next_id);
    try std.testing.expect(snapshot_client.current_id == null);
    try std.testing.expectEqual(@as(u64, 0), fault_network.now_ms);
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

test "core inspector panels expose bounded asset map input and frame state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const map = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/topdown.upmap", 256 * 1024);
    defer std.testing.allocator.free(map);
    const image = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(image);
    try tmp.dir.writeFile(.{ .sub_path = "note.txt", .data = "ok" });
    try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = map });
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = image });
    var store = assets.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    _ = try store.loadText("note.txt");
    _ = try store.loadTileMap("topdown.upmap", .{});
    try store.events.append(std.testing.allocator, .{ .path = "topdown.upmap", .status = .failed, .failure_class = .source, .line = 2, .column = 4, .retained_content = true, .message = "invalid map" });

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
    try std.testing.expectEqual(@as(usize, 1), store.stats().tile_maps);
    try std.testing.expectEqual(@as(usize, 1), store.stats().reload_events);
    try std.testing.expectEqual(@as(f32, 1), action_map.value(state, "game", "jump"));
    try std.testing.expectEqual(@as(u64, 8), metrics.frame);
    try std.testing.expectEqual(@as(u32, 4), metrics.resource_churn);
}
