const up = @import("unpolished-peas");
const Fixture = @import("surface-fixture").Fixture;
pub const width = 48;
pub const height = 32;
var active: ?*Game = null;
pub const Game = struct {
    fixture: ?*Fixture = null,
    selected_case: u32 = 0,
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        self.fixture = try Fixture.init(try ctx.requireAllocator(), @embedFile("assets/fonts/SourceSans3-Regular.otf"));
        active = self;
    }
    pub fn update(_: *Game, _: *up.core.GameContext, _: f32) !void {}
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const fixture = self.fixture.?;
        try fixture.draw(try ctx.requireCanvas(), self.selected_case);
        if (self.selected_case != 10) try (try ctx.requireRenderer2D()).composeSurfaces(&fixture.scene.?);
    }
    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.fixture) |value| value.deinit();
        self.fixture = null;
        active = null;
    }
};
pub export fn surface_probe_case(value: u32) i32 {
    if (value >= 12) return -1;
    const game = active orelse return -1;
    game.selected_case = value;
    return 0;
}
pub export fn surface_probe_metric(index: u32) u32 {
    const game = active orelse return 0;
    const fixture = game.fixture orelse return 0;
    return switch (index) {
        0 => fixture.case_index,
        1 => fixture.frames,
        2 => @intCast(fixture.scene.?.count),
        3 => fixture.second_layer.generation,
        else => 0,
    };
}
