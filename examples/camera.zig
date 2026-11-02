const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas camera",
        .width = 160,
        .height = 90,
        .scale = 6,
        .resizable = true,
        .presentation_mode = .integer_fit,
        .clear_color = up.core.Color.rgb(14, 18, 24),
    };

    camera: up.graphics.Camera2D = .{ .position = .{ .x = 48, .y = 32 }, .zoom = 2 },
    target: up.core.Vec2 = .{ .x = 48, .y = 32 },

    pub fn init(_: *sdl.Context) !Game {
        return .{};
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        var velocity = up.core.Vec2{};
        if (ctx.down(.left)) velocity.x -= 42;
        if (ctx.down(.right)) velocity.x += 42;
        if (ctx.down(.up)) velocity.y -= 42;
        if (ctx.down(.down)) velocity.y += 42;
        self.target = self.target.add(velocity.scale(ctx.dt));
        if (ctx.input.pointer.canvas) |point| self.target = self.camera.canvasToWorld(point, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
        self.camera.position = self.target;
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        drawWorld(ctx.gpuCamera(&self.camera), self.target);
        ctx.text("CAMERA", 4, 4, up.core.Color.rgb(222, 236, 255));
        ctx.text("ARROWS/MOUSE", 4, 14, up.core.Color.rgb(158, 184, 210));
    }
};

fn drawWorld(world: sdl.GpuCameraCanvas, target: up.core.Vec2) void {
    var y: i32 = -16;
    while (y < 96) : (y += 8) world.line(.{ .x = -16, .y = @floatFromInt(y) }, .{ .x = 144, .y = @floatFromInt(y) }, up.core.Color.rgb(28, 39, 54));
    var x: i32 = -16;
    while (x < 144) : (x += 8) world.line(.{ .x = @floatFromInt(x), .y = -16 }, .{ .x = @floatFromInt(x), .y = 96 }, up.core.Color.rgb(28, 39, 54));
    world.fillRect(.init(8, 8, 24, 18), up.core.Color.rgb(62, 123, 157));
    world.fillRect(.init(80, 48, 32, 24), up.core.Color.rgb(183, 91, 73));
    world.fillCircle(target, 5, up.core.Color.rgb(255, 204, 92));
    world.strokeRect(.init(-16, -16, 160, 112), up.core.Color.rgb(116, 170, 126));
}

pub fn main() !void {
    try sdl.playGame(Game);
}
