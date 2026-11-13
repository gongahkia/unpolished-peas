//! Prepared static UI copy; numeric HUD values use the allocation-free direct path.
const std = @import("std");
const up = @import("unpolished-peas");
const labels = @import("labels.zig").labels;
const headings = [_][]const u8{ "ASHEN CAUSEWAY", "PAUSED - LANTERN UPGRADES", "THE COAL GROWS COLD", "SETTINGS", "THE BEACON BURNS", "ASHEN CAUSEWAY - CREDITS" };

pub const Typography = struct {
    assets: ?up.assets.AssetCollection = null,
    body: ?*const up.assets.Font = null,
    heading: ?*const up.assets.Font = null,
    layouts: [labels.len]?up.assets.Font.TextLayout = .{null} ** labels.len,
    heading_layouts: [headings.len]?up.assets.Font.TextLayout = .{null} ** headings.len,
    pub fn init(t: *Typography, allocator: std.mem.Allocator) !void {
        t.assets = up.assets.AssetCollection.init(allocator);
        errdefer t.deinit();
        t.body = try t.assets.?.font(@embedFile("assets/fonts/ui.otf"), .{ .pixel_height = 12, .atlas_width = 256, .atlas_height = 256 });
        t.heading = try t.assets.?.font(@embedFile("assets/fonts/ui.otf"), .{ .pixel_height = 18, .atlas_width = 256, .atlas_height = 256 });
        for (labels, &t.layouts) |label, *layout| {
            const font = t.body.?;
            layout.* = try font.layoutText(allocator, label, .{ .wrap = .none });
        }
        for (headings, &t.heading_layouts) |label, *layout| layout.* = try t.heading.?.layoutText(allocator, label, .{ .wrap = .none });
    }
    pub fn deinit(t: *Typography) void {
        for (&t.layouts) |*entry| {
            if (entry.*) |*layout| layout.deinit();
            entry.* = null;
        }
        for (&t.heading_layouts) |*entry| {
            if (entry.*) |*layout| layout.deinit();
            entry.* = null;
        }
        if (t.assets) |*assets| assets.deinit();
        t.assets = null;
        t.body = null;
        t.heading = null;
    }
    pub fn drawHeading(t: *const Typography, c: *up.graphics.Canvas, text: []const u8, x: i32, y: i32, color: up.core.Color) void {
        for (headings, t.heading_layouts) |label, layout| if (std.mem.eql(u8, text, label)) {
            if (layout) |prepared| prepared.draw(c, x, y, color);
            return;
        };
    }
    pub fn draw(t: *const Typography, c: *up.graphics.Canvas, text: []const u8, x: i32, y: i32, color: up.core.Color) void {
        for (labels, t.layouts) |label, layout| if (std.mem.eql(u8, text, label)) {
            if (layout) |prepared| prepared.draw(c, x, y, color);
            return;
        };
        if (t.body) |font| font.drawText(c, text, x, y, color);
    }
};
fn failureWalk(allocator: std.mem.Allocator) !void {
    var t = Typography{};
    try t.init(allocator);
    defer t.deinit();
}
test "prepared typography releases every partial initialization" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failureWalk, .{});
}
test "static copy fits logical width and prepared drawing allocates nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var t = Typography{};
    try t.init(failing.allocator());
    defer t.deinit();
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 480, 270);
    defer canvas.deinit();
    failing.fail_index = failing.alloc_index;
    for (labels, t.layouts) |label, layout| {
        const prepared = layout.?;
        try std.testing.expect(prepared.metrics.width <= 464);
        t.draw(&canvas, label, 8, 8, up.core.Color.white);
    }
    for (t.heading_layouts) |layout| try std.testing.expect(layout.?.metrics.width <= 400);
    t.draw(&canvas, "HP 93/115", 130, 3, up.core.Color.white);
    try std.testing.expect(!failing.has_induced_failure);
}
