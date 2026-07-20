const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game_mod = @import("puzzle_game.zig");

const board_x = 45;
const board_y = 24;
const cell_size = 20;
const cell_gap = 4;

const Game = struct {
    pub const config: sdl.Config = .{ .title = "unpolished-peas Puzzle", .width = game_mod.width, .height = game_mod.height, .scale = 5, .fixed_hz = 60, .clear_color = up.core.Color.rgb(13, 18, 30) };

    game: game_mod.Game = .{},
    marker: up.assets.ImageHandle,
    blip: up.assets.AudioHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        return .{ .marker = try ctx.loadImage("ball.png"), .blip = try ctx.loadSound("blip.wav") };
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const event = self.game.step(ctx.input.*);
        if (event.toggled) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.3 });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        drawBoard(ctx.canvas, self.game);
        const marker = cellPosition(self.game.selected);
        try ctx.image(self.marker, marker.x + 2, marker.y + 2);
        ctx.text("LIGHTS OUT", 4, 4, up.core.Color.white);
        ctx.text("ARROWS SPACE", 82, 4, up.core.Color.rgb(180, 205, 230));
        ctx.text(if (self.game.solved()) "SOLVED" else "TOGGLE THE CROSS", 4, 86, if (self.game.solved()) up.core.Color.rgb(113, 232, 162) else up.core.Color.rgb(255, 198, 74));
    }
};

fn drawBoard(canvas: *up.graphics.Canvas, game: game_mod.Game) void {
    for (game.cells, 0..) |lit, index| {
        const position = cellPosition(index);
        canvas.fillRect(position.x, position.y, cell_size, cell_size, if (lit) up.core.Color.rgb(113, 232, 162) else up.core.Color.rgb(31, 47, 68));
        canvas.strokeRect(position.x, position.y, cell_size, cell_size, if (index == game.selected) up.core.Color.rgb(255, 198, 74) else up.core.Color.rgb(91, 124, 158));
    }
}

fn cellPosition(index: usize) struct { x: i32, y: i32 } {
    return .{
        .x = board_x + @as(i32, @intCast(index % game_mod.columns)) * (cell_size + cell_gap),
        .y = board_y + @as(i32, @intCast(index / game_mod.columns)) * (cell_size + cell_gap),
    };
}

pub fn main() !void {
    try sdl.playGame(Game);
}
