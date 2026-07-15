const std = @import("std");
const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");

const actions = [_]up.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "diagnostics", .binding = .{ .key = .debug } },
};

const Move = struct {
    moved: bool = false,
    blocked: bool = false,
};

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "external animation gameplay",
        .organization = "fixture",
        .application = "external-animation-gameplay",
        .width = 96,
        .height = 64,
        .scale = 4,
        .fixed_hz = 60,
        .max_frames = 2,
        .actions = &actions,
        .clear_color = up.Color.rgb(12, 18, 28),
    };

    allocator: std.mem.Allocator,
    atlas: *up.Atlas,
    animation: up.AnimationPlayer,
    blip: up.Sound,
    player: up.Rect = .{ .x = 8, .y = 28, .w = 4, .h = 4 },
    obstacle: up.Rect = .{ .x = 32, .y = 20, .w = 6, .h = 24 },
    camera: up.Camera2D = .{ .position = .{ .x = 32, .y = 32 } },

    pub fn init(ctx: *sdl.Context) !Game {
        return initResources(ctx.allocator);
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.deinitResources();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const timer = ctx.profile(.callback);
        defer timer.end();
        const move = self.advance(ctx.actions.*, ctx.input.*, ctx.dt);
        if (move.moved) _ = try ctx.audio.playSound(&self.blip, .{ .volume = 0.15 });
        if (diagnosticsRequested(ctx.actions.*, ctx.input.*)) {
            ctx.captureFrame();
            try ctx.exportCpuTrace();
        }
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        const camera = ctx.camera(&self.camera);
        camera.fillRect(self.obstacle, up.Color.rgb(115, 142, 170));
        camera.drawAtlasFrame(self.atlas.*, self.animation.frame(), .{ .x = self.player.x, .y = self.player.y }, .{ .scale = 2 });
        ctx.text("ARROWS MOVE  F3 DIAGNOSTICS", 2, 2, up.Color.white);
    }

    fn initResources(allocator: std.mem.Allocator) !Game {
        const atlas = try allocator.create(up.Atlas);
        errdefer allocator.destroy(atlas);
        atlas.* = try initAtlas(allocator);
        errdefer atlas.deinit();
        var blip = try initSound(allocator);
        errdefer blip.deinit();
        const animation = up.AnimationPlayer.init(atlas, atlas.findAnimation("walk") orelse return error.MissingAtlasAnimation);
        return .{ .allocator = allocator, .atlas = atlas, .animation = animation, .blip = blip };
    }

    fn deinitResources(self: *Game) void {
        self.blip.deinit();
        self.atlas.deinit();
        self.allocator.destroy(self.atlas);
        self.* = undefined;
    }

    fn advance(self: *Game, bindings: up.ActionMap, input: up.Input, dt: f32) Move {
        const direction = up.Vec2{ .x = bindings.value(input, "game", "right") - bindings.value(input, "game", "left") };
        const delta = direction.scale(48 * dt);
        if (delta.lenSq() == 0) return .{};
        if (up.collision.sweepRect(self.player, delta, self.obstacle)) |hit| {
            const fraction = @max(0, hit.fraction - 0.001);
            self.player.x += delta.x * fraction;
            self.player.y += delta.y * fraction;
            if (fraction > 0) self.animation.update(dt);
            return .{ .moved = fraction > 0, .blocked = true };
        }
        self.player.x += delta.x;
        self.player.y += delta.y;
        self.animation.update(dt);
        return .{ .moved = true };
    }
};

fn diagnosticsRequested(bindings: up.ActionMap, input: up.Input) bool {
    return bindings.value(input, "game", "diagnostics") > 0;
}

fn initAtlas(allocator: std.mem.Allocator) !up.Atlas {
    const pixels = try allocator.dupe(up.Color, &.{
        up.Color.rgb(255, 198, 74), up.Color.rgb(255, 198, 74), up.Color.rgb(113, 232, 162), up.Color.rgb(113, 232, 162),
        up.Color.rgb(255, 198, 74), up.Color.rgb(255, 198, 74), up.Color.rgb(113, 232, 162), up.Color.rgb(113, 232, 162),
    });
    errdefer allocator.free(pixels);
    const image_path = try allocator.dupe(u8, "generated-atlas");
    errdefer allocator.free(image_path);
    var frames = try allocator.alloc(up.AtlasFrame, 2);
    var initialized_frames: usize = 0;
    errdefer {
        for (frames[0..initialized_frames]) |frame| allocator.free(frame.name);
        allocator.free(frames);
    }
    frames[0] = .{ .name = try allocator.dupe(u8, "walk-0"), .x = 0, .y = 0, .w = 2, .h = 2, .source_w = 2, .source_h = 2, .offset_x = 0, .offset_y = 0, .duration = 0.1 };
    initialized_frames += 1;
    frames[1] = .{ .name = try allocator.dupe(u8, "walk-1"), .x = 2, .y = 0, .w = 2, .h = 2, .source_w = 2, .source_h = 2, .offset_x = 0, .offset_y = 0, .duration = 0.1 };
    initialized_frames += 1;
    var animations = try allocator.alloc(up.Animation, 1);
    var initialized_animations: usize = 0;
    errdefer {
        for (animations[0..initialized_animations]) |animation| {
            allocator.free(animation.name);
            allocator.free(animation.frames);
        }
        allocator.free(animations);
    }
    const animation_frames = try allocator.dupe(up.AnimationFrame, &.{ .{ .frame = .{ .index = 0 }, .duration = 0.1 }, .{ .frame = .{ .index = 1 }, .duration = 0.1 } });
    errdefer allocator.free(animation_frames);
    const animation_name = try allocator.dupe(u8, "walk");
    errdefer allocator.free(animation_name);
    animations[0] = .{ .name = animation_name, .frames = animation_frames };
    initialized_animations += 1;
    return .{
        .allocator = allocator,
        .image = .{ .allocator = allocator, .width = 4, .height = 2, .pixels = pixels },
        .image_path = image_path,
        .frames = frames,
        .animations = animations,
    };
}

fn initSound(allocator: std.mem.Allocator) !up.Sound {
    const frames = try allocator.dupe(up.AudioSample, &.{ .{ .left = 0.2, .right = 0.2 }, .{ .left = -0.2, .right = -0.2 } });
    return .{ .allocator = allocator, .sample_rate = 48_000, .frames = frames };
}

pub fn main() !void {
    try sdl.playGame(Game);
}

test "external animation game advances frames, plays audio, prevents collision, and exposes diagnostics" {
    var game = try Game.initResources(std.testing.allocator);
    defer game.deinitResources();
    const bindings = up.ActionMap{ .actions = &actions };
    var input = up.Input{};
    input.set(.right, true);
    const free_move = game.advance(bindings, input, 0.11);
    try std.testing.expect(free_move.moved and !free_move.blocked);
    try std.testing.expectEqual(@as(usize, 1), game.animation.frame().index);
    var mixer = try up.AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    _ = try mixer.playSound(&game.blip, .{});
    var mixed: [2]up.AudioSample = undefined;
    try mixer.mix(&mixed);
    try std.testing.expect(mixed[0].left != 0);
    const blocked_move = game.advance(bindings, input, 2);
    try std.testing.expect(blocked_move.blocked);
    try std.testing.expect(!up.Rect.intersects(game.player, game.obstacle));
    input.set(.debug, true);
    try std.testing.expect(diagnosticsRequested(bindings, input));
}
