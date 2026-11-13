//! Untimed state comparison, excluding resource handles and pointer addresses.
const up = @import("unpolished-peas");
const game = @import("game.zig");
pub fn digest(g: *const game.Game) u64 {
    var hash = up.testSupport.StateHash{};
    inline for (@typeInfo(@TypeOf(g.state)).@"struct".fields) |field| {
        if (comptime @import("std").mem.eql(u8, field.name, "message")) hash.updateBytes(g.state.message) else hash.updatePortable(@field(g.state, field.name));
    }
    hash.updatePortable(.{ g.settings, g.screen, g.camera, g.mouse_aim, g.action_notice, g.tutorial_stage, g.movement_teach, g.stride, g.walking, @as(u64, g.selected), g.return_screen, g.journey_started, g.save_failed, g.load_problem });
    return hash.finish();
}
