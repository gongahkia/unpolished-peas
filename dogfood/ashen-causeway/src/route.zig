//! Automated observer/controller. Uses ordinary commands; never edits world state.
const std = @import("std");
const world = @import("world.zig");
const Vec = world.Vec;
pub const Pilot = struct {
    ticks: u32 = 0,
    phase_two: bool = false,
    rings_seen: bool = false,
    pub fn command(p: *Pilot, w: *const world.World, goal: Vec) world.Command {
        p.ticks += 1;
        var nearest: ?usize = null;
        var distance: f32 = 210;
        for (w.enemies, 0..) |e, i| {
            if (e.hp == 0) continue;
            if (e.phase == 2) p.phase_two = true;
            const d = e.pos.sub(w.pos).length();
            if (d < distance and world.visible(w.room, w.pos, e.pos)) {
                nearest = i;
                distance = d;
            }
        }
        for (w.rings) |r| if (r.alive) {
            p.rings_seen = true;
        };
        var cmd = world.Command{};
        if (w.player.hp == 0) return cmd;
        if (nearest) |i| {
            const e = w.enemies[i];
            const toward = e.pos.sub(w.pos).unit();
            cmd.aim = toward;
            if (w.player.action != .idle) return cmd;
            for (w.rings) |r| if (r.alive and !r.hit) {
                const gap = w.pos.sub(r.center).length() - r.radius();
                if (gap > 30 and gap <= 42 and w.player.stamina >= 28) {
                    cmd.movement = r.center.sub(w.pos).unit();
                    cmd.action = .dodge;
                    return cmd;
                }
            };
            if (w.player.hp < 65 and w.player.flasks > 0 and (e.stage == .transition or (e.stage == .recovery and e.age < 4) or distance > 150)) {
                cmd.action = .heal;
                return cmd;
            }
            if (e.stage == .transition) return cmd;
            if (e.kind == .censer) {
                if (distance <= 48 and w.player.stamina >= 22) cmd.action = .light else cmd.movement = toward.add(.{ .x = -toward.y * 0.5, .y = toward.x * 0.5 }).unit();
                return cmd;
            }
            if (e.stage == .windup or e.stage == .active) {
                if (e.attack == .ring) return cmd;
                const safe = e.reach() + (if (e.kind == .hound) @as(f32, 38) else 16);
                if (distance < safe) cmd.movement = toward.scale(-1);
                return cmd;
            }
            if (e.stage == .recovery or e.stage == .stagger) {
                const remaining = if (e.stage == .stagger) 80 else e.recovery() -| e.age;
                if (distance <= 54 and remaining >= 36 and w.player.stamina >= 42) cmd.action = .heavy else if (distance <= 47 and remaining >= 18 and w.player.stamina >= 22) cmd.action = .light else if (distance > 44) cmd.movement = toward;
                return cmd;
            }
            if (distance > e.reach() + 5) cmd.movement = toward;
            return cmd;
        }
        if (w.player.hp < 80 and w.player.flasks > 0 and w.player.action == .idle) {
            cmd.action = .heal;
            return cmd;
        }
        cmd.movement = path(w.room, w.pos, goal);
        if (w.pos.sub(goal).length() < 16 and w.player.action == .idle) {
            cmd.interact = true;
            cmd.movement = .{};
        }
        return cmd;
    }
};
/// Small fixed-capacity BFS used only by automation. Player navigation is manual.
pub fn path(room: u8, start: Vec, goal: Vec) Vec {
    const cols = 60;
    const rows = 34;
    const count = cols * rows;
    var previous = [_]i16{-1} ** count;
    var queue: [count]u16 = undefined;
    const sx: usize = @intFromFloat(std.math.clamp(start.x / 16, 0, 59));
    const sy: usize = @intFromFloat(std.math.clamp(start.y / 16, 0, 33));
    const gx: usize = @intFromFloat(std.math.clamp(goal.x / 16, 0, 59));
    const gy: usize = @intFromFloat(std.math.clamp(goal.y / 16, 0, 33));
    const from = sy * cols + sx;
    const to = gy * cols + gx;
    if (from == to) return goal.sub(start).unit();
    previous[from] = @intCast(from);
    queue[0] = @intCast(from);
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail and previous[to] < 0) : (head += 1) {
        const index = queue[head];
        const x: i32 = @intCast(index % cols);
        const y: i32 = @intCast(index / cols);
        for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            const nx = x + d[0];
            const ny = y + d[1];
            if (nx < 0 or ny < 0 or nx >= cols or ny >= rows) continue;
            const next: usize = @intCast(ny * cols + nx);
            const point = Vec{ .x = @as(f32, @floatFromInt(nx)) * 16 + 8, .y = @as(f32, @floatFromInt(ny)) * 16 + 8 };
            if (previous[next] >= 0 or world.blocked(room, point, 8)) continue;
            previous[next] = @intCast(index);
            queue[tail] = @intCast(next);
            tail += 1;
        }
    }
    if (previous[to] < 0) return .{};
    var cursor = to;
    while (@as(usize, @intCast(previous[cursor])) != from) cursor = @intCast(previous[cursor]);
    const point = Vec{ .x = @as(f32, @floatFromInt(cursor % cols)) * 16 + 8, .y = @as(f32, @floatFromInt(cursor / cols)) * 16 + 8 };
    return point.sub(start).unit();
}

test "automated ordinary-command journey reaches every bell and defeats both boss phases" {
    var w = world.World.init();
    var pilot = Pilot{};
    // Swap through the normal command before beginning the route.
    w.tick(.{ .swap = true });
    var last_room: u8 = 0;
    for (0..60000) |tick| {
        var goal = Vec{ .x = 870, .y = 450 };
        if (w.room < 2 and w.bells[w.room]) goal = .{ .x = 915, .y = 270 };
        if (w.room == 1 and !w.reward) goal = .{ .x = 480, .y = 100 };
        const cmd = pilot.command(&w, goal);
        w.tick(cmd);
        if (w.player.hp == 0) {
            std.debug.print("died tick={d} room={d} pos={d:.1},{d:.1} boss={d} flasks={d}\n", .{ tick, w.room, w.pos.x, w.pos.y, w.enemies[4].hp, w.player.flasks });
            return error.RouteDied;
        }
        if (w.room != last_room) {
            std.debug.print("entered {d} tick {d} HP {d} flasks {d}\n", .{ w.room, tick, w.player.hp, w.player.flasks });
            last_room = w.room;
        }
        if (w.completed) {
            std.debug.print("won ticks={d} HP={d} phase2={} rings={}\n", .{ tick, w.player.hp, pilot.phase_two, pilot.rings_seen });
            break;
        }
        if (tick % 10000 == 9999) {
            for (w.enemies) |e| if (e.hp > 0) {
                std.debug.print("enemy {s} hp {d} pos {d:.1},{d:.1} stage {s} age {d}\n", .{ @tagName(e.kind), e.hp, e.pos.x, e.pos.y, @tagName(e.stage), e.age });
            };
            std.debug.print("tick {d} room {d} pos {d:.1},{d:.1} HP {d} targethp {d}\n", .{ tick, w.room, w.pos.x, w.pos.y, w.player.hp, w.enemies[4].hp });
        }
    }
    try std.testing.expect(w.completed);
    try std.testing.expect(pilot.phase_two and pilot.rings_seen);
    try std.testing.expect(w.reward and w.shortcut);
}
