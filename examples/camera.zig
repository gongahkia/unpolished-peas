const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    rig: up.CameraRig,
    director: up.CameraDirector,
    main: up.CameraHandle,
    inset: up.CameraHandle,
    target: up.Vec2 = .{ .x = 48, .y = 32 },

    pub fn init(ctx: *sdl.Context) !Game {
        var rig = up.CameraRig.init(ctx.allocator);
        errdefer rig.deinit();
        const primary = try rig.create(.{
            .position = .{ .x = 48, .y = 32 },
            .zoom = 2,
            .bounds = .{ .rect = .init(-16, -16, 160, 112) },
            .follow = .{ .spring = 7, .dead_zone = .init(56, 36, 48, 18) },
        });
        const inset = try rig.create(.{
            .position = .{ .x = 48, .y = 32 },
            .zoom = 0.6,
            .viewport = .{ .x = 104, .y = 4, .w = 52, .h = 34 },
            .bounds = .{ .rect = .init(-16, -16, 160, 112) },
            .pixel_snap = .off,
        });
        return .{ .rig = rig, .director = .init(ctx.allocator), .main = primary, .inset = inset };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.director.deinit();
        self.rig.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        var velocity = up.Vec2{};
        if (ctx.down(.left)) velocity.x -= 42;
        if (ctx.down(.right)) velocity.x += 42;
        if (ctx.down(.up)) velocity.y -= 42;
        if (ctx.down(.down)) velocity.y += 42;
        self.target = self.target.add(velocity.scale(ctx.dt));
        if (ctx.input.pointer.canvas) |canvas_point| {
            self.target = self.rig.getConst(self.main).?.canvasToWorld(canvas_point, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
        }

        const primary = self.rig.get(self.main).?;
        primary.setFollowTarget(self.target);
        if (ctx.input.pointerWasPressed(.left)) primary.startShake(.{ .x = 3, .y = 2 }, 22, 0.22, ctx.frame);
        if (ctx.input.wasPressed(.action)) try self.director.play(.{
            .camera = self.main,
            .position = self.target,
            .zoom = 4,
            .rotation = 0,
            .duration = 0.25,
            .easing = .ease_in_out,
        });

        const inset = self.rig.get(self.inset).?;
        inset.position = self.target;
        self.director.update(&self.rig, ctx.dt);
        self.rig.update(ctx.dt, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        drawWorld(ctx.camera(self.rig.getConst(self.main).?), self.target);
        drawWorld(ctx.camera(self.rig.getConst(self.inset).?), self.target);
        ctx.canvas.strokeRect(103, 3, 54, 36, up.Color.rgb(222, 236, 255));
        ctx.text("CAMERA", 4, 4, up.Color.rgb(222, 236, 255));
        ctx.text("ARROWS/MOUSE", 4, 14, up.Color.rgb(158, 184, 210));
        ctx.text("SPACE: SHOT", 4, 24, up.Color.rgb(158, 184, 210));
    }
};

fn drawWorld(world: up.CameraCanvas, target: up.Vec2) void {
    var y: i32 = -16;
    while (y < 96) : (y += 8) world.line(.{ .x = -16, .y = @floatFromInt(y) }, .{ .x = 144, .y = @floatFromInt(y) }, up.Color.rgb(28, 39, 54));
    var x: i32 = -16;
    while (x < 144) : (x += 8) world.line(.{ .x = @floatFromInt(x), .y = -16 }, .{ .x = @floatFromInt(x), .y = 96 }, up.Color.rgb(28, 39, 54));
    world.fillRect(.init(8, 8, 24, 18), up.Color.rgb(62, 123, 157));
    world.fillRect(.init(80, 48, 32, 24), up.Color.rgb(183, 91, 73));
    world.fillCircle(target, 5, up.Color.rgb(255, 204, 92));
    world.strokeRect(.init(-16, -16, 160, 112), up.Color.rgb(116, 170, 126));
}

pub fn main() !void {
    try sdl.play(.{
        .title = "unpolished-peas camera",
        .width = 160,
        .height = 90,
        .scale = 6,
        .resizable = true,
        .presentation_mode = .integer_fit,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, Game);
}
