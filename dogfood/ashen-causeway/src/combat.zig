//! Game-owned 60 Hz combat. No host, clock, allocator or rendering dependency.
const std = @import("std");
pub const Weapon = enum { sabre, spear };
pub const Action = enum { idle, light, heavy, dodge, heal, stagger };
pub const Spec = struct {
    startup: u16,
    active: u16,
    recovery: u16,
    cost: u8,
    damage: u8,
    reach: u8,
    pub fn duration(s: Spec) u16 {
        return s.startup + s.active + s.recovery;
    }
};
pub fn spec(w: Weapon, a: Action) Spec {
    return switch (a) {
        .light => if (w == .sabre) .{ .startup = 7, .active = 4, .recovery = 13, .cost = 18, .damage = 22, .reach = 28 } else .{ .startup = 12, .active = 3, .recovery = 18, .cost = 22, .damage = 27, .reach = 44 },
        .heavy => if (w == .sabre) .{ .startup = 19, .active = 5, .recovery = 23, .cost = 34, .damage = 44, .reach = 34 } else .{ .startup = 27, .active = 4, .recovery = 28, .cost = 42, .damage = 58, .reach = 52 },
        .dodge => .{ .startup = 3, .active = 12, .recovery = 11, .cost = 28, .damage = 0, .reach = 0 },
        .heal => .{ .startup = 36, .active = 1, .recovery = 23, .cost = 0, .damage = 0, .reach = 0 },
        .stagger => .{ .startup = 0, .active = 0, .recovery = 12, .cost = 0, .damage = 0, .reach = 0 },
        .idle => .{ .startup = 0, .active = 0, .recovery = 0, .cost = 0, .damage = 0, .reach = 0 },
    };
}
pub const Fighter = struct {
    weapon: Weapon = .sabre,
    action: Action = .idle,
    age: u16 = 0,
    hp: u8 = 100,
    max_hp: u8 = 100,
    max_stamina: u8 = 100,
    stamina: u8 = 100,
    flasks: u8 = 3,
    regen_delay: u8 = 0,
    immunity: u8 = 0,
    pending: ?Action = null,
    buffer_left: u8 = 0,
    hit_mask: u32 = 0,
    accepted: bool = false,
    rejected: bool = false,

    pub fn active(s: Fighter) bool {
        const t = spec(s.weapon, s.action);
        return (s.action == .light or s.action == .heavy) and s.age >= t.startup and s.age < t.startup + t.active;
    }
    pub fn invulnerable(s: Fighter) bool {
        return s.immunity > 0 or (s.action == .dodge and s.age >= 3 and s.age < 15);
    }
    pub fn hitOnce(s: *Fighter, target: u5) bool {
        const mask = @as(u32, 1) << target;
        if (!s.active() or s.hit_mask & mask != 0) return false;
        s.hit_mask |= mask;
        return true;
    }
    pub fn request(s: *Fighter, a: Action) void {
        if (a == .idle or a == .stagger or s.hp == 0) return;
        s.pending = a;
        s.buffer_left = 8;
    }
    /// Called once per simulation update, before collision/damage resolution.
    pub fn tick(s: *Fighter) void {
        s.accepted = false;
        s.rejected = false;
        if (s.hp == 0) return;
        if (s.immunity > 0) s.immunity -= 1;
        if (s.regen_delay > 0) s.regen_delay -= 1;
        if (s.action != .idle) {
            s.age += 1;
            if (s.action == .heal and s.age == 36) s.hp = @intCast(@min(s.max_hp, @as(u16, s.hp) + 45));
            if (s.age >= spec(s.weapon, s.action).duration()) {
                s.action = .idle;
                s.age = 0;
            }
        }
        if (s.action == .idle) {
            if (s.pending) |a| {
                const t = spec(s.weapon, a);
                if (s.stamina >= t.cost and (a != .heal or s.flasks > 0)) {
                    s.action = a;
                    s.age = 0;
                    s.stamina -= t.cost;
                    s.regen_delay = 36;
                    s.hit_mask = 0;
                    if (a == .heal) s.flasks -= 1;
                    s.accepted = true;
                } else s.rejected = true;
                s.pending = null;
            } else if (s.regen_delay == 0) s.stamina = @intCast(@min(s.max_stamina, @as(u16, s.stamina) + 1));
        }
        if (s.buffer_left > 0) {
            s.buffer_left -= 1;
            if (s.buffer_left == 0) s.pending = null;
        }
    }
    pub fn damage(s: *Fighter, amount: u8) bool {
        if (s.hp == 0 or s.invulnerable()) return false;
        s.hp -|= amount;
        s.action = .stagger;
        s.age = 0;
        s.pending = null;
        s.buffer_left = 0;
        s.immunity = 36;
        s.regen_delay = 36;
        return true;
    }
    pub fn equip(s: *Fighter, w: Weapon) bool {
        if (s.action != .idle or s.hp == 0) return false;
        s.weapon = w;
        return true;
    }
};

test "all weapon windows, costs, recovery and target damage once" {
    for (std.enums.values(Weapon)) |w| {
        for ([_]Action{ .light, .heavy }) |a| {
            var f = Fighter{ .weapon = w };
            const t = spec(w, a);
            f.request(a);
            f.tick();
            try std.testing.expect(f.accepted);
            try std.testing.expectEqual(100 - t.cost, f.stamina);
            for (0..t.duration()) |age| {
                try std.testing.expectEqual(age >= t.startup and age < t.startup + t.active, f.active());
                if (f.active()) {
                    if (age == t.startup) try std.testing.expect(f.hitOnce(0));
                    try std.testing.expect(!f.hitOnce(0));
                }
                f.tick();
            }
            try std.testing.expectEqual(Action.idle, f.action);
        }
    }
}
test "dodge boundaries and damage immunity prevent stagger loops" {
    var f = Fighter{};
    f.request(.dodge);
    f.tick();
    for (0..26) |age| {
        try std.testing.expectEqual(age >= 3 and age < 15, f.invulnerable());
        f.tick();
    }
    try std.testing.expect(f.damage(20));
    try std.testing.expect(!f.damage(20));
    for (0..36) |_| f.tick();
    try std.testing.expect(f.damage(20));
    try std.testing.expectEqual(@as(u8, 60), f.hp);
}
test "bounded buffer commits on first free tick and expires earlier input" {
    var f = Fighter{};
    f.request(.light);
    f.tick();
    f.request(.heavy);
    for (0..24) |_| f.tick();
    try std.testing.expectEqual(Action.idle, f.action);
    f.request(.light);
    f.tick();
    for (0..18) |_| f.tick();
    f.request(.dodge);
    for (0..6) |_| f.tick();
    try std.testing.expectEqual(Action.dodge, f.action);
    try std.testing.expectEqual(@as(u16, 0), f.age);
    try std.testing.expect(!f.equip(.spear));
}
test "heal commitment, interruption, exhaustion and delayed regen" {
    var f = Fighter{ .hp = 40, .stamina = 0 };
    f.request(.heavy);
    f.tick();
    try std.testing.expect(f.rejected);
    try std.testing.expectEqual(Action.idle, f.action);
    f.request(.heal);
    f.tick();
    try std.testing.expectEqual(@as(u8, 2), f.flasks);
    for (0..35) |_| f.tick();
    try std.testing.expectEqual(@as(u8, 40), f.hp);
    f.tick();
    try std.testing.expectEqual(@as(u8, 85), f.hp);
    try std.testing.expectEqual(@as(u8, 0), f.stamina);
    for (0..23) |_| f.tick();
    try std.testing.expectEqual(@as(u8, 0), f.stamina);
    f.tick(); // The completion tick is the first idle regeneration tick.
    try std.testing.expectEqual(@as(u8, 1), f.stamina);
    f.request(.heal);
    f.tick();
    try std.testing.expect(f.damage(10));
    for (0..60) |_| f.tick();
    try std.testing.expectEqual(@as(u8, 75), f.hp);
}
