const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;

pub const Visibility = enum { disabled, hidden, visible };

pub const Panel = struct {
    name: []const u8,
    context: *anyopaque,
    draw: *const fn (context: *anyopaque, canvas: *Canvas) anyerror!void,
};

pub const Logger = struct {
    context: *anyopaque,
    failure: *const fn (context: *anyopaque, panel: []const u8, err: anyerror) void,
};

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    panels: std.ArrayListUnmanaged(Panel) = .{},
    visibility: Visibility,
    selected: usize = 0,
    failures: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) Inspector {
        return .{ .allocator = allocator, .visibility = if (enabled) .visible else .disabled };
    }

    pub fn deinit(self: *Inspector) void {
        self.panels.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Inspector, panel: Panel) !void {
        if (self.visibility == .disabled) return;
        if (panel.name.len == 0) return error.InvalidInspectorPanel;
        for (self.panels.items) |existing| if (std.mem.eql(u8, existing.name, panel.name)) return error.DuplicateInspectorPanel;
        try self.panels.append(self.allocator, panel);
    }

    pub fn setVisible(self: *Inspector, visible: bool) void {
        if (self.visibility != .disabled) self.visibility = if (visible) .visible else .hidden;
    }

    pub fn toggle(self: *Inspector) void {
        if (self.visibility == .visible) self.visibility = .hidden else if (self.visibility == .hidden) self.visibility = .visible;
    }

    pub fn next(self: *Inspector) void {
        if (self.panels.items.len != 0) self.selected = (self.selected + 1) % self.panels.items.len;
    }

    pub fn previous(self: *Inspector) void {
        if (self.panels.items.len != 0) self.selected = if (self.selected == 0) self.panels.items.len - 1 else self.selected - 1;
    }

    pub fn selectedPanel(self: *const Inspector) ?[]const u8 {
        if (self.panels.items.len == 0) return null;
        return self.panels.items[self.selected].name;
    }

    pub fn draw(self: *Inspector, canvas: *Canvas, logger: ?Logger) void {
        if (self.visibility != .visible) return;
        if (self.selected >= self.panels.items.len) self.selected = 0;
        if (self.panels.items.len == 0) return;
        const panel = self.panels.items[self.selected];
        panel.draw(panel.context, canvas) catch |err| {
            self.failures +%= 1;
            if (logger) |value| value.failure(value.context, panel.name, err);
        };
    }
};

test "inspector disabled policy changes neither registration nor rendering" {
    var inspector = Inspector.init(std.testing.allocator, false);
    defer inspector.deinit();
    var calls: u8 = 0;
    try inspector.register(.{ .name = "counter", .context = &calls, .draw = Counter.draw });
    var canvas = try Canvas.init(std.testing.allocator, 8, 8);
    defer canvas.deinit();
    inspector.draw(&canvas, null);
    try std.testing.expectEqual(@as(usize, 0), inspector.panels.items.len);
    try std.testing.expectEqual(@as(u8, 0), calls);
}

test "inspector registers panels explicitly and isolates failures" {
    var inspector = Inspector.init(std.testing.allocator, true);
    defer inspector.deinit();
    var calls: u8 = 0;
    try inspector.register(.{ .name = "counter", .context = &calls, .draw = Counter.draw });
    try std.testing.expectError(error.DuplicateInspectorPanel, inspector.register(.{ .name = "counter", .context = &calls, .draw = Counter.draw }));
    try inspector.register(.{ .name = "failure", .context = &calls, .draw = Counter.fail });
    var logger = Counter{};
    var canvas = try Canvas.init(std.testing.allocator, 8, 8);
    defer canvas.deinit();
    inspector.draw(&canvas, .{ .context = &logger, .failure = Counter.log });
    try std.testing.expectEqual(@as(u8, 1), calls);
    try std.testing.expectEqual(@as(u32, 0), inspector.failures);
    inspector.next();
    inspector.draw(&canvas, .{ .context = &logger, .failure = Counter.log });
    try std.testing.expectEqual(@as(u32, 1), inspector.failures);
    try std.testing.expectEqual(@as(u8, 1), logger.logged);
    inspector.toggle();
    inspector.draw(&canvas, null);
    try std.testing.expectEqual(@as(u8, 1), calls);
}

test "inspector navigates selected panels" {
    var inspector = Inspector.init(std.testing.allocator, true);
    defer inspector.deinit();
    var calls: u8 = 0;
    try inspector.register(.{ .name = "first", .context = &calls, .draw = Counter.draw });
    try inspector.register(.{ .name = "second", .context = &calls, .draw = Counter.draw });
    try std.testing.expectEqualStrings("first", inspector.selectedPanel().?);
    inspector.next();
    try std.testing.expectEqualStrings("second", inspector.selectedPanel().?);
    inspector.previous();
    try std.testing.expectEqualStrings("first", inspector.selectedPanel().?);
}

const Counter = struct {
    logged: u8 = 0,

    fn draw(context: *anyopaque, canvas: *Canvas) anyerror!void {
        const calls: *u8 = @ptrCast(@alignCast(context));
        calls.* += 1;
        canvas.fillRect(0, 0, 1, 1, .white);
    }

    fn fail(_: *anyopaque, _: *Canvas) anyerror!void {
        return error.PanelFailed;
    }

    fn log(context: *anyopaque, _: []const u8, _: anyerror) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.logged += 1;
    }
};
