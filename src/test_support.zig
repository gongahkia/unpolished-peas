const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const diagnostics = @import("diagnostics.zig");
const Image = @import("image.zig").Image;
const Input = @import("input.zig").Input;
const input_replay = @import("input_replay.zig");
const render = @import("render.zig");

pub const TempProject = struct { // owns a temporary project directory and its absolute path; call deinit once.
    allocator: std.mem.Allocator,
    temp: std.testing.TmpDir,
    path: []u8,

    pub fn init(allocator: std.mem.Allocator) !TempProject {
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const root = try temp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(root);
        try temp.dir.makePath("project");
        const path = try std.fs.path.join(allocator, &.{ root, "project" });
        return .{ .allocator = allocator, .temp = temp, .path = path };
    }

    pub fn deinit(self: *TempProject) void {
        self.temp.cleanup();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn write(self: *TempProject, relative_path: []const u8, contents: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ "project", relative_path });
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.temp.dir.makePath(parent);
        try self.temp.dir.writeFile(.{ .sub_path = path, .data = contents });
    }
};

pub const Clock = struct {
    now_ms: u64 = 0,

    pub fn advance(self: *Clock, milliseconds: u64) void {
        self.now_ms +%= milliseconds;
    }

    pub fn seconds(self: Clock) f32 {
        return @as(f32, @floatFromInt(self.now_ms)) / 1_000;
    }
};

pub const Buttons = struct {
    pub const left: u8 = 1;
    pub const right: u8 = 2;
    pub const up: u8 = 4;
    pub const down: u8 = 8;
    pub const action: u8 = 16;
};

pub fn applyTopDownButtons(input: *Input, buttons: u8) void {
    input.set(.left, (buttons & Buttons.left) != 0);
    input.set(.right, (buttons & Buttons.right) != 0);
    input.set(.up, (buttons & Buttons.up) != 0);
    input.set(.down, (buttons & Buttons.down) != 0);
    input.set(.action, (buttons & Buttons.action) != 0);
}

pub fn frameSeconds(fixed_hz: u32) f32 {
    std.debug.assert(fixed_hz > 0);
    return 1 / @as(f32, @floatFromInt(fixed_hz));
}

pub const StateHash = struct {
    value: std.hash.Fnv1a_64 = std.hash.Fnv1a_64.init(),

    pub fn updateValue(self: *StateHash, value: anytype) void {
        var copy = value;
        self.value.update(std.mem.asBytes(&copy));
    }

    pub fn updateBool(self: *StateHash, value: bool) void {
        self.value.update(&.{@intFromBool(value)});
    }

    pub fn finish(self: StateHash) u64 {
        var value = self.value;
        return value.final();
    }
};

pub const GoldenOptions = struct {
    expected_hash: u64,
    diagnostics_path: []const u8,
};

pub const RendererConformance = struct {
    pub const Scenario = enum {
        opaque_rects,
        clipped_rect,
    };

    scenario: Scenario,
    width: u32,
    height: u32,
    commands: render.CommandBuffer,

    const background = Color.rgba(19, 37, 61, 255);
    const first = Color.rgba(1, 2, 3, 255);
    const second = Color.rgba(5, 6, 7, 255);
    const clipped = Color.rgba(13, 17, 23, 255);
    const last = Color.rgba(9, 10, 11, 255);

    pub fn init(allocator: std.mem.Allocator, scenario: Scenario, width: u32, height: u32) !RendererConformance {
        if (width < 4 or height < 3) return error.InvalidConformanceCanvas;
        var value = RendererConformance{
            .scenario = scenario,
            .width = width,
            .height = height,
            .commands = render.CommandBuffer.init(allocator),
        };
        errdefer value.deinit();
        try value.commands.append(.{ .clear = background });
        switch (scenario) {
            .opaque_rects => {
                try value.commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = first } });
                try value.commands.append(.{ .rect = .{ .x = 1, .y = 0, .w = 1, .h = 1, .color = second } });
            },
            .clipped_rect => {
                try value.commands.append(.{ .push_clip = .{ .x = 2, .y = @intCast(height - 2), .w = 1, .h = 1 } });
                try value.commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height), .color = clipped } });
                try value.commands.append(.pop_clip);
            },
        }
        try value.commands.append(.{ .rect = .{ .x = @intCast(width - 1), .y = @intCast(height - 1), .w = 1, .h = 1, .color = last } });
        return value;
    }

    pub fn deinit(self: *RendererConformance) void {
        self.commands.deinit();
        self.* = undefined;
    }

    pub fn commandSlice(self: *const RendererConformance) []const render.Command {
        return self.commands.commands.items;
    }

    pub fn initialCanvas(self: *const RendererConformance, allocator: std.mem.Allocator) !Canvas {
        var canvas = try Canvas.init(allocator, self.width, self.height);
        canvas.clear(background);
        return canvas;
    }

    pub fn referenceCanvas(self: *const RendererConformance, allocator: std.mem.Allocator) !Canvas {
        var canvas = try self.initialCanvas(allocator);
        errdefer canvas.deinit();
        var renderer = render.HeadlessRenderer.init(allocator, &canvas);
        defer renderer.deinit();
        try renderer.backend().submit(self.commandSlice());
        return canvas;
    }

    pub fn expectCapture(self: *const RendererConformance, canvas: *const Canvas) !void {
        if (canvas.width != self.width or canvas.height != self.height) return error.InvalidConformanceCanvas;
        const bottom_right = canvas.get(@intCast(self.width - 1), @intCast(self.height - 1)) orelse return error.InvalidConformanceCanvas;
        try std.testing.expectEqual(last, bottom_right);
        switch (self.scenario) {
            .opaque_rects => {
                try std.testing.expectEqual(first, canvas.get(0, 0).?);
                try std.testing.expectEqual(second, canvas.get(1, 0).?);
                try std.testing.expectEqual(background, canvas.get(2, 1).?);
            },
            .clipped_rect => {
                try std.testing.expectEqual(background, canvas.get(2, 0).?);
                try std.testing.expectEqual(clipped, canvas.get(2, @intCast(self.height - 2)).?);
            },
        }
    }
};

pub fn canvasHash(canvas: Canvas) u64 {
    var hash = StateHash{};
    for (canvas.pixels) |pixel| hash.updateValue(pixel);
    return hash.finish();
}

pub fn assertGolden(allocator: std.mem.Allocator, actual: Canvas, expected: Image, options: GoldenOptions) !void {
    if (canvasHash(actual) == options.expected_hash and actual.width == expected.width and actual.height == expected.height and pixelsEqual(actual.pixels, expected.pixels)) return;
    try writeGoldenDiagnostics(allocator, actual, expected, options.diagnostics_path);
    var buffer: [128]u8 = undefined;
    const log = std.fmt.bufPrint(&buffer, "golden mismatch actual_hash={x} expected_hash={x}\n", .{ canvasHash(actual), options.expected_hash }) catch "golden mismatch\n";
    try diagnostics.capture(allocator, .{ .path = options.diagnostics_path }, .{ .canvas = actual, .log = log });
    return error.GoldenMismatch;
}

pub fn assertReplayHash(allocator: std.mem.Allocator, expected: u64, actual: u64, value: *const input_replay.Replay, diagnostics_path: []const u8) !void {
    if (actual == expected) return;
    var buffer: [128]u8 = undefined;
    const log = std.fmt.bufPrint(&buffer, "replay mismatch actual_hash={x} expected_hash={x}\n", .{ actual, expected }) catch "replay mismatch\n";
    try diagnostics.capture(allocator, .{ .path = diagnostics_path }, .{ .log = log, .replay = value });
    return error.ReplayMismatch;
}

pub fn expectError(expected: anyerror, result: anytype) !void {
    try std.testing.expectError(expected, result);
}

fn pixelsEqual(actual: []const Color, expected: []const Color) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn writeGoldenDiagnostics(allocator: std.mem.Allocator, actual: Canvas, expected: Image, path: []const u8) !void {
    try std.fs.cwd().makePath(path);
    const actual_path = try std.fs.path.join(allocator, &.{ path, "actual.png" });
    defer allocator.free(actual_path);
    try actual.writePngFile(actual_path);

    var expected_canvas = try Canvas.init(allocator, expected.width, expected.height);
    defer expected_canvas.deinit();
    @memcpy(expected_canvas.pixels, expected.pixels);
    const expected_path = try std.fs.path.join(allocator, &.{ path, "expected.png" });
    defer allocator.free(expected_path);
    try expected_canvas.writePngFile(expected_path);

    var diff = try Canvas.init(allocator, @max(actual.width, expected.width), @max(actual.height, expected.height));
    defer diff.deinit();
    for (diff.pixels, 0..) |*pixel, index| {
        const x = index % diff.width;
        const y = index / diff.width;
        const actual_pixel = if (x < actual.width and y < actual.height) actual.pixels[y * actual.width + x] else Color.transparent;
        const expected_pixel = if (x < expected.width and y < expected.height) expected.pixels[y * expected.width + x] else Color.transparent;
        pixel.* = if (std.meta.eql(actual_pixel, expected_pixel)) Color.transparent else Color.rgba(255, 0, 255, 255);
    }
    const diff_path = try std.fs.path.join(allocator, &.{ path, "diff.png" });
    defer allocator.free(diff_path);
    try diff.writePngFile(diff_path);
}

test "test support creates projects and applies deterministic input" {
    var project = try TempProject.init(std.testing.allocator);
    defer project.deinit();
    try project.write("src/main.zig", "pub fn main() void {}\n");
    const source = try project.temp.dir.readFileAlloc(std.testing.allocator, "project/src/main.zig", 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", source);

    var clock = Clock{};
    clock.advance(250);
    try std.testing.expectEqual(@as(f32, 0.25), clock.seconds());

    var input = Input{};
    applyTopDownButtons(&input, Buttons.left | Buttons.action);
    try std.testing.expect(input.isDown(.left));
    try std.testing.expect(input.isDown(.action));
    try std.testing.expect(!input.isDown(.right));
}

test "test support hashes canvases and asserts failures" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    canvas.clear(Color.white);
    var hash = StateHash{};
    hash.updateValue(@as(u32, 7));
    hash.updateBool(true);
    try std.testing.expect(hash.finish() != 0);
    try expectError(error.InvalidCanvasSize, Canvas.init(std.testing.allocator, 0, 1));
    try std.testing.expect(canvasHash(canvas) != 0);
}

test "renderer conformance scenarios submit canonical command slices" {
    const scenarios = [_]RendererConformance.Scenario{ .opaque_rects, .clipped_rect };
    for (scenarios) |scenario_kind| {
        var scenario = try RendererConformance.init(std.testing.allocator, scenario_kind, 4, 3);
        defer scenario.deinit();
        var canvas = try scenario.initialCanvas(std.testing.allocator);
        defer canvas.deinit();
        var renderer = render.HeadlessRenderer.init(std.testing.allocator, &canvas);
        defer renderer.deinit();
        try renderer.backend().submit(scenario.commandSlice());
        try scenario.expectCapture(&canvas);
    }
    try expectError(error.InvalidConformanceCanvas, RendererConformance.init(std.testing.allocator, .opaque_rects, 3, 3));
}

test "test support writes golden mismatch diagnostics" {
    var project = try TempProject.init(std.testing.allocator);
    defer project.deinit();
    var actual = try Canvas.init(std.testing.allocator, 1, 1);
    defer actual.deinit();
    actual.clear(Color.white);
    const pixels = try std.testing.allocator.alloc(Color, 1);
    defer std.testing.allocator.free(pixels);
    pixels[0] = Color.black;
    const expected = Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = pixels };
    try expectError(error.GoldenMismatch, assertGolden(std.testing.allocator, actual, expected, .{ .expected_hash = 0, .diagnostics_path = project.path }));
    var directory = try std.fs.openDirAbsolute(project.path, .{});
    defer directory.close();
    try directory.access("actual.png", .{});
    try directory.access("expected.png", .{});
    try directory.access("diff.png", .{});
    try directory.access("screenshot.png", .{});
    try directory.access("commands.json", .{});
    try directory.access("failure.log", .{});
}

test "test support writes replay mismatch diagnostics" {
    var project = try TempProject.init(std.testing.allocator);
    defer project.deinit();
    var replay = try input_replay.parse(std.testing.allocator, "UPR1 60\n2 1\n");
    defer replay.deinit(std.testing.allocator);
    try expectError(error.ReplayMismatch, assertReplayHash(std.testing.allocator, 1, 2, &replay, project.path));
    var directory = try std.fs.openDirAbsolute(project.path, .{});
    defer directory.close();
    try directory.access("failure.log", .{});
    try directory.access("replay.json", .{});
}
