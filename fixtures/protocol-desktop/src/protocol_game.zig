const up = @import("unpolished-peas");

pub const Game = struct {
    position: up.core.Vec2 = .{ .x = 24, .y = 18 },
    draw_calls: u32 = 0,

    pub fn init(_: *@This(), _: *up.core.GameContext) !void {}

    pub fn update(self: *@This(), ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        const speed: f32 = 40;
        if (ctx.input.isDown(.left)) self.position.x -= speed * elapsed_seconds;
        if (ctx.input.isDown(.right)) self.position.x += speed * elapsed_seconds;
    }

    pub fn draw(self: *@This(), _: *up.core.GameContext) !void {
        self.draw_calls += 1;
    }
};
