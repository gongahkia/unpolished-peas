const std = @import("std");
const up = @import("unpolished-peas");
const art = @import("art.zig");
const sounds = @import("sounds.zig");
const ui = @import("ui.zig");
pub const width: u32 = 320;
pub const height: u32 = 200;
pub const world_width: u32 = 120;
pub const world_height: u32 = 70;
pub const default_seed: u64 = 0x4e45_4f4e_5349_4547;
pub const storage_id = "unpolished-peas.neon-siege";
const max_enemies = 8;
const max_projectiles = 12;
const max_pickups = 4;
const player_speed: f32 = 34;
pub const Screen = enum { title, playing, paused };
pub const Notice = enum { none, wave, hit, heal, pickup };
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
    .{ .name = "sprint", .binding = .{ .physical_key = .x } },
    .{ .name = "sprint", .binding = .{ .gamepad_button = .east } },
    .{ .name = "primary", .binding = .{ .key = .start } },
    .{ .name = "primary", .binding = .{ .gamepad_button = .start } },
    .{ .name = "toggle-audio", .binding = .{ .physical_key = .m } },
    .{ .name = "toggle-audio", .binding = .{ .gamepad_button = .back } },
    .{ .name = "pause", .binding = .{ .physical_key = .escape } },
    .{ .name = "new-run", .binding = .{ .physical_key = .r } },
    .{ .name = "new-run", .binding = .{ .gamepad_button = .left_shoulder } },
    .{ .name = "attack", .binding = .{ .gamepad_button = .right_shoulder } },
    .{ .name = "left", .binding = .{ .physical_key = .a } },
    .{ .name = "right", .binding = .{ .physical_key = .d } },
    .{ .name = "up", .binding = .{ .physical_key = .w } },
    .{ .name = "down", .binding = .{ .physical_key = .s } },
    .{ .name = "aim-left", .binding = .{ .physical_key = .j } },
    .{ .name = "aim-left", .binding = .{ .gamepad_axis = .{ .axis = .right_x, .sign = -1, .threshold = 0.15 } } },
    .{ .name = "aim-right", .binding = .{ .physical_key = .l } },
    .{ .name = "aim-right", .binding = .{ .gamepad_axis = .{ .axis = .right_x, .sign = 1, .threshold = 0.15 } } },
    .{ .name = "aim-up", .binding = .{ .physical_key = .i } },
    .{ .name = "aim-up", .binding = .{ .gamepad_axis = .{ .axis = .right_y, .sign = -1, .threshold = 0.15 } } },
    .{ .name = "aim-down", .binding = .{ .physical_key = .k } },
    .{ .name = "aim-down", .binding = .{ .gamepad_axis = .{ .axis = .right_y, .sign = 1, .threshold = 0.15 } } },
};

const Actor = struct { active: bool = false, position: up.core.Vec2 = .{}, velocity: up.core.Vec2 = .{}, health: u8 = 1, lifetime: f32 = 0, arming: u8 = 0, flash: u8 = 0 };
const Spark = struct { position: up.core.Vec2 = .{}, ticks: u8 = 0 };
pub const Game = struct {
    assets: ?up.assets.AssetCollection = null,
    actions: ?up.input.ActionMap = null,
    surface: ?up.graphics.RenderSurface = null,
    atlas: ?*up.assets.Atlas = null,
    font: ?*up.assets.Font = null,
    text: ui.Text = .{},
    player_animation: ?up.graphics.SpriteAnimationPlayer = null,
    enemy_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    projectile_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    pickup_frame: up.assets.AtlasFrameHandle = .{ .index = 0 },
    rng: up.core.DeterministicRng = up.core.DeterministicRng.init(default_seed),
    player: Actor = .{ .active = true, .position = .{ .x = 40, .y = 34 }, .health = 3 },
    enemies: [max_enemies]Actor = [_]Actor{.{}} ** max_enemies,
    projectiles: [max_projectiles]Actor = [_]Actor{.{}} ** max_projectiles,
    pickups: [max_pickups]Actor = [_]Actor{.{}} ** max_pickups,
    sparks: [8]Spark = [_]Spark{.{}} ** 8,
    last_direction: up.core.Vec2 = .{ .x = 1 },
    score: u32 = 0,
    best_score: u32 = 0,
    wave: u32 = 0,
    game_over: bool = false,
    screen: Screen = .title,
    audio_enabled: bool = true,
    attack_ticks: u8 = 0,
    hurt_ticks: u8 = 0,
    muzzle_ticks: u8 = 0,
    wave_delay: u8 = 0,
    notice: Notice = .none,
    notice_ticks: u8 = 0,
    save_failed: bool = false,
    load_problem: bool = false,
    sprinting: bool = false,
    shot_sound: ?up.core.Audio.SoundHandle = null,
    pickup_sound: ?up.core.Audio.SoundHandle = null,
    hurt_sound: ?up.core.Audio.SoundHandle = null,
    wave_sound: ?up.core.Audio.SoundHandle = null,
    background_music: ?up.core.Audio.MusicHandle = null,
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        self.* = .{};
        const allocator = try ctx.requireAllocator();
        self.assets = up.assets.AssetCollection.init(allocator);
        errdefer self.deinit(ctx) catch {};
        self.actions = try up.input.ActionMap.init(allocator, &controls);
        self.surface = try up.graphics.RenderSurface.init(allocator, world_width, world_height);
        const atlas = try self.assets.?.atlas(art.sprite_sheet_png, &art.frames, .{ .image_path = "neon-siege.png" });
        self.atlas = atlas;
        self.enemy_frame = atlas.findFrame("enemy") orelse return error.MissingEnemyFrame;
        self.projectile_frame = atlas.findFrame("projectile") orelse return error.MissingProjectileFrame;
        self.pickup_frame = atlas.findFrame("pickup") orelse return error.MissingPickupFrame;
        try art.player_idle_clip.validateForAtlas(atlas);
        try art.player_walk_clip.validateForAtlas(atlas);
        self.player_animation = try up.graphics.SpriteAnimationPlayer.init(&art.player_idle_clip);
        self.font = try self.assets.?.font(art.ui_font_ttf, .{ .pixel_height = 12, .atlas_width = 256, .atlas_height = 256 });
        try self.text.init(allocator, self.font.?);
        self.loadSettings(ctx);
        try self.reset(ctx.simulation_seed orelse default_seed);
        if (ctx.audio) |audio| {
            self.shot_sound = try audio.loadWav(sounds.shot_wav);
            self.pickup_sound = try audio.loadWav(sounds.pickup_wav);
            self.hurt_sound = try audio.loadWav(sounds.hurt_wav);
            self.wave_sound = try audio.loadWav(sounds.wave_wav);
            self.background_music = try audio.loadMusic(art.background_music_ogg, .{});
            self.syncMusic(audio);
        }
    }
    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void {
        if (ctx.audio) |audio| {
            if (self.shot_sound) |h| _ = audio.unloadSound(h);
            if (self.pickup_sound) |h| _ = audio.unloadSound(h);
            if (self.hurt_sound) |h| _ = audio.unloadSound(h);
            if (self.wave_sound) |h| _ = audio.unloadSound(h);
            if (self.background_music) |h| _ = audio.unloadMusic(h);
        }
        self.shot_sound = null;
        self.pickup_sound = null;
        self.hurt_sound = null;
        self.wave_sound = null;
        self.background_music = null;
        self.text.deinit();
        if (self.actions) |*a| a.deinit();
        self.actions = null;
        self.player_animation = null;
        if (self.assets) |*a| a.deinit();
        self.assets = null;
        self.atlas = null;
        self.font = null;
        if (self.surface) |*s| s.deinit();
        self.surface = null;
    }
    pub fn update(self: *Game, ctx: *up.core.GameContext, dt: f32) !void {
        const actions = if (self.actions) |*a| a else return error.GameNotInitialized;
        actions.update(ctx.input.*);
        if (actions.wasPressed("game", "toggle-audio")) {
            self.audio_enabled = !self.audio_enabled;
            self.saveSettings(ctx);
        }
        if (ctx.audio) |audio| self.syncMusic(audio);
        const primary = actions.wasPressed("game", "primary");
        const pause = actions.wasPressed("game", "pause");
        if (self.screen == .title) {
            if (primary) {
                try self.reset(ctx.simulation_seed orelse default_seed);
                self.screen = .playing;
                self.play(ctx, self.wave_sound, 0.2);
            }
            return;
        }
        if (actions.wasPressed("game", "new-run")) {
            try self.reset(ctx.simulation_seed orelse default_seed);
            self.screen = .playing;
            if (self.save_failed) self.saveSettings(ctx);
            return;
        }
        if (self.game_over) {
            if (primary) {
                try self.reset(ctx.simulation_seed orelse default_seed);
                if (self.save_failed) self.saveSettings(ctx);
            }
            return;
        }
        if (self.screen == .paused) {
            if (primary or pause) {
                self.screen = .playing;
                if (self.save_failed) self.saveSettings(ctx);
            }
            return;
        }
        if (primary or pause) {
            self.screen = .paused;
            return;
        }
        if (self.attack_ticks > 0) self.attack_ticks -= 1;
        if (self.hurt_ticks > 0) self.hurt_ticks -= 1;
        if (self.muzzle_ticks > 0) self.muzzle_ticks -= 1;
        if (self.notice_ticks > 0) self.notice_ticks -= 1;
        for (&self.sparks) |*spark| if (spark.ticks > 0) {
            spark.ticks -= 1;
        };
        var move = up.core.Vec2{ .x = actions.value(ctx.input.*, "game", "right") - actions.value(ctx.input.*, "game", "left"), .y = actions.value(ctx.input.*, "game", "down") - actions.value(ctx.input.*, "game", "up") };
        if (move.lenSq() > 1) move = move.normalized();
        const aim = up.core.Vec2{ .x = actions.value(ctx.input.*, "game", "aim-right") - actions.value(ctx.input.*, "game", "aim-left"), .y = actions.value(ctx.input.*, "game", "aim-down") - actions.value(ctx.input.*, "game", "aim-up") };
        if (aim.lenSq() > 0.01) self.last_direction = aim.normalized() else if (move.lenSq() > 0.01) self.last_direction = move.normalized();
        self.sprinting = actions.isDown("game", "sprint") and move.lenSq() > 0;
        const speed = player_speed * @as(f32, if (self.sprinting) 1.8 else 1);
        self.player.position.x = std.math.clamp(self.player.position.x + move.x * speed * dt, @as(f32, 4), @as(f32, 116));
        self.player.position.y = std.math.clamp(self.player.position.y + move.y * speed * dt, @as(f32, 4), @as(f32, 66));
        const animation = if (self.player_animation) |*a| a else return error.GameNotInitialized;
        const clip = if (move.lenSq() > 0.01) &art.player_walk_clip else &art.player_idle_clip;
        if (!animation.isCurrentClip(clip)) try animation.play(clip);
        animation.advance(1);
        if (actions.isDown("game", "attack") and self.attack_ticks == 0) self.fire(ctx);
        self.stepProjectiles(dt);
        self.stepEnemies(dt);
        self.resolveShots();
        self.resolveDamage(ctx);
        self.collectPickups(ctx, dt);
        self.updateBestScore(ctx);
        if (!self.game_over and !hasActive(&self.enemies)) {
            if (self.wave_delay == 0) {
                self.wave_delay = 45;
                self.notify(.wave, 60);
            } else {
                self.wave_delay -= 1;
                if (self.wave_delay == 0) {
                    try self.spawnWave();
                    self.play(ctx, self.wave_sound, 0.2);
                }
            }
        }
    }
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        try @import("presentation.zig").draw(self, ctx);
    }
    fn notify(self: *Game, notice: Notice, ticks: u8) void {
        self.notice = notice;
        self.notice_ticks = ticks;
    }
    fn reset(self: *Game, seed: u64) !void {
        self.rng = up.core.DeterministicRng.init(seed);
        self.player = .{ .active = true, .position = .{ .x = 40, .y = 34 }, .health = 3 };
        self.last_direction = .{ .x = 1 };
        self.score = 0;
        self.wave = 0;
        self.game_over = false;
        self.attack_ticks = 0;
        self.hurt_ticks = 0;
        self.muzzle_ticks = 0;
        self.wave_delay = 0;
        self.sprinting = false;
        self.enemies = [_]Actor{.{}} ** max_enemies;
        self.projectiles = [_]Actor{.{}} ** max_projectiles;
        self.pickups = [_]Actor{.{}} ** max_pickups;
        self.sparks = [_]Spark{.{}} ** 8;
        if (self.player_animation) |*a| a.restart();
        try self.spawnWave();
    }
    fn safeSpawn(self: *const Game, p: up.core.Vec2) bool {
        if (distanceSquared(p, self.player.position) < 28 * 28) return false;
        for (self.enemies) |enemy| if (enemy.active and distanceSquared(p, enemy.position) < 9 * 9) return false;
        return true;
    }
    fn spawnPosition(self: *Game) !up.core.Vec2 {
        for (0..24) |_| {
            const side = try self.rng.uintBelow(4);
            const x = 8 + @as(f32, @floatFromInt(try self.rng.uintBelow(104)));
            const y = 8 + @as(f32, @floatFromInt(try self.rng.uintBelow(54)));
            const p: up.core.Vec2 = switch (side) {
                0 => .{ .x = 4, .y = y },
                1 => .{ .x = 116, .y = y },
                2 => .{ .x = x, .y = 4 },
                else => .{ .x = x, .y = 66 },
            };
            if (self.safeSpawn(p)) return p;
        }
        var best = up.core.Vec2{ .x = 4, .y = 4 };
        var distance: f32 = -1;
        for (0..32) |index| {
            const along = @as(f32, @floatFromInt(index % 8)) / 7;
            const p: up.core.Vec2 = switch (index / 8) {
                0 => .{ .x = 4 + 112 * along, .y = 4 },
                1 => .{ .x = 4 + 112 * along, .y = 66 },
                2 => .{ .x = 4, .y = 4 + 62 * along },
                else => .{ .x = 116, .y = 4 + 62 * along },
            };
            const candidate = distanceSquared(p, self.player.position);
            if (self.safeSpawn(p) and candidate > distance) {
                best = p;
                distance = candidate;
            }
        }
        return best;
    }
    fn spawnWave(self: *Game) !void {
        self.wave +|= 1;
        self.notify(.wave, 60);
        for (self.enemies[0..@min(max_enemies, @as(usize, 1) + @min(7, self.wave))]) |*enemy| enemy.* = .{ .active = true, .position = try self.spawnPosition(), .health = 1 + @as(u8, @intCast(@min(3, self.wave / 3))), .arming = 45 };
    }
    fn fire(self: *Game, ctx: *up.core.GameContext) void {
        for (&self.projectiles) |*p| if (!p.active) {
            p.* = .{ .active = true, .position = self.player.position.add(self.last_direction.scale(4)), .velocity = self.last_direction.scale(110), .lifetime = 1.25 };
            self.attack_ticks = 10;
            self.muzzle_ticks = 3;
            self.play(ctx, self.shot_sound, 0.25);
            return;
        };
    }
    fn stepProjectiles(self: *Game, dt: f32) void {
        for (&self.projectiles) |*p| if (p.active) {
            p.position = p.position.add(p.velocity.scale(dt));
            p.lifetime -= dt;
            if (p.lifetime <= 0 or p.position.x < 0 or p.position.x > 120 or p.position.y < 0 or p.position.y > 70) p.active = false;
        };
    }
    fn stepEnemies(self: *Game, dt: f32) void {
        for (&self.enemies) |*e| if (e.active) {
            if (e.flash > 0) e.flash -= 1;
            if (e.arming > 0) {
                e.arming -= 1;
                continue;
            }
            e.position = e.position.add(self.player.position.sub(e.position).normalized().scale((13 + @as(f32, @floatFromInt(@min(12, self.wave))) * 0.6) * dt));
        };
    }
    fn addSpark(self: *Game, p: up.core.Vec2) void {
        for (&self.sparks) |*s| if (s.ticks == 0) {
            s.* = .{ .position = p, .ticks = 8 };
            return;
        };
    }
    fn resolveShots(self: *Game) void {
        for (&self.projectiles) |*p| if (p.active) {
            for (&self.enemies) |*e| if (e.active and e.arming == 0 and distanceSquared(p.position, e.position) < 24) {
                p.active = false;
                e.health -|= 1;
                e.flash = 5;
                self.addSpark(e.position);
                if (e.health == 0) {
                    e.active = false;
                    self.score +|= 10;
                    self.spawnPickupAt(e.position);
                }
                break;
            };
        };
    }
    fn resolveDamage(self: *Game, ctx: *up.core.GameContext) void {
        if (self.hurt_ticks > 0) return;
        for (&self.enemies) |*e| if (e.active and e.arming == 0 and distanceSquared(e.position, self.player.position) < 30) {
            self.player.health -|= 1;
            self.hurt_ticks = 30;
            e.active = false;
            self.notify(.hit, 30);
            self.play(ctx, self.hurt_sound, 0.4);
            self.game_over = self.player.health == 0;
            return;
        };
    }
    fn spawnPickupAt(self: *Game, position: up.core.Vec2) void {
        for (&self.pickups) |*p| if (!p.active) {
            p.* = .{ .active = true, .position = position, .lifetime = 10 };
            return;
        };
    }
    fn collectPickups(self: *Game, ctx: *up.core.GameContext, dt: f32) void {
        if (self.game_over) return;
        for (&self.pickups) |*p| if (p.active) {
            p.lifetime -= dt;
            if (p.lifetime <= 0) {
                p.active = false;
                continue;
            }
            if (distanceSquared(p.position, self.player.position) < 36) {
                p.active = false;
                self.score +|= 5;
                const healed = self.player.health < 3;
                if (healed) self.player.health += 1;
                self.notify(if (healed) .heal else .pickup, 30);
                self.play(ctx, self.pickup_sound, 0.35);
            }
        };
    }
    fn updateBestScore(self: *Game, ctx: *up.core.GameContext) void {
        if (self.score > self.best_score) {
            self.best_score = self.score;
            self.saveSettings(ctx);
        }
    }
    fn loadSettings(self: *Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse return;
        var bytes: [6]u8 = undefined;
        const saved = store.read("settings.v1", &bytes) catch |err| {
            self.load_problem = err != error.NotFound;
            return;
        };
        if (saved.len != 6 or bytes[0] != 1 or bytes[1] > 1) {
            self.load_problem = true;
            return;
        }
        self.audio_enabled = bytes[1] == 1;
        self.best_score = std.mem.readInt(u32, bytes[2..6], .little);
    }
    fn saveSettings(self: *Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse {
            self.save_failed = true;
            return;
        };
        var bytes = [_]u8{ 1, @intFromBool(self.audio_enabled), 0, 0, 0, 0 };
        std.mem.writeInt(u32, bytes[2..6], self.best_score, .little);
        store.write("settings.v1", &bytes) catch {
            self.save_failed = true;
            return;
        };
        self.save_failed = false;
        self.load_problem = false;
    }
    fn play(self: *const Game, ctx: *up.core.GameContext, sound: ?up.core.Audio.SoundHandle, volume: f32) void {
        if (!self.audio_enabled) return;
        if (ctx.audio) |audio| if (sound) |h| {
            _ = audio.play(h, .{ .volume = volume }) catch {};
        };
    }
    fn syncMusic(self: *Game, audio: *up.core.Audio) void {
        if (!self.audio_enabled) {
            _ = audio.stopMusic();
            return;
        }
        if (audio.availability() != .ready) return;
        const volume: f32 = if (self.screen == .playing and !self.game_over) 0.09 else 0.03;
        if (audio.musicState() == .playing) {
            _ = audio.setMusicVolume(volume) catch false;
            return;
        }
        if (self.background_music) |h| {
            _ = audio.playMusic(h, .{ .volume = volume, .loop = true }) catch {};
        }
    }
};
fn distanceSquared(a: up.core.Vec2, b: up.core.Vec2) f32 {
    return a.sub(b).lenSq();
}
fn hasActive(values: []const Actor) bool {
    for (values) |value| if (value.active) return true;
    return false;
}

fn configureCombatScenario(game: *Game) void {
    game.screen = .playing;
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
    const evidence = std.process.getEnvVarOwned(std.testing.allocator, "NEON_POLISH_EVIDENCE") catch null;
    if (evidence) |directory| {
        defer std.testing.allocator.free(directory);
        try std.fs.cwd().makePath(directory);
        var path: [1024]u8 = undefined;
        try first.canvas.writePngFile(try std.fmt.bufPrint(&path, "{s}/arranged-combat.png", .{directory}));
        std.debug.print("intentional Neon presentation: trace={d} pixels={d}\n", .{ trace_hash, first_capture.image_hash });
    }

    try std.testing.expectEqual(@as(u64, 7_243_524_748_433_357_246), trace_hash);
    try std.testing.expectEqual(@as(u64, 17_989_705_235_413_542_961), first_capture.image_hash);
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

test "Neon Siege advances its player animation in fixed update, not draw" {
    var runner = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer runner.deinit();
    runner.game.screen = .playing;

    try runner.run(&.{.{ .buttons = up.testSupport.Buttons.right }});
    const animation = runner.game.player_animation orelse return error.MissingPlayerAnimation;
    try std.testing.expect(animation.isCurrentClip(&art.player_walk_clip));
    try std.testing.expectEqual(@as(usize, 0), animation.currentFrame().index);

    // Extra presentation draws never advance the game-owned player.
    try runner.protocol.draw(&runner.context, 0);
    try runner.protocol.draw(&runner.context, 0);
    try std.testing.expectEqual(@as(usize, 0), (runner.game.player_animation orelse return error.MissingPlayerAnimation).currentFrame().index);

    try runner.run(&.{
        .{ .buttons = up.testSupport.Buttons.right },
        .{ .buttons = up.testSupport.Buttons.right },
        .{ .buttons = up.testSupport.Buttons.right },
        .{ .buttons = up.testSupport.Buttons.right },
        .{ .buttons = up.testSupport.Buttons.right },
    });
    try std.testing.expectEqual(@as(usize, 1), (runner.game.player_animation orelse return error.MissingPlayerAnimation).currentFrame().index);
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

test {
    _ = @import("route.zig");
}

const Runner = up.testSupport.HeadlessGameRunner(Game);
fn controlsStep(r: *Runner, input: *up.input.Input) !void {
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
}

test "sprint is held speed, preserves normalized diagonals and grants no immunity" {
    const a = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer a.deinit();
    const b = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer b.deinit();
    a.game.screen = .playing;
    b.game.screen = .playing;
    a.game.enemies = [_]Actor{.{}} ** max_enemies;
    b.game.enemies = a.game.enemies;
    var normal = up.input.Input{};
    normal.set(.right, true);
    var fast = normal;
    fast.setPhysical(.x, true, false);
    for (0..10) |_| {
        try controlsStep(a, &normal);
        try controlsStep(b, &fast);
    }
    const ordinary = a.game.player.position.x - 40;
    const boosted = b.game.player.position.x - 40;
    try std.testing.expectApproxEqAbs(ordinary * 1.8, boosted, 0.001);
    try std.testing.expect(b.game.sprinting and b.game.hurt_ticks == 0);
    const diagonal_start = a.game.player.position;
    normal.set(.down, true);
    for (0..10) |_| try controlsStep(a, &normal);
    const diagonal = a.game.player.position.sub(diagonal_start).len();
    try std.testing.expectApproxEqAbs(ordinary, diagonal, 0.001);

    b.game.enemies[0] = .{ .active = true, .position = b.game.player.position };
    try controlsStep(b, &fast);
    try std.testing.expectEqual(@as(u8, 2), b.game.player.health);
}

test "explicit aim overrides movement and held fire uses one fixed cadence" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    r.game.screen = .playing;
    r.game.enemies = [_]Actor{.{}} ** max_enemies;
    r.game.player.position.x = 60;
    var input = up.input.Input{};
    input.set(.right, true);
    input.setPhysical(.j, true, false);
    input.set(.action, true);
    try controlsStep(r, &input);
    try std.testing.expect(r.game.player.position.x > 40 and r.game.last_direction.x == -1);
    try std.testing.expect(r.game.projectiles[0].velocity.x < 0);
    input.set(.right, false);
    input.setPhysical(.j, false, false);
    input.setPhysical(.l, true, false);
    for (0..29) |_| try controlsStep(r, &input);
    var active: usize = 0;
    for (r.game.projectiles) |p| if (p.active) {
        active += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), active);
}

test "spawn safety holds at arena corners and late waves keep bounded enemy health" {
    var g = Game{};
    for ([_]up.core.Vec2{ .{ .x = 4, .y = 4 }, .{ .x = 116, .y = 4 }, .{ .x = 4, .y = 66 }, .{ .x = 116, .y = 66 }, .{ .x = 60, .y = 35 } }) |position| {
        g.player.position = position;
        g.enemies = [_]Actor{.{}} ** max_enemies;
        g.wave = std.math.maxInt(u32);
        try g.spawnWave();
        for (g.enemies) |e| {
            try std.testing.expect(e.active and e.arming == 45 and e.health <= 4);
            try std.testing.expect(distanceSquared(e.position, position) >= 28 * 28);
            try std.testing.expect(e.position.x >= 4 and e.position.x <= 116 and e.position.y >= 4 and e.position.y <= 66);
        }
    }
}

test "spawn warnings cannot damage early and existing recovery protects exactly its ticks" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    r.game.screen = .playing;
    r.game.enemies = [_]Actor{.{}} ** max_enemies;
    r.game.enemies[0] = .{ .active = true, .position = r.game.player.position, .arming = 3 };
    r.game.enemies[1] = r.game.enemies[0];
    var input = up.input.Input{};
    try controlsStep(r, &input);
    try controlsStep(r, &input);
    try std.testing.expectEqual(@as(u8, 3), r.game.player.health);
    try controlsStep(r, &input);
    try std.testing.expectEqual(@as(u8, 2), r.game.player.health);
    for (0..29) |_| try controlsStep(r, &input);
    try std.testing.expectEqual(@as(u8, 2), r.game.player.health);
    try controlsStep(r, &input);
    try std.testing.expectEqual(@as(u8, 1), r.game.player.health);
}

test "pause freezes actors cooldowns animation and released actions do not leak" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    r.game.screen = .playing;
    var input = up.input.Input{};
    input.setPhysical(.escape, true, false);
    try controlsStep(r, &input);
    const player = r.game.player.position;
    const enemies = r.game.enemies;
    const frame = r.game.player_animation.?.currentFrame();
    input.set(.action, true);
    input.set(.right, true);
    for (0..20) |_| try controlsStep(r, &input);
    try std.testing.expectEqualDeep(enemies, r.game.enemies);
    try std.testing.expectEqual(player, r.game.player.position);
    try std.testing.expectEqual(frame, r.game.player_animation.?.currentFrame());
    input.set(.action, false);
    input.set(.right, false);
    input.setPhysical(.escape, false, false);
    input.set(.start, true);
    try controlsStep(r, &input);
    input.set(.start, false);
    try controlsStep(r, &input);
    try std.testing.expect(!hasActive(&r.game.projectiles));
}

test "blocked music retries without a mute toggle and all prepared copy fits" {
    const r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    _ = r.audio.stopMusic();
    r.audio.setAvailability(.blocked);
    var input = up.input.Input{};
    try controlsStep(r, &input);
    try std.testing.expectEqual(up.core.Audio.MusicState.stopped, r.audio.musicState());
    r.audio.setAvailability(.ready);
    try controlsStep(r, &input);
    try std.testing.expectEqual(up.core.Audio.MusicState.playing, r.audio.musicState());
    for (r.game.text.layouts) |layout| try std.testing.expect(layout.?.metrics.width <= 304);
}

fn partialInitialization(allocator: std.mem.Allocator) !void {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = allocator;
    var g = Game{};
    try g.init(&ctx);
    defer g.deinit(&ctx) catch unreachable;
}
test "every partial initialization releases layouts atlas font surface and actions" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, partialInitialization, .{});
}

test "restarts retain resources and three lifecycles unload their audio sources" {
    var input = up.input.Input{};
    var ctx = up.core.GameContext.init(&input);
    ctx.allocator = std.testing.allocator;
    var audio = try up.core.Audio.init(std.testing.allocator, .{});
    defer audio.deinit();
    ctx.audio = &audio;
    var g = Game{};
    var previous_slot: ?usize = null;
    for (0..3) |_| {
        try g.init(&ctx);
        const atlas = g.atlas.?;
        const font = g.font.?;
        const sound = g.shot_sound.?;
        const music = g.background_music.?;
        if (previous_slot) |slot| try std.testing.expectEqual(slot, music.index);
        previous_slot = music.index;
        for (0..12) |_| try g.reset(default_seed);
        try std.testing.expect(atlas == g.atlas.? and font == g.font.?);
        try std.testing.expectEqual(sound, g.shot_sound.?);
        try g.deinit(&ctx);
        try std.testing.expect(!audio.hasActivePlayback());
        try std.testing.expectError(error.InvalidSound, audio.play(sound, .{}));
        try std.testing.expectError(error.InvalidMusic, audio.playMusic(music, .{}));
    }
}
