const up = @import("unpolished-peas");

/// One compact, intentionally hand-authored level. These static rectangles
/// are game data, not a tilemap format or a generic collision subsystem.
pub const world_width: f32 = 384;
pub const world_height: f32 = 90;

pub const platforms = [_]up.core.Rect{
    .init(0, 82, 70, 8),
    .init(88, 82, 70, 8),
    .init(158, 82, 100, 8),
    .init(280, 82, 104, 8),
    .init(40, 66, 28, 6),
    .init(98, 61, 28, 6),
    .init(148, 70, 26, 6),
    .init(204, 58, 32, 6),
    .init(256, 68, 30, 6),
    .init(314, 57, 44, 6),
};

pub const hazards = [_]up.core.Rect{
    .init(258, 78, 22, 4),
};

pub const collectible_positions = [_]up.core.Vec2{
    .{ .x = 48, .y = 76 },
    .{ .x = 110, .y = 51 },
    .{ .x = 161, .y = 60 },
    .{ .x = 218, .y = 48 },
    .{ .x = 270, .y = 56 },
    .{ .x = 332, .y = 45 },
};

pub const checkpoint_bounds = [_]up.core.Rect{
    .init(190, 70, 10, 12),
};
pub const checkpoint_spawns = [_]up.core.Vec2{
    .{ .x = 14, .y = 74 },
    .{ .x = 204, .y = 50 },
};

pub const goal_bounds = up.core.Rect.init(346, 49, 10, 14);
