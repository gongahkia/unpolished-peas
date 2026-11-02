const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game_mod = @import("topdown_game.zig");

const Game = struct {
    pub const config: sdl.Config = .{ .title = "unpolished-peas Top Down", .width = game_mod.width, .height = game_mod.height, .scale = 5, .fixed_hz = 60, .clear_color = up.core.Color.rgb(10, 18, 26) };

    game: game_mod.Game = .{},
    camera: up.graphics.Camera2D = .{},
    player: up.assets.ImageHandle,
    blip: up.assets.AudioHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        const player = try ctx.loadImage("ball.png");
        const blip = try ctx.loadSound("blip.wav");
        return .{ .player = player, .blip = blip };
    }
    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const event = self.game.step(ctx.input.*, ctx.dt);
        if (event.fired) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.3 });
    }
    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        self.camera = .{ .position = self.game.player, .zoom = 1.25 };
        drawWorld(ctx.gpuCamera(&self.camera));
        const world = ctx.camera(&self.camera);
        world.line(self.game.player, self.game.player.add(self.game.aim.scale(12)), up.core.Color.rgb(255, 198, 74));
        world.drawImage(try ctx.assets.tryImage(self.player), self.game.player.sub(.{ .x = 8, .y = 8 }));
        ctx.text("TOPDOWN", 4, 4, up.core.Color.white);
        ctx.text("ARROWS SPACE", 84, 4, up.core.Color.rgb(180, 205, 230));
    }
};

fn drawWorld(world: sdl.GpuCameraCanvas) void {
    var x: i32 = 0;
    while (x <= game_mod.width) : (x += 16) world.line(.{ .x = @floatFromInt(x), .y = 0 }, .{ .x = @floatFromInt(x), .y = game_mod.height }, up.core.Color.rgb(23, 35, 47));
    var y: i32 = 0;
    while (y <= game_mod.height) : (y += 16) world.line(.{ .x = 0, .y = @floatFromInt(y) }, .{ .x = game_mod.width, .y = @floatFromInt(y) }, up.core.Color.rgb(23, 35, 47));
    world.strokeRect(.init(8, 18, 144, 70), up.core.Color.rgb(91, 166, 210));
    world.fillRect(.init(24, 31, 24, 12), up.core.Color.rgb(51, 96, 122));
    world.fillRect(.init(108, 56, 20, 16), up.core.Color.rgb(133, 66, 61));
    world.fillCircle(.{ .x = 32, .y = 42 }, 4, up.core.Color.rgb(255, 198, 74));
    world.fillCircle(.{ .x = 128, .y = 62 }, 4, up.core.Color.rgb(113, 232, 162));
}

pub fn main() !void {
    try sdl.playGame(Game);
}
