const std = @import("std");
const up = @import("unpolished-peas");
const art = @import("art.zig");
const sounds = @import("sounds.zig");

pub const width: u32 = 160;
pub const height: u32 = 90;
pub const world_width: u32 = 80;
pub const world_height: u32 = 45;
pub const default_seed: u64 = 0x4e45_4f4e_5349_4547;
pub const storage_id = "unpolished-peas.neon-siege";

const max_enemies = 8;
const max_projectiles = 12;
const max_pickups = 4;
const player_speed: f32 = 34;

const controls = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "left", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1 } } },
    .{ .name = "left", .binding = .{ .gamepad_button = .dpad_left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "right", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } },
    .{ .name = "right", .binding = .{ .gamepad_button = .dpad_right } },
    .{ .name = "up", .binding = .{ .key = .up } },
    .{ .name = "up", .binding = .{ .gamepad_axis = .{ .axis = .left_y, .sign = -1 } } },
    .{ .name = "up", .binding = .{ .gamepad_button = .dpad_up } },
    .{ .name = "down", .binding = .{ .key = .down } },
    .{ .name = "down", .binding = .{ .gamepad_axis = .{ .axis = .left_y } } },
    .{ .name = "down", .binding = .{ .gamepad_button = .dpad_down } },
    .{ .name = "attack", .binding = .{ .key = .action } },
    .{ .name = "attack", .binding = .{ .gamepad_button = .south } },
    .{ .name = "dash", .binding = .{ .key = .cancel } },
    .{ .name = "dash", .binding = .{ .gamepad_button = .east } },
    .{ .name = "restart", .binding = .{ .key = .start } },
    .{ .name = "restart", .binding = .{ .gamepad_button = .start } },
    .{ .name = "toggle-audio", .binding = .{ .key = .select } },
    .{ .name = "toggle-audio", .binding = .{ .gamepad_button = .back } },
};

const Actor = struct {
    active: bool = false,
    position: up.core.Vec2 = .{},
    velocity: up.core.Vec2 = .{},
    health: u8 = 1,
    lifetime: f32 = 0,
};

pub const Game = struct {
    allocator: ?std.mem.Allocator = null,
    actions: ?up.input.ActionMap = null,
    surface: ?up.graphics.RenderSurface = null,
    atlas: ?*up.assets.Atlas = null,
    player_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    enemy_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    projectile_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    pickup_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    rng: up.core.DeterministicRng = up.core.DeterministicRng.init(default_seed),
    player: Actor = .{ .active = true, .position = .{ .x = 40, .y = 34 }, .health = 3 },
    enemies: [max_enemies]Actor = [_]Actor{Actor{}} ** max_enemies,
    projectiles: [max_projectiles]Actor = [_]Actor{Actor{}} ** max_projectiles,
    pickups: [max_pickups]Actor = [_]Actor{Actor{}} ** max_pickups,
    last_direction: up.core.Vec2 = .{ .x = 1, .y = 0 },
    score: u32 = 0,
    best_score: u32 = 0,
    wave: u32 = 0,
    game_over: bool = false,
    audio_enabled: bool = true,
    attack_cooldown: f32 = 0,
    hurt_cooldown: f32 = 0,
    shot_sound: ?up.core.Audio.SoundHandle = null,
    pickup_sound: ?up.core.Audio.SoundHandle = null,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        self.allocator = try ctx.requireAllocator();
        errdefer self.deinit(ctx) catch {};
        self.actions = try up.input.ActionMap.init(self.allocator.?, &controls);
        self.surface = try up.graphics.RenderSurface.init(self.allocator.?, world_width, world_height);

        const image = try art.makeImage(self.allocator.?);
        const atlas = try self.allocator.?.create(up.assets.Atlas);
        errdefer self.allocator.?.destroy(atlas);
        atlas.* = try up.assets.Atlas.init(self.allocator.?, image, "neon-siege.tga", &art.frames, &.{});
        self.atlas = atlas;
        self.player_frame = atlas.findFrame("player") orelse return error.MissingPlayerFrame;
        self.enemy_frame = atlas.findFrame("enemy") orelse return error.MissingEnemyFrame;
        self.projectile_frame = atlas.findFrame("projectile") orelse return error.MissingProjectileFrame;
        self.pickup_frame = atlas.findFrame("pickup") orelse return error.MissingPickupFrame;

        self.loadSettings(ctx);
        try self.reset(ctx.simulation_seed orelse default_seed);
        if (ctx.audio) |audio| {
            self.shot_sound = audio.loadWav(&sounds.shot_wav) catch null;
            self.pickup_sound = audio.loadWav(&sounds.pickup_wav) catch null;
        }
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.actions) |*actions| {
            actions.deinit();
            self.actions = null;
        }
        if (self.atlas) |atlas| {
            atlas.deinit();
            if (self.allocator) |allocator| allocator.destroy(atlas);
            self.atlas = null;
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
        if (actions.wasPressed("game", "toggle-audio")) {
            self.audio_enabled = !self.audio_enabled;
            self.saveSettings(ctx);
        }
        if (actions.wasPressed("game", "restart")) {
            try self.reset(ctx.simulation_seed orelse default_seed);
            return;
        }
        if (self.game_over) return;

        const x = boolValue(actions.isDown("game", "right")) - boolValue(actions.isDown("game", "left"));
        const y = boolValue(actions.isDown("game", "down")) - boolValue(actions.isDown("game", "up"));
        var movement = up.core.Vec2{ .x = x, .y = y };
        if (movement.lenSq() > 1) movement = movement.normalized();
        if (movement.lenSq() > 0) self.last_direction = movement;
        const dash: f32 = if (actions.isDown("game", "dash")) 1.8 else 1;
        self.player.position.x = std.math.clamp(self.player.position.x + movement.x * player_speed * dash * elapsed_seconds, 4, 116);
        self.player.position.y = std.math.clamp(self.player.position.y + movement.y * player_speed * dash * elapsed_seconds, 4, 66);

        self.attack_cooldown = @max(0, self.attack_cooldown - elapsed_seconds);
        self.hurt_cooldown = @max(0, self.hurt_cooldown - elapsed_seconds);
        if (actions.isDown("game", "attack") and self.attack_cooldown == 0) try self.fire(ctx);

        for (&self.projectiles) |*projectile| if (projectile.active) {
            projectile.position = projectile.position.add(projectile.velocity.scale(elapsed_seconds));
            projectile.lifetime -= elapsed_seconds;
            if (projectile.lifetime <= 0) projectile.active = false;
        };
        for (&self.enemies) |*enemy| if (enemy.active) {
            const toward_player = self.player.position.sub(enemy.position).normalized();
            enemy.position = enemy.position.add(toward_player.scale(13 * elapsed_seconds));
            if (distanceSquared(enemy.position, self.player.position) < 30 and self.hurt_cooldown == 0) {
                self.player.health -|= 1;
                self.hurt_cooldown = 0.5;
                enemy.active = false;
                if (self.player.health == 0) self.game_over = true;
            }
        };
        for (&self.projectiles) |*projectile| if (projectile.active) for (&self.enemies) |*enemy| if (enemy.active and distanceSquared(projectile.position, enemy.position) < 24) {
            projectile.active = false;
            enemy.health -|= 1;
            if (enemy.health == 0) {
                enemy.active = false;
                self.score += 10;
                self.spawnPickupAt(enemy.position);
                self.updateBestScore(ctx);
            }
            break;
        };
        for (&self.pickups) |*pickup| if (pickup.active and distanceSquared(pickup.position, self.player.position) < 36) {
            pickup.active = false;
            self.score += 5;
            if (self.player.health < 3) self.player.health += 1;
            self.play(ctx, self.pickup_sound, 0.4);
            self.updateBestScore(ctx);
        };
        if (!self.game_over and !hasActive(self.enemies[0..])) try self.spawnWave();
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        const surface = if (self.surface) |*value| value else return error.GameNotInitialized;
        const atlas = self.atlas orelse return error.GameNotInitialized;
        const world = surface.canvas();
        world.clear(up.core.Color.rgb(8, 12, 24));

        var camera = up.graphics.Camera2D{ .position = self.player.position, .pixel_snap = .nearest };
        const world_canvas = up.graphics.CameraCanvas.init(world, &camera);
        var grid_x: i32 = 0;
        while (grid_x <= 120) : (grid_x += 10) world_canvas.line(.{ .x = @floatFromInt(grid_x), .y = 0 }, .{ .x = @floatFromInt(grid_x), .y = 70 }, up.core.Color.rgb(18, 31, 55));
        var grid_y: i32 = 0;
        while (grid_y <= 70) : (grid_y += 10) world_canvas.line(.{ .x = 0, .y = @floatFromInt(grid_y) }, .{ .x = 120, .y = @floatFromInt(grid_y) }, up.core.Color.rgb(18, 31, 55));
        world_canvas.strokeRect(.init(0, 0, 120, 70), up.core.Color.rgb(56, 87, 126));
        for (self.pickups) |pickup| if (pickup.active) world_canvas.drawAtlasFrame(atlas.*, self.pickup_frame, pickup.position, .{ .origin = .center });
        for (self.enemies) |enemy| if (enemy.active) world_canvas.drawAtlasFrame(atlas.*, self.enemy_frame, enemy.position, .{ .origin = .center });
        for (self.projectiles) |projectile| if (projectile.active) world_canvas.drawAtlasFrame(atlas.*, self.projectile_frame, projectile.position, .{ .origin = .center });
        world_canvas.drawAtlasFrame(atlas.*, self.player_frame, self.player.position, .{ .origin = .center });

        canvas.clear(up.core.Color.rgb(3, 5, 13));
        try canvas.drawSurface(surface, .{ .x = 0, .y = 0, .width = width, .height = height, .filter = .nearest });
        canvas.fillRect(0, 0, @intCast(width), 12, up.core.Color.rgba(3, 5, 13, 220));
        var status: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&status, "SCORE {d}  BEST {d}  HP {d}  WAVE {d}", .{ self.score, self.best_score, self.player.health, self.wave });
        canvas.drawText(text, 3, 3, up.core.Color.rgb(231, 242, 255));
        canvas.drawText("ARROWS/STICK MOVE  SPACE/A SHOOT  X/B DASH", 3, 78, up.core.Color.rgb(173, 197, 222));
        canvas.drawText("ENTER/START RESTART  TAB/BACK TOGGLE AUDIO", 3, 84, up.core.Color.rgb(173, 197, 222));
        if (self.game_over) {
            canvas.fillRect(25, 31, 110, 26, up.core.Color.rgba(7, 9, 19, 230));
            canvas.drawText("SYSTEM BREACH", 48, 36, up.core.Color.rgb(255, 120, 151));
            canvas.drawText("PRESS ENTER TO RESTART", 31, 46, up.core.Color.rgb(235, 241, 250));
        }
    }

    fn reset(self: *Game, seed: u64) !void {
        self.rng = up.core.DeterministicRng.init(seed);
        self.player = .{ .active = true, .position = .{ .x = 40, .y = 34 }, .health = 3 };
        self.last_direction = .{ .x = 1, .y = 0 };
        self.score = 0;
        self.wave = 0;
        self.game_over = false;
        self.attack_cooldown = 0;
        self.hurt_cooldown = 0;
        self.enemies = [_]Actor{Actor{}} ** max_enemies;
        self.projectiles = [_]Actor{Actor{}} ** max_projectiles;
        self.pickups = [_]Actor{Actor{}} ** max_pickups;
        try self.spawnWave();
    }

    fn spawnWave(self: *Game) !void {
        self.wave += 1;
        const count = @min(max_enemies, @as(usize, 1 + self.wave));
        for (self.enemies[0..count]) |*enemy| {
            const side = try self.rng.uintBelow(4);
            const horizontal = 8 + @as(f32, @floatFromInt(try self.rng.uintBelow(104)));
            const vertical = 8 + @as(f32, @floatFromInt(try self.rng.uintBelow(54)));
            enemy.* = .{ .active = true, .position = switch (side) {
                0 => .{ .x = 3, .y = vertical },
                1 => .{ .x = 117, .y = vertical },
                2 => .{ .x = horizontal, .y = 3 },
                else => .{ .x = horizontal, .y = 67 },
            }, .health = 1 + @as(u8, @intCast(self.wave / 3)) };
        }
    }

    fn fire(self: *Game, ctx: *up.core.GameContext) !void {
        for (&self.projectiles) |*projectile| if (!projectile.active) {
            projectile.* = .{ .active = true, .position = self.player.position.add(self.last_direction.scale(4)), .velocity = self.last_direction.scale(110), .lifetime = 0.65 };
            self.attack_cooldown = 0.18;
            self.play(ctx, self.shot_sound, 0.3);
            return;
        };
    }

    fn spawnPickupAt(self: *Game, position: up.core.Vec2) void {
        for (&self.pickups) |*pickup| if (!pickup.active) {
            pickup.* = .{ .active = true, .position = position };
            return;
        };
    }

    fn updateBestScore(self: *Game, ctx: *up.core.GameContext) void {
        if (self.score <= self.best_score) return;
        self.best_score = self.score;
        self.saveSettings(ctx);
    }

    fn loadSettings(self: *Game, ctx: *up.core.GameContext) void {
        const saves = ctx.save_data orelse return;
        var bytes: [6]u8 = undefined;
        const value = saves.read("settings.v1", &bytes) catch return;
        if (value.len != bytes.len or bytes[0] != 1) return;
        self.audio_enabled = bytes[1] != 0;
        self.best_score = std.mem.readInt(u32, bytes[2..6], .little);
    }

    fn saveSettings(self: *const Game, ctx: *up.core.GameContext) void {
        const saves = ctx.save_data orelse return;
        var bytes: [6]u8 = undefined;
        bytes[0] = 1;
        bytes[1] = @intFromBool(self.audio_enabled);
        std.mem.writeInt(u32, bytes[2..6], self.best_score, .little);
        // Storage is external state. A failure preserves the current run and
        // leaves the in-memory best score/settings usable.
        saves.write("settings.v1", &bytes) catch {};
    }

    fn play(self: *Game, ctx: *up.core.GameContext, sound: ?up.core.Audio.SoundHandle, volume: f32) void {
        if (!self.audio_enabled) return;
        if (sound) |handle| if (ctx.audio) |audio| {
            _ = audio.play(handle, .{ .volume = volume }) catch {};
        };
    }
};

fn boolValue(value: bool) f32 {
    return if (value) 1 else 0;
}

fn distanceSquared(a: up.core.Vec2, b: up.core.Vec2) f32 {
    return a.sub(b).lenSq();
}

fn hasActive(values: []const Actor) bool {
    for (values) |value| if (value.active) return true;
    return false;
}

fn configureCombatScenario(game: *Game) void {
    game.player.position = .{ .x = 50, .y = 34 };
    game.player.health = 3;
    game.last_direction = .{ .x = 1, .y = 0 };
    game.score = 0;
    game.best_score = 4;
    game.wave = 1;
    game.enemies = [_]Actor{Actor{}} ** max_enemies;
    game.projectiles = [_]Actor{Actor{}} ** max_projectiles;
    game.pickups = [_]Actor{Actor{}} ** max_pickups;
    game.enemies[0] = .{ .active = true, .position = .{ .x = 60, .y = 34 }, .health = 1 };
}

fn scriptedAttackReplay(allocator: std.mem.Allocator) !up.preview.developer.InputReplay {
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, default_seed);
    defer recorder.deinit();
    var input = up.input.Input{};
    for (0..5) |_| {
        input.beginFrame();
        input.set(.action, true);
        try recorder.record(input);
    }
    input.beginFrame();
    input.set(.action, false);
    try recorder.record(input);
    return recorder.finish();
}

test "Neon Siege replays combat with seeded state, save data, Canvas trace, and pixels" {
    var replay = try scriptedAttackReplay(std.testing.allocator);
    defer replay.deinit(std.testing.allocator);

    var first_saves: up.testSupport.InMemorySaveStore = undefined;
    first_saves.init(std.testing.allocator);
    defer first_saves.deinit();
    var second_saves: up.testSupport.InMemorySaveStore = undefined;
    second_saves.init(std.testing.allocator);
    defer second_saves.deinit();
    const initial_settings = [_]u8{ 1, 1, 4, 0, 0, 0 };
    try first_saves.capability().write("settings.v1", &initial_settings);
    try second_saves.capability().write("settings.v1", &initial_settings);

    var first = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, first_saves.capability());
    defer first.deinit();
    configureCombatScenario(&first.game);
    try first.runReplay(replay);
    const first_capture = first.capture();

    var second = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, second_saves.capability());
    defer second.deinit();
    configureCombatScenario(&second.game);
    try second.runReplay(replay);
    const second_capture = second.capture();

    try std.testing.expectEqual(@as(u32, 10), first.game.score);
    try std.testing.expectEqual(@as(u32, 10), first.game.best_score);
    try std.testing.expect(first.audio.hasActivePlayback());
    try std.testing.expectEqual(first.game.score, second.game.score);
    try std.testing.expectEqual(first.game.wave, second.game.wave);
    try std.testing.expectEqual(first.game.player.position, second.game.player.position);
    try up.testSupport.expectCanvasTraceEqual(first_capture.canvas_trace, second_capture.canvas_trace);
    const trace_hash = try first_capture.canvas_trace.hash();
    try std.testing.expectEqual(@as(u64, 7_064_560_318_589_015_269), trace_hash);
    try std.testing.expectEqual(@as(u64, 10_160_251_712_926_268_076), first_capture.image_hash);
    try std.testing.expectEqual(trace_hash, try second_capture.canvas_trace.hash());
    try std.testing.expectEqual(first_capture.image_hash, second_capture.image_hash);
}

test "Neon Siege uses gamepad actions for movement and shooting" {
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer runner.deinit();
    configureCombatScenario(&runner.game);
    try std.testing.expect(runner.input.addGamepad(7));
    runner.input.setGamepadAxis(7, .left_x, 1, 0);
    const before = runner.game.player.position.x;
    try runner.run(&.{.{}});
    try std.testing.expect(runner.game.player.position.x > before);
    runner.input.setGamepadButton(7, .south, true);
    try runner.run(&.{.{}});
    try std.testing.expect(runner.audio.hasActivePlayback());
}

test "Neon Siege handles a breach and action-based restart" {
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer runner.deinit();
    configureCombatScenario(&runner.game);
    runner.game.player.health = 1;
    runner.game.enemies[0].position = runner.game.player.position;
    try runner.run(&.{.{}});
    try std.testing.expect(runner.game.game_over);
    try std.testing.expectEqual(@as(u8, 0), runner.game.player.health);

    runner.input.set(.start, true);
    try runner.run(&.{.{}});
    try std.testing.expect(!runner.game.game_over);
    try std.testing.expectEqual(@as(u8, 3), runner.game.player.health);
    try std.testing.expectEqual(@as(u32, 0), runner.game.score);
}

test "Neon Siege reads and writes its game-owned settings bytes" {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(std.testing.allocator);
    defer saves.deinit();
    const initial = [_]u8{ 1, 0, 9, 0, 0, 0 };
    try saves.capability().write("settings.v1", &initial);

    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeededWithSaveData(std.testing.allocator, width, height, default_seed, saves.capability());
    defer runner.deinit();
    try std.testing.expectEqual(@as(u32, 9), runner.game.best_score);
    try std.testing.expect(!runner.game.audio_enabled);
    runner.game.score = 12;
    runner.game.updateBestScore(&runner.context);
    var bytes: [6]u8 = undefined;
    _ = try saves.capability().read("settings.v1", &bytes);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, bytes[2..6], .little));
}

test "Neon Siege keeps playing when its save store rejects writes" {
    const FailingStore = struct {
        const vtable = up.core.SaveStore.VTable{
            .read_size = readSize,
            .read = read,
            .write = write,
            .delete = delete,
            .exists = exists,
        };

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
    runner.game.score = 20;
    runner.game.updateBestScore(&runner.context);
    try std.testing.expectEqual(@as(u32, 20), runner.game.best_score);
}
