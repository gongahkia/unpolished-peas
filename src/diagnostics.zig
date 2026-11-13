const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const profiler = @import("profiler.zig");
const render = @import("render.zig");
const replay = @import("input_replay.zig");
const runtime_log = @import("runtime_log.zig");
const incident_marker = ".peas-incident-v1";
const incident_owner = "unpolished-peas diagnostics 1\n";

pub const schema_version: u32 = 1;

pub const Options = struct {
    path: []const u8,
    max_commands: usize = 256,
    max_text_bytes: usize = 256,
    max_log_bytes: usize = 16 * 1024,
    max_replay_frames: usize = 4096,
    max_bundle_bytes: usize = 64 * 1024 * 1024,
    max_session_bundles: usize = 32,
    max_log_events: usize = 128,
    max_event_bytes: usize = 256 * 1024,
};

pub const LogContext = struct {
    events: []const runtime_log.Event = &.{},
    dropped_events: u64 = 0,
    write_errors: u64 = 0,
    truncated_values: u64 = 0,
    file_rotations: u64 = 0,
    discarded_file_bytes: u64 = 0,
};

pub const Input = struct {
    canvas: ?Canvas = null,
    commands: []const render.Command = &.{},
    profiler: ?*const profiler.Profiler = null,
    log: []const u8 = "",
    replay: ?*const replay.Replay = null,
    environment: ?Environment = null,
    event_log: ?LogContext = null,
};

pub const Environment = struct {
    engine_version: []const u8,
    build_id: []const u8,
    target: []const u8,
    renderer: []const u8,
    driver: []const u8,
    launch_config: []const u8,
    asset_root: []const u8,
    capabilities: []const u8,
};

pub fn capture(allocator: std.mem.Allocator, options: Options, input: Input) !void {
    if (options.path.len == 0) return error.InvalidDiagnosticsPath;
    try std.fs.cwd().makePath(options.path);
    if (input.canvas) |canvas| {
        const path = try artifactPath(allocator, options.path, "screenshot.png");
        defer allocator.free(path);
        try canvas.writePngFile(path);
    }
    try writeCommands(allocator, options, input.commands);
    try writeLog(allocator, options, input.log);
    if (input.event_log) |events| try writeEvents(allocator, options, events);
    if (input.profiler) |value| {
        const path = try artifactPath(allocator, options.path, "trace.json");
        defer allocator.free(path);
        try value.writeTrace(path);
    }
    if (input.replay) |value| try writeReplay(allocator, options, value);
    if (input.environment) |value| try writeEnvironment(allocator, options, value);
    try writeMetadata(allocator, options, input);
    if (try bundleSize(allocator, options.path) > options.max_bundle_bytes) return error.DiagnosticsBundleTooLarge;
}

pub fn captureSession(allocator: std.mem.Allocator, root: []const u8, session_id: u64, failure_id: u64, input: Input) ![]u8 {
    return captureSessionWithOptions(allocator, root, session_id, failure_id, input, .{ .path = "" });
}

pub fn captureSessionWithOptions(allocator: std.mem.Allocator, root: []const u8, session_id: u64, failure_id: u64, input: Input, options: Options) ![]u8 {
    if (root.len == 0) return error.InvalidDiagnosticsPath;
    if (options.max_bundle_bytes == 0 or options.max_session_bundles == 0) return error.InvalidDiagnosticsLimits;
    const name = try std.fmt.allocPrint(allocator, "session-{d}-failure-{d}", .{ session_id, failure_id });
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ root, name });
    errdefer allocator.free(path);
    try std.fs.cwd().makePath(root);
    std.fs.cwd().makeDir(path) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DiagnosticsBundleExists,
        else => return err,
    };
    // The exclusively created directory is ours. A failed capture must not
    // leave a partial incident or remove a pre-existing caller directory.
    errdefer std.fs.cwd().deleteTree(path) catch {};
    var session_options = options;
    session_options.path = path;
    capture(allocator, session_options, input) catch |err| {
        std.fs.cwd().deleteTree(path) catch {};
        return err;
    };
    var directory = try std.fs.cwd().openDir(path, .{});
    defer directory.close();
    try directory.writeFile(.{ .sub_path = incident_marker, .data = incident_owner });
    if (try bundleSize(allocator, path) > options.max_bundle_bytes) return error.DiagnosticsBundleTooLarge;
    try retainSessionBundles(allocator, root, options.max_session_bundles, name);
    return path;
}

const Bundle = struct { name: []u8, session: u64, failure: u64, modified_ns: i128 };

fn retainSessionBundles(allocator: std.mem.Allocator, root: []const u8, maximum: usize, current: []const u8) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var bundles = std.ArrayListUnmanaged(Bundle){};
    defer {
        for (bundles.items) |bundle| allocator.free(bundle.name);
        bundles.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        const parsed = parseBundleName(entry.name) orelse continue;
        if (!try ownedIncident(dir, entry.name)) continue;
        const owned_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(owned_name);
        const info = try dir.statFile(entry.name);
        try bundles.append(allocator, .{ .name = owned_name, .session = parsed.session, .failure = parsed.failure, .modified_ns = info.mtime });
    }
    std.mem.sort(Bundle, bundles.items, {}, lessBundle);
    while (bundles.items.len > maximum) {
        // The just-created incident is always retained, including filesystems
        // with coarse timestamp precision. Session IDs are identities, not time.
        const index: usize = if (std.mem.eql(u8, bundles.items[0].name, current)) 1 else 0;
        const bundle = bundles.orderedRemove(index);
        dir.deleteTree(bundle.name) catch |err| {
            allocator.free(bundle.name);
            return err;
        };
        allocator.free(bundle.name);
    }
}

fn ownedIncident(root: std.fs.Dir, name: []const u8) !bool {
    var dir = try root.openDir(name, .{ .iterate = true, .no_follow = true });
    defer dir.close();
    var marker: [64]u8 = undefined;
    var file = dir.openFile(incident_marker, .{}) catch return false;
    defer file.close();
    const length = try file.readAll(&marker);
    if (!std.mem.eql(u8, marker[0..length], incident_owner)) return false;
    var entries = dir.iterate();
    while (try entries.next()) |entry| {
        if (entry.kind != .file) return false;
        if (!std.mem.eql(u8, entry.name, incident_marker) and
            !std.mem.eql(u8, entry.name, "metadata.json") and
            !std.mem.eql(u8, entry.name, "environment.json") and
            !std.mem.eql(u8, entry.name, "failure.log") and
            !std.mem.eql(u8, entry.name, "events.jsonl") and
            !std.mem.eql(u8, entry.name, "logging.json") and
            !std.mem.eql(u8, entry.name, "commands.json") and
            !std.mem.eql(u8, entry.name, "trace.json") and
            !std.mem.eql(u8, entry.name, "replay.json") and
            !std.mem.eql(u8, entry.name, "screenshot.png")) return false;
    }
    return true;
}

fn parseBundleName(name: []const u8) ?struct { session: u64, failure: u64 } {
    const prefix = "session-";
    const separator = "-failure-";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const split = std.mem.indexOf(u8, name[prefix.len..], separator) orelse return null;
    const session = std.fmt.parseInt(u64, name[prefix.len .. prefix.len + split], 10) catch return null;
    const failure = std.fmt.parseInt(u64, name[prefix.len + split + separator.len ..], 10) catch return null;
    return .{ .session = session, .failure = failure };
}

fn lessBundle(_: void, a: Bundle, b: Bundle) bool {
    if (a.modified_ns != b.modified_ns) return a.modified_ns < b.modified_ns;
    if (a.session != b.session) return a.session < b.session;
    return a.failure < b.failure;
}

fn bundleSize(allocator: std.mem.Allocator, path: []const u8) !usize {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        total = std.math.add(usize, total, (try dir.statFile(entry.path)).size) catch return error.DiagnosticsBundleTooLarge;
    }
    return total;
}

fn writeEnvironment(allocator: std.mem.Allocator, options: Options, value: Environment) !void {
    const path = try artifactPath(allocator, options.path, "environment.json");
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffer: [2048]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    try out.writeAll("{\"version\":1,\"engine_version\":");
    try std.json.Stringify.value(value.engine_version, .{}, out);
    try out.writeAll(",\"build_id\":");
    try std.json.Stringify.value(value.build_id, .{}, out);
    try out.writeAll(",\"target\":");
    try std.json.Stringify.value(value.target, .{}, out);
    try out.writeAll(",\"renderer\":");
    try std.json.Stringify.value(value.renderer, .{}, out);
    try out.writeAll(",\"driver\":");
    try std.json.Stringify.value(value.driver, .{}, out);
    try out.writeAll(",\"launch_config\":");
    try std.json.Stringify.value(value.launch_config, .{}, out);
    try out.writeAll(",\"asset_root\":");
    try std.json.Stringify.value(value.asset_root, .{}, out);
    try out.writeAll(",\"capabilities\":");
    try std.json.Stringify.value(value.capabilities, .{}, out);
    try out.writeAll("}");
    try out.flush();
}

fn writeCommands(allocator: std.mem.Allocator, options: Options, commands: []const render.Command) !void {
    const path = try artifactPath(allocator, options.path, "commands.json");
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    const count = @min(commands.len, options.max_commands);
    try out.writeAll("{\"version\":1,\"count\":");
    try out.print("{d}", .{commands.len});
    try out.writeAll(",\"truncated\":");
    try out.writeAll(if (count != commands.len) "true" else "false");
    try out.writeAll(",\"commands\":[");
    for (commands[0..count], 0..) |command, index| {
        if (index != 0) try out.writeByte(',');
        try writeCommand(out, command, options.max_text_bytes);
    }
    try out.writeAll("]}");
    try out.flush();
}

fn writeCommand(out: *std.Io.Writer, command: render.Command, max_text_bytes: usize) !void {
    switch (command) {
        .begin_frame => |color| try writeColorCommand(out, "begin_frame", color),
        .clear => |color| try writeColorCommand(out, "clear", color),
        .rect => |value| try writeRect(out, "rect", value),
        .stroke_rect => |value| try writeRect(out, "stroke_rect", value),
        .circle => |value| try writeCircle(out, "circle", value),
        .stroke_circle => |value| try writeCircle(out, "stroke_circle", value),
        .line => |value| try writeLine(out, value),
        .triangle => |value| try writeTriangle(out, "triangle", value),
        .stroke_triangle => |value| try writeTriangle(out, "stroke_triangle", value),
        .image => |value| try out.print("{{\"tag\":\"image\",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ value.x, value.y, value.image.width, value.image.height }),
        .text => |value| {
            const text = value.value[0..@min(value.value.len, max_text_bytes)];
            try out.print("{{\"tag\":\"text\",\"x\":{d},\"y\":{d},\"length\":{d},\"truncated\":", .{ value.x, value.y, value.value.len });
            try out.writeAll(if (text.len != value.value.len) "true" else "false");
            try out.writeAll(",\"bytes_hex\":\"");
            try writeHex(out, text);
            try out.writeAll("\",\"color\":");
            try writeColor(out, value.color);
            try out.writeByte('}');
        },
        .push_clip => |value| try out.print("{{\"tag\":\"push_clip\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ value.x, value.y, value.w, value.h }),
        .pop_clip => try out.writeAll("{\"tag\":\"pop_clip\"}"),
        .push_blend => |value| try out.print("{{\"tag\":\"push_blend\",\"mode\":\"{s}\"}}", .{@tagName(value)}),
        .pop_blend => try out.writeAll("{\"tag\":\"pop_blend\"}"),
        .present => |value| try out.print("{{\"tag\":\"present\",\"canvas\":[{d:.6},{d:.6}],\"framebuffer\":[{d:.6},{d:.6}],\"mode\":\"{s}\"}}", .{ value.canvas_size.x, value.canvas_size.y, value.framebuffer_size.x, value.framebuffer_size.y, @tagName(value.mode) }),
    }
}

fn writeColorCommand(out: *std.Io.Writer, tag: []const u8, color: Color) !void {
    try out.print("{{\"tag\":\"{s}\",\"color\":", .{tag});
    try writeColor(out, color);
    try out.writeByte('}');
}

fn writeTriangle(out: *std.Io.Writer, tag: []const u8, value: render.Triangle) !void {
    try out.print("{{\"tag\":\"{s}\",\"a\":[{d:.6},{d:.6}],\"b\":[{d:.6},{d:.6}],\"c\":[{d:.6},{d:.6}],\"color\":", .{ tag, value.a.x, value.a.y, value.b.x, value.b.y, value.c.x, value.c.y });
    try writeColor(out, value.color);
    try out.writeByte('}');
}

fn writeRect(out: *std.Io.Writer, tag: []const u8, value: render.Rect) !void {
    try out.print("{{\"tag\":\"{s}\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"color\":", .{ tag, value.x, value.y, value.w, value.h });
    try writeColor(out, value.color);
    try out.writeByte('}');
}

fn writeCircle(out: *std.Io.Writer, tag: []const u8, value: render.Circle) !void {
    try out.print("{{\"tag\":\"{s}\",\"x\":{d},\"y\":{d},\"radius\":{d},\"color\":", .{ tag, value.x, value.y, value.radius });
    try writeColor(out, value.color);
    try out.writeByte('}');
}

fn writeLine(out: *std.Io.Writer, value: render.Line) !void {
    try out.print("{{\"tag\":\"line\",\"x0\":{d},\"y0\":{d},\"x1\":{d},\"y1\":{d},\"color\":", .{ value.x0, value.y0, value.x1, value.y1 });
    try writeColor(out, value.color);
    try out.writeByte('}');
}

fn writeColor(out: *std.Io.Writer, color: Color) !void {
    try out.print("[{d},{d},{d},{d}]", .{ color.r, color.g, color.b, color.a });
}

fn writeHex(out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| try out.print("{x:0>2}", .{byte});
}

fn writeLog(allocator: std.mem.Allocator, options: Options, log: []const u8) !void {
    const path = try artifactPath(allocator, options.path, "failure.log");
    defer allocator.free(path);
    const count = @min(log.len, options.max_log_bytes);
    const start = log.len - count;
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = log[start..] });
}

fn writeEvents(allocator: std.mem.Allocator, options: Options, context: LogContext) !void {
    // Keep the newest complete JSONL records. Validation bounds each event;
    // the record buffer never exceeds one event's bounded encoded size.
    var record = std.Io.Writer.Allocating.init(allocator);
    defer record.deinit();
    var retained: std.ArrayList(u8) = .empty;
    defer retained.deinit(allocator);
    var kept: usize = 0;
    var dropped = context.dropped_events;
    const first = context.events.len - @min(context.events.len, options.max_log_events);
    dropped +|= first;
    for (context.events[first..]) |event| {
        record.clearRetainingCapacity();
        runtime_log.writeJsonl(&record.writer, event) catch |err| switch (err) {
            // This writer has no I/O sink: WriteFailed means allocation failed.
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        const line = record.written();
        if (line.len > options.max_event_bytes) {
            dropped +|= 1;
            continue;
        }
        while (retained.items.len > options.max_event_bytes - line.len) {
            const end = (std.mem.indexOfScalar(u8, retained.items, '\n') orelse unreachable) + 1;
            std.mem.copyForwards(u8, retained.items[0 .. retained.items.len - end], retained.items[end..]);
            retained.items.len -= end;
            kept -= 1;
            dropped +|= 1;
        }
        try retained.appendSlice(allocator, line);
        kept += 1;
    }
    const events_path = try artifactPath(allocator, options.path, "events.jsonl");
    defer allocator.free(events_path);
    try std.fs.cwd().writeFile(.{ .sub_path = events_path, .data = retained.items });
    const summary_path = try artifactPath(allocator, options.path, "logging.json");
    defer allocator.free(summary_path);
    const summary = try std.json.Stringify.valueAlloc(allocator, .{
        .version = 1,
        .event_schema_version = runtime_log.schema_version,
        .timestamp_unit = "nanoseconds",
        .timestamp_origin = "session_start",
        .retained_events = kept,
        .retained_bytes = retained.items.len,
        .dropped_events = dropped,
        .write_errors = context.write_errors,
        .truncated_values = context.truncated_values,
        .file_rotations = context.file_rotations,
        .discarded_file_bytes = context.discarded_file_bytes,
        .max_events = options.max_log_events,
        .max_bytes = options.max_event_bytes,
    }, .{});
    defer allocator.free(summary);
    try std.fs.cwd().writeFile(.{ .sub_path = summary_path, .data = summary });
}

fn writeReplay(allocator: std.mem.Allocator, options: Options, value: *const replay.Replay) !void {
    const path = try artifactPath(allocator, options.path, "replay.json");
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    const count = @min(value.frames.len, options.max_replay_frames);
    try out.print("{{\"version\":3,\"kind\":\"diagnostic-summary\",\"complete_replay\":false,\"fixed_hz\":{d},\"frame_count\":{d},\"truncated\":{s},\"simulation_seed\":", .{ value.fixed_hz, value.frames.len, if (count != value.frames.len) "true" else "false" });
    if (value.simulation_seed) |seed| {
        // Keep the full `u64` exact in JavaScript JSON consumers.
        try out.print("\"{d}\"", .{seed});
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"rng_algorithm\":");
    if (value.rng_algorithm) |algorithm| {
        try out.print("{d}", .{@intFromEnum(algorithm)});
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"key_down_masks\":[");
    for (value.frames[0..count], 0..) |frame, index| {
        if (index != 0) try out.writeByte(',');
        try out.print("{d}", .{keyMask(frame.down)});
    }
    try out.writeAll("]}");
    try out.flush();
}

fn keyMask(values: anytype) u16 {
    var result: u16 = 0;
    inline for (values, 0..) |value, index| {
        if (value) result |= @as(u16, 1) << @intCast(index);
    }
    return result;
}

fn writeMetadata(allocator: std.mem.Allocator, options: Options, input: Input) !void {
    const path = try artifactPath(allocator, options.path, "metadata.json");
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    const command_count = @min(input.commands.len, options.max_commands);
    const log_count = @min(input.log.len, options.max_log_bytes);
    const replay_frames = if (input.replay) |value| value.frames.len else 0;
    const replay_count = @min(replay_frames, options.max_replay_frames);
    try out.print("{{\"version\":{d},\"limits\":{{\"bundle_bytes\":{d},\"session_bundles\":{d}}},\"screenshot\":{{\"present\":{s},\"format\":\"png\"}},\"commands\":{{\"version\":1,\"count\":{d},\"truncated\":{s}}},\"trace\":{{\"present\":{s},\"format\":\"chrome-trace\"}},\"failure\":{{\"format\":\"text\",\"bytes\":{d},\"truncated\":{s}}},\"replay\":{{\"present\":{s},\"frame_count\":{d},\"truncated\":{s}}},\"environment\":{{\"present\":{s},\"format\":\"json\"}}}}", .{
        schema_version,
        options.max_bundle_bytes,
        options.max_session_bundles,
        if (input.canvas != null) "true" else "false",
        input.commands.len,
        if (command_count != input.commands.len) "true" else "false",
        if (input.profiler != null) "true" else "false",
        log_count,
        if (log_count != input.log.len) "true" else "false",
        if (input.replay != null) "true" else "false",
        replay_frames,
        if (replay_count != replay_frames) "true" else "false",
        if (input.environment != null) "true" else "false",
    });
    try out.flush();
}

fn artifactPath(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, name });
}

test "diagnostics capture deterministic bounded artifacts" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "diagnostics" });
    defer std.testing.allocator.free(path);
    var canvas = try Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();
    canvas.clear(Color.rgb(1, 2, 3));
    const image_pixels = [_]Color{Color.white};
    const image = @import("image.zig").Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = @constCast(&image_pixels) };
    const commands = [_]render.Command{
        .{ .clear = Color.black },
        .{ .text = .{ .value = "hello", .x = 1, .y = 2, .color = Color.white } },
        .{ .image = .{ .image = &image, .x = 3, .y = 4 } },
    };
    var frame_profiler = profiler.Profiler.init(true);
    frame_profiler.beginFrame(3);
    frame_profiler.scope(.draw).end();
    var input_replay = try replay.parse(std.testing.allocator, "UPR1 60\n2 1\n1 4\n");
    defer input_replay.deinit(std.testing.allocator);
    try capture(std.testing.allocator, .{ .path = path, .max_commands = 2, .max_text_bytes = 3, .max_log_bytes = 4, .max_replay_frames = 2 }, .{ .canvas = canvas, .commands = &commands, .profiler = &frame_profiler, .log = "failure-log", .replay = &input_replay, .environment = .{ .engine_version = "1.0.0", .build_id = "abc", .target = "macos", .renderer = "opengl", .driver = "test", .launch_config = "--frames 2", .asset_root = "assets", .capabilities = "audio,storage" } });
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    try dir.access("screenshot.png", .{});
    try dir.access("trace.json", .{});
    const screenshot_bytes = try dir.readFileAlloc(std.testing.allocator, "screenshot.png", 4096);
    defer std.testing.allocator.free(screenshot_bytes);
    var screenshot = try @import("image.zig").Image.decode(std.testing.allocator, screenshot_bytes, .{});
    defer screenshot.deinit();
    try std.testing.expectEqual(Color.rgb(1, 2, 3), screenshot.pixels[0]);
    const command_bytes = try dir.readFileAlloc(std.testing.allocator, "commands.json", 4096);
    defer std.testing.allocator.free(command_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, command_bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("version").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("count").?.integer);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
    const trace_bytes = try dir.readFileAlloc(std.testing.allocator, "trace.json", 4096);
    defer std.testing.allocator.free(trace_bytes);
    var trace = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trace_bytes, .{});
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 2), trace.value.object.get("traceEvents").?.array.items.len);
    const log = try dir.readFileAlloc(std.testing.allocator, "failure.log", 64);
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("-log", log);
    const replay_bytes = try dir.readFileAlloc(std.testing.allocator, "replay.json", 4096);
    defer std.testing.allocator.free(replay_bytes);
    try std.testing.expect(std.mem.indexOf(u8, replay_bytes, "\"truncated\":true") != null);
    const metadata_bytes = try dir.readFileAlloc(std.testing.allocator, "metadata.json", 4096);
    defer std.testing.allocator.free(metadata_bytes);
    var metadata = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, metadata_bytes, .{});
    defer metadata.deinit();
    const root_object = metadata.value.object;
    try std.testing.expectEqual(@as(i64, schema_version), root_object.get("version").?.integer);
    try std.testing.expect(root_object.get("screenshot").?.object.get("present").?.bool);
    try std.testing.expectEqualStrings("png", root_object.get("screenshot").?.object.get("format").?.string);
    try std.testing.expect(root_object.get("commands").?.object.get("truncated").?.bool);
    try std.testing.expect(root_object.get("trace").?.object.get("present").?.bool);
    try std.testing.expectEqual(@as(i64, 4), root_object.get("failure").?.object.get("bytes").?.integer);
    try std.testing.expect(root_object.get("failure").?.object.get("truncated").?.bool);
    try std.testing.expect(root_object.get("replay").?.object.get("truncated").?.bool);
    try std.testing.expect(root_object.get("environment").?.object.get("present").?.bool);
    const environment_bytes = try dir.readFileAlloc(std.testing.allocator, "environment.json", 4096);
    defer std.testing.allocator.free(environment_bytes);
    try std.testing.expect(std.mem.indexOf(u8, environment_bytes, "\"renderer\":\"opengl\"") != null);
}

test "session diagnostics retain newest bounded bundles" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const diagnostics_root = try std.fs.path.join(std.testing.allocator, &.{ root, "sessions" });
    defer std.testing.allocator.free(diagnostics_root);
    const first = try captureSessionWithOptions(std.testing.allocator, diagnostics_root, 1, 1, .{ .log = "first" }, .{ .path = "", .max_session_bundles = 1, .max_bundle_bytes = 4096 });
    defer std.testing.allocator.free(first);
    const second = try captureSessionWithOptions(std.testing.allocator, diagnostics_root, 2, 1, .{ .log = "second" }, .{ .path = "", .max_session_bundles = 1, .max_bundle_bytes = 4096 });
    defer std.testing.allocator.free(second);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(first, .{}));
    try std.fs.cwd().access(second, .{});
    try std.testing.expectError(error.DiagnosticsBundleExists, captureSessionWithOptions(std.testing.allocator, diagnostics_root, 2, 1, .{}, .{ .path = "", .max_session_bundles = 1 }));
    try std.testing.expectError(error.InvalidDiagnosticsLimits, captureSessionWithOptions(std.testing.allocator, diagnostics_root, 3, 1, .{}, .{ .path = "", .max_session_bundles = 0 }));
    try std.testing.expectError(error.DiagnosticsBundleTooLarge, captureSessionWithOptions(std.testing.allocator, diagnostics_root, 3, 1, .{ .log = "too large" }, .{ .path = "", .max_session_bundles = 1, .max_bundle_bytes = 1 }));
    const oversized = try std.fs.path.join(std.testing.allocator, &.{ diagnostics_root, "session-3-failure-1" });
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(oversized, .{}));
}

test "incident retention only removes marked artifacts owned by Peas" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    try temp.dir.makePath("session-0-failure-1");
    try temp.dir.writeFile(.{ .sub_path = "session-0-failure-1/notes.txt", .data = "caller-owned" });
    const first = try captureSessionWithOptions(std.testing.allocator, root, 1, 1, .{}, .{ .path = "", .max_session_bundles = 1 });
    defer std.testing.allocator.free(first);
    // Even a marked directory becomes caller-owned when unknown files appear.
    var dir = try std.fs.cwd().openDir(first, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = "notes.txt", .data = "keep" });
    const second = try captureSessionWithOptions(std.testing.allocator, root, 2, 1, .{}, .{ .path = "", .max_session_bundles = 1 });
    defer std.testing.allocator.free(second);
    try temp.dir.access("session-0-failure-1/notes.txt", .{});
    try dir.access("notes.txt", .{});
    try std.fs.cwd().access(second, .{});
}

test "failure events retain newest complete parseable records and report drops" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const events = [_]runtime_log.Event{
        .{ .timestamp_ns = 1, .session_id = 7, .level = .info, .category = .engine, .message = "first" },
        .{ .timestamp_ns = 2, .session_id = 7, .frame_id = 42, .level = .err, .category = .engine, .message = "last", .fields = &.{.{ .key = "phase", .value = .{ .string = "draw" } }} },
    };
    try capture(std.testing.allocator, .{ .path = root, .max_log_events = 1, .max_event_bytes = 1024 }, .{ .event_log = .{ .events = &events, .dropped_events = 3, .write_errors = 2 } });
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "events.jsonl", 1024);
    defer std.testing.allocator.free(bytes);
    const event = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer event.deinit();
    try std.testing.expectEqualStrings("last", event.value.object.get("message").?.string);
    try std.testing.expectEqual(@as(i64, 42), event.value.object.get("frame_id").?.integer);
    const summary_bytes = try temp.dir.readFileAlloc(std.testing.allocator, "logging.json", 1024);
    defer std.testing.allocator.free(summary_bytes);
    const summary = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, summary_bytes, .{});
    defer summary.deinit();
    try std.testing.expectEqual(@as(i64, 4), summary.value.object.get("dropped_events").?.integer);
    try std.testing.expectEqual(@as(i64, 2), summary.value.object.get("write_errors").?.integer);
    try capture(std.testing.allocator, .{ .path = root, .max_event_bytes = 1 }, .{ .event_log = .{ .events = &events } });
    const empty = try temp.dir.readFileAlloc(std.testing.allocator, "events.jsonl", 1024);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "incident chronology does not depend on random session identity" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const old = try captureSessionWithOptions(std.testing.allocator, root, 999, 8, .{}, .{ .path = "", .max_session_bundles = 1 });
    defer std.testing.allocator.free(old);
    const current = try captureSessionWithOptions(std.testing.allocator, root, 1, 1, .{}, .{ .path = "", .max_session_bundles = 1 });
    defer std.testing.allocator.free(current);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(old, .{}));
    try std.fs.cwd().access(current, .{});
}

fn incidentAllocationFailures(allocator: std.mem.Allocator, root: []const u8) !void {
    const events = [_]runtime_log.Event{.{ .timestamp_ns = 1, .session_id = 7, .level = .err, .category = .engine, .message = "original failure" }};
    const path = try captureSession(allocator, root, 7, 1, .{ .event_log = .{ .events = &events }, .log = "original failure" });
    defer allocator.free(path);
    defer std.fs.cwd().deleteTree(path) catch {};
}

test "incident allocation failure releases ownership and partial output" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    try temp.dir.writeFile(.{ .sub_path = "caller.txt", .data = "keep" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, incidentAllocationFailures, .{root});
    try temp.dir.access("caller.txt", .{});
    try std.testing.expectError(error.FileNotFound, temp.dir.access("session-7-failure-1", .{}));
}
