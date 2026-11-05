const std = @import("std");
const up = @import("unpolished-peas");

pub const width = 320;
pub const height = 160;
pub const default_seed: u64 = 42;
pub const storage_id = "peas.portable-conformance";
pub const progress_size = 82;
const controls = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .physical_key = .q } },
    .{ .name = "right", .binding = .{ .physical_key = .e } },
    .{ .name = "one", .binding = .{ .physical_key = .digit_1 } },
    .{ .name = "two", .binding = .{ .physical_key = .digit_2 } },
    .{ .name = "collect", .binding = .{ .physical_key = .space } },
};
const frames = [_]up.assets.AtlasFrameSpec{
    .{ .name = "left", .x = 0, .y = 0, .w = 8, .h = 16 },
    .{ .name = "right", .x = 8, .y = 0, .w = 8, .h = 16 },
};
const steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 0 }, .ticks = 6 },
    .{ .frame = .{ .index = 1 }, .ticks = 6 },
};
const clip = up.graphics.SpriteAnimationClip{ .steps = &steps, .mode = .loop };

/// One ordinary portable game. Test wrappers supply inputs and observe state;
/// the game itself imports no SDL, DOM, private engine code, or host globals.
pub const Game = struct {
    assets: ?up.assets.AssetCollection = null,
    actions: ?up.input.ActionMap = null,
    image: ?*const up.assets.Image = null,
    font: ?*const up.assets.Font = null,
    atlas: ?*const up.assets.Atlas = null,
    animation: ?up.graphics.SpriteAnimationPlayer = null,
    effect: ?up.core.Audio.SoundHandle = null,
    score: u32 = 0,
    one: u32 = 0,
    two: u32 = 0,
    x: i32 = 120,
    rebound: bool = false,
    editing: bool = false,
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,
    preedit: [1024]u8 = .{0} ** 1024,
    preedit_len: usize = 0,
    sound_requests: u32 = 0,
    /// Fixture-only failure injection, after real resources have been loaded.
    reject_init: bool = false,
    cleanup_calls: u32 = 0,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        self.assets = up.assets.AssetCollection.init(allocator);
        errdefer self.deinit(ctx) catch unreachable;
        self.actions = try up.input.ActionMap.init(allocator, &controls);
        self.image = try self.assets.?.image(@embedFile("assets/ball.png"), .{});
        self.font = try self.assets.?.font(@embedFile("assets/fonts/Basic-Regular.ttf"), .{ .pixel_height = 12, .atlas_width = 256, .atlas_height = 256 });
        if (self.reject_init) return error.ConformanceInitRejected;
        self.atlas = try self.assets.?.atlas(@embedFile("assets/ball.png"), &frames, .{});
        try clip.validateForAtlas(self.atlas.?);
        self.animation = try up.graphics.SpriteAnimationPlayer.init(&clip);
        self.load(ctx);
        try self.actions.?.rebind("game", "left", .{ .physical_key = if (self.rebound) .r else .q });
        if (ctx.audio) |audio| self.effect = audio.loadWav(@embedFile("assets/blip.wav")) catch null;
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        self.cleanup_calls += 1;
        if (self.actions) |*actions| actions.deinit();
        if (self.assets) |*assets| assets.deinit();
        self.assets = null;
        self.actions = null;
        self.image = null;
        self.font = null;
        self.atlas = null;
        self.animation = null;
        self.effect = null; // Audio owns the loaded resource until host teardown.
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        var changed = false;
        for (ctx.input.extended.eventSlice()) |event| switch (event.kind) {
            .key_down => if (!event.repeat) {
                if (event.key == .f5) {
                    self.rebound = !self.rebound;
                    try self.actions.?.rebind("game", "left", .{ .physical_key = if (self.rebound) .r else .q });
                    changed = true;
                } else if (event.key == .f4) {
                    self.editing = !self.editing;
                    if (!self.editing) self.preedit_len = 0;
                    try ctx.setTextInput(self.editing);
                }
            },
            .text_commit => if (self.editing) {
                self.preedit_len = 0;
                const text = ctx.input.extended.eventText(event);
                if (text.len <= self.name.len - self.name_len) {
                    @memcpy(self.name[self.name_len..][0..text.len], text);
                    self.name_len += text.len;
                    changed = true;
                }
            },
            .composition_update => {
                const text = ctx.input.extended.eventText(event);
                @memcpy(self.preedit[0..text.len], text);
                self.preedit_len = text.len;
            },
            .composition_end, .composition_cancel, .text_stopped => self.preedit_len = 0,
            else => {},
        };
        if (ctx.input.extended.overflow) {
            self.editing = false;
            self.preedit_len = 0;
            try ctx.setTextInput(false);
        }
        const actions = &self.actions.?;
        actions.update(ctx.input.*);
        if (!self.editing) {
            if (actions.isDown("game", "left")) self.x -= 1;
            if (actions.isDown("game", "right")) self.x += 1;
            self.x = std.math.clamp(self.x, 80, 300);
            if (actions.wasPressed("game", "one")) {
                self.one +|= 1;
                self.score +|= 1;
                changed = true;
            }
            if (actions.wasPressed("game", "two")) {
                self.two +|= 1;
                self.score +|= 2;
                changed = true;
            }
            if (actions.wasPressed("game", "collect")) {
                self.score +|= 1;
                self.sound_requests +|= 1;
                if (ctx.audio) |audio| if (self.effect) |effect| {
                    _ = audio.play(effect, .{ .volume = 0.2 }) catch {};
                };
                changed = true;
            }
        }
        self.animation.?.advance(1);
        if (changed) self.save(ctx);
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(14, 18, 24));
        self.font.?.drawText(canvas, "One portable game", 8, 8, up.core.Color.white);
        canvas.drawImage(self.image.?.*, 20, 42);
        canvas.drawAtlasFrame(self.atlas.?.*, self.animation.?.currentFrame(), self.x, 38, .{ .scale = 2 });
        self.font.?.drawText(canvas, self.name[0..self.name_len], 8, 78, up.core.Color.white);
        self.font.?.drawText(canvas, self.preedit[0..self.preedit_len], 8, 96, up.core.Color.rgb(255, 198, 74));
        var label: [64]u8 = undefined;
        canvas.drawText(try std.fmt.bufPrint(&label, "SCORE {d}  1:{d} 2:{d}", .{ self.score, self.one, self.two }), 8, 116, up.core.Color.white);
        canvas.drawText(if (self.rebound) "R/E move F5 rebind F4 name" else "Q/E move F5 rebind F4 name", 8, 132, up.core.Color.white);
        canvas.drawText("1/2 score  SPACE sound + save", 8, 145, up.core.Color.white);
    }

    pub fn progress(self: *const Game) [progress_size]u8 {
        var bytes = [_]u8{0} ** progress_size;
        @memcpy(bytes[0..4], "PCG1");
        std.mem.writeInt(u32, bytes[4..8], self.score, .little);
        std.mem.writeInt(u32, bytes[8..12], self.one, .little);
        std.mem.writeInt(u32, bytes[12..16], self.two, .little);
        bytes[16] = @intFromBool(self.rebound);
        bytes[17] = @intCast(self.name_len);
        @memcpy(bytes[18..][0..self.name_len], self.name[0..self.name_len]);
        return bytes;
    }

    fn save(self: *const Game, ctx: *up.core.GameContext) void {
        const saves = ctx.save_data orelse return;
        saves.write("progress", &self.progress()) catch {};
    }

    fn load(self: *Game, ctx: *up.core.GameContext) void {
        const saves = ctx.save_data orelse return;
        var buffer: [progress_size]u8 = undefined;
        const bytes = saves.read("progress", &buffer) catch return;
        if (bytes.len != progress_size or !std.mem.eql(u8, bytes[0..4], "PCG1") or bytes[16] > 1 or bytes[17] > 64) return;
        const name = bytes[18..][0..bytes[17]];
        if (!std.unicode.utf8ValidateSlice(name)) return;
        self.score = std.mem.readInt(u32, bytes[4..8], .little);
        self.one = std.mem.readInt(u32, bytes[8..12], .little);
        self.two = std.mem.readInt(u32, bytes[12..16], .little);
        self.rebound = bytes[16] == 1;
        self.name_len = name.len;
        @memcpy(self.name[0..name.len], name);
    }
};
