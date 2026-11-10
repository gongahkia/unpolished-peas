const std = @import("std");
const up = @import("unpolished-peas");
const world = @import("world.zig");
const combat = @import("combat.zig");
const save = @import("save.zig");
const sound = @import("sound.zig");
const typography = @import("typography.zig");
pub const width: u32 = 480;
pub const height: u32 = 270;
pub const default_seed: u64 = 0x415348454e;
pub const storage_id = "unpolished-peas.ashen-causeway";
const Color = up.core.Color;
const Vec = world.Vec;
const bindings = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },                                                        .{ .name = "left", .binding = .{ .physical_key = .a } },
    .{ .name = "right", .binding = .{ .key = .right } },                                                      .{ .name = "right", .binding = .{ .physical_key = .d } },
    .{ .name = "up", .binding = .{ .key = .up } },                                                            .{ .name = "up", .binding = .{ .physical_key = .w } },
    .{ .name = "down", .binding = .{ .key = .down } },                                                        .{ .name = "down", .binding = .{ .physical_key = .s } },
    .{ .name = "left", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1, .threshold = 0.15 } } }, .{ .name = "right", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .threshold = 0.15 } } },
    .{ .name = "up", .binding = .{ .gamepad_axis = .{ .axis = .left_y, .sign = -1, .threshold = 0.15 } } },   .{ .name = "down", .binding = .{ .gamepad_axis = .{ .axis = .left_y, .threshold = 0.15 } } },
    .{ .name = "light", .binding = .{ .physical_key = .j } },                                                 .{ .name = "light", .binding = .{ .pointer_button = .left } },
    .{ .name = "light", .binding = .{ .gamepad_button = .left_shoulder } },                                   .{ .name = "heavy", .binding = .{ .physical_key = .k } },
    .{ .name = "heavy", .binding = .{ .pointer_button = .right } },                                           .{ .name = "heavy", .binding = .{ .gamepad_button = .right_shoulder } },
    .{ .name = "dodge", .binding = .{ .key = .action } },                                                     .{ .name = "dodge", .binding = .{ .gamepad_button = .south } },
    .{ .name = "heal", .binding = .{ .physical_key = .h } },                                                  .{ .name = "heal", .binding = .{ .gamepad_button = .north } },
    .{ .name = "interact", .binding = .{ .physical_key = .e } },                                              .{ .name = "interact", .binding = .{ .gamepad_button = .west } },
    .{ .name = "swap", .binding = .{ .physical_key = .q } },                                                  .{ .name = "swap", .binding = .{ .gamepad_button = .back } },
    .{ .name = "pause", .binding = .{ .key = .cancel } },                                                     .{ .name = "pause", .binding = .{ .gamepad_button = .start } },
    .{ .name = "confirm", .binding = .{ .key = .start } },
};
const Screen = enum { title, play, pause, death, settings, victory, credits };
pub const Game = struct {
    state: world.World = .{},
    soundscape: sound.Sound = .{},
    typefaces: typography.Typography = .{},
    action_notice: u8 = 0,
    tutorial_stage: u8 = 0,
    movement_teach: u8 = 0,
    stride: u32 = 0,
    walking: bool = false,
    actions: ?up.input.ActionMap = null,
    screen: Screen = .title,
    camera: Vec = .{},
    mouse_aim: bool = false,
    settings: save.Settings = .{},
    selected: usize = 0,
    return_screen: Screen = .title,
    journey_started: bool = false,
    save_failed: bool = false,
    load_problem: bool = false,
    load_note: []const u8 = "No saved journey. Begin when ready.",
    pub fn init(g: *Game, ctx: *up.core.GameContext) !void {
        errdefer g.deinit(ctx) catch {};
        g.actions = try up.input.ActionMap.init(try ctx.requireAllocator(), &bindings);
        try g.typefaces.init(try ctx.requireAllocator());
        g.state = world.World.init();
        g.load(ctx);
        g.soundscape.init(ctx);
        g.follow();
    }
    pub fn deinit(g: *Game, ctx: *up.core.GameContext) !void {
        g.soundscape.deinit(ctx);
        g.typefaces.deinit();
        if (g.actions) |*a| a.deinit();
        g.actions = null;
    }
    fn pressed(g: *Game, name: []const u8) bool {
        return g.actions.?.wasPressed("game", name);
    }
    fn value(g: *Game, ctx: *up.core.GameContext, name: []const u8) f32 {
        return g.actions.?.value(ctx.input.*, "game", name);
    }
    fn follow(g: *Game) void {
        g.camera = .{ .x = std.math.clamp(g.state.pos.x - 240, 0, 480), .y = std.math.clamp(g.state.pos.y - 135, 0, 270) };
        if (g.settings.shake and g.state.hurt_feedback > 0) g.camera.x += if (g.state.hurt_feedback % 2 == 0) @as(f32, 2) else -2;
    }
    pub fn update(g: *Game, ctx: *up.core.GameContext, _: f32) !void {
        g.actions.?.update(ctx.input.*);
        g.soundscape.ensureMusic(ctx, g.settings.music);
        if (g.action_notice > 0) g.action_notice -= 1;
        if (g.screen != .play and (g.pressed("confirm") or g.pressed("interact") or g.pressed("up") or g.pressed("down"))) g.soundscape.play(ctx, .menu, g.settings.effects);
        if (g.screen != .play) {
            try g.menu(ctx);
            return;
        }
        if (g.pressed("pause")) {
            g.screen = .pause;
            g.selected = 0;
            return;
        }
        const before = save.encode(g.state, g.settings);
        var cmd = world.Command{ .movement = .{ .x = g.value(ctx, "right") - g.value(ctx, "left"), .y = g.value(ctx, "down") - g.value(ctx, "up") }, .interact = g.pressed("interact"), .swap = g.pressed("swap") };
        if (cmd.movement.length() > 0.1) g.mouse_aim = false;
        if (ctx.input.pointer.delta.x != 0 or ctx.input.pointer.delta.y != 0 or ctx.input.pointerWasPressed(.left) or ctx.input.pointerWasPressed(.right)) g.mouse_aim = true;
        if (g.mouse_aim) if (ctx.input.pointer.canvas) |p| {
            if (std.math.isFinite(p.x) and std.math.isFinite(p.y)) cmd.aim = (Vec{ .x = p.x + g.camera.x, .y = p.y + g.camera.y }).sub(g.state.pos);
        };
        for (ctx.input.gamepads) |slot| if (slot) |pad| {
            const aim = Vec{ .x = pad.axis(.right_x), .y = pad.axis(.right_y) };
            if (aim.length() > 0.25) {
                cmd.aim = aim;
                g.mouse_aim = false;
            }
        };
        inline for (.{ combat.Action.light, combat.Action.heavy, combat.Action.dodge, combat.Action.heal }) |a| {
            if (g.pressed(@tagName(a))) cmd.action = a;
        }
        g.walking = cmd.movement.length() > 0.1 and g.state.player.action == .idle;
        if (g.walking) g.stride +%= 1;
        const old_hp = g.state.player.hp;
        g.state.tick(cmd);
        if (g.state.player.rejected) {
            g.action_notice = 36;
            g.soundscape.play(ctx, .reject, g.settings.effects);
        }
        if (g.state.hit_feedback == 8) g.soundscape.play(ctx, .hit, g.settings.effects);
        if (g.state.hurt_feedback == 12) g.soundscape.play(ctx, .hurt, g.settings.effects);
        if (g.state.player.hp > old_hp) g.soundscape.play(ctx, .heal, g.settings.effects);
        if (g.state.player.active() and g.state.player.age == combat.spec(g.state.player.weapon, g.state.player.action).startup) g.soundscape.play(ctx, .swing, g.settings.effects);
        if (cmd.interact) g.soundscape.play(ctx, .bell, g.settings.effects);
        for (g.state.enemies) |e| if (e.hp > 0 and ((e.stage == .windup or e.stage == .transition) and e.age == 0)) {
            g.soundscape.play(ctx, .bell, g.settings.effects / 2);
        };
        if (g.tutorial_stage == 0 and cmd.movement.length() > 0.1) {
            g.movement_teach +|= 1;
            if (g.movement_teach >= 30) g.tutorial_stage = 1;
        }
        if (g.state.player.accepted) {
            if (g.tutorial_stage == 1 and (g.state.player.action == .light or g.state.player.action == .heavy)) g.tutorial_stage = 2;
            if (g.tutorial_stage == 2 and g.state.player.action == .dodge) g.tutorial_stage = 3;
            if (g.tutorial_stage == 3 and g.state.player.action == .heal) g.tutorial_stage = 4;
        }
        if (g.tutorial_stage == 4 and cmd.interact and g.state.nearLantern()) g.tutorial_stage = 5;
        g.follow();
        if (g.state.player.hp == 0) g.screen = .death;
        if (g.state.completed) g.screen = .victory;
        const after = save.encode(g.state, g.settings);
        if (!std.mem.eql(u8, &before, &after)) g.persist(ctx);
    }
    fn load(g: *Game, ctx: *up.core.GameContext) void {
        const store = ctx.save_data orelse {
            g.load_note = "Storage unavailable. Play remains available.";
            return;
        };
        var bytes: [save.size]u8 = undefined;
        const data = store.read(save.key, &bytes) catch |err| {
            g.load_problem = err != error.NotFound;
            g.load_note = if (err == error.NotFound) "No saved journey. Begin when ready." else "Save unreadable. New Game replaces it.";
            return;
        };
        const loaded = save.decode(data) catch {
            g.load_problem = true;
            g.load_note = "Save corrupt or unsupported. New Game replaces it.";
            return;
        };
        g.state = loaded.state;
        g.settings = loaded.settings;
        g.journey_started = true;
        g.tutorial_stage = 5;
        g.load_note = "Journey found. Continue from your last lantern.";
    }
    fn persist(g: *Game, ctx: *up.core.GameContext) void {
        if (g.load_problem and !g.journey_started) {
            g.save_failed = true;
            return;
        }
        const store = ctx.save_data orelse {
            g.save_failed = true;
            return;
        };
        const bytes = save.encode(g.state, g.settings);
        store.write(save.key, &bytes) catch {
            g.save_failed = true;
            return;
        };
        g.save_failed = false;
    }
    fn menu(g: *Game, ctx: *up.core.GameContext) !void {
        const confirm = g.pressed("confirm") or g.pressed("interact") or g.pressed("dodge");
        if (g.screen == .death) {
            if (confirm) {
                g.state.respawn();
                g.screen = .play;
                g.follow();
                g.persist(ctx);
            }
            return;
        }
        if (g.screen == .victory) {
            if (g.pressed("pause")) g.persist(ctx);
            if (confirm) g.screen = .credits;
            return;
        }
        if (g.screen == .credits) {
            if (confirm or g.pressed("pause")) {
                g.screen = .title;
                g.selected = 0;
            }
            return;
        }
        const count: usize = switch (g.screen) {
            .title => 4,
            .pause => 8,
            .settings => 4,
            else => unreachable,
        };
        if (g.pressed("down")) g.selected = (g.selected + 1) % count;
        if (g.pressed("up")) g.selected = (g.selected + count - 1) % count;
        if (g.screen == .settings) {
            if (g.pressed("pause")) {
                g.screen = g.return_screen;
                g.selected = 0;
                return;
            }
            const change: i16 = if (g.pressed("left")) -10 else if (g.pressed("right") or confirm) 10 else 0;
            if (change != 0) {
                switch (g.selected) {
                    0 => g.settings.music = @intCast(std.math.clamp(@as(i16, g.settings.music) + change, 0, 100)),
                    1 => g.settings.effects = @intCast(std.math.clamp(@as(i16, g.settings.effects) + change, 0, 100)),
                    2 => g.settings.shake = !g.settings.shake,
                    3 => g.settings.flash = !g.settings.flash,
                    else => unreachable,
                }
                g.persist(ctx);
            }
            return;
        }
        if (g.screen == .pause and g.pressed("pause")) {
            g.screen = .play;
            return;
        }
        if (!confirm) return;
        if (g.screen == .title) {
            switch (g.selected) {
                0 => {
                    if (g.load_problem and !g.journey_started) return;
                    if (!g.journey_started) {
                        g.journey_started = true;
                        g.persist(ctx);
                    }
                    g.screen = if (g.state.completed) .victory else .play;
                    g.follow();
                },
                1 => {
                    g.state = world.World.init();
                    g.tutorial_stage = 0;
                    g.movement_teach = 0;
                    g.journey_started = true;
                    g.persist(ctx);
                    g.screen = .play;
                    g.follow();
                },
                2 => {
                    g.return_screen = .title;
                    g.screen = .settings;
                    g.selected = 0;
                },
                3 => g.screen = .credits,
                else => unreachable,
            }
        } else {
            switch (g.selected) {
                0 => g.screen = .play,
                1 => g.persist(ctx),
                2 => {
                    _ = g.state.purchase(false);
                    g.persist(ctx);
                },
                3 => {
                    _ = g.state.purchase(true);
                    g.persist(ctx);
                },
                4 => {
                    _ = g.state.toggleCharm();
                    g.persist(ctx);
                },
                5 => {
                    g.return_screen = .pause;
                    g.screen = .settings;
                    g.selected = 0;
                },
                6 => g.screen = .credits,
                7 => {
                    g.screen = .title;
                    g.selected = 0;
                },
                else => unreachable,
            }
        }
    }
    fn text(g: *const Game, c: *up.graphics.Canvas, label: []const u8, x: i32, y: i32, color: Color) void {
        g.typefaces.draw(c, label, x, y, color);
    }
    fn rect(g: *const Game, c: *up.graphics.Canvas, r: world.Rect, color: Color) void {
        c.fillRect(@intFromFloat(r.x - g.camera.x), @intFromFloat(r.y - g.camera.y), @intFromFloat(r.w), @intFromFloat(r.h), color);
    }
    fn circle(g: *const Game, c: *up.graphics.Canvas, p: Vec, r: i32, color: Color) void {
        c.fillCircle(@intFromFloat(p.x - g.camera.x), @intFromFloat(p.y - g.camera.y), r, color);
    }
    fn line(g: *const Game, c: *up.graphics.Canvas, a: Vec, b: Vec, color: Color) void {
        c.line(@intFromFloat(a.x - g.camera.x), @intFromFloat(a.y - g.camera.y), @intFromFloat(b.x - g.camera.x), @intFromFloat(b.y - g.camera.y), color);
    }
    fn ringOutline(g: *const Game, c: *up.graphics.Canvas, center: Vec, radius: f32, color: Color, dotted: bool) void {
        var previous = center.add(.{ .x = radius });
        for (1..81) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.tau / 80;
            const p = center.add(.{ .x = @cos(a) * radius, .y = @sin(a) * radius });
            if ((!dotted or i % 2 == 0) and world.visible(g.state.room, center, p)) g.line(c, previous, p, color);
            previous = p;
        }
    }
    fn telegraph(g: *const Game, c: *up.graphics.Canvas, e: world.Enemy, color: Color) void {
        if (e.attack == .ring) {
            g.ringOutline(c, e.pos, 200, color, true);
            g.ringOutline(c, e.pos, 20, color, true);
            return;
        }
        if (e.kind == .censer) {
            var n: f32 = 12;
            while (n < 200) : (n += 9) {
                const p = e.pos.add(e.aim.scale(n));
                if (!world.visible(g.state.room, e.pos, p)) break;
                g.circle(c, p, 1, color);
            }
            return;
        }
        if (e.kind == .pike or e.kind == .hound) {
            const side = Vec{ .x = -e.aim.y, .y = e.aim.x };
            const half: f32 = if (e.kind == .pike) 10 else 14;
            for ([_]f32{ -half, half }) |offset| {
                const a = e.pos.add(side.scale(offset));
                const extent = e.reach() + (if (e.kind == .hound) (if (e.stage == .windup) @as(f32, 27) else @as(f32, @floatFromInt(9 -| e.age)) * 3) else 0);
                const b = a.add(e.aim.scale(extent));
                if (world.visible(g.state.room, a, b)) g.line(c, a, b, color);
            }
            return;
        }
        const angle = std.math.atan2(e.aim.y, e.aim.x);
        var last = e.pos.add(.{ .x = @cos(angle - 1.104) * e.reach(), .y = @sin(angle - 1.104) * e.reach() });
        if (world.visible(g.state.room, e.pos, last)) g.line(c, e.pos, last, color);
        for (1..17) |i| {
            const a = angle - 1.104 + 2.208 * @as(f32, @floatFromInt(i)) / 16;
            const p = e.pos.add(.{ .x = @cos(a) * e.reach(), .y = @sin(a) * e.reach() });
            if (world.visible(g.state.room, e.pos, p)) g.line(c, last, p, color);
            last = p;
        }
        if (world.visible(g.state.room, e.pos, last)) g.line(c, e.pos, last, color);
    }
    fn scenery(g: *const Game, c: *up.graphics.Canvas) void {
        const stone = Color.rgb(91, 111, 115);
        const gold = Color.rgb(239, 185, 96);
        const ink = Color.rgb(15, 28, 38);
        // Quiet decorative detail stays outside the collision geometry.
        for (0..28) |i| {
            const y = 48 + @as(f32, @floatFromInt(i)) * 17;
            g.line(c, .{ .x = 0, .y = y }, .{ .x = 12, .y = y - 2 }, Color.rgb(40, 64, 77));
            g.line(c, .{ .x = 948, .y = y }, .{ .x = 960, .y = y + 2 }, Color.rgb(40, 64, 77));
        }
        // Lantern pedestal, frame and flame sit above the rest location.
        g.rect(c, .{ .x = 58, .y = 268, .w = 24, .h = 5 }, stone);
        g.rect(c, .{ .x = 68, .y = 247, .w = 4, .h = 23 }, stone);
        g.rect(c, .{ .x = 63, .y = 240, .w = 14, .h = 15 }, gold);
        g.rect(c, .{ .x = 65, .y = 242, .w = 10, .h = 11 }, ink);
        g.circle(c, .{ .x = 70, .y = 247 }, 3, gold);
        g.text(c, "E - REST", 46 - @as(i32, @intFromFloat(g.camera.x)), 290 - @as(i32, @intFromFloat(g.camera.y)), gold);
        // The mooring bell is a landmark, with a clapper and stone arch.
        g.rect(c, .{ .x = 850, .y = 422, .w = 4, .h = 34 }, stone);
        g.rect(c, .{ .x = 886, .y = 422, .w = 4, .h = 34 }, stone);
        g.rect(c, .{ .x = 850, .y = 420, .w = 40, .h = 4 }, stone);
        g.rect(c, .{ .x = 868, .y = 424, .w = 4, .h = 8 }, gold);
        g.rect(c, .{ .x = 860, .y = 432, .w = 20, .h = 16 }, gold);
        g.rect(c, .{ .x = 857, .y = 447, .w = 26, .h = 4 }, gold);
        g.circle(c, .{ .x = 870, .y = 452 }, 3, ink);
        g.text(c, "E - RING", 846 - @as(i32, @intFromFloat(g.camera.x)), 467 - @as(i32, @intFromFloat(g.camera.y)), gold);
        if (g.state.room < 2) {
            g.rect(c, .{ .x = 922, .y = 245, .w = 5, .h = 50 }, stone);
            g.text(c, if (g.state.bells[g.state.room]) "PASSAGE" else "BELL FIRST", 876 - @as(i32, @intFromFloat(g.camera.x)), 300 - @as(i32, @intFromFloat(g.camera.y)), gold);
        }
        if (g.state.shortcut and g.state.room < 2) {
            g.rect(c, .{ .x = 96, .y = 436, .w = 28, .h = 28 }, stone);
            for (0..4) |i| {
                const x = 100 + @as(f32, @floatFromInt(i)) * 6;
                g.line(c, .{ .x = x, .y = 438 }, .{ .x = x, .y = 462 }, ink);
            }
            g.text(c, "E - LIFT", 87 - @as(i32, @intFromFloat(g.camera.x)), 468 - @as(i32, @intFromFloat(g.camera.y)), gold);
        }
        if (g.state.room == 1 and !g.state.reward) {
            g.rect(c, .{ .x = 468, .y = 92, .w = 24, .h = 16 }, stone);
            g.rect(c, .{ .x = 468, .y = 91, .w = 24, .h = 4 }, gold);
            g.rect(c, .{ .x = 478, .y = 94, .w = 4, .h = 10 }, gold);
            g.text(c, "E - OPEN", 456 - @as(i32, @intFromFloat(g.camera.x)), 114 - @as(i32, @intFromFloat(g.camera.y)), gold);
        }
    }
    fn compass(g: *const Game, c: *up.graphics.Canvas) void {
        if (g.screen != .play or g.state.completed) return;
        const target = if (g.state.room == 2 and !g.state.boss_defeated) g.state.enemies[4].pos else if (g.state.room < 2 and g.state.bells[g.state.room]) Vec{ .x = 915, .y = 270 } else Vec{ .x = 870, .y = 450 };
        const p = target.sub(g.camera);
        if (p.x >= 16 and p.x <= 464 and p.y >= 50 and p.y <= 225) return;
        const x: i32 = @intFromFloat(std.math.clamp(p.x, 24, 445));
        const y: i32 = @intFromFloat(std.math.clamp(p.y, 55, 228));
        const gold = Color.rgb(239, 185, 96);
        c.line(x, y - 4, x + 4, y, gold);
        c.line(x + 4, y, x, y + 4, gold);
        c.line(x, y + 4, x - 4, y, gold);
        c.line(x - 4, y, x, y - 4, gold);
        g.text(c, if (g.state.room == 2 and !g.state.boss_defeated) "WARDEN" else if (g.state.room < 2 and g.state.bells[g.state.room]) "PASSAGE" else "BELL", x - 15, y - 18, gold);
    }
    pub fn draw(g: *Game, ctx: *up.core.GameContext) !void {
        const c = try ctx.requireCanvas();
        const ink = Color.rgb(15, 28, 38);
        const stone = Color.rgb(91, 111, 115);
        const gold = Color.rgb(239, 185, 96);
        const white = Color.rgb(228, 233, 220);
        c.clear(ink);
        g.rect(c, .{ .x = 16, .y = 40, .w = 928, .h = 484 }, switch (g.state.room) {
            0 => Color.rgb(33, 51, 58),
            1 => Color.rgb(42, 54, 48),
            else => Color.rgb(42, 45, 59),
        });
        for (0..24) |x| {
            for (0..13) |y| {
                const px = 20 + @as(f32, @floatFromInt(x)) * 40;
                const py = 42 + @as(f32, @floatFromInt(y)) * 38;
                g.rect(c, .{ .x = px, .y = py, .w = 36, .h = 1 }, Color.rgb(59, 71, 72));
                if (g.state.room == 1) g.rect(c, .{ .x = px, .y = py, .w = 1, .h = 34 }, Color.rgb(59, 71, 65));
                if (g.state.room == 2 and (x + y) % 3 == 0) g.rect(c, .{ .x = px + 16, .y = py + 16, .w = 3, .h = 3 }, Color.rgb(70, 73, 84));
            }
        }
        for (world.walls(g.state.room)) |r| {
            g.rect(c, .{ .x = r.x + 3, .y = r.y + 4, .w = r.w, .h = r.h }, ink);
            g.rect(c, r, stone);
            g.rect(c, .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, Color.rgb(141, 155, 150));
        }
        g.scenery(c);
        if (g.state.drop.amount > 0 and g.state.drop.room == g.state.room) {
            g.circle(c, g.state.drop.pos, 8, gold);
            g.circle(c, g.state.drop.pos, 4, ink);
        }
        for (g.state.enemies) |e| {
            if (e.hp == 0) continue;
            const color = if (e.stage == .windup) gold else if (e.stage == .active) Color.rgb(226, 113, 91) else Color.rgb(143, 123, 133);
            if (e.stage == .windup or e.stage == .active) g.telegraph(c, e, color);
            g.circle(c, e.pos.add(.{ .y = 5 }), if (e.kind == .warden) 17 else 11, ink);
            const lift: f32 = if (e.stage == .windup) -3 else if (e.stage == .recovery) 2 else 0;
            switch (e.kind) {
                .drifter => {
                    g.rect(c, .{ .x = e.pos.x - 7, .y = e.pos.y - 5 + lift, .w = 14, .h = 14 }, color);
                    g.circle(c, e.pos.add(.{ .y = -8 + lift }), 5, stone);
                },
                .pike => {
                    g.rect(c, .{ .x = e.pos.x - 4, .y = e.pos.y - 10 + lift, .w = 8, .h = 20 }, color);
                    g.circle(c, e.pos.add(.{ .y = -12 + lift }), 4, white);
                    g.line(c, e.pos, e.pos.add(e.aim.scale(23)), white);
                },
                .hound => {
                    g.rect(c, .{ .x = e.pos.x - 11, .y = e.pos.y - 4, .w = 20, .h = 8 }, color);
                    g.circle(c, e.pos.add(e.aim.scale(9)), 5, color);
                    g.line(c, e.pos.add(.{ .x = -7, .y = 2 }), e.pos.add(.{ .x = -10, .y = 8 }), stone);
                    g.line(c, e.pos.add(.{ .x = 6, .y = 2 }), e.pos.add(.{ .x = 10, .y = 8 }), stone);
                },
                .censer => {
                    g.rect(c, .{ .x = e.pos.x - 8, .y = e.pos.y - 2, .w = 16, .h = 5 }, stone);
                    g.rect(c, .{ .x = e.pos.x - 2, .y = e.pos.y, .w = 4, .h = 10 }, stone);
                    g.circle(c, e.pos.add(.{ .y = -6 + lift }), 5, color);
                    g.circle(c, e.pos.add(.{ .y = -9 + lift }), 2, gold);
                },
                .warden => {
                    g.rect(c, .{ .x = e.pos.x - 14, .y = e.pos.y - 9 + lift, .w = 28, .h = 21 }, color);
                    g.circle(c, e.pos.add(.{ .y = -14 + lift }), 8, gold);
                    g.line(c, e.pos, e.pos.add(e.aim.scale(if (e.stage == .windup) @as(f32, 24) else 17)), stone);
                    g.circle(c, e.pos.add(e.aim.scale(23)), 6, white);
                },
            }
            g.circle(c, e.pos.add(e.aim.scale(5)), 2, ink);
            const p = e.pos.sub(g.camera);
            const hp_max: i32 = if (e.kind == .warden) 480 else if (e.kind == .hound) 60 else 85;
            c.fillRect(@intFromFloat(p.x - 12), @intFromFloat(p.y - 24), 24, 2, ink);
            c.fillRect(@intFromFloat(p.x - 12), @intFromFloat(p.y - 24), @divTrunc(@as(i32, e.hp) * 24, hp_max), 2, white);
            if (e.stage == .transition) {
                g.ringOutline(c, e.pos, 30 + @as(f32, @floatFromInt(e.age % 60)), gold, true);
                g.text(c, "SECOND TOLL", @intFromFloat(p.x - 33), @intFromFloat(p.y - 36), gold);
            }
        }
        for (g.state.shots) |shot| if (shot.life > 0) {
            g.circle(c, shot.pos, 5, gold);
            g.circle(c, shot.pos, 2, white);
        };
        for (g.state.rings) |ring| if (ring.alive) {
            g.ringOutline(c, ring.center, ring.radius(), gold, false);
            g.ringOutline(c, ring.center, ring.radius() - 6, white, false);
        };
        const player_color = if (g.settings.flash and g.state.hurt_feedback > 0) white else if (g.state.player.invulnerable()) gold else Color.rgb(159, 211, 208);
        const bob: f32 = if (g.walking and g.state.player.action == .idle and (g.stride / 8) % 2 == 0) 1 else 0;
        const healing = g.state.player.action == .heal;
        const t = combat.spec(g.state.player.weapon, g.state.player.action);
        const preparing = (g.state.player.action == .light or g.state.player.action == .heavy) and g.state.player.age < t.startup;
        const crouch: f32 = if (g.state.player.action == .dodge) 3 else if (healing) 2 else if (preparing) -1 else 0;
        g.circle(c, g.state.pos.add(.{ .y = 5 }), 10, ink);
        g.rect(c, .{ .x = g.state.pos.x - 6, .y = g.state.pos.y - 3 + bob + crouch, .w = 12, .h = 11 - crouch }, player_color);
        g.circle(c, g.state.pos.add(.{ .y = -6 + bob + crouch }), 4, white);
        const resting_length: f32 = if (g.state.player.weapon == .spear) 20 else 13;
        const weapon_length: f32 = if (g.state.player.active()) @floatFromInt(t.reach) else if (preparing) resting_length * 0.55 else resting_length;
        const tip = g.state.pos.add(g.state.facing.scale(weapon_length));
        g.line(c, g.state.pos, tip, if (g.state.player.active()) white else stone);
        if (healing) {
            // Raise a visible vial during the vulnerable commitment. The small
            // cross appears at the same age as healing, then leaves at recovery.
            const vial = g.state.pos.add(.{ .x = 7, .y = -10 });
            g.rect(c, .{ .x = vial.x - 2, .y = vial.y - 3, .w = 4, .h = 6 }, gold);
            g.line(c, vial.add(.{ .x = -1, .y = -4 }), vial.add(.{ .x = 1, .y = -4 }), white);
            if (g.state.player.age >= 36) {
                const mark = g.state.pos.add(.{ .y = -21 });
                g.line(c, mark.add(.{ .x = -3 }), mark.add(.{ .x = 3 }), gold);
                g.line(c, mark.add(.{ .y = -3 }), mark.add(.{ .y = 3 }), gold);
            }
        }
        const side = Vec{ .x = -g.state.facing.y, .y = g.state.facing.x };
        g.line(c, g.state.pos.add(g.state.facing.scale(8)).add(side.scale(-3)), g.state.pos.add(g.state.facing.scale(8)).add(side.scale(3)), gold);
        if (g.state.player.active()) {
            const angle = std.math.atan2(g.state.facing.y, g.state.facing.x);
            var previous = g.state.pos.add(.{ .x = @cos(angle - 0.988) * weapon_length, .y = @sin(angle - 0.988) * weapon_length });
            for (1..9) |i| {
                const a = angle - 0.988 + 1.976 * @as(f32, @floatFromInt(i)) / 8;
                const point = g.state.pos.add(.{ .x = @cos(a) * weapon_length, .y = @sin(a) * weapon_length });
                if (world.visible(g.state.room, g.state.pos, point)) g.line(c, previous, point, white);
                previous = point;
            }
        }
        c.fillRect(0, 0, 480, 34, ink);
        g.text(c, world.names[g.state.room], 10, 5, gold);
        c.fillRect(10, 18, 100, 5, Color.rgb(66, 43, 47));
        c.fillRect(10, 18, @divTrunc(@as(i32, g.state.player.hp) * 100, g.state.player.max_hp), 5, Color.rgb(211, 121, 106));
        c.fillRect(10, 26, 100, 4, Color.rgb(40, 56, 55));
        c.fillRect(10, 26, @divTrunc(@as(i32, g.state.player.stamina) * 100, g.state.player.max_stamina), 4, Color.rgb(150, 189, 151));
        var buffer: [100]u8 = undefined;
        g.text(c, try std.fmt.bufPrint(&buffer, "HP {d}/{d}", .{ g.state.player.hp, g.state.player.max_hp }), 130, 3, white);
        g.text(c, try std.fmt.bufPrint(&buffer, "ST {d}/{d}", .{ g.state.player.stamina, g.state.player.max_stamina }), 218, 3, white);
        g.text(c, try std.fmt.bufPrint(&buffer, "Flasks {d}", .{g.state.player.flasks}), 302, 3, white);
        g.text(c, try std.fmt.bufPrint(&buffer, "Embers {d}", .{g.state.embers}), 382, 3, gold);
        g.text(c, try std.fmt.bufPrint(&buffer, "{s}   Q switch", .{@tagName(g.state.player.weapon)}), 130, 18, white);
        for (g.state.enemies) |e| if (e.kind == .warden and e.hp > 0 and e.pos.sub(g.state.pos).length() < 240) {
            c.fillRect(120, 219, 240, 5, ink);
            c.fillRect(120, 219, @divTrunc(@as(i32, e.hp) * 240, 480), 5, gold);
            g.text(c, if (e.phase == 2) "BELL WARDEN - SECOND TOLL" else "BELL WARDEN", 120, 208, white);
            if (e.stage == .windup and e.attack == .ring) g.text(c, "BELL SHOCK - DODGE THROUGH OR RETREAT", 120, 229, gold);
        };
        c.fillRect(0, 242, 480, 28, ink);
        g.text(c, g.state.message, 8, 246, gold);
        g.text(c, if (g.action_notice > 0) "ACTION EXPIRED OR UNAVAILABLE - WAIT / RESTORE STAMINA" else switch (g.tutorial_stage) {
            0 => "WASD / ARROWS MOVE. E AT A LANTERN RESTORES YOU.",
            1 => "J LIGHT / K HEAVY. ATTACKS COMMIT UNTIL RECOVERY.",
            2 => "SPACE DODGES. STAMINA RETURNS WHILE YOU REST.",
            3 => "H USES A FLASK. HEALING COMMITS YOU - FIND AN OPENING.",
            4 => "E AT A LANTERN REFILLS FLASKS AND SETS YOUR CHECKPOINT.",
            else => "J LIGHT  K HEAVY  SPACE DODGE  H HEAL  E USE",
        }, 8, 258, white);
        g.compass(c);
        if (g.screen != .play) {
            c.fillRect(0, 242, 480, 28, ink);
            g.text(c, switch (g.screen) {
                .title => "A LIGHT FOR THOSE STILL FINDING THEIR WAY HOME.",
                .settings => "LEFT / RIGHT CHANGE - ESCAPE / START BACK",
                .credits => "ENTER / E RETURNS TO TITLE",
                .victory => "ENTER / E CREDITS - ESCAPE / START RETRIES SAVE",
                .death => "ENTER / E RETURNS TO YOUR CHECKPOINT",
                else => "ARROWS CHOOSE - ENTER / E ACCEPT - ESCAPE RESUMES",
            }, 8, 247, white);
            if (g.screen == .pause) g.text(c, g.state.message, 8, 258, gold);
        }
        if (g.save_failed) {
            c.fillRect(0, 34, 480, 12, ink);
            g.text(c, "SAVE FAILED - LAST GOOD SAVE KEPT - PAUSE TO RETRY", 8, 36, gold);
        }
        if (g.screen != .play) {
            c.fillRect(25, 48, 430, 190, ink);
            c.fillRect(25, 48, 430, 2, gold);
            g.typefaces.drawHeading(c, switch (g.screen) {
                .title => "ASHEN CAUSEWAY",
                .pause => "PAUSED - LANTERN UPGRADES",
                .death => "THE COAL GROWS COLD",
                .settings => "SETTINGS",
                .victory => "THE BEACON BURNS",
                .credits => "ASHEN CAUSEWAY - CREDITS",
                else => "",
            }, 40, 54, gold);
            switch (g.screen) {
                .title => {
                    g.text(c, "Carry the coal. Ring three bells. Defeat the Warden.", 40, 82, white);
                    g.text(c, g.load_note, 40, 97, gold);
                    const labels = [_][]const u8{ if (g.journey_started) "CONTINUE" else if (g.load_problem) "CONTINUE UNAVAILABLE - SELECT NEW GAME" else "BEGIN JOURNEY", "NEW GAME - REPLACE PROGRESS", "SETTINGS", "CREDITS" };
                    for (labels, 0..) |label, i| {
                        const y: i32 = 112 + @as(i32, @intCast(i)) * 20;
                        if (i == g.selected) c.fillRect(35, y - 3, 400, 15, Color.rgb(52, 73, 82));
                        g.text(c, label, 44, y, white);
                    }
                    g.text(c, "ARROWS CHOOSE - ENTER / E ACCEPT", 40, 214, gold);
                },
                .pause => {
                    const labels = [_][]const u8{ "RESUME", "SAVE / RETRY", "WEAPON UPGRADE - 50 / 100 / 150 EMBERS", "VITALITY - 50 / 100 / 150 EMBERS", "REED CHARM - EQUIP / REMOVE", "SETTINGS", "CREDITS", "RETURN TO TITLE" };
                    for (labels, 0..) |label, i| {
                        const y: i32 = 80 + @as(i32, @intCast(i)) * 17;
                        if (i == g.selected) c.fillRect(35, y - 3, 400, 15, Color.rgb(52, 73, 82));
                        g.text(c, label, 44, y, white);
                    }
                    var b: [80]u8 = undefined;
                    g.text(c, try std.fmt.bufPrint(&b, "FORGE {d}/3  VITALITY {d}/3  CHARM {s}", .{ g.state.upgrade, g.state.vitality, if (g.state.charm) "ON" else "OFF" }), 40, 220, gold);
                },
                .settings => {
                    var b: [160]u8 = undefined;
                    g.text(c, try std.fmt.bufPrint(&b, "MUSIC VOLUME {d}\n\nEFFECTS VOLUME {d}\n\nCAMERA SHAKE {s}\n\nFLASH EFFECTS {s}", .{ g.settings.music, g.settings.effects, if (g.settings.shake) "ON" else "OFF", if (g.settings.flash) "ON" else "OFF" }), 55, 94, white);
                    c.fillRect(40, 94 + @as(i32, @intCast(g.selected)) * 24, 5, 7, gold);
                    g.text(c, "UP / DOWN SELECT - LEFT / RIGHT CHANGE\nESCAPE / START BACK", 40, 196, gold);
                },
                .death => g.text(c, "Your embers remain where you fell.\nA second death replaces that drop, even with zero.\n\nENTER / E - RETURN TO THE LAST LANTERN", 40, 100, white),
                .victory => {
                    g.text(c, "The living coal catches. Across the drowned quay,\nwindows answer with small and patient lights.\nThe ferryman has brought the lost a way home.\n\nENTER / E - CREDITS", 40, 100, white);
                    g.text(c, if (g.save_failed) "SAVE FAILED - ESCAPE / START RETRIES" else "JOURNEY SAVED", 40, 166, gold);
                },
                .credits => g.text(c, "ASHEN CAUSEWAY\nGame implementation: Codex\nPowered by unpolished-peas\nOriginal art and bell score made for this game.\nTypeface: Source Sans 3 - Adobe\n\nFor everyone who keeps a light in the window.\n\nENTER / E - TITLE", 40, 90, white),
                else => {},
            }
        }
    }
};
test "GameProtocol movement pause attack swap and repeated cleanup" {
    const Runner = up.testSupport.HeadlessGameRunner(Game);
    for (0..3) |_| {
        var r = try Runner.initSeeded(std.testing.allocator, width, height, default_seed);
        defer r.deinit();
        var input = up.input.Input{};
        input.set(.start, true);
        try r.step(input.snapshot(), 1.0 / 60.0);
        try std.testing.expectEqual(Screen.play, r.game.screen);
        input.beginFrame();
        input.set(.start, false);
        input.set(.right, true);
        try r.step(input.snapshot(), 1.0 / 60.0);
        try std.testing.expect(r.game.state.pos.x > 70);
        input.beginFrame();
        input.set(.right, false);
        input.setPhysical(.q, true, false);
        try r.step(input.snapshot(), 1.0 / 60.0);
        try std.testing.expectEqual(combat.Weapon.spear, r.game.state.player.weapon);
        input.beginFrame();
        input.setPhysical(.q, false, false);
        input.setPhysical(.j, true, false);
        try r.step(input.snapshot(), 1.0 / 60.0);
        try std.testing.expectEqual(combat.Action.light, r.game.state.player.action);
        input.beginFrame();
        input.set(.cancel, true);
        try r.step(input.snapshot(), 1.0 / 60.0);
        const age = r.game.state.player.age;
        input.beginFrame();
        try r.step(input.snapshot(), 1.0 / 60.0);
        try std.testing.expectEqual(age, r.game.state.player.age);
    }
}

test "rejected writes show warning preserve old journey and can retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var store: up.testSupport.InMemorySaveStore = undefined;
    store.init(failing.allocator());
    defer store.deinit();
    var w = world.World.init();
    w.upgrade = 2;
    w.embers = 70;
    const good = save.encode(w, .{});
    try store.capability().write(save.key, &good);
    const r = try up.testSupport.HeadlessGameRunner(Game).initWithSaveData(std.testing.allocator, width, height, store.capability());
    defer r.deinit();
    try std.testing.expect(r.game.journey_started);
    try std.testing.expectEqual(@as(u8, 2), r.game.state.upgrade);
    r.game.state.embers = 99;
    failing.fail_index = failing.alloc_index;
    r.game.persist(&r.context);
    try std.testing.expect(r.game.save_failed);
    var bytes: [save.size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &good, try store.capability().read(save.key, &bytes));
    try r.draw(0);
    failing.fail_index = std.math.maxInt(usize);
    r.game.persist(&r.context);
    try std.testing.expect(!r.game.save_failed);
    const loaded = try save.decode(try store.capability().read(save.key, &bytes));
    try std.testing.expectEqual(@as(u32, 99), loaded.state.embers);
    r.game.state.bells = .{true} ** 3;
    r.game.state.boss_defeated = true;
    r.game.state.completed = true;
    r.game.screen = .victory;
    failing.fail_index = failing.alloc_index;
    r.game.persist(&r.context);
    try std.testing.expect(r.game.save_failed);
    try r.draw(0);
    failing.fail_index = std.math.maxInt(usize);
    var retry_input = up.input.Input{};
    retry_input.set(.cancel, true);
    try r.step(retry_input.snapshot(), 1.0 / 60.0);
    try std.testing.expect(!r.game.save_failed);
    const ending = try save.decode(try store.capability().read(save.key, &bytes));
    try std.testing.expect(ending.state.completed);
}
test "corrupt save is retained until explicit new game and settings survive reset" {
    var store: up.testSupport.InMemorySaveStore = undefined;
    store.init(std.testing.allocator);
    defer store.deinit();
    try store.capability().write(save.key, "broken");
    const r = try up.testSupport.HeadlessGameRunner(Game).initWithSaveData(std.testing.allocator, width, height, store.capability());
    defer r.deinit();
    try std.testing.expect(!r.game.journey_started);
    var b: [40]u8 = undefined;
    try std.testing.expectEqualStrings("broken", try store.capability().read(save.key, &b));
    r.game.settings.music = 20;
    r.game.persist(&r.context);
    try std.testing.expect(r.game.save_failed);
    try std.testing.expectEqualStrings("broken", try store.capability().read(save.key, &b));
    var input = up.input.Input{};
    input.set(.down, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
    input.set(.down, false);
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    try std.testing.expectEqual(Screen.play, r.game.screen);
    const loaded = try save.decode(try store.capability().read(save.key, &b));
    try std.testing.expectEqual(@as(u8, 20), loaded.settings.music);
    try std.testing.expectEqual(@as(u8, 0), loaded.state.upgrade);
    inline for (.{ Screen.title, Screen.pause, Screen.settings, Screen.death, Screen.victory, Screen.credits }) |screen| {
        r.game.screen = screen;
        r.game.selected = 0;
        try r.draw(0);
    }
}

test "audio assets decode volume zero is silent and release invalidates sources" {
    const r = try up.testSupport.HeadlessGameRunner(Game).init(std.testing.allocator, width, height);
    defer r.deinit();
    var samples: [1024]up.assets.AudioSample = undefined;
    for (0..3) |cycle| {
        if (cycle > 0) r.game.soundscape.init(&r.context);
        for (r.game.soundscape.effects) |h| try std.testing.expect(h != null);
        try std.testing.expect(r.game.soundscape.music != null);
        r.game.soundscape.ensureMusic(&r.context, 0);
        r.game.soundscape.play(&r.context, .hit, 0);
        try r.audio.mix(&samples);
        for (samples) |sample| {
            try std.testing.expectEqual(@as(f32, 0), sample.left);
        }
        r.game.soundscape.play(&r.context, .hit, 100);
        try r.audio.mix(&samples);
        var nonzero = false;
        for (samples) |sample| {
            try std.testing.expect(std.math.isFinite(sample.left));
            if (sample.left != 0) nonzero = true;
        }
        try std.testing.expect(nonzero);
        const old = r.game.soundscape.effects[0].?;
        r.game.soundscape.deinit(&r.context);
        try std.testing.expectError(error.InvalidSound, r.audio.play(old, .{}));
        try r.audio.mix(&samples);
        for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample.left);
    }
}

fn playerPoseDigest(r: anytype) u64 {
    const x: usize = @intFromFloat(r.game.state.pos.x - r.game.camera.x);
    const y: usize = @intFromFloat(r.game.state.pos.y - r.game.camera.y);
    var digest = std.hash.Wyhash.init(0);
    for (y - 27..y + 18) |row| digest.update(std.mem.sliceAsBytes(r.canvas.pixels[row * width + x - 16 .. row * width + x + 18]));
    return digest.final();
}
fn poseEvidence(r: anytype, label: []const u8) !void {
    const allocator = std.testing.allocator;
    const output = std.process.getEnvVarOwned(allocator, "ASHEN_POSE_EVIDENCE") catch return;
    defer allocator.free(output);
    try std.fs.cwd().makePath(output);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ output, label });
    defer allocator.free(path);
    try r.canvas.writePngFile(path);
}
test "healing commitment and weapon startup have distinct player poses" {
    const r = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    var input = up.input.Input{};
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
    input.set(.start, false);
    input.set(.right, true);
    for (0..16) |_| {
        try r.step(input.snapshot(), 1.0 / 60.0);
        input.beginFrame();
    }
    input.set(.right, false);
    try r.step(input.snapshot(), 1.0 / 60.0);
    try r.draw(0);
    const idle = playerPoseDigest(r);
    try poseEvidence(r, "idle");
    input.beginFrame();
    input.set(.start, false);
    input.setPhysical(.h, true, false);
    try r.step(input.snapshot(), 1.0 / 60.0);
    try std.testing.expectEqual(combat.Action.heal, r.game.state.player.action);
    try r.draw(0);
    const holding = playerPoseDigest(r);
    try std.testing.expect(idle != holding);
    try poseEvidence(r, "healing-hold");
    input.beginFrame();
    input.setPhysical(.h, false, false);
    for (0..36) |_| {
        try r.step(input.snapshot(), 1.0 / 60.0);
        input.beginFrame();
    }
    try r.draw(0);
    try std.testing.expectEqual(@as(u16, 36), r.game.state.player.age);
    try std.testing.expect(holding != playerPoseDigest(r));
    try poseEvidence(r, "healing-release");
    for (0..24) |_| try r.step(input.snapshot(), 1.0 / 60.0);
    try r.draw(0);
    try std.testing.expectEqual(combat.Action.idle, r.game.state.player.action);
    try std.testing.expectEqual(idle, playerPoseDigest(r));
    input.setPhysical(.j, true, false);
    try r.step(input.snapshot(), 1.0 / 60.0);
    try r.draw(0);
    const startup = playerPoseDigest(r);
    try std.testing.expect(startup != idle);
    try poseEvidence(r, "sabre-startup");
    input.beginFrame();
    input.setPhysical(.j, false, false);
    for (0..7) |_| {
        try r.step(input.snapshot(), 1.0 / 60.0);
        input.beginFrame();
    }
    try std.testing.expect(r.game.state.player.active());
    try r.draw(0);
    try std.testing.expect(startup != playerPoseDigest(r));
    try poseEvidence(r, "sabre-active");
}

test "pause explains rejected upgrades in its visible footer" {
    const r = try up.testSupport.HeadlessGameRunner(Game).initSeeded(std.testing.allocator, width, height, default_seed);
    defer r.deinit();
    var input = up.input.Input{};
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
    input.set(.start, false);
    input.set(.right, true);
    for (0..40) |_| {
        try r.step(input.snapshot(), 1.0 / 60.0);
        input.beginFrame();
    }
    input.set(.right, false);
    input.set(.cancel, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
    input.set(.cancel, false);
    for (0..2) |_| {
        input.set(.down, true);
        try r.step(input.snapshot(), 1.0 / 60.0);
        input.beginFrame();
        input.set(.down, false);
        try r.step(input.snapshot(), 1.0 / 60.0);
        input.beginFrame();
    }
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    try std.testing.expectEqualStrings("Rest at a lantern before upgrading.", r.game.state.message);
    try std.testing.expectEqual(@as(u8, 0), r.game.state.upgrade);
    try r.draw(0);
    const ink = Color.rgb(15, 28, 38);
    var message_pixels: usize = 0;
    for (261..269) |y| for (r.canvas.pixels[y * width + 8 .. y * width + 470]) |pixel| {
        if (!std.meta.eql(pixel, ink)) message_pixels += 1;
    };
    try std.testing.expect(message_pixels > 0);
    try poseEvidence(r, "upgrade-away");
}
