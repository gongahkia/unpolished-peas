//! Seeded arena pilot using ordinary controls only; no health/spawn/state edits.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
pub const Mode = enum { keyboard, controller };
pub const Pilot = struct {
    phase: u8 = 0,
    wait: u8 = 0,
    sprint_ticks: u16 = 0,
    paused_once: bool = false,
    saw_damage: bool = false,
    saw_heal: bool = false,
    saw_death: bool = false,
    saw_sprint: bool = false,
    finished: bool = false,
    previous_hp: u8 = 3,
    pub fn next(self: *Pilot, g: *const game.Game, input: *up.input.Input, mode: Mode) void {
        if (g.player.health < self.previous_hp) self.saw_damage = true;
        if (g.player.health > self.previous_hp and !g.game_over and g.score > 0) self.saw_heal = true;
        self.previous_hp = g.player.health;
        var move = up.core.Vec2{};
        var aim = up.core.Vec2{ .x = 1 };
        var fire = false;
        var sprint = false;
        var primary = false;
        var pause = false;
        var mute = false;
        switch (self.phase) {
            0 => {
                if (g.screen == .title) primary = true else self.phase = 1;
            },
            1 => {
                if (self.saw_damage) self.phase = 2;
            },
            2 => {
                if (g.game_over) {
                    self.saw_death = true;
                    self.phase = 4;
                } else if (g.wave >= 4 and self.saw_heal and g.score >= 100) self.phase = 3 else if (g.wave == 2 and !self.paused_once) self.phase = 20 else {
                    var nearest: f32 = 1e9;
                    var target = g.player.position;
                    for (g.enemies) |enemy| if (enemy.active) {
                        const d = enemy.position.sub(g.player.position).lenSq();
                        if (d < nearest) {
                            nearest = d;
                            target = enemy.position;
                        }
                    };
                    aim = target.sub(g.player.position).normalized();
                    fire = true;
                    move = if (nearest > 11 * 11) aim else if (nearest < 8 * 8) aim.scale(-1) else .{};
                    if (g.player.health < 3) {
                        var pickup_distance: f32 = 1e9;
                        var pickup_target: ?up.core.Vec2 = null;
                        for (g.pickups) |pickup| if (pickup.active) {
                            const d = pickup.position.sub(g.player.position).lenSq();
                            if (d < pickup_distance) {
                                pickup_distance = d;
                                pickup_target = pickup.position;
                            }
                        };
                        if (pickup_target) |p| move = p.sub(g.player.position).normalized();
                    }
                    sprint = self.sprint_ticks < 60 and move.lenSq() > 0;
                    if (sprint) {
                        self.sprint_ticks += 1;
                        self.saw_sprint = true;
                    }
                }
            },
            3 => {
                if (g.game_over) {
                    self.saw_death = true;
                    self.phase = 4;
                }
            },
            4 => {
                primary = true;
                self.phase = 5;
            },
            5 => {
                mute = true;
                self.phase = 6;
            },
            6 => {
                self.finished = true;
            },
            20 => {
                if (g.screen == .paused) {
                    self.wait = 12;
                    self.phase = 21;
                } else pause = true;
            },
            21 => {
                fire = true;
                move = .{ .x = 1 };
                if (self.wait > 0) self.wait -= 1 else self.phase = 22;
            },
            22 => {
                primary = true;
                self.paused_once = true;
                self.phase = 2;
            },
            else => unreachable,
        }
        input.beginFrame();
        if (mode == .keyboard) {
            input.set(.left, move.x < -0.3);
            input.set(.right, move.x > 0.3);
            input.set(.up, move.y < -0.3);
            input.set(.down, move.y > 0.3);
            input.set(.action, fire);
            input.set(.start, primary);
            input.setPhysical(.escape, pause, false);
            input.setPhysical(.x, sprint, false);
            input.setPhysical(.m, mute, false);
            input.setPhysical(.j, aim.x < -0.383, false);
            input.setPhysical(.l, aim.x > 0.383, false);
            input.setPhysical(.i, aim.y < -0.383, false);
            input.setPhysical(.k, aim.y > 0.383, false);
        } else {
            if (input.gamepad(7) == null) _ = input.addGamepad(7);
            input.setGamepadAxis(7, .left_x, move.x, 0);
            input.setGamepadAxis(7, .left_y, move.y, 0);
            input.setGamepadAxis(7, .right_x, aim.x, 0);
            input.setGamepadAxis(7, .right_y, aim.y, 0);
            input.setGamepadButton(7, .right_shoulder, fire);
            input.setGamepadButton(7, .east, sprint);
            input.setGamepadButton(7, .start, primary or pause);
            input.setGamepadButton(7, .back, mute);
        }
    }
};
pub fn record(allocator: std.mem.Allocator, mode: Mode) !up.preview.developer.InputReplay {
    const r = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(allocator, game.width, game.height, game.default_seed);
    defer r.deinit();
    r.canvas.detachTrace();
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, game.default_seed);
    defer recorder.deinit();
    var pilot = Pilot{};
    var input = up.input.Input{};
    var pcm: [800]up.assets.AudioSample = undefined;
    for (0..7200) |index| {
        pilot.next(&r.game, &input, mode);
        try recorder.record(input);
        try r.step(input.snapshot(), 1.0 / 60.0);
        try r.audio.mix(&pcm);
        if (pilot.finished) {
            if (!pilot.saw_damage or !pilot.saw_heal or !pilot.saw_death or !pilot.saw_sprint or !pilot.paused_once or r.game.best_score < 100 or r.game.player.health != 3 or r.game.score != 0 or r.game.game_over or r.game.audio_enabled or r.game.save_failed) return error.RouteWitnessMissing;
            std.debug.print("Neon {s}: four waves, damage/heal, sprint, pause, death/restart in {d} ticks; best={d}\n", .{ @tagName(mode), index + 1, r.game.best_score });
            return recorder.finish();
        }
        if (index == 7199) std.debug.print("Neon stuck phase={d} wave={d} score={d} hp={d} pos={any} damage={} heal={} pause={}\n", .{ pilot.phase, r.game.wave, r.game.score, r.game.player.health, r.game.player.position, pilot.saw_damage, pilot.saw_heal, pilot.paused_once });
    }
    return error.RouteDidNotFinish;
}
test "complete keyboard and virtual-controller survival routes use ordinary arena input" {
    for ([_]Mode{ .keyboard, .controller }) |mode| {
        var replay = try record(std.testing.allocator, mode);
        defer replay.deinit(std.testing.allocator);
        const r = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(std.testing.allocator, game.width, game.height, game.default_seed);
        defer r.deinit();
        try r.runReplay(replay);
        try std.testing.expect(r.game.best_score >= 100 and r.game.score == 0 and !r.game.audio_enabled and !r.game.game_over);
        var bytes: [6]u8 = undefined;
        _ = try r.save_data.read("settings.v1", &bytes);
        try std.testing.expectEqual(r.game.best_score, std.mem.readInt(u32, bytes[2..6], .little));
        try std.testing.expectEqual(@as(u8, 0), bytes[1]);
    }
}
