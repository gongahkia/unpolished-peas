const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const profiler = @import("profiler.zig");
const render = @import("render.zig");
const replay = @import("input_replay.zig");

pub const Options = struct {
    path: []const u8,
    max_commands: usize = 256,
    max_text_bytes: usize = 256,
    max_log_bytes: usize = 16 * 1024,
    max_replay_frames: usize = 4096,
};

pub const Input = struct {
    canvas: ?Canvas = null,
    commands: []const render.Command = &.{},
    profiler: ?*const profiler.Profiler = null,
    log: []const u8 = "",
    replay: ?*const replay.Replay = null,
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
    if (input.profiler) |value| {
        const path = try artifactPath(allocator, options.path, "trace.json");
        defer allocator.free(path);
        try value.writeTrace(path);
    }
    if (input.replay) |value| try writeReplay(allocator, options, value);
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

fn writeReplay(allocator: std.mem.Allocator, options: Options, value: *const replay.Replay) !void {
    const path = try artifactPath(allocator, options.path, "replay.json");
    defer allocator.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    const count = @min(value.frames.len, options.max_replay_frames);
    try out.print("{{\"version\":1,\"fixed_hz\":{d},\"frame_count\":{d},\"truncated\":{s},\"buttons\":[", .{ value.fixed_hz, value.frames.len, if (count != value.frames.len) "true" else "false" });
    for (value.frames[0..count], 0..) |frame, index| {
        if (index != 0) try out.writeByte(',');
        try out.print("{d}", .{frame.buttons});
    }
    try out.writeAll("]}");
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
    try capture(std.testing.allocator, .{ .path = path, .max_commands = 2, .max_text_bytes = 3, .max_log_bytes = 4, .max_replay_frames = 2 }, .{ .canvas = canvas, .commands = &commands, .profiler = &frame_profiler, .log = "failure-log", .replay = &input_replay });
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    try dir.access("screenshot.png", .{});
    try dir.access("trace.json", .{});
    const command_bytes = try dir.readFileAlloc(std.testing.allocator, "commands.json", 4096);
    defer std.testing.allocator.free(command_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, command_bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
    const log = try dir.readFileAlloc(std.testing.allocator, "failure.log", 64);
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("-log", log);
    const replay_bytes = try dir.readFileAlloc(std.testing.allocator, "replay.json", 4096);
    defer std.testing.allocator.free(replay_bytes);
    try std.testing.expect(std.mem.indexOf(u8, replay_bytes, "\"truncated\":true") != null);
}
