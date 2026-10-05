const std = @import("std");

/// Private, opt-in runtime diagnostics shared by the native host and its
/// developer overlay. It deliberately contains only bounded value data: no
/// command traces, allocator ownership, or backend resource handles.
pub const rolling_window_frames: u32 = 120;

pub const Capability = enum {
    unavailable,
    ready,
};

pub const Timings = struct {
    /// CPU wall-clock work done by fixed update callbacks during a presentation
    /// frame. This may contain zero or many fixed updates.
    update: Aggregate = .{},
    /// CPU wall-clock work done by the game draw callback.
    draw: Aggregate = .{},
    /// Host-side submission/presentation time. This is not completed GPU time.
    host_present: Aggregate = .{},
    /// Wall-clock duration of one presentation frame.
    frame: Aggregate = .{},
};

pub const Aggregate = struct {
    samples: u32 = 0,
    last_ns: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    pub fn add(self: *Aggregate, elapsed_ns: u64) void {
        self.samples +|= 1;
        self.last_ns = elapsed_ns;
        self.total_ns +|= elapsed_ns;
        self.min_ns = @min(self.min_ns, elapsed_ns);
        self.max_ns = @max(self.max_ns, elapsed_ns);
    }

    pub fn meanNs(self: Aggregate) u64 {
        return if (self.samples == 0) 0 else self.total_ns / self.samples;
    }

    pub fn reset(self: *Aggregate) void {
        self.* = .{};
    }
};

pub const Display = struct {
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    canvas_width: u32 = 0,
    canvas_height: u32 = 0,
    scale_x: f32 = 0,
    scale_y: f32 = 0,
};

pub const Renderer = struct {
    requested: []const u8 = "unavailable",
    selected: []const u8 = "unavailable",
    video_driver: []const u8 = "unavailable",
    shader_path: []const u8 = "unavailable",
    fallback: []const u8 = "unavailable",
    recovery: []const u8 = "none",
};

/// Cheap queue/submission values that the renderer already owns. `commands`
/// is the native RenderCommand queue; it is not a CanvasTrace command count.
pub const RenderWork = struct {
    commands: u32 = 0,
    sprite_draws: u32 = 0,
    sprite_batches: u32 = 0,
    material_sprites: u32 = 0,
    particle_instances: u32 = 0,
    particle_batches: u32 = 0,
    post_passes: u32 = 0,
};

pub const Capabilities = struct {
    audio: Capability = .unavailable,
    save: Capability = .unavailable,
};

/// Bounded developer-only authored-asset reload state. This is local
/// diagnostic metadata, not game state or a stable serialization contract.
pub const AssetReload = struct {
    enabled: bool = false,
    registered: u32 = 0,
    reloads_total: u32 = 0,
    reload_failures: u32 = 0,
    last_asset: []const u8 = "",
    last_result: []const u8 = "none",
};

/// A completed presentation-frame snapshot. The native overlay intentionally
/// shows the last completed snapshot so host presentation timing is complete
/// before it is displayed on the next frame.
pub const Snapshot = struct {
    presentation_frame: u64 = 0,
    simulation_tick: u64 = 0,
    fixed_hz: u32 = 0,
    updates_this_frame: u32 = 0,
    simulation_seed: ?u64 = null,
    fps: f64 = 0,
    timings: Timings = .{},
    display: Display = .{},
    renderer: Renderer = .{},
    work: RenderWork = .{},
    capabilities: Capabilities = .{},
    asset_reload: AssetReload = .{},
};

pub const FrameInfo = struct {
    presentation_frame: u64,
    simulation_tick: u64,
    fixed_hz: u32,
    updates_this_frame: u32,
    simulation_seed: ?u64,
    display: Display,
    renderer: Renderer,
    work: RenderWork,
    capabilities: Capabilities,
    asset_reload: AssetReload = .{},
};

/// Fixed-size, opt-in collector. When disabled all methods avoid clocks and
/// counter aggregation; callers may still pass it through their normal host
/// lifecycle without affecting production rendering.
pub const Collector = struct {
    enabled: bool,
    frames_in_window: u32 = 0,
    frame_started_ns: u64 = 0,
    update_this_frame_ns: u64 = 0,
    draw_this_frame_ns: u64 = 0,
    present_this_frame_ns: u64 = 0,
    timings: Timings = .{},
    snapshot: Snapshot = .{},

    pub fn init(enabled: bool) Collector {
        return .{ .enabled = enabled };
    }

    pub fn beginFrame(self: *Collector) void {
        if (!self.enabled) return;
        if (self.frames_in_window == rolling_window_frames) self.resetWindow();
        self.frame_started_ns = nowNs();
        self.update_this_frame_ns = 0;
        self.draw_this_frame_ns = 0;
        self.present_this_frame_ns = 0;
    }

    pub fn start(self: Collector) u64 {
        return if (self.enabled) nowNs() else 0;
    }

    pub fn recordUpdate(self: *Collector, started_ns: u64) void {
        if (self.enabled) self.update_this_frame_ns +|= nowNs() -| started_ns;
    }

    pub fn recordDraw(self: *Collector, started_ns: u64) void {
        if (self.enabled) self.draw_this_frame_ns +|= nowNs() -| started_ns;
    }

    pub fn recordPresent(self: *Collector, started_ns: u64) void {
        if (self.enabled) self.present_this_frame_ns +|= nowNs() -| started_ns;
    }

    pub fn finish(self: *Collector, info: FrameInfo) Snapshot {
        if (!self.enabled) return self.snapshot;
        return self.finishWithFrameDuration(info, nowNs() -| self.frame_started_ns);
    }

    /// Allows deterministic unit tests to verify aggregation without asserting
    /// any host wall-clock duration.
    pub fn finishWithFrameDuration(self: *Collector, info: FrameInfo, frame_ns: u64) Snapshot {
        if (!self.enabled) return self.snapshot;
        self.timings.update.add(self.update_this_frame_ns);
        self.timings.draw.add(self.draw_this_frame_ns);
        self.timings.host_present.add(self.present_this_frame_ns);
        self.timings.frame.add(frame_ns);
        self.frames_in_window +|= 1;
        const mean_frame_ns = self.timings.frame.meanNs();
        self.snapshot = .{
            .presentation_frame = info.presentation_frame,
            .simulation_tick = info.simulation_tick,
            .fixed_hz = info.fixed_hz,
            .updates_this_frame = info.updates_this_frame,
            .simulation_seed = info.simulation_seed,
            .fps = if (mean_frame_ns == 0) 0 else @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(mean_frame_ns)),
            .timings = self.timings,
            .display = info.display,
            .renderer = info.renderer,
            .work = info.work,
            .capabilities = info.capabilities,
            .asset_reload = info.asset_reload,
        };
        return self.snapshot;
    }

    pub fn resetWindow(self: *Collector) void {
        self.frames_in_window = 0;
        self.timings = .{};
    }
};

pub const OverlayLine = enum {
    header,
    timing,
    display,
    renderer,
    work,
    capabilities,
};

/// Formats bounded, deterministic overlay text from a snapshot. It never
/// reads the clock and does not allocate.
pub fn formatOverlayLine(buffer: []u8, snapshot: Snapshot, line: OverlayLine) ![]const u8 {
    return switch (line) {
        .header => if (snapshot.simulation_seed) |seed|
            std.fmt.bufPrint(buffer, "PEAS DEV {d:.1}FPS T{d} U{d} S{d}", .{ snapshot.fps, snapshot.simulation_tick, snapshot.updates_this_frame, seed })
        else
            std.fmt.bufPrint(buffer, "PEAS DEV {d:.1}FPS T{d} U{d}", .{ snapshot.fps, snapshot.simulation_tick, snapshot.updates_this_frame }),
        .timing => std.fmt.bufPrint(buffer, "UPD {d:.2} DRW {d:.2} PRE {d:.2}ms", .{ nsToMs(snapshot.timings.update.meanNs()), nsToMs(snapshot.timings.draw.meanNs()), nsToMs(snapshot.timings.host_present.meanNs()) }),
        .display => std.fmt.bufPrint(buffer, "CAN {d}x{d} FB {d}x{d} @{d:.2}x", .{ snapshot.display.canvas_width, snapshot.display.canvas_height, snapshot.display.framebuffer_width, snapshot.display.framebuffer_height, snapshot.display.scale_x }),
        .renderer => std.fmt.bufPrint(buffer, "R {s}/{s} {s} REC {s}", .{ snapshot.renderer.selected, snapshot.renderer.video_driver, snapshot.renderer.shader_path, snapshot.renderer.recovery }),
        .work => std.fmt.bufPrint(buffer, "CMD {d} SPR {d}/{d} M{d} P{d}/{d} X{d}", .{ snapshot.work.commands, snapshot.work.sprite_draws, snapshot.work.sprite_batches, snapshot.work.material_sprites, snapshot.work.particle_instances, snapshot.work.particle_batches, snapshot.work.post_passes }),
        .capabilities => std.fmt.bufPrint(buffer, "AUDIO {s} SAVE {s} {d}Hz", .{ @tagName(snapshot.capabilities.audio), @tagName(snapshot.capabilities.save), snapshot.fixed_hz }),
    };
}

/// Writes a small local JSON diagnostic object. This is a user-requested
/// snapshot, not telemetry: no network or periodic reporting is involved.
pub fn writeJson(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    try writer.writeAll("{\"presentation_frame\":");
    try writer.print("{d}", .{snapshot.presentation_frame});
    try writer.writeAll(",\"simulation_tick\":");
    try writer.print("{d}", .{snapshot.simulation_tick});
    try writer.writeAll(",\"fixed_hz\":");
    try writer.print("{d}", .{snapshot.fixed_hz});
    try writer.writeAll(",\"updates_this_frame\":");
    try writer.print("{d}", .{snapshot.updates_this_frame});
    try writer.writeAll(",\"simulation_seed\":");
    if (snapshot.simulation_seed) |seed| try writer.print("{d}", .{seed}) else try writer.writeAll("null");
    try writer.writeAll(",\"fps\":");
    try writer.print("{d}", .{snapshot.fps});
    try writer.writeAll(",\"timing_ns\":{\"update_mean\":");
    try writer.print("{d}", .{snapshot.timings.update.meanNs()});
    try writer.writeAll(",\"draw_mean\":");
    try writer.print("{d}", .{snapshot.timings.draw.meanNs()});
    try writer.writeAll(",\"host_present_mean\":");
    try writer.print("{d}", .{snapshot.timings.host_present.meanNs()});
    try writer.writeAll("},\"renderer\":{\"requested\":");
    try std.json.Stringify.value(snapshot.renderer.requested, .{}, writer);
    try writer.writeAll(",\"selected\":");
    try std.json.Stringify.value(snapshot.renderer.selected, .{}, writer);
    try writer.writeAll(",\"video_driver\":");
    try std.json.Stringify.value(snapshot.renderer.video_driver, .{}, writer);
    try writer.writeAll(",\"shader_path\":");
    try std.json.Stringify.value(snapshot.renderer.shader_path, .{}, writer);
    try writer.writeAll(",\"fallback\":");
    try std.json.Stringify.value(snapshot.renderer.fallback, .{}, writer);
    try writer.writeAll(",\"recovery\":");
    try std.json.Stringify.value(snapshot.renderer.recovery, .{}, writer);
    try writer.writeAll("},\"display\":{\"logical\":[");
    try writer.print("{d},{d}", .{ snapshot.display.logical_width, snapshot.display.logical_height });
    try writer.writeAll("],\"framebuffer\":[");
    try writer.print("{d},{d}", .{ snapshot.display.framebuffer_width, snapshot.display.framebuffer_height });
    try writer.writeAll("],\"canvas\":[");
    try writer.print("{d},{d}", .{ snapshot.display.canvas_width, snapshot.display.canvas_height });
    try writer.writeAll("],\"scale\":[");
    try writer.print("{d},{d}", .{ snapshot.display.scale_x, snapshot.display.scale_y });
    try writer.writeAll("]},\"work\":{\"commands\":");
    try writer.print("{d}", .{snapshot.work.commands});
    try writer.writeAll(",\"sprite_draws\":");
    try writer.print("{d}", .{snapshot.work.sprite_draws});
    try writer.writeAll(",\"sprite_batches\":");
    try writer.print("{d}", .{snapshot.work.sprite_batches});
    try writer.writeAll(",\"material_sprites\":");
    try writer.print("{d}", .{snapshot.work.material_sprites});
    try writer.writeAll(",\"particle_instances\":");
    try writer.print("{d}", .{snapshot.work.particle_instances});
    try writer.writeAll(",\"particle_batches\":");
    try writer.print("{d}", .{snapshot.work.particle_batches});
    try writer.writeAll(",\"post_passes\":");
    try writer.print("{d}", .{snapshot.work.post_passes});
    try writer.writeAll("},\"capabilities\":{\"audio\":");
    try std.json.Stringify.value(@tagName(snapshot.capabilities.audio), .{}, writer);
    try writer.writeAll(",\"save\":");
    try std.json.Stringify.value(@tagName(snapshot.capabilities.save), .{}, writer);
    try writer.writeAll("},\"asset_reload\":{\"enabled\":");
    try writer.print("{}", .{snapshot.asset_reload.enabled});
    try writer.writeAll(",\"registered\":");
    try writer.print("{d}", .{snapshot.asset_reload.registered});
    try writer.writeAll(",\"reloads_total\":");
    try writer.print("{d}", .{snapshot.asset_reload.reloads_total});
    try writer.writeAll(",\"reload_failures\":");
    try writer.print("{d}", .{snapshot.asset_reload.reload_failures});
    try writer.writeAll(",\"last_asset\":");
    try std.json.Stringify.value(snapshot.asset_reload.last_asset, .{}, writer);
    try writer.writeAll(",\"last_result\":");
    try std.json.Stringify.value(snapshot.asset_reload.last_result, .{}, writer);
    try writer.writeAll("}}");
}

fn nsToMs(value: u64) f64 {
    return @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn nowNs() u64 {
    return @intCast(@max(@as(i128, 0), std.time.nanoTimestamp()));
}

test "collector aggregates a bounded window without requiring wall clock assertions" {
    var collector = Collector.init(true);
    collector.beginFrame();
    collector.update_this_frame_ns = 3;
    collector.draw_this_frame_ns = 5;
    collector.present_this_frame_ns = 7;
    const first = collector.finishWithFrameDuration(.{
        .presentation_frame = 4,
        .simulation_tick = 12,
        .fixed_hz = 60,
        .updates_this_frame = 2,
        .simulation_seed = 42,
        .display = .{ .canvas_width = 160, .canvas_height = 90 },
        .renderer = .{ .selected = "sdl_gpu", .video_driver = "wayland", .shader_path = "spirv" },
        .work = .{ .commands = 3, .sprite_draws = 2, .sprite_batches = 1 },
        .capabilities = .{ .audio = .ready, .save = .ready },
    }, 20);
    try std.testing.expectEqual(@as(u64, 3), first.timings.update.meanNs());
    try std.testing.expectEqual(@as(u64, 5), first.timings.draw.meanNs());
    try std.testing.expectEqual(@as(u64, 7), first.timings.host_present.meanNs());
    try std.testing.expectEqual(@as(u64, 20), first.timings.frame.meanNs());
    try std.testing.expect(first.fps > 0);
    var line: [160]u8 = undefined;
    const header = try formatOverlayLine(&line, first, .header);
    try std.testing.expect(std.mem.indexOf(u8, header, "S42") != null);
    const timing = try formatOverlayLine(&line, first, .timing);
    try std.testing.expect(std.mem.indexOf(u8, timing, "PRE") != null);
}

test "disabled collector does not create timing samples" {
    var collector = Collector.init(false);
    collector.beginFrame();
    const started = collector.start();
    collector.recordUpdate(started);
    const snapshot = collector.finish(.{
        .presentation_frame = 1,
        .simulation_tick = 0,
        .fixed_hz = 60,
        .updates_this_frame = 0,
        .simulation_seed = null,
        .display = .{},
        .renderer = .{},
        .work = .{},
        .capabilities = .{},
    });
    try std.testing.expectEqual(@as(u32, 0), snapshot.timings.frame.samples);
    try std.testing.expectEqual(@as(u64, 0), started);
}

test "diagnostic JSON is local structured data with host present terminology" {
    var bytes: [2048]u8 = undefined;
    var stream = std.Io.Writer.fixed(&bytes);
    try writeJson(&stream, .{ .simulation_seed = 42, .renderer = .{ .selected = "sdl_gpu", .fallback = "not_needed", .recovery = "none" }, .asset_reload = .{ .enabled = true, .registered = 2, .reloads_total = 4, .last_asset = "sprite.png", .last_result = "changed" } });
    const output = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "host_present_mean") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "gpu_time") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"simulation_seed\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"fallback\":\"not_needed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"asset_reload\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("renderer") != null);
}
