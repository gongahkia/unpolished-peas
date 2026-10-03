const sdl = @import("unpolished-peas-sdl3");

/// The desktop entry point deliberately stays tiny. All game state and the
/// fixed-step `GameProtocol` callbacks live in `game.zig`.
pub const Game = @import("game.zig").Game;

pub fn main() !void {
    try sdl.playGame(Game);
}

test {
    _ = @import("game.zig");
}
