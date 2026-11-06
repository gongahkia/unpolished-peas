//! Portable menu/dialogue: prepare at init, draw without decoding or allocation.
const up = @import("unpolished-peas");
pub const width: u32 = 320;
pub const height: u32 = 180;
const labels = [_][]const u8{ "New game", "Continue", "Settings" };
const pages = [_][]const u8{
    "Zoë: Find the lantern, then meet me by the old bridge.\nBring a warm coat!",
    "The narrow path winds uphill. Watch for the little white flowers.\nI will wait here.",
};

pub const Game = struct {
    assets: ?up.assets.AssetCollection = null,
    font: ?*const up.assets.Font = null,
    title: ?up.assets.Font.TextLayout = null,
    menu: [3]?up.assets.Font.TextLayout = .{null} ** 3,
    dialogue: [2]?up.assets.Font.TextLayout = .{null} ** 2,
    hint: ?up.assets.Font.TextLayout = null,
    selected: u8 = 0,
    page: u8 = 0,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        self.assets = up.assets.AssetCollection.init(allocator);
        errdefer self.deinit(ctx) catch {};
        // Collection pointers are stable even if its registry or Game moves.
        self.font = try self.assets.?.font(@embedFile("assets/fonts/SourceSans3-Regular.otf"), .{ .pixel_height = 14 });
        const font = self.font.?;
        self.title = try font.layoutText(allocator, "Lantern Post", .{ .max_width = 304, .alignment = .center });
        for (labels, &self.menu) |label, *target| target.* = try font.layoutText(allocator, label, .{ .max_width = 100, .alignment = .center, .wrap = .none });
        for (pages, &self.dialogue) |text, *target| target.* = try font.layoutText(allocator, text, .{ .max_width = 156, .line_spacing = 2 });
        self.hint = try font.layoutText(allocator, "UP/DOWN: choose   SPACE: next clue", .{ .max_width = 304, .alignment = .center });
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        // Prepared layouts borrow the font: release them before the collection.
        if (self.title) |*value| value.deinit();
        self.title = null;
        for (&self.menu) |*value| {
            if (value.*) |*layout| layout.deinit();
            value.* = null;
        }
        for (&self.dialogue) |*value| {
            if (value.*) |*layout| layout.deinit();
            value.* = null;
        }
        if (self.hint) |*value| value.deinit();
        self.hint = null;
        if (self.assets) |*assets| assets.deinit();
        self.assets = null;
        self.font = null;
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        if (ctx.input.wasPressed(.down)) self.selected = (self.selected + 1) % 3;
        if (ctx.input.wasPressed(.up)) self.selected = (self.selected + 2) % 3;
        if (ctx.input.wasPressed(.action)) self.page = (self.page + 1) % 2;
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(17, 24, 32));
        self.title.?.draw(canvas, 8, 8, up.core.Color.rgb(239, 211, 144));
        canvas.fillRect(128, 34, 184, 116, up.core.Color.rgb(29, 40, 51));
        for (self.menu, 0..) |entry, index| {
            const y: i32 = 42 + @as(i32, @intCast(index)) * 30;
            if (index == self.selected) canvas.fillRect(8, y - 3, 108, 24, up.core.Color.rgb(53, 79, 80));
            entry.?.draw(canvas, 12, y, up.core.Color.white);
        }
        self.dialogue[self.page].?.draw(canvas, 140, 42, up.core.Color.rgb(222, 231, 235));
        self.hint.?.draw(canvas, 8, 159, up.core.Color.rgb(166, 187, 199));
    }
};
