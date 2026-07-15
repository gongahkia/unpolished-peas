const up = @import("unpolished-peas").api;

pub const Canvas = struct {
    commands: *up.RenderCommandBuffer,
    camera: *const up.Camera2D,
    canvas_size: up.Vec2,

    pub fn init(commands: *up.RenderCommandBuffer, camera: *const up.Camera2D, canvas_size: up.Vec2) Canvas {
        return .{ .commands = commands, .camera = camera, .canvas_size = canvas_size };
    }

    pub fn line(self: Canvas, from: up.Vec2, to: up.Vec2, color: up.Color) void {
        const a = self.camera.worldToCanvas(from, self.canvas_size);
        const b = self.camera.worldToCanvas(to, self.canvas_size);
        self.withViewport(.{ .line = .{ .x0 = @intFromFloat(@round(a.x)), .y0 = @intFromFloat(@round(a.y)), .x1 = @intFromFloat(@round(b.x)), .y1 = @intFromFloat(@round(b.y)), .color = color } });
    }

    pub fn fillRect(self: Canvas, rect: up.Rect, color: up.Color) void {
        if (!self.camera.isVisibleRect(rect, self.canvas_size)) return;
        const a = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y }, self.canvas_size);
        const b = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y }, self.canvas_size);
        const c = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, self.canvas_size);
        const d = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y + rect.h }, self.canvas_size);
        self.pushViewport();
        self.append(.{ .triangle = .{ .a = a, .b = b, .c = c, .color = color } });
        self.append(.{ .triangle = .{ .a = a, .b = c, .c = d, .color = color } });
        self.append(.pop_clip);
    }

    pub fn fillCircle(self: Canvas, center: up.Vec2, radius: f32, color: up.Color) void {
        if (!self.camera.isVisibleRect(.init(center.x - radius, center.y - radius, radius * 2, radius * 2), self.canvas_size)) return;
        const screen = self.camera.worldToCanvas(center, self.canvas_size);
        self.withViewport(.{ .circle = .{ .x = @intFromFloat(@round(screen.x)), .y = @intFromFloat(@round(screen.y)), .radius = @max(@as(i32, 1), @as(i32, @intFromFloat(@round(radius * self.camera.zoom)))), .color = color } });
    }

    pub fn strokeRect(self: Canvas, rect: up.Rect, color: up.Color) void {
        self.line(.{ .x = rect.x, .y = rect.y }, .{ .x = rect.x + rect.w, .y = rect.y }, color);
        self.line(.{ .x = rect.x + rect.w, .y = rect.y }, .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, color);
        self.line(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .{ .x = rect.x, .y = rect.y + rect.h }, color);
        self.line(.{ .x = rect.x, .y = rect.y + rect.h }, .{ .x = rect.x, .y = rect.y }, color);
    }

    fn withViewport(self: Canvas, command: up.RenderCommand) void {
        self.pushViewport();
        self.append(command);
        self.append(.pop_clip);
    }

    fn pushViewport(self: Canvas) void {
        const viewport = self.camera.canvasViewport(self.canvas_size);
        self.append(.{ .push_clip = .{ .x = @intFromFloat(@floor(viewport.x)), .y = @intFromFloat(@floor(viewport.y)), .w = @max(@as(i32, 0), @as(i32, @intFromFloat(@ceil(viewport.w)))), .h = @max(@as(i32, 0), @as(i32, @intFromFloat(@ceil(viewport.h)))) } });
    }

    fn append(self: Canvas, command: up.RenderCommand) void {
        self.commands.append(command) catch @panic("render command allocation failed");
    }
};
