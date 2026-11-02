const std = @import("std");
const up = @import("unpolished-peas");
const art = @import("art.zig");
const level = @import("level.zig");
const sounds = @import("sounds.zig");

pub const width: u32 = 160;
pub const height: u32 = 90;
pub const surface_width: u32 = 80;
pub const surface_height: u32 = 45;
pub const default_seed: u64 = 0x4c41_4e54_4552_4e4c;
pub const storage_id = "unpolished-peas.lantern-leap";

const player_width: f32 = 8;
const player_height: f32 = 8;
const gravity: f32 = 520;
const jump_speed: f32 = 178;
const terminal_speed: f32 = 230;
const move_speed: f32 = 70;
const coyote_ticks: u8 = 6;
const respawn_delay_ticks: u8 = 30;

const controls = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "left", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1 } } },
    .{ .name = "left", .binding = .{ .gamepad_button = .dpad_left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "right", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } },
    .{ .name = "right", .binding = .{ .gamepad_button = .dpad_right } },
    .{ .name = "jump", .binding = .{ .key = .action } },
    .{ .name = "jump", .binding = .{ .gamepad_button = .south } },
    .{ .name = "restart", .binding = .{ .key = .start } },
    .{ .name = "restart", .binding = .{ .gamepad_button = .start } },
};

const Player = struct {
    position: up.core.Vec2 = .{ .x = 14, .y = 74 },
    velocity: up.core.Vec2 = .{},
    grounded: bool = false,
    facing_left: bool = false,
    coyote: u8 = 0,
};

/// Lantern Leap deliberately keeps normal platformer state in ordinary Zig
/// values. Peas supplies deterministic input, rendering, assets and hosts;
/// gravity, collision, checkpoints, and level rules stay game owned.
pub const Game = struct {
    allocator: ?std.mem.Allocator = null,
    actions: ?up.input.ActionMap = null,
    surface: ?up.graphics.RenderSurface = null,
    atlas: ?*up.assets.Atlas = null,
    font: ?*up.assets.Font = null,
    player_animation: ?up.graphics.SpriteAnimationPlayer = null,
    player: Player = .{},
    collected: [level.collectible_positions.len]bool = [_]bool{false} ** level.collectible_positions.len,
    checkpoint: usize = 0,
    completed: bool = false,
    dead: bool = false,
    respawn_ticks: u8 = 0,
    best_collectibles: u8 = 0,
    completion_unlocked: bool = false,
    run_ticks: u32 = 0,
    jump_sound: ?up.core.Audio.SoundHandle = null,
    collect_sound: ?up.core.Audio.SoundHandle = null,
    reset_sound: ?up.core.Audio.SoundHandle = null,
    background_music: ?up.core.Audio.MusicHandle = null,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        self.allocator = try ctx.requireAllocator();
        errdefer self.deinit(ctx) catch {};
        self.actions = try up.input.ActionMap.init(self.allocator.?, &controls);
        self.surface = try up.graphics.RenderSurface.init(self.allocator.?, surface_width, surface_height);

        const image = try up.assets.Image.decode(self.allocator.?, art.sprite_sheet_png, .{});
        const atlas = try self.allocator.?.create(up.assets.Atlas);
        errdefer self.allocator.?.destroy(atlas);
        atlas.* = try up.assets.Atlas.init(self.allocator.?, image, "lantern-leap.png", &art.frames, &.{});
        self.atlas = atlas;
        try art.player_idle_clip.validateForAtlas(atlas);
        try art.player_run_clip.validateForAtlas(atlas);
        try art.player_jump_clip.validateForAtlas(atlas);
        self.player_animation = try up.graphics.SpriteAnimationPlayer.init(&art.player_idle_clip);

        const font = try self.allocator.?.create(up.assets.Font);
        errdefer self.allocator.?.destroy(font);
        font.* = try up.assets.Font.decodeTrueType(self.allocator.?, art.ui_font_ttf, .{ .pixel_height = 8, .atlas_width = 128, .atlas_height = 128 });
        self.font = font;

        self.loadProgress(ctx);
        self.resetRun();
        if (ctx.audio) |audio| {
            self.jump_sound = audio.loadWav(&sounds.jump_wav) catch null;
            self.collect_sound = audio.loadWav(&sounds.collect_wav) catch null;
            self.reset_sound = audio.loadWav(&sounds.reset_wav) catch null;
            self.background_music = audio.loadMusic(art.background_music_ogg, .{}) catch null;
            if (self.background_music) |music| _ = audio.playMusic(music, .{ .loop = true, .volume = 0.35 }) catch {};
        }
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.actions) |*actions| {
            actions.deinit();
            self.actions = null;
        }
        self.player_animation = null;
        if (self.atlas) |atlas| {
            atlas.deinit();
            if (self.allocator) |allocator| allocator.destroy(atlas);
            self.atlas = null;
        }
        if (self.font) |font| {
            font.deinit();
            if (self.allocator) |allocator| allocator.destroy(font);
            self.font = null;
        }
        if (self.surface) |*surface| {
            surface.deinit();
            self.surface = null;
        }
        self.allocator = null;
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        const actions = &(self.actions orelse return error.GameNotInitialized);
        actions.update(ctx.input.*);
        if (actions.wasPressed("game", "restart")) {
            self.resetRun();
            play(ctx, self.reset_sound, 0.45);
            return;
        }
        if (self.completed) return;
        if (self.dead) {
            if (self.respawn_ticks > 0) self.respawn_ticks -= 1;
            if (self.respawn_ticks == 0) self.respawnAtCheckpoint();
            return;
        }

        self.run_ticks +%= 1;
        const direction = boolToFloat(actions.isDown("game", "right")) - boolToFloat(actions.isDown("game", "left"));
        self.player.velocity.x = direction * move_speed;
        if (direction < 0) self.player.facing_left = true;
        if (direction > 0) self.player.facing_left = false;
        if (self.player.grounded) self.player.coyote = coyote_ticks else if (self.player.coyote > 0) self.player.coyote -= 1;
        if (actions.wasPressed("game", "jump") and self.player.coyote > 0) {
            self.player.velocity.y = -jump_speed;
            self.player.grounded = false;
            self.player.coyote = 0;
            play(ctx, self.jump_sound, 0.55);
        }

        self.moveAndCollide(elapsed_seconds);
        self.updateAnimation() catch {};
        self.collectNearby(ctx);
        self.activateCheckpoint(ctx);
        if (playerRect(self.player).intersects(level.goal_bounds)) {
            self.completed = true;
            self.completion_unlocked = true;
            self.persistProgress(ctx);
        }
        for (level.hazards) |hazard| if (playerRect(self.player).intersects(hazard)) {
            self.kill(ctx);
            return;
        };
        if (self.player.position.y > level.world_height + 16) self.kill(ctx);
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        const surface = if (self.surface) |*value| value else return error.GameNotInitialized;
        const atlas = self.atlas orelse return error.GameNotInitialized;
        _ = self.font orelse return error.GameNotInitialized;
        const world = surface.canvas();
        world.clear(up.core.Color.rgb(12, 17, 37));

        var camera = up.graphics.Camera2D{
            .position = .{
                .x = std.math.clamp(self.player.position.x + player_width / 2, @as(f32, 80), level.world_width - 80),
                .y = 45,
            },
            .zoom = 0.5,
            .pixel_snap = .nearest,
        };
        const world_canvas = up.graphics.CameraCanvas.init(world, &camera);
        world_canvas.fillRect(.init(0, 0, level.world_width, level.world_height), up.core.Color.rgb(18, 26, 56));
        for (level.platforms) |platform| {
            world_canvas.fillRect(platform, up.core.Color.rgb(83, 91, 137));
            world_canvas.strokeRect(platform, up.core.Color.rgb(145, 160, 211));
        }
        for (level.hazards) |hazard| {
            var spike_x = hazard.x;
            while (spike_x < hazard.x + hazard.w) : (spike_x += 8) {
                world_canvas.drawAtlasFrame(atlas.*, .{ .index = 7 }, .{ .x = spike_x, .y = hazard.y - 4 }, .{});
            }
        }
        for (level.collectible_positions, 0..) |position, index| if (!self.collected[index]) {
            world_canvas.drawAtlasFrame(atlas.*, .{ .index = 4 }, position, .{ .origin = .center });
        };
        for (level.checkpoint_bounds, 0..) |bounds, index| {
            const active = self.checkpoint == index + 1;
            world_canvas.drawAtlasFrame(atlas.*, .{ .index = 5 }, .{ .x = bounds.x + 1, .y = bounds.y + 2 }, .{ .tint = if (active) up.core.Color.rgb(255, 241, 150) else up.core.Color.rgb(170, 170, 190) });
        }
        world_canvas.drawAtlasFrame(atlas.*, .{ .index = 6 }, .{ .x = level.goal_bounds.x + 1, .y = level.goal_bounds.y + 5 }, .{});
        const animation = self.player_animation orelse return error.GameNotInitialized;
        world_canvas.drawAtlasFrame(atlas.*, animation.currentFrame(), self.player.position, .{ .flip_x = self.player.facing_left });

        canvas.clear(up.core.Color.rgb(4, 7, 18));
        try canvas.drawSurface(surface, .{ .x = 0, .y = 0, .width = width, .height = height, .filter = .nearest });
        canvas.fillRect(0, 0, @intCast(width), 11, up.core.Color.rgba(4, 7, 18, 225));
        canvas.fillRect(0, 79, @intCast(width), 11, up.core.Color.rgba(4, 7, 18, 235));
        // The 5x7 bitmap glyphs stay sharp when this small canvas is scaled up.
        var hud: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&hud, "GLOWS {d}/{d}  BEST {d}", .{ self.collectedCount(), level.collectible_positions.len, self.best_collectibles });
        canvas.drawText(text, 3, 2, up.core.Color.rgb(235, 244, 255));
        canvas.drawText("ARROWS MOVE SPACE JUMP", 3, 81, up.core.Color.rgb(201, 214, 245));
        if (self.dead) {
            canvas.fillRect(32, 33, 96, 24, up.core.Color.rgba(5, 8, 20, 230));
            canvas.drawText("LANTERN OUT", 44, 37, up.core.Color.rgb(255, 159, 174));
            canvas.drawText("RESPAWNING", 47, 46, up.core.Color.rgb(229, 237, 255));
        }
        if (self.completed) {
            canvas.fillRect(18, 32, 124, 26, up.core.Color.rgba(5, 8, 20, 235));
            canvas.drawText("THE WAY IS LIT", 38, 37, up.core.Color.rgb(255, 235, 128));
            canvas.drawText("ENTER TO WALK AGAIN", 23, 46, up.core.Color.rgb(229, 237, 255));
        }
    }

    fn resetRun(self: *Game) void {
        self.player = .{};
        self.player.position = level.checkpoint_spawns[0];
        self.collected = [_]bool{false} ** level.collectible_positions.len;
        self.checkpoint = 0;
        self.completed = false;
        self.dead = false;
        self.respawn_ticks = 0;
        self.run_ticks = 0;
        if (self.player_animation) |*animation| animation.restart();
    }

    fn respawnAtCheckpoint(self: *Game) void {
        self.player = .{};
        self.player.position = level.checkpoint_spawns[self.checkpoint];
        self.dead = false;
        self.respawn_ticks = 0;
        if (self.player_animation) |*animation| animation.restart();
    }

    fn moveAndCollide(self: *Game, elapsed_seconds: f32) void {
        self.player.position.x += self.player.velocity.x * elapsed_seconds;
        for (level.platforms) |platform| if (playerRect(self.player).intersects(platform)) {
            if (self.player.velocity.x > 0) self.player.position.x = platform.x - player_width;
            if (self.player.velocity.x < 0) self.player.position.x = platform.x + platform.w;
            self.player.velocity.x = 0;
        };

        self.player.velocity.y = @min(terminal_speed, self.player.velocity.y + gravity * elapsed_seconds);
        self.player.position.y += self.player.velocity.y * elapsed_seconds;
        self.player.grounded = false;
        for (level.platforms) |platform| if (playerRect(self.player).intersects(platform)) {
            if (self.player.velocity.y > 0) {
                self.player.position.y = platform.y - player_height;
                self.player.grounded = true;
            } else if (self.player.velocity.y < 0) {
                self.player.position.y = platform.y + platform.h;
            }
            self.player.velocity.y = 0;
        };
    }

    fn updateAnimation(self: *Game) !void {
        const player_animation = &(self.player_animation orelse return error.GameNotInitialized);
        const wanted = if (!self.player.grounded) &art.player_jump_clip else if (@abs(self.player.velocity.x) > 0.1) &art.player_run_clip else &art.player_idle_clip;
        if (!player_animation.isCurrentClip(wanted)) try player_animation.play(wanted);
        // Exactly one game-owned tick per fixed `Game.update`; draws observe.
        player_animation.advance(1);
    }

    fn collectNearby(self: *Game, ctx: *up.core.GameContext) void {
        const center: up.core.Vec2 = .{ .x = self.player.position.x + player_width / 2, .y = self.player.position.y + player_height / 2 };
        for (level.collectible_positions, 0..) |position, index| {
            if (!self.collected[index] and distanceSquared(center, position) < 64) {
                self.collected[index] = true;
                play(ctx, self.collect_sound, 0.45);
                if (self.collectedCount() > self.best_collectibles) {
                    self.best_collectibles = self.collectedCount();
                    self.persistProgress(ctx);
                }
            }
        }
    }

    fn activateCheckpoint(self: *Game, ctx: *up.core.GameContext) void {
        for (level.checkpoint_bounds, 0..) |bounds, index| if (self.checkpoint < index + 1 and playerRect(self.player).intersects(bounds)) {
            self.checkpoint = index + 1;
            self.persistProgress(ctx);
            play(ctx, self.collect_sound, 0.3);
        };
    }

    fn kill(self: *Game, ctx: *up.core.GameContext) void {
        if (self.dead) return;
        self.dead = true;
        self.respawn_ticks = respawn_delay_ticks;
        self.player.velocity = .{};
        play(ctx, self.reset_sound, 0.45);
    }

    fn collectedCount(self: Game) u8 {
        var count: u8 = 0;
        for (self.collected) |value| {
            if (value) count += 1;
        }
        return count;
    }

    fn loadProgress(self: *Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse return;
        var bytes: [3]u8 = undefined;
        const saved = store.read("progress.v1", &bytes) catch return;
        if (saved.len != bytes.len or saved[0] != 1) return;
        self.best_collectibles = saved[1];
        self.completion_unlocked = saved[2] != 0;
    }

    fn persistProgress(self: *const Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse return;
        const bytes = [_]u8{ 1, self.best_collectibles, @intFromBool(self.completion_unlocked) };
        store.write("progress.v1", &bytes) catch {};
    }

    fn play(ctx: *up.core.GameContext, sound: ?up.core.Audio.SoundHandle, volume: f32) void {
        const audio = ctx.audio orelse return;
        const handle = sound orelse return;
        _ = audio.play(handle, .{ .volume = volume }) catch {};
    }
};

fn playerRect(player: Player) up.core.Rect {
    return .init(player.position.x, player.position.y, player_width, player_height);
}

fn distanceSquared(a: up.core.Vec2, b: up.core.Vec2) f32 {
    return a.sub(b).lenSq();
}

fn boolToFloat(value: bool) f32 {
    return if (value) 1 else 0;
}

fn scriptedPlatformReplay(allocator: std.mem.Allocator) !up.preview.developer.InputReplay {
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, default_seed);
    defer recorder.deinit();
    var input = up.input.Input{};
    for (0..180) |tick| {
        input.beginFrame();
        input.set(.right, true);
        input.set(.action, tick == 38);
        try recorder.record(input);
    }
    return recorder.finish();
}

test "Lantern Leap deterministically replays movement, jump, checkpoint, animation, trace, and pixels" {
    var replay = try scriptedPlatformReplay(std.testing.allocator);
    defer replay.deinit(std.testing.allocator);
    var first_saves: up.testSupport.InMemorySaveStore = undefined;
    first_saves.init(std.testing.allocator);
    defer first_saves.deinit();
    var second_saves: up.testSupport.InMemorySaveStore = undefined;
    second_saves.init(std.testing.allocator);
    defer second_saves.deinit();
    const saved = [_]u8{ 1, 1, 0 };
    try first_saves.capability().write("progress.v1", &saved);
    try second_saves.capability().write("progress.v1", &saved);

    var first = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, first_saves.capability());
    defer first.deinit();
    try first.runReplay(replay);
    const first_capture = first.capture();
    var second = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, second_saves.capability());
    defer second.deinit();
    try second.runReplay(replay);
    const second_capture = second.capture();

    try std.testing.expectEqual(@as(u32, 180), first.game.run_ticks);
    try std.testing.expect(first.game.collectedCount() >= 1);
    try std.testing.expect(first.game.checkpoint == 1);
    try std.testing.expect(first.audio.hasActivePlayback());
    try std.testing.expectEqual(up.core.Audio.MusicState.playing, first.audio.musicState());
    try std.testing.expectEqual(first.game.player.position, second.game.player.position);
    try std.testing.expectEqual(first.game.collected, second.game.collected);
    try std.testing.expectEqual((first.game.player_animation orelse return error.MissingAnimation).currentFrame(), (second.game.player_animation orelse return error.MissingAnimation).currentFrame());
    try up.testSupport.expectCanvasTraceEqual(first_capture.canvas_trace, second_capture.canvas_trace);
    try std.testing.expectEqual(try first_capture.canvas_trace.hash(), try second_capture.canvas_trace.hash());
    try std.testing.expectEqual(first_capture.image_hash, second_capture.image_hash);
}

test "Lantern Leap collision, death, checkpoint respawn, and gamepad jump stay game owned" {
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer runner.deinit();
    try runner.run(&.{ .{}, .{}, .{} });
    try std.testing.expect(runner.game.player.grounded);
    const floor_y = runner.game.player.position.y;
    try runner.run(&.{.{ .buttons = up.testSupport.Buttons.action }});
    try std.testing.expect(runner.game.player.position.y < floor_y);
    const first_jump_velocity = runner.game.player.velocity.y;
    try runner.run(&.{.{}});
    try runner.run(&.{.{ .buttons = up.testSupport.Buttons.action }});
    try std.testing.expect(runner.game.player.velocity.y > first_jump_velocity);
    try std.testing.expect(runner.input.addGamepad(17));
    runner.input.setGamepadAxis(17, .left_x, 1, 0);
    const before_x = runner.game.player.position.x;
    try runner.run(&.{.{}});
    try std.testing.expect(runner.game.player.position.x > before_x);

    runner.game.checkpoint = 1;
    runner.game.player.position = .{ .x = level.hazards[0].x, .y = 74 };
    runner.game.player.velocity = .{};
    runner.game.player.grounded = true;
    try runner.run(&.{.{}});
    try std.testing.expect(runner.game.dead);
    for (0..@as(usize, respawn_delay_ticks)) |_| try runner.run(&.{.{}});
    try std.testing.expect(!runner.game.dead);
    try std.testing.expectEqual(level.checkpoint_spawns[1], runner.game.player.position);
    runner.input.set(.start, true);
    try runner.run(&.{.{}});
    try std.testing.expect(!runner.game.dead);
    try std.testing.expectEqual(level.checkpoint_spawns[0], runner.game.player.position);
}

test "Lantern Leap animation advances in update and ignores extra presentation draws" {
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer runner.deinit();
    try runner.run(&.{.{ .buttons = up.testSupport.Buttons.right }});
    try std.testing.expect((runner.game.player_animation orelse return error.MissingAnimation).isCurrentClip(&art.player_run_clip));
    const before = (runner.game.player_animation orelse return error.MissingAnimation).currentFrame();
    try runner.protocol.draw(&runner.context, 0);
    try runner.protocol.draw(&runner.context, 0);
    try std.testing.expectEqual(before, (runner.game.player_animation orelse return error.MissingAnimation).currentFrame());
}

test "Lantern Leap persists game-owned progress and survives failed persistence" {
    const FailingStore = struct {
        const vtable = up.core.SaveStore.VTable{ .read_size = readSize, .read = read, .write = write, .delete = delete, .exists = exists };
        fn capability(self: *@This()) up.core.SaveStore {
            return .init(self, &vtable);
        }
        fn readSize(_: *anyopaque, _: []const u8) up.core.SaveStore.Error!usize {
            return error.NotFound;
        }
        fn read(_: *anyopaque, _: []const u8, _: []u8) up.core.SaveStore.Error!usize {
            return error.NotFound;
        }
        fn write(_: *anyopaque, _: []const u8, _: []const u8) up.core.SaveStore.Error!void {
            return error.Unavailable;
        }
        fn delete(_: *anyopaque, _: []const u8) up.core.SaveStore.Error!void {
            return error.Unavailable;
        }
        fn exists(_: *anyopaque, _: []const u8) up.core.SaveStore.Error!bool {
            return error.Unavailable;
        }
    };
    var failing = FailingStore{};
    var store = failing.capability();
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, &store);
    defer runner.deinit();
    runner.game.best_collectibles = 6;
    runner.game.persistProgress(&runner.context);
    try std.testing.expectEqual(@as(u8, 6), runner.game.best_collectibles);
}
