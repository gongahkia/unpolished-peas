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

pub const headless_width: u32 = 8;
pub const headless_height: u32 = 6;
pub const headless_frames = [_]up.testSupport.HeadlessFrame{
    .{ .buttons = up.testSupport.Buttons.right },
    .{ .buttons = up.testSupport.Buttons.right },
};
pub const headless_commands = [_]up.graphics.RenderCommand{
    .{ .rect = .{ .x = 6, .y = 5, .w = 1, .h = 1, .color = up.core.Color.rgb(255, 198, 74) } },
};
pub const expected_headless_image_hash: u64 = 6_420_562_283_987_650_127;

pub const HeadlessGame = struct {
    x: i32 = 0,

    pub fn init(_: *@This(), _: *up.core.GameContext) !void {}

    pub fn update(self: *@This(), context: *up.core.GameContext, _: f32) !void {
        if (context.input.isDown(.right)) self.x += 1;
    }

    pub fn draw(self: *@This(), context: *up.core.GameContext) !void {
        const canvas = try context.requireCanvas();
        canvas.clear(up.core.Color.black);
        canvas.fillRect(self.x, 2, 1, 1, up.core.Color.white);
    }
};
