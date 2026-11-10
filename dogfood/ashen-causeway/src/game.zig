const std = @import("std");
const up = @import("unpolished-peas");
const world = @import("world.zig");
const combat = @import("combat.zig");
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
const Screen = enum { title, play, pause, death };
pub const Game = struct {
    state: world.World = .{},
    actions: ?up.input.ActionMap = null,
    screen: Screen = .title,
    camera: Vec = .{},
    mouse_aim: bool = false,
    pub fn init(g: *Game, ctx: *up.core.GameContext) !void {
        g.actions = try up.input.ActionMap.init(try ctx.requireAllocator(), &bindings);
        g.state = world.World.init();
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
            if (g.pressed("confirm") or g.pressed("interact") or g.pressed("pause")) {
                if (g.screen == .death) g.state.respawn();
                g.screen = .play;
                g.follow();
            }
            return;
        }
        if (g.pressed("pause")) {
            g.screen = .pause;
            return;
        }
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
        c.fillRect(10, 18, g.state.player.hp, 5, Color.rgb(211, 121, 106));
        c.fillRect(10, 26, 100, 4, Color.rgb(40, 56, 55));
        c.fillRect(10, 26, g.state.player.stamina, 4, Color.rgb(150, 189, 151));
        var buffer: [100]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "HP {d}  ST {d}  FLASKS {d}  EMBERS {d}\n{s}   Q SWITCH", .{ g.state.player.hp, g.state.player.stamina, g.state.player.flasks, g.state.embers, @tagName(g.state.player.weapon) });
        c.drawText(text, 130, 6, white);
        c.fillRect(0, 242, 480, 28, ink);
        c.drawText(g.state.message, 8, 246, gold);
        c.drawText("J LIGHT  K HEAVY  SPACE DODGE  H HEAL  E USE", 8, 258, white);
        if (g.screen != .play) {
            c.fillRect(35, 65, 410, 140, ink);
            c.fillRect(35, 65, 410, 2, gold);
            c.drawText(switch (g.screen) {
                .title => "ASHEN CAUSEWAY",
                .pause => "PAUSED",
                .death => "THE COAL GROWS COLD",
                else => "",
            }, 60, 83, gold);
            c.drawText(switch (g.screen) {
                .title => "Carry a coal through the drowned monastery.\nRing each bell to open the next passage.\nRest at lanterns. Defeat the Bell Warden.\n\nIN DEVELOPMENT - SAVES AND ART PENDING",
                .pause => "WASD OR ARROWS MOVE - MOUSE AIMS\nJ OR LEFT CLICK - LIGHT ATTACK\nK OR RIGHT CLICK - HEAVY ATTACK\nSPACE DODGE - H HEAL - Q WEAPON - E USE",
                .death => "Your embers remain where you fell.\nAnother death replaces that drop.\nReturn from the last lantern to recover them.",
                else => "",
            }, 60, 104, white);
            c.drawText("ENTER OR E TO CONTINUE", 60, 184, gold);
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
