const up = @import("unpolished-peas");

pub const PausePolicy = enum { never, unfocused, minimized };

pub const Config = struct {
    title: [:0]const u8 = "starter",
    organization: [:0]const u8 = "starter",
    application: [:0]const u8 = "starter",
    width: u32 = 320,
    height: u32 = 180,
    scale: u32 = 3,
    pause_policy: PausePolicy = .never,
    clear_color: up.core.Color = up.core.Color.black,
};

pub fn playGame(comptime Game: type) !void {
    _ = up.core.GameProtocol(Game);
}
