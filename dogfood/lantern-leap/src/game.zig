const std = @import("std");
const up = @import("unpolished-peas");
const art = @import("art.zig");
const level = @import("level.zig");
const sounds = @import("sounds.zig");
const progress = @import("progress.zig");
const ui = @import("ui.zig");
pub const Screen = enum { title, playing, paused };
pub const Notice = enum { none, glow, checkpoint, queued, unavailable, back };

pub const width: u32 = 320;
pub const height: u32 = 200;
pub const surface_width: u32 = 160;
pub const surface_height: u32 = 80;
pub const default_seed: u64 = 0x4c41_4e54_4552_4e4c;
pub const storage_id = "unpolished-peas.lantern-leap";

pub const player_width: f32 = 8;
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
    .{ .name = "primary", .binding = .{ .key = .start } },
    .{ .name = "primary", .binding = .{ .gamepad_button = .start } },
    .{ .name = "pause", .binding = .{ .physical_key = .escape } },
    .{ .name = "new-run", .binding = .{ .physical_key = .r } },
    .{ .name = "new-run", .binding = .{ .gamepad_button = .left_shoulder } },
    .{ .name = "audio", .binding = .{ .physical_key = .m } },
    .{ .name = "audio", .binding = .{ .gamepad_button = .back } },
    .{ .name = "left", .binding = .{ .physical_key = .a } },
    .{ .name = "right", .binding = .{ .physical_key = .d } },
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
    assets: ?up.assets.AssetCollection = null,
    actions: ?up.input.ActionMap = null,
    surface: ?up.graphics.RenderSurface = null,
    atlas: ?*up.assets.Atlas = null,
    font: ?*up.assets.Font = null,
    player_animation: ?up.graphics.SpriteAnimationPlayer = null,
    text: ui.Text = .{},
    screen: Screen = .title,
    run_started: bool = false,
    audio_enabled: bool = true,
    save_failed: bool = false,
    load_problem: bool = false,
    jump_buffer: u8 = 0,
    jump_armed: bool = false,
    camera_x: f32 = 80,
    notice: Notice = .none,
    notice_ticks: u8 = 0,
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
        self.* = .{};
        const allocator = try ctx.requireAllocator();
        self.assets = up.assets.AssetCollection.init(allocator);
        errdefer self.deinit(ctx) catch {};
        self.actions = try up.input.ActionMap.init(allocator, &controls);
        self.surface = try up.graphics.RenderSurface.init(allocator, surface_width, surface_height);

        const atlas = try self.assets.?.atlas(art.sprite_sheet_png, &art.frames, .{ .image_path = "lantern-leap.png" });
        self.atlas = atlas;
        try art.player_idle_clip.validateForAtlas(atlas);
        try art.player_run_clip.validateForAtlas(atlas);
        try art.player_jump_clip.validateForAtlas(atlas);
        self.player_animation = try up.graphics.SpriteAnimationPlayer.init(&art.player_idle_clip);

        self.font = try self.assets.?.font(art.ui_font_ttf, .{ .pixel_height = 12, .atlas_width = 256, .atlas_height = 256 });

        try self.text.init(allocator, self.font.?);
        self.resetRun();
        self.run_started = false;
        self.loadProgress(ctx);
        self.respawnAtCheckpoint();
        self.notice_ticks = 0;
        if (ctx.audio) |audio| {
            self.jump_sound = try audio.loadWav(sounds.jump_wav);
            self.collect_sound = try audio.loadWav(sounds.collect_wav);
            self.reset_sound = try audio.loadWav(sounds.reset_wav);
            self.background_music = try audio.loadMusic(art.background_music_ogg, .{});
            self.syncMusic(audio);
        }
    }

    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void {
        if (ctx.audio) |audio| {
            if (self.jump_sound) |h| _ = audio.unloadSound(h);
            if (self.collect_sound) |h| _ = audio.unloadSound(h);
            if (self.reset_sound) |h| _ = audio.unloadSound(h);
            if (self.background_music) |h| _ = audio.unloadMusic(h);
        }
        self.jump_sound = null;
        self.collect_sound = null;
        self.reset_sound = null;
        self.background_music = null;
        self.text.deinit();
        if (self.actions) |*actions| {
            actions.deinit();
            self.actions = null;
        }
        self.player_animation = null;
        if (self.assets) |*assets| assets.deinit();
        self.assets = null;
        self.atlas = null;
        self.font = null;
        if (self.surface) |*surface| {
            surface.deinit();
            self.surface = null;
        }
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        const actions = if (self.actions) |*value| value else return error.GameNotInitialized;
        actions.update(ctx.input.*);
        if (actions.wasPressed("game", "audio")) {
            self.audio_enabled = !self.audio_enabled;
            self.persistProgress(ctx);
        }
        if (ctx.audio) |audio| self.syncMusic(audio);
        const primary = actions.wasPressed("game", "primary");
        const pause = actions.wasPressed("game", "pause");
        if (self.screen == .title) {
            if (primary) {
                if (!self.run_started or self.completed) self.resetRun();
                self.screen = .playing;
                self.clearJump();
                self.persistProgress(ctx);
            }
            return;
        }
        if (actions.wasPressed("game", "new-run")) {
            self.resetRun();
            self.screen = .playing;
            self.persistProgress(ctx);
            self.play(ctx, self.reset_sound, 0.35);
            return;
        }
        if (self.screen == .paused) {
            if (primary or pause) {
                self.screen = .playing;
                self.clearJump();
                if (self.save_failed) self.persistProgress(ctx);
            }
            return;
        }
        if (self.completed) {
            if (primary) {
                self.resetRun();
                self.persistProgress(ctx);
            }
            return;
        }
        if (self.dead) {
            if (primary) {
                self.respawnAtCheckpoint();
                if (self.save_failed) self.persistProgress(ctx);
                return;
            }
            if (pause) {
                self.screen = .paused;
                self.clearJump();
                return;
            }
            if (self.respawn_ticks > 0) self.respawn_ticks -= 1;
            if (self.respawn_ticks == 0) self.respawnAtCheckpoint();
            return;
        }
        if (primary or pause) {
            self.screen = .paused;
            self.clearJump();
            return;
        }
        self.run_ticks +%= 1;
        if (self.notice_ticks > 0) self.notice_ticks -= 1;
        if (!actions.isDown("game", "jump")) self.jump_armed = true;
        if (actions.wasPressed("game", "jump") and self.jump_armed) {
            self.jump_buffer = 6;
            self.jump_armed = false;
            self.notify(.queued, 6);
        } else if (self.jump_buffer > 0) {
            self.jump_buffer -= 1;
            if (self.jump_buffer == 0) self.notify(.unavailable, 24);
        }
        const direction = boolToFloat(actions.isDown("game", "right")) - boolToFloat(actions.isDown("game", "left"));
        self.player.velocity.x = direction * move_speed;
        if (direction != 0) self.player.facing_left = direction < 0;
        if (self.player.grounded) self.player.coyote = coyote_ticks else if (self.player.coyote > 0) self.player.coyote -= 1;
        if (self.jump_buffer > 0 and self.player.coyote > 0) self.jump(ctx);
        if (actions.wasReleased("game", "jump") and self.player.velocity.y < -70) self.player.velocity.y *= 0.5;
        self.moveAndCollide(elapsed_seconds);
        if (self.jump_buffer > 0 and self.player.grounded) self.jump(ctx);
        try self.updateAnimation();
        self.collectNearby(ctx);
        self.activateCheckpoint(ctx);
        const target = std.math.clamp(self.player.position.x + 4, @as(f32, 80), level.world_width - 80);
        self.camera_x += std.math.clamp(target - self.camera_x, @as(f32, -3), @as(f32, 3));
        for (level.hazards) |hazard| if (playerRect(self.player).intersects(hazard)) {
            self.kill(ctx);
            return;
        };
        if (self.player.position.y > level.world_height + 16) {
            self.kill(ctx);
            return;
        }
        if (playerRect(self.player).intersects(level.goal_bounds)) {
            self.completed = true;
            self.completion_unlocked = true;
            self.clearJump();
            self.persistProgress(ctx);
            self.play(ctx, self.collect_sound, 0.55);
        }
    }
    fn jump(self: *Game, ctx: *up.core.GameContext) void {
        self.player.velocity.y = -jump_speed;
        self.player.grounded = false;
        self.player.coyote = 0;
        self.jump_buffer = 0;
        self.notice_ticks = 0;
        self.play(ctx, self.jump_sound, 0.45);
    }
    fn clearJump(self: *Game) void {
        self.jump_buffer = 0;
        self.jump_armed = false;
    }
    fn notify(self: *Game, notice: Notice, ticks: u8) void {
        self.notice = notice;
        self.notice_ticks = ticks;
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        try @import("presentation.zig").draw(self, ctx);
    }

    fn resetRun(self: *Game) void {
        self.player = .{};
        self.player.position = level.checkpoint_spawns[0];
        self.camera_x = 80;
        self.run_started = true;
        self.clearJump();
        self.notice_ticks = 0;
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
        self.camera_x = std.math.clamp(self.player.position.x + 4, @as(f32, 80), level.world_width - 80);
        self.clearJump();
        self.notify(.back, 45);
        self.dead = false;
        self.respawn_ticks = 0;
        if (self.player_animation) |*animation| animation.restart();
    }

    fn moveAndCollide(self: *Game, elapsed_seconds: f32) void {
        self.player.position.x = std.math.clamp(self.player.position.x + self.player.velocity.x * elapsed_seconds, @as(f32, 2), level.world_width - player_width - 2);
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
                self.notify(.glow, 36);
                self.play(ctx, self.collect_sound, 0.45);
                if (self.collectedCount() > self.best_collectibles) {
                    self.best_collectibles = self.collectedCount();
                }
                self.persistProgress(ctx);
            }
        }
    }

    fn activateCheckpoint(self: *Game, ctx: *up.core.GameContext) void {
        for (level.checkpoint_bounds, 0..) |bounds, index| if (self.checkpoint < index + 1 and playerRect(self.player).intersects(bounds)) {
            self.checkpoint = index + 1;
            self.persistProgress(ctx);
            self.notify(.checkpoint, 90);
            self.play(ctx, self.collect_sound, 0.35);
        };
    }

    fn kill(self: *Game, ctx: *up.core.GameContext) void {
        if (self.dead) return;
        self.dead = true;
        self.respawn_ticks = respawn_delay_ticks;
        self.player.velocity = .{};
        self.clearJump();
        self.play(ctx, self.reset_sound, 0.35);
    }

    pub fn collectedCount(self: Game) u8 {
        var count: u8 = 0;
        for (self.collected) |value| {
            if (value) count += 1;
        }
        return count;
    }

    pub fn record(self: *const Game) progress.Record {
        var mask: u8 = 0;
        for (self.collected, 0..) |collected, i| if (collected) {
            mask |= @as(u8, 1) << @intCast(i);
        };
        return .{ .best = self.best_collectibles, .finished = self.completion_unlocked, .audio = self.audio_enabled, .mask = mask, .checkpoint = @intCast(self.checkpoint), .started = self.run_started, .completed = self.completed };
    }
    fn loadProgress(self: *Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse return;
        var bytes: [progress.size]u8 = undefined;
        var loaded: ?progress.Record = null;
        if (store.read(progress.key, &bytes)) |saved| {
            loaded = progress.decode(saved) catch null;
            if (loaded == null) self.load_problem = true;
        } else |err| {
            if (err != error.NotFound) self.load_problem = true;
        }
        if (loaded == null) {
            if (store.read("progress.v1", &bytes)) |saved| {
                loaded = progress.legacy(saved) catch null;
                if (loaded == null) self.load_problem = true;
            } else |err| {
                if (err != error.NotFound) self.load_problem = true;
            }
        }
        if (loaded) |r| {
            self.best_collectibles = r.best;
            self.completion_unlocked = r.finished;
            self.audio_enabled = r.audio;
            self.checkpoint = r.checkpoint;
            self.run_started = r.started;
            self.completed = r.completed;
            for (&self.collected, 0..) |*entry, i| entry.* = r.mask & (@as(u8, 1) << @intCast(i)) != 0;
        }
    }
    fn persistProgress(self: *Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse {
            self.save_failed = true;
            return;
        };
        const bytes = progress.encode(self.record());
        store.write(progress.key, &bytes) catch {
            self.save_failed = true;
            return;
        };
        self.save_failed = false;
        self.load_problem = false;
    }
    fn play(self: *const Game, ctx: *up.core.GameContext, sound: ?up.core.Audio.SoundHandle, volume: f32) void {
        if (!self.audio_enabled) return;
        if (ctx.audio) |audio| if (sound) |handle| {
            _ = audio.play(handle, .{ .volume = volume }) catch {};
        };
    }
    fn syncMusic(self: *Game, audio: *up.core.Audio) void {
        if (!self.audio_enabled) {
            _ = audio.stopMusic();
            return;
        }
        if (audio.availability() != .ready) return;
        const volume: f32 = if (self.screen == .playing and !self.dead and !self.completed) 0.12 else 0.045;
        if (audio.musicState() == .playing) {
            _ = audio.setMusicVolume(volume) catch false;
            return;
        }
        if (self.background_music) |music| {
            _ = audio.playMusic(music, .{ .loop = true, .volume = volume }) catch {};
        }
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
    input.set(.start, true);
    try recorder.record(input);
    for (0..180) |tick| {
        input.set(.start, false);
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
    try begin(runner);
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
    runner.input.setPhysical(.r, true, false);
    try runner.run(&.{.{}});
    try std.testing.expect(!runner.game.dead);
    try std.testing.expectEqual(level.checkpoint_spawns[0], runner.game.player.position);
}

test "Lantern Leap animation advances in update and ignores extra presentation draws" {
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer runner.deinit();
    try begin(runner);
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

const Runner = up.testSupport.HeadlessGameRunner(Game);
fn begin(r: *Runner) !void {
    var input = up.input.Input{};
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
    input.set(.start, false);
    try r.step(input.snapshot(), 1.0 / 60.0);
}
fn stepInput(r: *Runner, input: *up.input.Input) !void {
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
}

test "immediate checkpoint respawn preserves glows; explicit full restart clears only current run" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    try begin(r);
    r.game.checkpoint = 1;
    r.game.collected[0] = true;
    r.game.best_collectibles = 1;
    r.game.jump_buffer = 5;
    r.game.kill(&r.context);
    var input = up.input.Input{};
    input.set(.start, true);
    try stepInput(r, &input);
    try std.testing.expectEqual(level.checkpoint_spawns[1], r.game.player.position);
    try std.testing.expect(r.game.collected[0] and r.game.checkpoint == 1 and !r.game.dead and r.game.jump_buffer == 0);
    input.set(.start, false);
    input.setPhysical(.r, true, false);
    try stepInput(r, &input);
    try std.testing.expectEqual(level.checkpoint_spawns[0], r.game.player.position);
    try std.testing.expect(r.game.collectedCount() == 0 and r.game.checkpoint == 0 and r.game.best_collectibles == 1);
}

test "jump buffers a landing once, expires in air, and never repeats held input" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    try begin(r);
    r.game.player.position = .{ .x = 80, .y = 73 };
    r.game.player.velocity = .{ .y = 30 };
    r.game.player.grounded = false;
    r.game.player.coyote = 0;
    var input = up.input.Input{};
    input.set(.action, true);
    try stepInput(r, &input);
    try std.testing.expect(r.game.jump_buffer > 0 and r.game.player.velocity.y > 0);
    try stepInput(r, &input);
    try std.testing.expect(r.game.player.velocity.y == -jump_speed and !r.game.player.grounded and r.game.jump_buffer == 0);
    for (0..60) |_| try stepInput(r, &input);
    try std.testing.expect(r.game.player.grounded and r.game.player.velocity.y == 0);
    input.set(.action, false);
    try stepInput(r, &input);
    r.game.player.position = .{ .x = 80, .y = 30 };
    r.game.player.velocity = .{};
    r.game.player.grounded = false;
    r.game.player.coyote = 0;
    input.set(.action, true);
    try stepInput(r, &input);
    for (0..6) |_| try stepInput(r, &input);
    try std.testing.expect(r.game.jump_buffer == 0 and r.game.player.velocity.y > 0);
}

test "last coyote opportunity is consumed once and release gives a lower jump" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    try begin(r);
    r.game.player.position = .{ .x = 80, .y = 70 };
    r.game.player.grounded = false;
    r.game.player.coyote = 2;
    var input = up.input.Input{};
    input.set(.action, true);
    try stepInput(r, &input);
    const rising = r.game.player.velocity.y;
    try std.testing.expect(rising < -160 and r.game.player.coyote == 0);
    input.set(.action, false);
    try stepInput(r, &input);
    try std.testing.expect(r.game.player.velocity.y > rising * 0.6);
    input.set(.action, true);
    try stepInput(r, &input);
    try std.testing.expect(r.game.player.velocity.y > rising and r.game.jump_buffer > 0);
}

test "pause freezes play and discards jump requests until a fresh release" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    try begin(r);
    var input = up.input.Input{};
    input.setPhysical(.escape, true, false);
    try stepInput(r, &input);
    const position = r.game.player.position;
    const ticks = r.game.run_ticks;
    input.set(.action, true);
    for (0..20) |_| try stepInput(r, &input);
    try std.testing.expectEqual(position, r.game.player.position);
    try std.testing.expectEqual(ticks, r.game.run_ticks);
    input.setPhysical(.escape, false, false);
    input.set(.start, true);
    try stepInput(r, &input);
    input.set(.start, false);
    for (0..10) |_| try stepInput(r, &input);
    try std.testing.expect(r.game.player.grounded and r.game.jump_buffer == 0);
    input.set(.action, false);
    try stepInput(r, &input);
    input.set(.action, true);
    try stepInput(r, &input);
    try std.testing.expect(r.game.player.velocity.y < 0);
}

test "blocked music recovers without a toggle and prepared UI copy fits" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    _ = r.audio.stopMusic();
    r.audio.setAvailability(.blocked);
    try r.step((up.input.Input{}).snapshot(), 1.0 / 60.0);
    try std.testing.expectEqual(up.core.Audio.MusicState.stopped, r.audio.musicState());
    r.audio.setAvailability(.ready);
    try r.step((up.input.Input{}).snapshot(), 1.0 / 60.0);
    try std.testing.expectEqual(up.core.Audio.MusicState.playing, r.audio.musicState());
    for (r.game.text.layouts) |layout| try std.testing.expect(layout.?.metrics.width <= 304);
}

test {
    _ = @import("route.zig");
}

test "current checkpoint progress reloads and legacy records remain readable" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    const legacy = [_]u8{ 1, 3, 1 };
    try saves.capability().write("progress.v1", &legacy);
    {
        const r = try Runner.initSeededWithSaveData(std.testing.allocator, width, height, default_seed, saves.capability());
        defer r.deinit();
        try std.testing.expect(r.game.best_collectibles == 3 and r.game.completion_unlocked and !r.game.run_started);
    }
    const saved = progress.encode(.{ .best = 4, .mask = 15, .checkpoint = 1, .started = true, .audio = false });
    try saves.capability().write(progress.key, &saved);
    const r = try Runner.initSeededWithSaveData(std.testing.allocator, width, height, default_seed, saves.capability());
    defer r.deinit();
    try std.testing.expect(r.game.checkpoint == 1 and r.game.collectedCount() == 4 and !r.game.audio_enabled and r.game.screen == .title);
    try std.testing.expectEqual(level.checkpoint_spawns[1], r.game.player.position);
    try begin(r);
    try std.testing.expect(r.game.checkpoint == 1 and r.game.collectedCount() == 4);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &legacy, try saves.capability().read("progress.v1", &bytes));
}

test "rejected replacement keeps good progress and retry clears pending feedback" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(failing.allocator());
    defer saves.deinit();
    const saved = progress.encode(.{ .best = 4, .mask = 15, .checkpoint = 1, .started = true });
    try saves.capability().write(progress.key, &saved);
    const r = try Runner.initSeededWithSaveData(std.testing.allocator, width, height, default_seed, saves.capability());
    defer r.deinit();
    try begin(r);
    r.game.best_collectibles = 5;
    failing.fail_index = failing.alloc_index;
    r.game.persistProgress(&r.context);
    try std.testing.expect(r.game.save_failed);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &saved, try saves.capability().read(progress.key, &bytes));
    failing.fail_index = std.math.maxInt(usize);
    r.game.persistProgress(&r.context);
    try std.testing.expect(!r.game.save_failed);
    try std.testing.expectEqual(@as(u8, 5), (try progress.decode(try saves.capability().read(progress.key, &bytes))).best);
}

fn initializationFailure(allocator: std.mem.Allocator) !void {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = allocator;
    var g = Game{};
    try g.init(&ctx);
    defer g.deinit(&ctx) catch unreachable;
}
test "partial initialization releases every owned layout font atlas and surface" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initializationFailure, .{});
}

test "three lifecycles reuse audio slots and ordinary restarts retain resources" {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = std.testing.allocator;
    var audio = try up.core.Audio.init(std.testing.allocator, .{});
    defer audio.deinit();
    ctx.audio = &audio;
    var music_slot: ?usize = null;
    for (0..3) |_| {
        var g = Game{};
        try g.init(&ctx);
        const atlas = g.atlas.?;
        const font = g.font.?;
        const sound = g.jump_sound.?;
        const music = g.background_music.?;
        if (music_slot) |slot| try std.testing.expectEqual(slot, music.index);
        music_slot = music.index;
        for (0..12) |_| g.resetRun();
        try std.testing.expect(g.atlas.? == atlas and g.font.? == font);
        try std.testing.expectEqual(music, g.background_music.?);
        try g.deinit(&ctx);
        try std.testing.expect(!audio.hasActivePlayback());
        try std.testing.expectError(error.InvalidSound, audio.play(sound, .{}));
        try std.testing.expectError(error.InvalidMusic, audio.playMusic(music, .{}));
    }
}
