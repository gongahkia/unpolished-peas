//! Bounded game-owned world, collision and combat. Coordinates are world pixels.
const std = @import("std");
const combat = @import("combat.zig");
pub const Vec = struct {
    x: f32 = 0,
    y: f32 = 0,
    pub fn add(a: Vec, b: Vec) Vec {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec, b: Vec) Vec {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec, n: f32) Vec {
        return .{ .x = a.x * n, .y = a.y * n };
    }
    pub fn length(a: Vec) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }
    pub fn unit(a: Vec) Vec {
        const n = a.length();
        return if (n > 0.001) a.scale(1 / n) else .{};
    }
    pub fn dot(a: Vec, b: Vec) f32 {
        return a.x * b.x + a.y * b.y;
    }
};
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fn contains(r: Rect, p: Vec, radius: f32) bool {
        return p.x > r.x - radius and p.x < r.x + r.w + radius and p.y > r.y - radius and p.y < r.y + r.h + radius;
    }
};
pub const room_width: f32 = 960;
pub const room_height: f32 = 540;
pub const names = [_][]const u8{ "REED QUAY", "SILT CLOISTER", "BEACON CROWN" };
const quay = [_]Rect{
    .{ .x = 220, .y = 110, .w = 40, .h = 220 }, .{ .x = 420, .y = 250, .w = 180, .h = 36 }, .{ .x = 690, .y = 100, .w = 40, .h = 230 },
};
const cloister = [_]Rect{
    .{ .x = 180, .y = 180, .w = 260, .h = 36 }, .{ .x = 180, .y = 340, .w = 260, .h = 36 }, .{ .x = 530, .y = 180, .w = 260, .h = 36 }, .{ .x = 530, .y = 340, .w = 260, .h = 36 },
};
const crown = [_]Rect{
    .{ .x = 160, .y = 90, .w = 40, .h = 140 }, .{ .x = 160, .y = 340, .w = 40, .h = 110 }, .{ .x = 360, .y = 90, .w = 40, .h = 140 }, .{ .x = 360, .y = 340, .w = 40, .h = 110 },
};
pub fn walls(room: u8) []const Rect {
    return switch (room) {
        0 => &quay,
        1 => &cloister,
        else => &crown,
    };
}
pub fn blocked(room: u8, p: Vec, radius: f32) bool {
    if (p.x < radius + 16 or p.y < radius + 40 or p.x > room_width - 16 - radius or p.y > room_height - 16 - radius) return true;
    for (walls(room)) |r| if (r.contains(p, radius)) return true;
    return false;
}
/// Substeps prevent tunnelling even during dodge/knockback.
pub fn move(room: u8, p: Vec, delta: Vec, radius: f32) Vec {
    var out = p;
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(delta.length() / 3))));
    const d = delta.scale(1 / @as(f32, @floatFromInt(steps)));
    for (0..steps) |_| {
        const x = Vec{ .x = out.x + d.x, .y = out.y };
        if (!blocked(room, x, radius)) out = x;
        const y = Vec{ .x = out.x, .y = out.y + d.y };
        if (!blocked(room, y, radius)) out = y;
    }
    return out;
}
pub fn visible(room: u8, a: Vec, b: Vec) bool {
    const d = b.sub(a);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(d.length()))));
    for (0..steps + 1) |i| {
        const p = a.add(d.scale(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps))));
        for (walls(room)) |r| if (r.contains(p, 0)) return false;
    }
    return true;
}
pub const Kind = enum { drifter, pike, censer, hound, warden };
pub const Stage = enum { approach, windup, active, recovery, stagger, transition };
pub const Enemy = struct {
    kind: Kind = .drifter,
    pos: Vec = .{},
    aim: Vec = .{ .x = -1 },
    hp: u16 = 0,
    stage: Stage = .approach,
    age: u16 = 0,
    hit: bool = false,
    phase: u8 = 1,
    stagger_guard: u8 = 0,
    pub fn reach(e: Enemy) f32 {
        return switch (e.kind) {
            .drifter => 32,
            .pike => 56,
            .censer => 200,
            .hound => 30,
            .warden => 76,
        };
    }
    pub fn windup(e: Enemy) u16 {
        return switch (e.kind) {
            .drifter => 42,
            .pike => 48,
            .censer => 70,
            .hound => 34,
            .warden => if (e.phase == 2) 36 else 54,
        };
    }
    pub fn recovery(e: Enemy) u16 {
        return switch (e.kind) {
            .hound => 72,
            .warden => 64,
            else => 48,
        };
    }
};
pub const Drop = struct { room: u8 = 0, pos: Vec = .{}, amount: u32 = 0 };
pub const Command = struct { movement: Vec = .{}, aim: ?Vec = null, action: ?combat.Action = null, interact: bool = false, swap: bool = false };
pub const World = struct {
    player: combat.Fighter = .{},
    pos: Vec = .{ .x = 70, .y = 270 },
    facing: Vec = .{ .x = 1 },
    dodge_dir: Vec = .{ .x = 1 },
    room: u8 = 0,
    checkpoint: u8 = 0,
    embers: u32 = 0,
    drop: Drop = .{},
    shortcut: bool = false,
    bells: [3]bool = .{false} ** 3,
    reward: bool = false,
    boss_defeated: bool = false,
    upgrade: u8 = 0,
    vitality: u8 = 0,
    charm: bool = false,
    completed: bool = false,
    enemies: [32]Enemy = [_]Enemy{.{}} ** 32,
    message: []const u8 = "Find the lantern. Carry the coal to the beacon.",
    pub fn init() World {
        var w = World{};
        w.spawn();
        return w;
    }
    pub fn spawn(w: *World) void {
        w.enemies = [_]Enemy{.{}} ** 32;
        const kinds = [_]Kind{ .drifter, .pike, .hound, .censer };
        const points = [_]Vec{ .{ .x = 340, .y = 150 }, .{ .x = 510, .y = 390 }, .{ .x = 650, .y = 300 }, .{ .x = 820, .y = 150 } };
        for (points, kinds, 0..) |p, k, i| w.enemies[i] = .{ .kind = k, .pos = p, .hp = if (k == .hound) 60 else 85 };
        if (w.room == 2) {
            w.enemies[3].hp = 0;
            if (!w.boss_defeated) w.enemies[4] = .{ .kind = .warden, .pos = .{ .x = 760, .y = 280 }, .hp = 480 };
        }
    }
    pub fn rest(w: *World) void {
        w.checkpoint = w.room;
        const weapon = w.player.weapon;
        w.player = .{ .weapon = weapon };
        w.applyEquipment();
        w.player.hp = w.player.max_hp;
        w.player.stamina = w.player.max_stamina;
        w.player.flasks = if (w.reward) 4 else 3;
        w.spawn();
        w.message = "Lantern kindled. Health and flasks restored.";
    }
    pub fn respawn(w: *World) void {
        w.room = w.checkpoint;
        w.pos = .{ .x = 70, .y = 270 };
        w.rest();
    }
    pub fn die(w: *World) void {
        w.drop = .{ .room = w.room, .pos = w.pos, .amount = w.embers };
        w.embers = 0;
        w.message = "Your embers wait where you fell. A second death replaces them.";
    }
    pub fn tick(w: *World, cmd: Command) void {
        if (w.player.hp == 0) return;
        if (cmd.swap) _ = w.player.equip(if (w.player.weapon == .sabre) .spear else .sabre);
        if (w.player.action == .idle) {
            if (cmd.aim) |a| {
                if (a.length() > 0.1) w.facing = a.unit();
            } else if (cmd.movement.length() > 0.1) w.facing = cmd.movement.unit();
        }
        if (cmd.action) |a| w.player.request(a);
        w.player.tick();
        if (w.player.accepted and w.player.action == .dodge) w.dodge_dir = if (cmd.movement.length() > 0.1) cmd.movement.unit() else w.facing;
        if (w.player.action == .idle) w.pos = move(w.room, w.pos, cmd.movement.unit().scale(@min(1, cmd.movement.length()) * (if (w.charm) @as(f32, 1.5) else 1.7)), 7);
        if (w.player.action == .dodge) w.pos = move(w.room, w.pos, w.dodge_dir.scale(if (w.player.age < 15) @as(f32, 4) else 1), 7);
        for (&w.enemies, 0..) |*e, i| {
            if (e.hp == 0) continue;
            const d = e.pos.sub(w.pos);
            const t = combat.spec(w.player.weapon, w.player.action);
            if (e.stage != .transition and w.player.active() and d.length() <= @as(f32, @floatFromInt(t.reach)) + 9 and d.unit().dot(w.facing) > 0.55 and visible(w.room, w.pos, e.pos) and w.player.hitOnce(@intCast(i))) {
                e.hp -|= @as(u16, t.damage) + @as(u16, w.upgrade) * 6;
                if (e.hp == 0) {
                    w.embers +|= if (e.kind == .warden) @as(u32, 200) else 25;
                    if (e.kind == .warden) {
                        w.boss_defeated = true;
                        w.message = "The Bell Warden falls. Rekindle the beacon.";
                    }
                    continue;
                }
                if (e.stagger_guard == 0) {
                    e.stage = .stagger;
                    e.age = 0;
                    e.stagger_guard = 72;
                }
                e.pos = move(w.room, e.pos, w.facing.scale(8), 9);
            }
            w.enemyTick(e);
            if (w.player.hp == 0) {
                w.die();
                return;
            }
        }
        if (w.drop.amount > 0 and w.drop.room == w.room and w.pos.sub(w.drop.pos).length() < 18) {
            w.embers +|= w.drop.amount;
            w.drop.amount = 0;
            w.message = "Lost embers recovered.";
        }
        if (cmd.interact and w.player.action == .idle) w.interact();
    }
    fn enemyTick(w: *World, e: *Enemy) void {
        const d = w.pos.sub(e.pos);
        e.age +|= 1;
        if (e.stagger_guard > 0) e.stagger_guard -= 1;
        switch (e.stage) {
            .approach => {
                if (d.length() > 240 or !visible(w.room, e.pos, w.pos)) return;
                if (d.length() <= e.reach() + 10) {
                    e.stage = .windup;
                    e.age = 0;
                    e.aim = d.unit();
                    e.hit = false;
                } else if (e.kind != .censer) e.pos = move(w.room, e.pos, d.unit().scale(if (e.kind == .hound) @as(f32, 1.25) else 0.65), 9);
            },
            .windup => {
                if (e.age >= e.windup()) {
                    e.stage = .active;
                    e.age = 0;
                }
            },
            .active => {
                if (e.kind == .hound and e.age < 10) e.pos = move(w.room, e.pos, e.aim.scale(3), 9);
                const target = w.pos.sub(e.pos);
                if (!e.hit and target.length() <= e.reach() and target.unit().dot(e.aim) > 0.45 and visible(w.room, e.pos, w.pos)) {
                    e.hit = true;
                    if (w.player.damage(if (e.kind == .warden) 32 else 18)) w.pos = move(w.room, w.pos, e.aim.scale(9), 7);
                }
                if (e.age >= 10) {
                    e.stage = .recovery;
                    e.age = 0;
                }
            },
            .recovery => {
                if (e.age >= e.recovery()) {
                    e.stage = .approach;
                    e.age = 0;
                }
            },
            .stagger => {
                if (e.age >= 18) {
                    e.stage = .recovery;
                    e.age = 0;
                }
            },
            .transition => {
                if (e.age >= 120) {
                    e.stage = .recovery;
                    e.age = 0;
                }
            },
        }
        if (e.kind == .warden and e.hp <= 240 and e.phase == 1) {
            e.phase = 2;
            e.stage = .transition;
            e.age = 0;
            w.message = "The second bell tolls. The Warden quickens.";
        }
    }
    pub fn nearLantern(w: World) bool {
        return w.pos.sub(.{ .x = 70, .y = 270 }).length() < 30;
    }
    pub fn applyEquipment(w: *World) void {
        w.player.max_hp = 100 + w.vitality * 15;
        w.player.max_stamina = if (w.charm) 125 else 100;
        w.player.hp = @min(w.player.hp, w.player.max_hp);
        w.player.stamina = @min(w.player.stamina, w.player.max_stamina);
    }
    pub fn purchase(w: *World, health: bool) bool {
        if (!w.nearLantern() or w.player.action != .idle or w.player.hp == 0) return false;
        const level = if (health) &w.vitality else &w.upgrade;
        const cost = (@as(u32, level.*) + 1) * 50;
        if (level.* >= 3 or w.embers < cost) {
            w.message = "Upgrade unavailable: need embers or already capped.";
            return false;
        }
        w.embers -= cost;
        level.* += 1;
        w.applyEquipment();
        w.message = "Upgrade forged. Rest to restore your new capacity.";
        return true;
    }
    pub fn toggleCharm(w: *World) bool {
        if (!w.reward or !w.nearLantern() or w.player.action != .idle or w.player.hp == 0) return false;
        w.charm = !w.charm;
        w.applyEquipment();
        w.message = if (w.charm) "Reed charm: 25 more stamina, slower walking." else "Reed charm removed. Normal walking speed.";
        return true;
    }
    fn interact(w: *World) void {
        if (w.room == 2 and w.boss_defeated and w.bells[2] and w.pos.sub(.{ .x = 870, .y = 450 }).length() < 30) {
            w.completed = true;
            w.message = "The beacon burns. The drowned can find their way home.";
            return;
        }
        if (w.pos.sub(.{ .x = 70, .y = 270 }).length() < 30) {
            w.rest();
            return;
        }
        if (w.pos.sub(.{ .x = 870, .y = 450 }).length() < 30) {
            w.bells[w.room] = true;
            w.message = "Mooring bell rung. The passage opens.";
            if (w.room == 1) w.shortcut = true;
            return;
        }
        if (w.pos.x > 900 and w.room < 2 and w.bells[w.room]) {
            w.room += 1;
            w.pos = .{ .x = 70, .y = 270 };
            w.spawn();
            return;
        }
        if (w.pos.x < 50 and w.room > 0) {
            w.room -= 1;
            w.pos = .{ .x = 890, .y = 270 };
            w.spawn();
            return;
        }
        if (w.room == 1 and w.pos.sub(.{ .x = 480, .y = 100 }).length() < 30 and !w.reward) {
            w.reward = true;
            w.embers +|= 75;
            w.player.flasks = @min(4, w.player.flasks + 1);
            w.message = "Reliquary: extra flask, reed charm, 75 embers.";
            return;
        }
        if (w.shortcut and w.pos.sub(.{ .x = 110, .y = 450 }).length() < 30 and w.room < 2) {
            w.room = 1 - w.room;
            w.pos = .{ .x = 110, .y = 450 };
            w.spawn();
            w.message = "The return lift bypasses the old quay.";
        }
    }
};

test "collision substeps prevent tunnelling and walls block attacks" {
    const p = move(0, .{ .x = 200, .y = 200 }, .{ .x = 150 }, 7);
    try std.testing.expect(p.x <= 213);
    try std.testing.expect(!visible(0, .{ .x = 210, .y = 200 }, .{ .x = 270, .y = 200 }));
    try std.testing.expect(visible(0, .{ .x = 100, .y = 350 }, .{ .x = 800, .y = 350 }));
}
test "death replaces old drop, respawn resets enemies and recovery is once" {
    var w = World.init();
    w.embers = 35;
    w.die();
    try std.testing.expectEqual(@as(u32, 35), w.drop.amount);
    w.enemies[0].hp = 0;
    w.respawn();
    try std.testing.expect(w.enemies[0].hp > 0);
    w.tick(.{});
    try std.testing.expectEqual(@as(u32, 35), w.embers);
    w.tick(.{});
    try std.testing.expectEqual(@as(u32, 35), w.embers);
    w.embers = 12;
    w.die();
    w.die();
    try std.testing.expectEqual(@as(u32, 0), w.drop.amount);
}
test "bell unlocks area, rest establishes checkpoint, lift is bidirectional" {
    var w = World.init();
    w.pos = .{ .x = 870, .y = 450 };
    w.tick(.{ .interact = true });
    try std.testing.expect(w.bells[0]);
    w.pos = .{ .x = 910, .y = 270 };
    w.tick(.{ .interact = true });
    try std.testing.expectEqual(@as(u8, 1), w.room);
    w.pos = .{ .x = 70, .y = 270 };
    w.tick(.{ .interact = true });
    try std.testing.expectEqual(@as(u8, 1), w.checkpoint);
    w.pos = .{ .x = 870, .y = 450 };
    w.tick(.{ .interact = true });
    try std.testing.expect(w.shortcut);
    w.pos = .{ .x = 110, .y = 450 };
    w.tick(.{ .interact = true });
    try std.testing.expectEqual(@as(u8, 0), w.room);
    w.tick(.{ .interact = true });
    try std.testing.expectEqual(@as(u8, 1), w.room);
}

test "enemy anticipation locks direction, attacks once and respects solid walls" {
    var w = World.init();
    w.pos = .{ .x = 300, .y = 200 };
    w.enemies = [_]Enemy{.{}} ** 32;
    var e = Enemy{ .kind = .pike, .pos = .{ .x = 280, .y = 200 }, .hp = 85 };
    w.enemyTick(&e);
    try std.testing.expectEqual(Stage.windup, e.stage);
    const aim = e.aim;
    for (0..47) |_| w.enemyTick(&e);
    try std.testing.expectEqual(@as(u8, 100), w.player.hp);
    w.enemyTick(&e);
    try std.testing.expectEqual(Stage.active, e.stage);
    w.enemyTick(&e);
    try std.testing.expectEqual(@as(u8, 82), w.player.hp);
    for (0..10) |_| w.enemyTick(&e);
    try std.testing.expectEqual(@as(u8, 82), w.player.hp);
    try std.testing.expectEqualDeep(aim, e.aim);
    w.player = .{};
    w.pos = .{ .x = 270, .y = 200 };
    e = .{ .kind = .pike, .pos = .{ .x = 210, .y = 200 }, .hp = 85, .stage = .active, .aim = .{ .x = 1 } };
    w.enemyTick(&e);
    try std.testing.expectEqual(@as(u8, 100), w.player.hp);
}
test "boss transition grants a safe interval and preserves the second phase" {
    var w = World.init();
    w.room = 2;
    w.pos = .{ .x = 740, .y = 280 };
    w.spawn();
    for (w.enemies[0..4]) |*e| e.hp = 0;
    w.enemies[4].hp = 240;
    w.tick(.{});
    try std.testing.expectEqual(Stage.transition, w.enemies[4].stage);
    try std.testing.expectEqual(@as(u8, 2), w.enemies[4].phase);
    const hp = w.enemies[4].hp;
    w.player.action = .heavy;
    w.player.age = 19;
    w.tick(.{});
    try std.testing.expectEqual(hp, w.enemies[4].hp);
    for (0..119) |_| w.tick(.{});
    try std.testing.expectEqual(Stage.recovery, w.enemies[4].stage);
    try std.testing.expectEqual(@as(u8, 100), w.player.hp);
}

test "lantern upgrades spend capped currency, alter capacity and charm trades speed" {
    var w = World.init();
    w.embers = 1000;
    for (0..3) |_| try std.testing.expect(w.purchase(false));
    try std.testing.expectEqual(@as(u32, 700), w.embers);
    try std.testing.expect(!w.purchase(false));
    w.pos.x = 140;
    try std.testing.expect(!w.purchase(true));
    w.pos.x = 70;
    try std.testing.expect(w.purchase(true));
    try std.testing.expectEqual(@as(u8, 115), w.player.max_hp);
    try std.testing.expectEqual(@as(u8, 100), w.player.hp);
    try std.testing.expect(!w.toggleCharm());
    w.reward = true;
    try std.testing.expect(w.toggleCharm());
    w.rest();
    try std.testing.expectEqual(@as(u8, 125), w.player.stamina);
    try std.testing.expectEqual(@as(u8, 115), w.player.hp);
    try std.testing.expectEqual(@as(u8, 4), w.player.flasks);
    w.tick(.{ .movement = .{ .x = 1 } });
    try std.testing.expectApproxEqAbs(@as(f32, 71.5), w.pos.x, 0.001);
    try std.testing.expect(w.toggleCharm());
    try std.testing.expectEqual(@as(u8, 100), w.player.stamina);
}

test "beacon victory requires boss defeat and its mooring bell" {
    var w = World.init();
    w.room = 2;
    w.bells = .{ true, true, false };
    w.pos = .{ .x = 870, .y = 450 };
    for (&w.enemies) |*e| e.hp = 0;
    w.tick(.{ .interact = true });
    try std.testing.expect(!w.completed);
    w.boss_defeated = true;
    w.tick(.{ .interact = true });
    try std.testing.expect(w.completed);
}
