const std = @import("std");
const up = @import("unpolished-peas");
const world = @import("world.zig");
const combat = @import("combat.zig");
const save = @import("save.zig");
pub const width: u32 = 480;
pub const height: u32 = 270;
pub const default_seed: u64 = 0x415348454e;
pub const storage_id = "unpolished-peas.ashen-causeway";
const Color = up.core.Color;
const Vec = world.Vec;
const bindings = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },                                     .{ .name = "left", .binding = .{ .physical_key = .a } },
    .{ .name = "right", .binding = .{ .key = .right } },                                   .{ .name = "right", .binding = .{ .physical_key = .d } },
    .{ .name = "up", .binding = .{ .key = .up } },                                         .{ .name = "up", .binding = .{ .physical_key = .w } },
    .{ .name = "down", .binding = .{ .key = .down } },                                     .{ .name = "down", .binding = .{ .physical_key = .s } },
    .{ .name = "left", .binding = .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1 } } }, .{ .name = "right", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } },
    .{ .name = "up", .binding = .{ .gamepad_axis = .{ .axis = .left_y, .sign = -1 } } },   .{ .name = "down", .binding = .{ .gamepad_axis = .{ .axis = .left_y } } },
    .{ .name = "light", .binding = .{ .physical_key = .j } },                              .{ .name = "light", .binding = .{ .pointer_button = .left } },
    .{ .name = "light", .binding = .{ .gamepad_button = .left_shoulder } },                .{ .name = "heavy", .binding = .{ .physical_key = .k } },
    .{ .name = "heavy", .binding = .{ .pointer_button = .right } },                        .{ .name = "heavy", .binding = .{ .gamepad_button = .right_shoulder } },
    .{ .name = "dodge", .binding = .{ .key = .action } },                                  .{ .name = "dodge", .binding = .{ .gamepad_button = .south } },
    .{ .name = "heal", .binding = .{ .physical_key = .h } },                               .{ .name = "heal", .binding = .{ .gamepad_button = .north } },
    .{ .name = "interact", .binding = .{ .physical_key = .e } },                           .{ .name = "interact", .binding = .{ .gamepad_button = .west } },
    .{ .name = "swap", .binding = .{ .physical_key = .q } },                               .{ .name = "swap", .binding = .{ .gamepad_button = .back } },
    .{ .name = "pause", .binding = .{ .key = .cancel } },                                  .{ .name = "pause", .binding = .{ .gamepad_button = .start } },
    .{ .name = "confirm", .binding = .{ .key = .start } },
};
const Screen = enum { title, play, pause, death, settings, victory, credits };
pub const Game = struct {
    state: world.World = .{},
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
        g.actions = try up.input.ActionMap.init(try ctx.requireAllocator(), &bindings);
        g.state = world.World.init();
        g.load(ctx);
        g.follow();
    }
    pub fn deinit(g: *Game, _: *up.core.GameContext) !void {
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
    }
    pub fn update(g: *Game, ctx: *up.core.GameContext, _: f32) !void {
        g.actions.?.update(ctx.input.*);
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
        g.state.tick(cmd);
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
    fn rect(g: Game, c: *up.graphics.Canvas, r: world.Rect, color: Color) void {
        c.fillRect(@intFromFloat(r.x - g.camera.x), @intFromFloat(r.y - g.camera.y), @intFromFloat(r.w), @intFromFloat(r.h), color);
    }
    fn circle(g: Game, c: *up.graphics.Canvas, p: Vec, r: i32, color: Color) void {
        c.fillCircle(@intFromFloat(p.x - g.camera.x), @intFromFloat(p.y - g.camera.y), r, color);
    }
    pub fn draw(g: *Game, ctx: *up.core.GameContext) !void {
        const c = try ctx.requireCanvas();
        const ink = Color.rgb(15, 28, 38);
        const stone = Color.rgb(91, 111, 115);
        const gold = Color.rgb(239, 185, 96);
        const white = Color.rgb(228, 233, 220);
        c.clear(ink);
        g.rect(c, .{ .x = 16, .y = 40, .w = 928, .h = 484 }, Color.rgb(33, 51, 58));
        for (0..24) |x| {
            for (0..13) |y| {
                g.rect(c, .{ .x = 20 + @as(f32, @floatFromInt(x)) * 40, .y = 42 + @as(f32, @floatFromInt(y)) * 38, .w = 36, .h = 1 }, Color.rgb(45, 63, 68));
            }
        }
        for (world.walls(g.state.room)) |r| {
            g.rect(c, .{ .x = r.x + 3, .y = r.y + 4, .w = r.w, .h = r.h }, ink);
            g.rect(c, r, stone);
            g.rect(c, .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, Color.rgb(141, 155, 150));
        }
        g.circle(c, .{ .x = 70, .y = 270 }, 13, stone);
        g.circle(c, .{ .x = 70, .y = 270 }, 5, gold);
        g.circle(c, .{ .x = 870, .y = 450 }, 12, if (g.state.bells[g.state.room]) gold else stone);
        if (g.state.shortcut and g.state.room < 2) g.rect(c, .{ .x = 100, .y = 440, .w = 20, .h = 20 }, gold);
        if (g.state.room == 1 and !g.state.reward) g.circle(c, .{ .x = 480, .y = 100 }, 7, gold);
        if (g.state.drop.amount > 0 and g.state.drop.room == g.state.room) {
            g.circle(c, g.state.drop.pos, 8, gold);
            g.circle(c, g.state.drop.pos, 4, ink);
        }
        for (g.state.enemies) |e| {
            if (e.hp == 0) continue;
            const color = if (e.stage == .windup) gold else if (e.stage == .active) Color.rgb(226, 113, 91) else Color.rgb(143, 123, 133);
            if (e.stage == .windup or e.stage == .active) {
                var n: f32 = 10;
                while (n < e.reach()) : (n += 8) {
                    g.circle(c, e.pos.add(e.aim.scale(n)), 2, color);
                }
            }
            g.circle(c, e.pos.add(.{ .y = 4 }), if (e.kind == .warden) 15 else 10, ink);
            g.circle(c, e.pos, if (e.kind == .warden) 13 else 8, color);
            g.circle(c, e.pos.add(e.aim.scale(5)), 2, ink);
            const p = e.pos.sub(g.camera);
            c.drawText(switch (e.kind) {
                .drifter => "D",
                .pike => "P",
                .censer => "C",
                .hound => "H",
                .warden => "W",
            }, @intFromFloat(p.x - 3), @intFromFloat(p.y - 18), white);
        }
        g.circle(c, g.state.pos.add(.{ .y = 4 }), 9, ink);
        g.circle(c, g.state.pos, 7, if (g.state.player.invulnerable()) gold else Color.rgb(159, 211, 208));
        const t = combat.spec(g.state.player.weapon, g.state.player.action);
        g.circle(c, g.state.pos.add(g.state.facing.scale(if (g.state.player.active()) @as(f32, @floatFromInt(t.reach)) else 13)), 3, white);
        c.fillRect(0, 0, 480, 34, ink);
        c.drawText(world.names[g.state.room], 10, 5, gold);
        c.fillRect(10, 18, 100, 5, Color.rgb(66, 43, 47));
        c.fillRect(10, 18, @divTrunc(@as(i32, g.state.player.hp) * 100, g.state.player.max_hp), 5, Color.rgb(211, 121, 106));
        c.fillRect(10, 26, 100, 4, Color.rgb(40, 56, 55));
        c.fillRect(10, 26, @divTrunc(@as(i32, g.state.player.stamina) * 100, g.state.player.max_stamina), 4, Color.rgb(150, 189, 151));
        var buffer: [100]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "HP {d}  ST {d}  FLASKS {d}  EMBERS {d}\n{s}   Q SWITCH", .{ g.state.player.hp, g.state.player.stamina, g.state.player.flasks, g.state.embers, @tagName(g.state.player.weapon) });
        c.drawText(text, 130, 6, white);
        c.fillRect(0, 242, 480, 28, ink);
        c.drawText(g.state.message, 8, 246, gold);
        c.drawText("J LIGHT  K HEAVY  SPACE DODGE  H HEAL  E USE", 8, 258, white);
        if (g.save_failed) {
            c.fillRect(0, 34, 480, 12, ink);
            c.drawText("SAVE FAILED - LAST GOOD SAVE KEPT - PAUSE TO RETRY", 8, 36, gold);
        }
        if (g.screen != .play) {
            c.fillRect(25, 48, 430, 190, ink);
            c.fillRect(25, 48, 430, 2, gold);
            c.drawText(switch (g.screen) {
                .title => "ASHEN CAUSEWAY",
                .pause => "PAUSED - LANTERN UPGRADES",
                .death => "THE COAL GROWS COLD",
                .settings => "SETTINGS",
                .victory => "THE BEACON BURNS",
                .credits => "ASHEN CAUSEWAY - CREDITS",
                else => "",
            }, 40, 60, gold);
            switch (g.screen) {
                .title => {
                    c.drawText("Carry the coal. Ring three bells. Defeat the Warden.", 40, 78, white);
                    c.drawText(g.load_note, 40, 90, gold);
                    const labels = [_][]const u8{ if (g.journey_started) "CONTINUE" else if (g.load_problem) "CONTINUE UNAVAILABLE - SELECT NEW GAME" else "BEGIN JOURNEY", "NEW GAME - REPLACE PROGRESS", "SETTINGS", "CREDITS" };
                    for (labels, 0..) |label, i| {
                        const y: i32 = 112 + @as(i32, @intCast(i)) * 20;
                        if (i == g.selected) c.fillRect(35, y - 3, 400, 15, stone);
                        c.drawText(label, 44, y, white);
                    }
                    c.drawText("ARROWS CHOOSE - ENTER / E ACCEPT", 40, 214, gold);
                },
                .pause => {
                    const labels = [_][]const u8{ "RESUME", "SAVE / RETRY", "WEAPON UPGRADE - 50 / 100 / 150 EMBERS", "VITALITY - 50 / 100 / 150 EMBERS", "REED CHARM - EQUIP / REMOVE", "SETTINGS", "CREDITS", "RETURN TO TITLE" };
                    for (labels, 0..) |label, i| {
                        const y: i32 = 80 + @as(i32, @intCast(i)) * 17;
                        if (i == g.selected) c.fillRect(35, y - 3, 400, 15, stone);
                        c.drawText(label, 44, y, white);
                    }
                    var b: [80]u8 = undefined;
                    c.drawText(try std.fmt.bufPrint(&b, "FORGE {d}/3  VITALITY {d}/3  CHARM {s}", .{ g.state.upgrade, g.state.vitality, if (g.state.charm) "ON" else "OFF" }), 40, 220, gold);
                },
                .settings => {
                    var b: [160]u8 = undefined;
                    c.drawText(try std.fmt.bufPrint(&b, "MUSIC VOLUME {d}\n\nEFFECTS VOLUME {d}\n\nCAMERA SHAKE {s}\n\nFLASH EFFECTS {s}", .{ g.settings.music, g.settings.effects, if (g.settings.shake) "ON" else "OFF", if (g.settings.flash) "ON" else "OFF" }), 55, 94, white);
                    c.fillRect(40, 94 + @as(i32, @intCast(g.selected)) * 16, 5, 7, gold);
                    c.drawText("UP / DOWN SELECT - LEFT / RIGHT CHANGE\nESCAPE / START BACK", 40, 196, gold);
                },
                .death => c.drawText("Your embers remain where you fell.\nA second death replaces that drop, even with zero.\n\nENTER / E - RETURN TO THE LAST LANTERN", 40, 100, white),
                .victory => c.drawText("The living coal catches. Across the drowned quay,\nwindows answer with small and patient lights.\nThe ferryman has brought the lost a way home.\n\nYour journey is saved.\nENTER / E - CREDITS", 40, 100, white),
                .credits => c.drawText("ASHEN CAUSEWAY\nGame design and implementation: Codex with Gabriel\nFramework: unpolished-peas\nCurrent art: original game-owned Canvas geometry\n\nBuilt as a public-API framework dogfood game.\nSee GUIDE.md and FRICTION.md for evidence.\n\nENTER / E - TITLE", 40, 90, white),
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
