// Internal native proof for the existing Renderer2D particle path. It is not
// an example, public API surface, or a general GPU benchmarking framework.
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const particle_count = 5_000;

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas advanced particle proof",
        .organization = "unpolished-peas",
        .application = "advanced-particle-proof",
        .width = 320,
        .height = 180,
        .scale = 3,
        .resizable = false,
        .fixed_hz = 60,
        .clear_color = up.core.Color.rgb(4, 8, 18),
    };

    particles: ?up.graphics.ParticleSystem = null,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        var particles = try up.graphics.ParticleSystem.init(allocator, .{
            .max_particles = particle_count,
            .seed = 0x4d45_5441_4c,
            .lifetime_min_seconds = 120,
            .lifetime_max_seconds = 120,
            .speed_min = 8,
            .speed_max = 48,
            .size_min = 1,
            .size_max = 3,
            .position = .{ .x = 160, .y = 90 },
            .direction = .{ .x = 1, .y = 0 },
            .spread_radians = 3.1415926,
            .start_color = up.core.Color.rgb(115, 220, 255),
            .end_color = up.core.Color.rgba(37, 69, 114, 0),
            .blend = .additive,
        });
        _ = try particles.emit(particle_count);
        self.particles = particles;
    }

    pub fn update(self: *Game, _: *up.core.GameContext, elapsed_seconds: f32) !void {
        try self.particles.?.update(elapsed_seconds);
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        try self.particles.?.submit(try ctx.requireRenderer2D());
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.particles) |*particles| particles.deinit();
        self.particles = null;
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
