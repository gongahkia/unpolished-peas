//! Ordinary-input level pilot. Observes the game, never changes its state.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const progress = @import("progress.zig");
pub const Mode = enum { keyboard, controller };
pub const Pilot = struct {
    retreat: bool = false,
    death_progress: u8 = 0,
    phase: u8 = 0,
    hold_jump: u8 = 0,
    wait: u8 = 0,
    restarted: bool = false,
    paused_once: bool = false,
    saw_death: bool = false,
    saw_respawn: bool = false,
    saw_completion: bool = false,
    finished: bool = false,
    pub fn next(self: *Pilot, g: *const game.Game, input: *up.input.Input, mode: Mode) void {
        var move: f32 = 0;
        var primary = false;
        var reset = false;
        var pause = false;
        var mute = false;
        var trigger = false;
        switch (self.phase) {
            0 => {
                if (g.screen == .title) primary = true else self.phase = 1;
            },
            1 => {
                if (g.collected[0]) {
                    self.phase = if (self.paused_once) 2 else 20;
                } else move = toward(g.player.position.x, 44);
            },
            2 => {
                if (g.collected[1] and g.player.grounded) {
                    self.phase = 3;
                } else {
                    move = toward(g.player.position.x, 106);
                    trigger = g.player.grounded and g.player.position.x >= 79;
                }
            },
            3 => {
                if (g.collected[2] and g.player.grounded) {
                    self.phase = 4;
                } else {
                    move = toward(g.player.position.x, 157);
                    trigger = g.player.grounded and g.player.position.x >= 115;
                }
            },
            4 => {
                if (g.checkpoint == 1 and g.player.grounded) {
                    self.phase = 5;
                } else move = toward(g.player.position.x, 190);
            },
            5 => {
                if (g.collected[3] and g.player.grounded) {
                    self.phase = if (self.restarted) 9 else 6;
                } else {
                    move = toward(g.player.position.x, 214);
                    trigger = g.player.grounded and g.player.position.x >= 188;
                }
            },
            6 => {
                if (g.dead) {
                    self.saw_death = true;
                    self.death_progress = g.record().mask;
                    self.phase = 7;
                } else {
                    if (g.player.position.x >= 312) self.retreat = true;
                    move = if (self.retreat) -1 else 1;
                }
            },
            7 => {
                if (g.dead) primary = true else {
                    self.saw_respawn = g.checkpoint == 1 and g.record().mask == self.death_progress;
                    self.phase = 8;
                }
            },
            8 => {
                reset = true;
                self.restarted = true;
                self.phase = 1;
            },
            9 => {
                if (g.collected[4] and g.player.grounded) {
                    self.phase = 10;
                } else {
                    move = toward(g.player.position.x, 266);
                    trigger = g.player.grounded and g.player.position.x >= 226;
                }
            },
            10 => {
                if (g.player.grounded and g.player.position.x >= 310) {
                    self.phase = 11;
                } else {
                    move = toward(g.player.position.x, 318);
                    trigger = g.player.grounded and g.player.position.x >= 276;
                }
            },
            11 => {
                if (g.collected[5]) {
                    self.phase = 12;
                } else {
                    move = toward(g.player.position.x, 328);
                    trigger = g.player.grounded;
                }
            },
            12 => {
                if (g.completed) {
                    self.saw_completion = g.collectedCount() == 6;
                    self.phase = 13;
                } else move = toward(g.player.position.x, 347);
            },
            13 => {
                primary = true;
                self.phase = 14;
            },
            14 => {
                mute = true;
                self.phase = 15;
            },
            15 => {
                self.finished = true;
            },
            20 => {
                if (g.screen == .paused) {
                    self.wait = 12;
                    self.phase = 21;
                } else pause = true;
            },
            21 => {
                move = 1;
                if (self.wait > 0) self.wait -= 1 else self.phase = 22;
            },
            22 => {
                primary = true;
                self.paused_once = true;
                self.phase = 2;
            },
            else => unreachable,
        }
        if (trigger and self.hold_jump == 0) self.hold_jump = 20;
        const jump = self.hold_jump > 0;
        if (self.hold_jump > 0) self.hold_jump -= 1;
        input.beginFrame();
        if (mode == .keyboard) {
            input.set(.left, move < 0);
            input.set(.right, move > 0);
            input.set(.action, jump);
            input.set(.start, primary);
            input.setPhysical(.escape, pause, false);
            input.setPhysical(.r, reset, false);
            input.setPhysical(.m, mute, false);
        } else {
            if (input.gamepad(17) == null) _ = input.addGamepad(17);
            input.setGamepadAxis(17, .left_x, move, 0);
            input.setGamepadButton(17, .south, jump);
            input.setGamepadButton(17, .start, primary or pause);
            input.setGamepadButton(17, .left_shoulder, reset);
            input.setGamepadButton(17, .back, mute);
        }
    }
};
fn toward(x: f32, target: f32) f32 {
    return if (x < target - 0.65) 1 else if (x > target + 0.65) -1 else 0;
}
pub fn record(allocator: std.mem.Allocator, mode: Mode) !up.preview.developer.InputReplay {
    const Runner = up.testSupport.HeadlessGameRunner(game.Game);
    const r = try Runner.initSeeded(allocator, game.width, game.height, game.default_seed);
    defer r.deinit();
    r.canvas.detachTrace();
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, game.default_seed);
    defer recorder.deinit();
    var pilot = Pilot{};
    var input = up.input.Input{};
    var pcm: [800]up.assets.AudioSample = undefined;
    for (0..2400) |index| {
        pilot.next(&r.game, &input, mode);
        try recorder.record(input);
        try r.step(input.snapshot(), 1.0 / 60.0);
        try r.audio.mix(&pcm);
        if (pilot.finished) {
            if (!pilot.saw_death or !pilot.saw_respawn or !pilot.saw_completion or !pilot.restarted or !pilot.paused_once or r.game.best_collectibles != 6 or !r.game.completion_unlocked or r.game.collectedCount() != 0 or r.game.audio_enabled or r.game.save_failed) return error.RouteWitnessMissing;
            std.debug.print("Lantern {s}: all six, checkpoint death/respawn, full restart, completion/replay in {d} ticks\n", .{ @tagName(mode), index + 1 });
            return recorder.finish();
        }
        if (index == 2399) std.debug.print("Lantern route stuck phase={d} pos={any} v={any} glows={any} checkpoint={d} dead={}\n", .{ pilot.phase, r.game.player.position, r.game.player.velocity, r.game.collected, r.game.checkpoint, r.game.dead });
    }
    return error.RouteDidNotFinish;
}
test "complete keyboard and virtual-controller routes collect every glow and prove recovery" {
    for ([_]Mode{ .keyboard, .controller }) |mode| {
        var replay = try record(std.testing.allocator, mode);
        defer replay.deinit(std.testing.allocator);
        const r = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(std.testing.allocator, game.width, game.height, game.default_seed);
        defer r.deinit();
        try r.runReplay(replay);
        try std.testing.expect(r.game.best_collectibles == 6 and r.game.completion_unlocked and !r.game.audio_enabled and !r.game.save_failed);
        var bytes: [progress.size]u8 = undefined;
        const saved = try progress.decode(try r.save_data.read(progress.key, &bytes));
        try std.testing.expect(saved.finished and saved.best == 6 and saved.started and !saved.completed and saved.mask == 0);
    }
}
