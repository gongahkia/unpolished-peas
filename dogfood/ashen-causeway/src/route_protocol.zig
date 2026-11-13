//! Complete input-driven route. The pilot observes state and supplies normal
//! keyboard/mouse or controller snapshots; it never grants resources or teleports.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const world = @import("world.zig");
const route = @import("route.zig");
const saves = @import("save.zig");
const Runner = up.testSupport.HeadlessGameRunner(game.Game);
const Mode = enum { keyboard_mouse, controller };
fn apply(input: *up.input.Input, g: *const game.Game, cmd: world.Command, mode: Mode) void {
    input.beginFrame();
    input.set(.start, false);
    const move = cmd.movement;
    if (mode == .controller) {
        input.setGamepadAxis(7, .left_x, move.x, 0);
        input.setGamepadAxis(7, .left_y, move.y, 0);
        const aim = cmd.aim orelse g.state.facing;
        input.setGamepadAxis(7, .right_x, aim.x, 0);
        input.setGamepadAxis(7, .right_y, aim.y, 0);
        input.setGamepadButton(7, .left_shoulder, cmd.action == .light);
        input.setGamepadButton(7, .right_shoulder, cmd.action == .heavy);
        input.setGamepadButton(7, .south, cmd.action == .dodge);
        input.setGamepadButton(7, .north, cmd.action == .heal);
        input.setGamepadButton(7, .back, cmd.swap);
        input.setGamepadButton(7, .west, cmd.interact and !(input.gamepad(7).?.button(.west)));
    } else {
        input.set(.left, move.x < -0.2);
        input.set(.right, move.x > 0.2);
        input.set(.up, move.y < -0.2);
        input.set(.down, move.y > 0.2);
        input.setPhysical(.j, cmd.action == .light, false);
        input.setPhysical(.k, cmd.action == .heavy, false);
        input.set(.action, cmd.action == .dodge);
        input.setPhysical(.h, cmd.action == .heal, false);
        input.setPhysical(.q, cmd.swap, false);
        input.setPhysical(.e, cmd.interact and !input.physicalIsDown(.e), false);
        const aim = cmd.aim orelse g.state.facing;
        const point = up.core.Vec2{ .x = std.math.clamp(g.state.pos.x - g.camera.x + aim.x * 70, 1, 479), .y = std.math.clamp(g.state.pos.y - g.camera.y + aim.y * 70, 35, 241) };
        input.setPointerPosition(point, point, point);
    }
}

fn menuKey(r: *Runner, recorder: *up.preview.developer.InputReplayRecorder, input: *up.input.Input, mode: Mode, key: up.input.Key) !void {
    input.* = .{};
    if (mode == .controller) {
        _ = input.addGamepad(7);
        switch (key) {
            .down => input.setGamepadAxis(7, .left_y, 1, 0),
            .up => input.setGamepadAxis(7, .left_y, -1, 0),
            .cancel => input.setGamepadButton(7, .start, true),
            else => input.setGamepadButton(7, .west, true),
        }
    } else input.set(key, true);
    try recorder.record(input.*);
    try r.step(input.snapshot(), 1.0 / 60.0);
    input.beginFrame();
    if (mode == .controller) {
        input.setGamepadAxis(7, .left_y, 0, 0);
        input.setGamepadButton(7, .start, false);
        input.setGamepadButton(7, .west, false);
    } else input.set(key, false);
    try recorder.record(input.*);
    try r.step(input.snapshot(), 1.0 / 60.0);
}

fn capture(r: *Runner, dir: []const u8, mode: Mode, label: []const u8) !void {
    try r.draw(0);
    var filename: [1024]u8 = undefined;
    try r.canvas.writePngFile(try std.fmt.bufPrint(&filename, "{s}/{s}-{s}.png", .{ dir, @tagName(mode), label }));
}

test "complete keyboard mouse and controller journeys save continue and replay" {
    const evidence = std.process.getEnvVarOwned(std.testing.allocator, "ASHEN_ROUTE_EVIDENCE") catch null;
    defer if (evidence) |dir| std.testing.allocator.free(dir);
    if (evidence) |dir| try std.fs.cwd().makePath(dir);
    for (std.enums.values(Mode)) |mode| {
        var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(std.testing.allocator, 60, game.default_seed);
        defer recorder.deinit();
        const r = try Runner.initSeeded(std.testing.allocator, game.width, game.height, game.default_seed);
        defer r.deinit();
        var input = up.input.Input{};
        if (mode == .controller) _ = input.addGamepad(7);
        input.set(.start, true);
        try recorder.record(input);
        try r.step(input.snapshot(), 1.0 / 60.0);
        apply(&input, &r.game, .{ .swap = true }, mode);
        try recorder.record(input);
        try r.step(input.snapshot(), 1.0 / 60.0);
        var pilot = route.Pilot{};
        var backtracked = false;
        var lift_done = false;
        var captured = [_]bool{false} ** 5;
        for (0..30000) |tick| {
            const w = &r.game.state;
            var goal = world.Vec{ .x = 870, .y = 450 };
            if (w.room < 2 and w.bells[w.room]) goal = .{ .x = 915, .y = 270 };
            if (w.room == 1 and !w.reward) goal = .{ .x = 480, .y = 100 };
            if (w.checkpoint != w.room) goal = .{ .x = 70, .y = 270 };
            if (w.shortcut and !lift_done) goal = .{ .x = 110, .y = 450 };
            if (w.room == 1 and w.checkpoint == 1 and w.upgrade == 0 and w.embers >= 50) {
                try menuKey(r, &recorder, &input, mode, .cancel);
                try menuKey(r, &recorder, &input, mode, .down);
                try menuKey(r, &recorder, &input, mode, .down);
                try menuKey(r, &recorder, &input, mode, .start);
                try menuKey(r, &recorder, &input, mode, .up);
                try menuKey(r, &recorder, &input, mode, .up);
                try menuKey(r, &recorder, &input, mode, .start);
                try std.testing.expectEqual(@as(u8, 1), w.upgrade);
            }
            const previous_room = w.room;
            const cmd = pilot.command(w, goal);
            apply(&input, &r.game, cmd, mode);
            try recorder.record(input);
            try r.step(input.snapshot(), 1.0 / 60.0);
            if (previous_room == 1 and w.room == 0 and w.shortcut) backtracked = true;
            if (previous_room == 0 and w.room == 1 and backtracked) lift_done = true;
            if (tick % 300 == 0) try r.draw(0);
            if (evidence) |dir| {
                if (w.room == 1 and !captured[0]) {
                    try capture(r, dir, mode, "cloister");
                    captured[0] = true;
                }
                for (w.enemies) |e| if (e.kind == .warden and e.hp > 0) {
                    if (e.stage == .windup and !captured[1]) {
                        try capture(r, dir, mode, "warden-windup");
                        captured[1] = true;
                    }
                    if (e.stage == .transition and !captured[2]) {
                        try capture(r, dir, mode, "warden-transition");
                        captured[2] = true;
                    }
                };
                for (w.rings) |ring| if (ring.alive and ring.age > 10 and !captured[3]) {
                    try capture(r, dir, mode, "warden-shock");
                    captured[3] = true;
                };
            }
            if (r.game.state.player.hp == 0) {
                std.debug.print("{s} died tick {d} room {d}\n", .{ @tagName(mode), tick, w.room });
                return error.RouteDied;
            }
            if (r.game.state.completed) break;
        }
        try std.testing.expect(r.game.state.completed);
        try std.testing.expect(pilot.phase_two and pilot.rings_seen);
        try std.testing.expect(r.game.state.reward and r.game.state.shortcut and lift_done);
        try std.testing.expectEqual(@as(u8, 2), r.game.state.checkpoint);
        try std.testing.expectEqual(@as(u8, 1), r.game.state.upgrade);
        var bytes: [saves.size]u8 = undefined;
        const ending = try saves.decode(try r.save_data.read(saves.key, &bytes));
        try std.testing.expect(ending.state.completed);
        const continued = try Runner.initSeededWithSaveData(std.testing.allocator, game.width, game.height, game.default_seed, r.save_data);
        defer continued.deinit();
        try std.testing.expect(continued.game.state.completed and continued.game.state.boss_defeated);
        try std.testing.expectEqual(r.game.state.player.weapon, continued.game.state.player.weapon);
        var replay = try recorder.finish();
        defer replay.deinit(std.testing.allocator);
        if (evidence) |dir| {
            try capture(r, dir, mode, "victory");
            const encoded = try replay.encode(std.testing.allocator);
            defer std.testing.allocator.free(encoded);
            var filename: [1024]u8 = undefined;
            try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&filename, "{s}/{s}.upr", .{ dir, @tagName(mode) }), .data = encoded });
        }
        const again = try Runner.initSeeded(std.testing.allocator, game.width, game.height, game.default_seed);
        defer again.deinit();
        // Replay fixed input without the pilot observing or adapting a second time.
        for (replay.frames) |frame| try again.step(frame, 1.0 / 60.0);
        try std.testing.expectEqualDeep(saves.encode(r.game.state, r.game.settings), saves.encode(again.game.state, again.game.settings));
        try r.draw(0);
        try again.draw(0);
        try up.testSupport.expectCanvasTraceEqual(r.capture().canvas_trace, again.capture().canvas_trace);
        std.debug.print("{s}: won and replayed {d} input ticks, HP {d}, flasks {d}\n", .{ @tagName(mode), replay.frames.len, r.game.state.player.hp, r.game.state.player.flasks });
    }
}

test "ordinary input earns currency dies respawns and recovers the drop" {
    const r = try Runner.initSeeded(std.testing.allocator, game.width, game.height, game.default_seed);
    defer r.deinit();
    const evidence = std.process.getEnvVarOwned(std.testing.allocator, "ASHEN_ROUTE_EVIDENCE") catch null;
    defer if (evidence) |dir| std.testing.allocator.free(dir);
    if (evidence) |dir| try std.fs.cwd().makePath(dir);
    var input = up.input.Input{};
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    apply(&input, &r.game, .{ .swap = true }, .keyboard_mouse);
    try r.step(input.snapshot(), 1.0 / 60.0);
    var pilot = route.Pilot{};
    for (0..5000) |_| {
        const cmd = pilot.command(&r.game.state, .{ .x = 870, .y = 450 });
        apply(&input, &r.game, cmd, .keyboard_mouse);
        try r.step(input.snapshot(), 1.0 / 60.0);
        if (r.game.state.embers >= 25) break;
    }
    try std.testing.expect(r.game.state.embers >= 25);
    const carried = r.game.state.embers;
    try std.testing.expect(r.game.state.enemies[1].hp > 0);
    // Deliberately refuse to attack/dodge, approaching the living Pike normally.
    for (0..4000) |_| {
        const cmd = world.Command{ .movement = route.path(0, r.game.state.pos, r.game.state.enemies[1].pos) };
        apply(&input, &r.game, cmd, .keyboard_mouse);
        try r.step(input.snapshot(), 1.0 / 60.0);
        if (r.game.state.player.hp == 0) break;
    }
    try std.testing.expectEqual(@as(u8, 0), r.game.state.player.hp);
    try std.testing.expectEqual(carried, r.game.state.drop.amount);
    try std.testing.expectEqual(@as(u32, 0), r.game.state.embers);
    if (evidence) |dir| try capture(r, dir, .keyboard_mouse, "death");
    const drop_pos = r.game.state.drop.pos;
    input = .{};
    input.set(.start, true);
    try r.step(input.snapshot(), 1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 70), r.game.state.pos.x);
    try std.testing.expectEqual(@as(u8, 100), r.game.state.player.hp);
    try std.testing.expect(r.game.state.enemies[0].hp > 0);
    if (evidence) |dir| try capture(r, dir, .keyboard_mouse, "respawn");
    for (0..8000) |_| {
        const cmd = pilot.command(&r.game.state, drop_pos);
        apply(&input, &r.game, cmd, .keyboard_mouse);
        try r.step(input.snapshot(), 1.0 / 60.0);
        if (r.game.state.drop.amount == 0) break;
        if (r.game.state.player.hp == 0) return error.RecoveryRouteDied;
    }
    try std.testing.expectEqual(@as(u32, 0), r.game.state.drop.amount);
    try std.testing.expect(r.game.state.embers >= carried);
    if (evidence) |dir| try capture(r, dir, .keyboard_mouse, "recovered");
}
