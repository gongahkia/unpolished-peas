const std = @import("std");
const builtin = @import("builtin");
const up = @import("api.zig");
const camera_commands = @import("camera_commands.zig");
const primitive_commands = @import("primitive_commands.zig");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const GlViewport = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
};

const BuiltinShaderSource = enum {
    sprite_vertex,
    sprite_fragment,
    primitive_vertex,
    primitive_fragment,
    sprite_program,
    primitive_program,
};

const Gl = struct {
    const GetIntegerv = *const fn (u32, *i32) callconv(.c) void;
    const Viewport = *const fn (i32, i32, i32, i32) callconv(.c) void;
    const ClearColor = *const fn (f32, f32, f32, f32) callconv(.c) void;
    const Clear = *const fn (u32) callconv(.c) void;
    const Enable = *const fn (u32) callconv(.c) void;
    const Disable = *const fn (u32) callconv(.c) void;
    const BlendFuncSeparate = *const fn (u32, u32, u32, u32) callconv(.c) void;
    const Scissor = *const fn (i32, i32, i32, i32) callconv(.c) void;
    const CreateShader = *const fn (u32) callconv(.c) u32;
    const ShaderSource = *const fn (u32, i32, [*]const [*]const u8, ?*const i32) callconv(.c) void;
    const CompileShader = *const fn (u32) callconv(.c) void;
    const GetShaderiv = *const fn (u32, u32, *i32) callconv(.c) void;
    const GetShaderInfoLog = *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void;
    const DeleteShader = *const fn (u32) callconv(.c) void;
    const CreateProgram = *const fn () callconv(.c) u32;
    const AttachShader = *const fn (u32, u32) callconv(.c) void;
    const LinkProgram = *const fn (u32) callconv(.c) void;
    const GetProgramiv = *const fn (u32, u32, *i32) callconv(.c) void;
    const GetProgramInfoLog = *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void;
    const DeleteProgram = *const fn (u32) callconv(.c) void;
    const UseProgram = *const fn (u32) callconv(.c) void;
    const GetUniformLocation = *const fn (u32, [*:0]const u8) callconv(.c) i32;
    const Uniform1i = *const fn (i32, i32) callconv(.c) void;
    const GenVertexArrays = *const fn (i32, *u32) callconv(.c) void;
    const BindVertexArray = *const fn (u32) callconv(.c) void;
    const DeleteVertexArrays = *const fn (i32, *const u32) callconv(.c) void;
    const GenBuffers = *const fn (i32, *u32) callconv(.c) void;
    const BindBuffer = *const fn (u32, u32) callconv(.c) void;
    const BufferData = *const fn (u32, isize, ?*const anyopaque, u32) callconv(.c) void;
    const DeleteBuffers = *const fn (i32, *const u32) callconv(.c) void;
    const EnableVertexAttribArray = *const fn (u32) callconv(.c) void;
    const VertexAttribPointer = *const fn (u32, i32, u32, u8, i32, ?*const anyopaque) callconv(.c) void;
    const GenTextures = *const fn (i32, *u32) callconv(.c) void;
    const BindTexture = *const fn (u32, u32) callconv(.c) void;
    const TexParameteri = *const fn (u32, u32, i32) callconv(.c) void;
    const PixelStorei = *const fn (u32, i32) callconv(.c) void;
    const TexImage2D = *const fn (u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void;
    const DeleteTextures = *const fn (i32, *const u32) callconv(.c) void;
    const ActiveTexture = *const fn (u32) callconv(.c) void;
    const DrawArrays = *const fn (u32, i32, i32) callconv(.c) void;
    const ReadPixels = *const fn (i32, i32, i32, i32, u32, u32, ?*anyopaque) callconv(.c) void;

    get_integerv: GetIntegerv,
    viewport: Viewport,
    clear_color: ClearColor,
    clear: Clear,
    enable: Enable,
    disable: Disable,
    blend_func_separate: BlendFuncSeparate,
    scissor: Scissor,
    create_shader: CreateShader,
    shader_source: ShaderSource,
    compile_shader: CompileShader,
    get_shader_iv: GetShaderiv,
    get_shader_info_log: GetShaderInfoLog,
    delete_shader: DeleteShader,
    create_program: CreateProgram,
    attach_shader: AttachShader,
    link_program: LinkProgram,
    get_program_iv: GetProgramiv,
    get_program_info_log: GetProgramInfoLog,
    delete_program: DeleteProgram,
    use_program: UseProgram,
    get_uniform_location: GetUniformLocation,
    uniform_1i: Uniform1i,
    gen_vertex_arrays: GenVertexArrays,
    bind_vertex_array: BindVertexArray,
    delete_vertex_arrays: DeleteVertexArrays,
    gen_buffers: GenBuffers,
    bind_buffer: BindBuffer,
    buffer_data: BufferData,
    delete_buffers: DeleteBuffers,
    enable_vertex_attrib_array: EnableVertexAttribArray,
    vertex_attrib_pointer: VertexAttribPointer,
    gen_textures: GenTextures,
    bind_texture: BindTexture,
    tex_parameter_i: TexParameteri,
    pixel_store_i: PixelStorei,
    tex_image_2d: TexImage2D,
    delete_textures: DeleteTextures,
    active_texture: ActiveTexture,
    draw_arrays: DrawArrays,
    read_pixels: ReadPixels,

    fn load() !Gl {
        return .{
            .get_integerv = try loadProc(GetIntegerv, "glGetIntegerv"),
            .viewport = try loadProc(Viewport, "glViewport"),
            .clear_color = try loadProc(ClearColor, "glClearColor"),
            .clear = try loadProc(Clear, "glClear"),
            .enable = try loadProc(Enable, "glEnable"),
            .disable = try loadProc(Disable, "glDisable"),
            .blend_func_separate = try loadProc(BlendFuncSeparate, "glBlendFuncSeparate"),
            .scissor = try loadProc(Scissor, "glScissor"),
            .create_shader = try loadProc(CreateShader, "glCreateShader"),
            .shader_source = try loadProc(ShaderSource, "glShaderSource"),
            .compile_shader = try loadProc(CompileShader, "glCompileShader"),
            .get_shader_iv = try loadProc(GetShaderiv, "glGetShaderiv"),
            .get_shader_info_log = try loadProc(GetShaderInfoLog, "glGetShaderInfoLog"),
            .delete_shader = try loadProc(DeleteShader, "glDeleteShader"),
            .create_program = try loadProc(CreateProgram, "glCreateProgram"),
            .attach_shader = try loadProc(AttachShader, "glAttachShader"),
            .link_program = try loadProc(LinkProgram, "glLinkProgram"),
            .get_program_iv = try loadProc(GetProgramiv, "glGetProgramiv"),
            .get_program_info_log = try loadProc(GetProgramInfoLog, "glGetProgramInfoLog"),
            .delete_program = try loadProc(DeleteProgram, "glDeleteProgram"),
            .use_program = try loadProc(UseProgram, "glUseProgram"),
            .get_uniform_location = try loadProc(GetUniformLocation, "glGetUniformLocation"),
            .uniform_1i = try loadProc(Uniform1i, "glUniform1i"),
            .gen_vertex_arrays = try loadProc(GenVertexArrays, "glGenVertexArrays"),
            .bind_vertex_array = try loadProc(BindVertexArray, "glBindVertexArray"),
            .delete_vertex_arrays = try loadProc(DeleteVertexArrays, "glDeleteVertexArrays"),
            .gen_buffers = try loadProc(GenBuffers, "glGenBuffers"),
            .bind_buffer = try loadProc(BindBuffer, "glBindBuffer"),
            .buffer_data = try loadProc(BufferData, "glBufferData"),
            .delete_buffers = try loadProc(DeleteBuffers, "glDeleteBuffers"),
            .enable_vertex_attrib_array = try loadProc(EnableVertexAttribArray, "glEnableVertexAttribArray"),
            .vertex_attrib_pointer = try loadProc(VertexAttribPointer, "glVertexAttribPointer"),
            .gen_textures = try loadProc(GenTextures, "glGenTextures"),
            .bind_texture = try loadProc(BindTexture, "glBindTexture"),
            .tex_parameter_i = try loadProc(TexParameteri, "glTexParameteri"),
            .pixel_store_i = try loadProc(PixelStorei, "glPixelStorei"),
            .tex_image_2d = try loadProc(TexImage2D, "glTexImage2D"),
            .delete_textures = try loadProc(DeleteTextures, "glDeleteTextures"),
            .active_texture = try loadProc(ActiveTexture, "glActiveTexture"),
            .draw_arrays = try loadProc(DrawArrays, "glDrawArrays"),
            .read_pixels = try loadProc(ReadPixels, "glReadPixels"),
        };
    }
};

pub fn configureContext() !void {
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3)) return error.OpenGlContextConfigurationFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3)) return error.OpenGlContextConfigurationFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE)) return error.OpenGlContextConfigurationFailed;
}

pub const Presenter = struct {
    window: *anyopaque,
    context: c.SDL_GLContext,
    context_active: bool = true,
    gl: Gl,
    width: u32,
    height: u32,
    sprite_program: u32 = 0,
    primitive_program: u32 = 0,
    sprite_vao: u32 = 0,
    sprite_vbo: u32 = 0,
    primitive_vao: u32 = 0,
    primitive_vbo: u32 = 0,
    canvas_texture: u32 = 0,
    primitive_batch: up.PrimitiveBatch,
    command_sprites: up.SpriteBatch,
    command_operations: std.ArrayList(primitive_commands.Operation) = .empty,
    recovery_failure: ?anyerror = null,
    viewport: GlViewport,

    pub fn init(window: *anyopaque, width: u32, height: u32) !Presenter {
        if (width == 0 or height == 0) return error.InvalidRenderCanvas;
        const context = c.SDL_GL_CreateContext(@ptrCast(window)) orelse return error.OpenGlContextCreationFailed;
        errdefer _ = c.SDL_GL_DestroyContext(context);
        if (!c.SDL_GL_MakeCurrent(@ptrCast(window), context)) return error.OpenGlContextActivationFailed;
        const gl = try Gl.load();
        var presenter = Presenter{
            .window = window,
            .context = context,
            .gl = gl,
            .width = width,
            .height = height,
            .primitive_batch = up.PrimitiveBatch.init(std.heap.page_allocator),
            .command_sprites = up.SpriteBatch.init(std.heap.page_allocator),
            .viewport = .{ .width = width, .height = height },
        };
        errdefer presenter.deinit();
        try presenter.createGpuResources();
        return presenter;
    }

    pub fn deinit(self: *Presenter) void {
        if (self.context_active) {
            _ = c.SDL_GL_MakeCurrent(@ptrCast(self.window), self.context);
            self.releaseGpuResources();
            _ = c.SDL_GL_DestroyContext(self.context);
        }
        self.primitive_batch.deinit();
        self.command_sprites.deinit();
        self.command_operations.deinit(std.heap.page_allocator);
        self.* = undefined;
    }

    pub fn recover(self: *Presenter) !void {
        if (self.context_active) {
            _ = c.SDL_GL_MakeCurrent(@ptrCast(self.window), self.context);
            self.releaseGpuResources();
            if (!c.SDL_GL_DestroyContext(self.context)) {
                self.context_active = false;
                return self.recordRecoveryFailure(error.OpenGlContextDestructionFailed);
            }
            self.context_active = false;
        }
        const context = c.SDL_GL_CreateContext(@ptrCast(self.window)) orelse return self.recordRecoveryFailure(error.OpenGlContextCreationFailed);
        self.context = context;
        self.context_active = true;
        if (!c.SDL_GL_MakeCurrent(@ptrCast(self.window), context)) {
            _ = c.SDL_GL_DestroyContext(context);
            self.context_active = false;
            return self.recordRecoveryFailure(error.OpenGlContextActivationFailed);
        }
        self.gl = Gl.load() catch |err| {
            _ = c.SDL_GL_DestroyContext(context);
            self.context_active = false;
            return self.recordRecoveryFailure(err);
        };
        self.createGpuResources() catch |err| {
            self.releaseGpuResources();
            _ = c.SDL_GL_DestroyContext(context);
            self.context_active = false;
            return self.recordRecoveryFailure(err);
        };
        self.recovery_failure = null;
    }

    pub fn recoveryFailure(self: *const Presenter) ?anyerror {
        return self.recovery_failure;
    }

    pub fn render(self: *Presenter, canvas: up.Canvas, sprites: *up.SpriteBatch, commands: []const up.RenderCommand) !void {
        try self.renderToViewport(canvas, sprites, commands, .{ .width = self.width, .height = self.height });
    }

    pub fn present(self: *Presenter, canvas: up.Canvas, sprites: *up.SpriteBatch, commands: []const up.RenderCommand) !void {
        try self.render(canvas, sprites, commands);
        if (!c.SDL_GL_SwapWindow(@ptrCast(self.window))) return error.OpenGlSwapFailed;
    }

    pub fn presentWithPresentation(self: *Presenter, canvas: up.Canvas, sprites: *up.SpriteBatch, commands: []const up.RenderCommand, presentation: up.Presentation) !void {
        try self.renderToViewport(canvas, sprites, commands, try viewportForPresentation(presentation));
        if (!c.SDL_GL_SwapWindow(@ptrCast(self.window))) return error.OpenGlSwapFailed;
    }

    fn renderToViewport(self: *Presenter, canvas: up.Canvas, sprites: *up.SpriteBatch, commands: []const up.RenderCommand, viewport: GlViewport) !void {
        if (!self.context_active) return error.OpenGlRecoveryRequired;
        if (canvas.width != self.width or canvas.height != self.height) return error.InvalidRenderCanvas;
        if (!c.SDL_GL_MakeCurrent(@ptrCast(self.window), self.context)) return error.OpenGlContextActivationFailed;
        self.viewport = viewport;
        self.gl.viewport(try glI32(viewport.x), try glI32(viewport.y), try glI32(viewport.width), try glI32(viewport.height));
        self.gl.clear_color(0, 0, 0, 1);
        self.gl.clear(gl_color_buffer_bit);
        self.gl.enable(gl_blend);
        self.setBlend(.alpha);
        try self.renderCanvas(canvas);
        self.primitive_batch.clear();
        self.command_sprites.clear();
        self.command_operations.clearRetainingCapacity();
        try primitive_commands.appendOrdered(&self.primitive_batch, &self.command_sprites, &self.command_operations, self.width, self.height, commands);
        try self.renderCommandOperations();
        try self.renderSprites(sprites);
    }

    pub fn capture(self: *Presenter, allocator: std.mem.Allocator) !up.Canvas {
        if (!self.context_active) return error.OpenGlRecoveryRequired;
        if (!c.SDL_GL_MakeCurrent(@ptrCast(self.window), self.context)) return error.OpenGlContextActivationFailed;
        var canvas = try up.Canvas.init(allocator, self.width, self.height);
        errdefer canvas.deinit();
        const byte_len = try byteLen(self.viewport.width, self.viewport.height);
        const pixels = try allocator.alloc(u8, byte_len);
        defer allocator.free(pixels);
        self.gl.read_pixels(try glI32(self.viewport.x), try glI32(self.viewport.y), try glI32(self.viewport.width), try glI32(self.viewport.height), gl_rgba, gl_unsigned_byte, @ptrCast(pixels.ptr));
        for (0..self.height) |y| for (0..self.width) |x| {
            const source_x = x * self.viewport.width / self.width;
            const source_y = (self.height - 1 - y) * self.viewport.height / self.height;
            const source = (@as(usize, source_y) * self.viewport.width + source_x) * 4;
            const destination = @as(usize, y) * self.width + x;
            canvas.pixels[destination] = up.Color.rgba(pixels[source], pixels[source + 1], pixels[source + 2], pixels[source + 3]);
        };
        return canvas;
    }

    fn requireVersion(self: *const Presenter) !void {
        var major: i32 = 0;
        var minor: i32 = 0;
        self.gl.get_integerv(gl_major_version, &major);
        self.gl.get_integerv(gl_minor_version, &minor);
        if (!versionAtLeast(major, minor, 3, 3)) return error.UnsupportedOpenGl33;
    }

    fn createGpuResources(self: *Presenter) !void {
        try self.requireVersion();
        self.sprite_program = try self.makeProgram(.sprite_program, .sprite_vertex, sprite_vertex_source, .sprite_fragment, sprite_fragment_source);
        errdefer self.releaseGpuResources();
        self.primitive_program = try self.makeProgram(.primitive_program, .primitive_vertex, primitive_vertex_source, .primitive_fragment, primitive_fragment_source);
        self.configureSpriteProgram();
        try self.makeBuffers();
        self.gl.gen_textures(1, &self.canvas_texture);
        if (self.canvas_texture == 0) return error.OpenGlTextureCreationFailed;
    }

    fn releaseGpuResources(self: *Presenter) void {
        if (self.canvas_texture != 0) self.gl.delete_textures(1, &self.canvas_texture);
        if (self.sprite_vbo != 0) self.gl.delete_buffers(1, &self.sprite_vbo);
        if (self.primitive_vbo != 0) self.gl.delete_buffers(1, &self.primitive_vbo);
        if (self.sprite_vao != 0) self.gl.delete_vertex_arrays(1, &self.sprite_vao);
        if (self.primitive_vao != 0) self.gl.delete_vertex_arrays(1, &self.primitive_vao);
        if (self.sprite_program != 0) self.gl.delete_program(self.sprite_program);
        if (self.primitive_program != 0) self.gl.delete_program(self.primitive_program);
        self.canvas_texture = 0;
        self.sprite_vbo = 0;
        self.primitive_vbo = 0;
        self.sprite_vao = 0;
        self.primitive_vao = 0;
        self.sprite_program = 0;
        self.primitive_program = 0;
    }

    fn recordRecoveryFailure(self: *Presenter, err: anyerror) anyerror {
        self.recovery_failure = err;
        return err;
    }

    fn makeBuffers(self: *Presenter) !void {
        self.gl.gen_vertex_arrays(1, &self.sprite_vao);
        self.gl.gen_buffers(1, &self.sprite_vbo);
        self.gl.gen_vertex_arrays(1, &self.primitive_vao);
        self.gl.gen_buffers(1, &self.primitive_vbo);
        if (self.sprite_vao == 0 or self.sprite_vbo == 0 or self.primitive_vao == 0 or self.primitive_vbo == 0) return error.OpenGlBufferCreationFailed;
        self.gl.bind_vertex_array(self.sprite_vao);
        self.gl.bind_buffer(gl_array_buffer, self.sprite_vbo);
        self.gl.enable_vertex_attrib_array(0);
        self.gl.vertex_attrib_pointer(0, 2, gl_float, 0, @sizeOf(up.SpriteBatchVertex), @ptrFromInt(@offsetOf(up.SpriteBatchVertex, "x")));
        self.gl.enable_vertex_attrib_array(1);
        self.gl.vertex_attrib_pointer(1, 2, gl_float, 0, @sizeOf(up.SpriteBatchVertex), @ptrFromInt(@offsetOf(up.SpriteBatchVertex, "u")));
        self.gl.enable_vertex_attrib_array(2);
        self.gl.vertex_attrib_pointer(2, 4, gl_float, 0, @sizeOf(up.SpriteBatchVertex), @ptrFromInt(@offsetOf(up.SpriteBatchVertex, "r")));
        self.gl.bind_vertex_array(self.primitive_vao);
        self.gl.bind_buffer(gl_array_buffer, self.primitive_vbo);
        self.gl.enable_vertex_attrib_array(0);
        self.gl.vertex_attrib_pointer(0, 2, gl_float, 0, @sizeOf(up.PrimitiveBatchVertex), @ptrFromInt(@offsetOf(up.PrimitiveBatchVertex, "x")));
        self.gl.enable_vertex_attrib_array(1);
        self.gl.vertex_attrib_pointer(1, 4, gl_float, 0, @sizeOf(up.PrimitiveBatchVertex), @ptrFromInt(@offsetOf(up.PrimitiveBatchVertex, "r")));
    }

    fn configureSpriteProgram(self: *Presenter) void {
        self.gl.use_program(self.sprite_program);
        const location = self.gl.get_uniform_location(self.sprite_program, "sprite_texture");
        if (location >= 0) self.gl.uniform_1i(location, 0);
    }

    fn renderCanvas(self: *Presenter, canvas: up.Canvas) !void {
        const vertices = [_]up.SpriteBatchVertex{
            .{ .x = -1, .y = 1, .u = 0, .v = 0, .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .x = 1, .y = 1, .u = 1, .v = 0, .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .x = 1, .y = -1, .u = 1, .v = 1, .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .x = -1, .y = 1, .u = 0, .v = 0, .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .x = 1, .y = -1, .u = 1, .v = 1, .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .x = -1, .y = -1, .u = 0, .v = 1, .r = 1, .g = 1, .b = 1, .a = 1 },
        };
        try self.uploadTexture(self.canvas_texture, canvas.width, canvas.height, std.mem.sliceAsBytes(canvas.pixels), gl_nearest);
        try self.uploadSpriteVertices(&vertices);
        self.gl.use_program(self.sprite_program);
        self.gl.active_texture(gl_texture0);
        self.gl.bind_texture(gl_texture_2d, self.canvas_texture);
        self.gl.bind_vertex_array(self.sprite_vao);
        self.gl.draw_arrays(gl_triangles, 0, vertices.len);
    }

    fn renderCommandOperations(self: *Presenter) !void {
        if (self.primitive_batch.vertices.items.len != 0) try self.uploadBuffer(self.primitive_vbo, std.mem.sliceAsBytes(self.primitive_batch.vertices.items));
        if (self.command_sprites.vertices.items.len != 0) try self.uploadSpriteVertices(self.command_sprites.vertices.items);
        for (self.command_operations.items) |operation| switch (operation) {
            .clear => |color| self.clearCommandTarget(color),
            .primitive => |index| try self.renderPrimitiveDraw(self.primitive_batch.draws.items[index]),
            .sprite => |index| try self.renderSpriteDraw(self.command_sprites.draws.items[index]),
        };
        self.gl.disable(gl_scissor_test);
        self.setBlend(.alpha);
    }

    fn clearCommandTarget(self: *Presenter, color: up.Color) void {
        self.gl.disable(gl_scissor_test);
        self.gl.clear_color(@as(f32, @floatFromInt(color.r)) / 255, @as(f32, @floatFromInt(color.g)) / 255, @as(f32, @floatFromInt(color.b)) / 255, @as(f32, @floatFromInt(color.a)) / 255);
        self.gl.clear(gl_color_buffer_bit);
    }

    fn renderPrimitiveDraw(self: *Presenter, draw: up.PrimitiveBatchDraw) !void {
        self.gl.use_program(self.primitive_program);
        self.gl.bind_vertex_array(self.primitive_vao);
        self.setBlend(draw.blend);
        self.applyClip(draw.clip);
        self.gl.draw_arrays(gl_triangles, try glI32(draw.vertex_start), try glI32(draw.vertex_count));
    }

    fn renderSprites(self: *Presenter, sprites: *up.SpriteBatch) !void {
        if (sprites.draws.items.len == 0) return;
        try sprites.sortByTexture();
        try self.uploadSpriteVertices(sprites.vertices.items);
        self.gl.use_program(self.sprite_program);
        self.gl.bind_vertex_array(self.sprite_vao);
        self.gl.active_texture(gl_texture0);
        for (sprites.sorted.items) |draw_index| try self.renderSpriteDraw(sprites.draws.items[draw_index]);
        self.gl.disable(gl_scissor_test);
        self.setBlend(.alpha);
    }

    fn renderSpriteDraw(self: *Presenter, draw: up.SpriteBatchDraw) !void {
        var texture: u32 = 0;
        self.gl.gen_textures(1, &texture);
        if (texture == 0) return error.OpenGlTextureCreationFailed;
        defer self.gl.delete_textures(1, &texture);
        const filter = switch (draw.sampling) {
            .nearest => gl_nearest,
            .linear => gl_linear,
        };
        try self.uploadTexture(texture, draw.image.width, draw.image.height, std.mem.sliceAsBytes(draw.image.pixels), filter);
        self.gl.use_program(self.sprite_program);
        self.gl.bind_vertex_array(self.sprite_vao);
        self.gl.active_texture(gl_texture0);
        self.gl.bind_texture(gl_texture_2d, texture);
        self.setBlend(draw.blend);
        self.applyClip(draw.clip);
        self.gl.draw_arrays(gl_triangles, try glI32(draw.vertex_start), 6);
    }

    fn uploadSpriteVertices(self: *Presenter, vertices: []const up.SpriteBatchVertex) !void {
        try self.uploadBuffer(self.sprite_vbo, std.mem.sliceAsBytes(vertices));
    }

    fn setBlend(self: *Presenter, blend: up.BlendMode) void {
        self.gl.blend_func_separate(gl_src_alpha, switch (blend) {
            .alpha => gl_one_minus_src_alpha,
            .additive => gl_one,
        }, gl_one, gl_one_minus_src_alpha);
    }

    fn applyClip(self: *Presenter, clip: ?up.ClipRect) void {
        const value = clip orelse {
            self.gl.disable(gl_scissor_test);
            return;
        };
        const max_x: i64 = @intCast(self.width);
        const max_y: i64 = @intCast(self.height);
        const right = @as(i64, value.x) + @max(@as(i64, 0), @as(i64, value.w));
        const bottom = @as(i64, value.y) + @max(@as(i64, 0), @as(i64, value.h));
        const x0 = @max(@as(i64, 0), @min(max_x, @as(i64, value.x)));
        const y0 = @max(@as(i64, 0), @min(max_y, @as(i64, value.y)));
        const x1 = @max(x0, @min(max_x, right));
        const y1 = @max(y0, @min(max_y, bottom));
        self.gl.enable(gl_scissor_test);
        const viewport_width: i64 = @intCast(self.viewport.width);
        const viewport_height: i64 = @intCast(self.viewport.height);
        self.gl.scissor(
            @intCast(@as(i64, self.viewport.x) + @divTrunc(x0 * viewport_width, max_x)),
            @intCast(@as(i64, self.viewport.y) + @divTrunc((max_y - y1) * viewport_height, max_y)),
            @intCast(@divTrunc((x1 - x0) * viewport_width, max_x)),
            @intCast(@divTrunc((y1 - y0) * viewport_height, max_y)),
        );
    }

    fn uploadBuffer(self: *Presenter, buffer: u32, bytes: []const u8) !void {
        self.gl.bind_buffer(gl_array_buffer, buffer);
        self.gl.buffer_data(gl_array_buffer, try glSize(bytes.len), if (bytes.len == 0) null else @ptrCast(bytes.ptr), gl_dynamic_draw);
    }

    fn uploadTexture(self: *Presenter, texture: u32, width: u32, height: u32, bytes: []const u8, filter: u32) !void {
        if (bytes.len != try byteLen(width, height)) return error.InvalidTexturePixels;
        self.gl.bind_texture(gl_texture_2d, texture);
        self.gl.tex_parameter_i(gl_texture_2d, gl_texture_min_filter, @intCast(filter));
        self.gl.tex_parameter_i(gl_texture_2d, gl_texture_mag_filter, @intCast(filter));
        self.gl.tex_parameter_i(gl_texture_2d, gl_texture_wrap_s, @intCast(gl_clamp_to_edge));
        self.gl.tex_parameter_i(gl_texture_2d, gl_texture_wrap_t, @intCast(gl_clamp_to_edge));
        self.gl.pixel_store_i(gl_unpack_alignment, 1);
        self.gl.tex_image_2d(gl_texture_2d, 0, @intCast(gl_rgba), try glI32(width), try glI32(height), 0, gl_rgba, gl_unsigned_byte, @ptrCast(bytes.ptr));
    }

    fn makeProgram(self: *Presenter, program_source: BuiltinShaderSource, vertex_source_name: BuiltinShaderSource, vertex_source: []const u8, fragment_source_name: BuiltinShaderSource, fragment_source: []const u8) !u32 {
        const vertex = try self.compileShader(vertex_source_name, gl_vertex_shader, vertex_source);
        defer self.gl.delete_shader(vertex);
        const fragment = try self.compileShader(fragment_source_name, gl_fragment_shader, fragment_source);
        defer self.gl.delete_shader(fragment);
        const program = self.gl.create_program();
        if (program == 0) return error.OpenGlProgramCreationFailed;
        errdefer self.gl.delete_program(program);
        self.gl.attach_shader(program, vertex);
        self.gl.attach_shader(program, fragment);
        self.gl.link_program(program);
        var status: i32 = 0;
        self.gl.get_program_iv(program, gl_link_status, &status);
        if (status == 0) {
            self.reportProgramFailure(program_source, program);
            return error.OpenGlProgramLinkFailed;
        }
        return program;
    }

    fn compileShader(self: *Presenter, source_name: BuiltinShaderSource, kind: u32, source: []const u8) !u32 {
        const shader = self.gl.create_shader(kind);
        if (shader == 0) return error.OpenGlShaderCreationFailed;
        errdefer self.gl.delete_shader(shader);
        const source_ptrs = [_][*]const u8{source.ptr};
        const lengths = [_]i32{try glI32(source.len)};
        self.gl.shader_source(shader, 1, &source_ptrs, &lengths[0]);
        self.gl.compile_shader(shader);
        var status: i32 = 0;
        self.gl.get_shader_iv(shader, gl_compile_status, &status);
        if (status == 0) {
            self.reportShaderFailure(source_name, shader);
            return error.OpenGlShaderCompileFailed;
        }
        return shader;
    }

    fn reportShaderFailure(self: *Presenter, source: BuiltinShaderSource, shader: u32) void {
        var log: [512]u8 = undefined;
        var written: i32 = 0;
        self.gl.get_shader_info_log(shader, @intCast(log.len), &written, &log);
        const message = infoLog(log[0..], written);
        var diagnostic: [768]u8 = undefined;
        const output = formatShaderFailure(&diagnostic, .compile, source, message) catch "OpenGL shader failure: diagnostic formatting failed";
        std.debug.print("{s}\n", .{output});
    }

    fn reportProgramFailure(self: *Presenter, source: BuiltinShaderSource, program: u32) void {
        var log: [512]u8 = undefined;
        var written: i32 = 0;
        self.gl.get_program_info_log(program, @intCast(log.len), &written, &log);
        const message = infoLog(log[0..], written);
        var diagnostic: [768]u8 = undefined;
        const output = formatShaderFailure(&diagnostic, .link, source, message) catch "OpenGL shader failure: diagnostic formatting failed";
        std.debug.print("{s}\n", .{output});
    }
};

const ShaderFailureOperation = enum { compile, link };

fn infoLog(buffer: []const u8, written: i32) []const u8 {
    if (written <= 0) return "driver returned no log";
    const length: usize = @intCast(@min(written, @as(i32, @intCast(buffer.len))));
    return std.mem.trimRight(u8, buffer[0..length], "\x00\r\n");
}

fn formatShaderFailure(buffer: []u8, operation: ShaderFailureOperation, source: BuiltinShaderSource, message: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "OpenGL shader failure: operation={s} platform={s} source={s} log={s}", .{ @tagName(operation), @tagName(builtin.os.tag), @tagName(source), message });
}

pub const Backend = struct {
    presenter: *Presenter,
    canvas: up.Canvas,
    sprites: *up.SpriteBatch,

    pub fn rendererBackend(self: *Backend) up.RendererBackend {
        return .{ .context = self, .submit_fn = submit };
    }

    fn submit(context: *anyopaque, commands: []const up.RenderCommand) anyerror!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        try self.presenter.present(self.canvas, self.sprites, commands);
    }
};

fn loadProc(comptime T: type, name: [:0]const u8) !T {
    const pointer = c.SDL_GL_GetProcAddress(name) orelse return error.MissingOpenGlProcedure;
    return @ptrCast(pointer);
}

fn versionAtLeast(major: i32, minor: i32, required_major: i32, required_minor: i32) bool {
    return major > required_major or (major == required_major and minor >= required_minor);
}

fn glI32(value: anytype) !i32 {
    return std.math.cast(i32, value) orelse error.OpenGlValueOutOfRange;
}

fn glSize(value: usize) !isize {
    return std.math.cast(isize, value) orelse error.OpenGlValueOutOfRange;
}

fn byteLen(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidRenderCanvas;
    return std.math.mul(usize, pixels, 4) catch error.InvalidRenderCanvas;
}

fn viewportForPresentation(presentation: up.Presentation) !GlViewport {
    const destination = presentation.destination();
    const framebuffer_height = try presentationDimension(presentation.framebuffer_size.y);
    const x = try presentationDimension(destination.x);
    const top = try presentationDimension(destination.y);
    const width = try presentationDimension(destination.w);
    const height = try presentationDimension(destination.h);
    if (width == 0 or height == 0 or top > framebuffer_height or height > framebuffer_height - top) return error.InvalidPresentationViewport;
    return .{ .x = x, .y = framebuffer_height - top - height, .width = width, .height = height };
}

fn presentationDimension(value: f32) !u32 {
    if (!std.math.isFinite(value) or value < 0 or value > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidPresentationViewport;
    return @intFromFloat(@round(value));
}

fn conformanceEnabled() bool {
    const value = std.posix.getenv("UP_OPENGL_CONFORMANCE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

const gl_array_buffer: u32 = 0x8892;
const gl_blend: u32 = 0x0BE2;
const gl_clamp_to_edge: u32 = 0x812F;
const gl_color_buffer_bit: u32 = 0x00004000;
const gl_compile_status: u32 = 0x8B81;
const gl_dynamic_draw: u32 = 0x88E8;
const gl_float: u32 = 0x1406;
const gl_fragment_shader: u32 = 0x8B30;
const gl_link_status: u32 = 0x8B82;
const gl_linear: u32 = 0x2601;
const gl_major_version: u32 = 0x821B;
const gl_minor_version: u32 = 0x821C;
const gl_nearest: u32 = 0x2600;
const gl_one_minus_src_alpha: u32 = 0x0303;
const gl_one: u32 = 1;
const gl_rgba: u32 = 0x1908;
const gl_scissor_test: u32 = 0x0C11;
const gl_src_alpha: u32 = 0x0302;
const gl_texture0: u32 = 0x84C0;
const gl_texture_2d: u32 = 0x0DE1;
const gl_texture_mag_filter: u32 = 0x2800;
const gl_texture_min_filter: u32 = 0x2801;
const gl_texture_wrap_s: u32 = 0x2802;
const gl_texture_wrap_t: u32 = 0x2803;
const gl_triangles: u32 = 0x0004;
const gl_unpack_alignment: u32 = 0x0CF5;
const gl_unsigned_byte: u32 = 0x1401;
const gl_vertex_shader: u32 = 0x8B31;

const sprite_vertex_source =
    \\#version 330 core
    \\layout(location = 0) in vec2 in_position;
    \\layout(location = 1) in vec2 in_uv;
    \\layout(location = 2) in vec4 in_tint;
    \\out vec2 out_uv;
    \\out vec4 out_tint;
    \\void main() {
    \\    gl_Position = vec4(in_position, 0.0, 1.0);
    \\    out_uv = in_uv;
    \\    out_tint = in_tint;
    \\}
;

const sprite_fragment_source =
    \\#version 330 core
    \\uniform sampler2D sprite_texture;
    \\in vec2 out_uv;
    \\in vec4 out_tint;
    \\out vec4 out_color;
    \\void main() {
    \\    out_color = texture(sprite_texture, out_uv) * out_tint;
    \\}
;

const primitive_vertex_source =
    \\#version 330 core
    \\layout(location = 0) in vec2 in_position;
    \\layout(location = 1) in vec4 in_color;
    \\out vec4 out_color;
    \\void main() {
    \\    gl_Position = vec4(in_position, 0.0, 1.0);
    \\    out_color = in_color;
    \\}
;

const primitive_fragment_source =
    \\#version 330 core
    \\in vec4 out_color;
    \\out vec4 fragment_color;
    \\void main() {
    \\    fragment_color = out_color;
    \\}
;

test "OpenGL 3.3 version requirement is bounded" {
    try std.testing.expect(versionAtLeast(3, 3, 3, 3));
    try std.testing.expect(versionAtLeast(4, 0, 3, 3));
    try std.testing.expect(!versionAtLeast(3, 2, 3, 3));
}

test "OpenGL presentation viewport respects integer letterboxing" {
    const viewport = try viewportForPresentation(up.Presentation.init(.{ .x = 320, .y = 180 }, .{ .x = 1000, .y = 800 }, .integer_fit));
    try std.testing.expectEqual(GlViewport{ .x = 20, .y = 130, .width = 960, .height = 540 }, viewport);
}

test "OpenGL recovery retains presenter failures" {
    var presenter: Presenter = undefined;
    presenter.recovery_failure = null;
    const err = presenter.recordRecoveryFailure(error.OpenGlContextCreationFailed);
    try std.testing.expectEqual(error.OpenGlContextCreationFailed, err);
    try std.testing.expectEqual(error.OpenGlContextCreationFailed, presenter.recoveryFailure().?);
}

test "OpenGL shader diagnostics identify built-in sources" {
    var buffer: [256]u8 = undefined;
    const diagnostic = try formatShaderFailure(&buffer, .compile, .sprite_fragment, "syntax error near texture");
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "operation=compile") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "source=sprite_fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "log=syntax error near texture") != null);
    try std.testing.expectEqualStrings("driver returned no log", infoLog("ignored", 0));
}

test "OpenGL 3.3 presenter renders canonical primitives, text, and sprites" {
    if (!conformanceEnabled()) return;
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitializationFailed;
    defer c.SDL_Quit();
    try configureContext();
    const window = c.SDL_CreateWindow("unpolished-peas OpenGL conformance", 64, 32, c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_OPENGL) orelse return error.OpenGlWindowCreationFailed;
    defer c.SDL_DestroyWindow(window);
    var presenter = try Presenter.init(window, 64, 32);
    defer presenter.deinit();
    var scenario = try up.testSupport.RendererConformance.init(std.testing.allocator, .opaque_rects, 64, 32);
    defer scenario.deinit();
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    for (scenario.commandSlice()) |command| try commands.append(command);
    try commands.append(.{ .text = .{ .value = "A", .x = 20, .y = 20, .color = up.Color.white } });
    var canvas = try scenario.initialCanvas(std.testing.allocator);
    defer canvas.deinit();
    var image_pixels = [_]up.Color{up.Color.white};
    const image = up.Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = &image_pixels };
    var sprites = up.SpriteBatch.init(std.testing.allocator);
    defer sprites.deinit();
    try sprites.appendQuad(&image, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .{ .x = -0.6875, .y = 0.375 }, .{ .x = -0.625, .y = 0.375 }, .{ .x = -0.625, .y = 0.25 }, .{ .x = -0.6875, .y = 0.25 } }, .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } }, up.Color.white, .nearest);
    try presenter.render(canvas, &sprites, commands.commands.items);
    try std.testing.expect(presenter.primitive_batch.vertices.items.len > 6);
    var captured = try presenter.capture(std.testing.allocator);
    defer captured.deinit();
    try scenario.expectCapture(&captured);
    try std.testing.expectEqual(up.Color.white, captured.get(10, 10).?);
    image_pixels[0] = up.Color.rgb(255, 0, 0);
    try presenter.render(canvas, &sprites, commands.commands.items);
    var reloaded_capture = try presenter.capture(std.testing.allocator);
    defer reloaded_capture.deinit();
    try std.testing.expectEqual(up.Color.rgb(255, 0, 0), reloaded_capture.get(10, 10).?);
    try presenter.recover();
    try std.testing.expect(presenter.recoveryFailure() == null);
    try presenter.render(canvas, &sprites, commands.commands.items);
    var recovered_capture = try presenter.capture(std.testing.allocator);
    defer recovered_capture.deinit();
    try std.testing.expectEqual(up.Color.rgb(255, 0, 0), recovered_capture.get(10, 10).?);
    var backend = Backend{ .presenter = &presenter, .canvas = canvas, .sprites = &sprites };
    try backend.rendererBackend().submit(commands.commands.items);

    sprites.clear();
    var clipped_scenario = try up.testSupport.RendererConformance.init(std.testing.allocator, .clipped_rect, 64, 32);
    defer clipped_scenario.deinit();
    var clipped_canvas = try clipped_scenario.initialCanvas(std.testing.allocator);
    defer clipped_canvas.deinit();
    try presenter.render(clipped_canvas, &sprites, clipped_scenario.commandSlice());
    var clipped_capture = try presenter.capture(std.testing.allocator);
    defer clipped_capture.deinit();
    try clipped_scenario.expectCapture(&clipped_capture);

    const background = up.Color.rgba(19, 37, 61, 255);
    const alpha = up.Color.rgba(255, 0, 0, 128).over(background);
    const additive = up.Color.rgba(0, 0, 255, 128).add(alpha);
    var state_commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer state_commands.deinit();
    try state_commands.append(.{ .push_clip = .{ .x = 8, .y = 8, .w = 16, .h = 16 } });
    try state_commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 64, .h = 32, .color = up.Color.rgba(255, 0, 0, 128) } });
    try state_commands.append(.{ .push_blend = .additive });
    try state_commands.append(.{ .rect = .{ .x = 12, .y = 12, .w = 4, .h = 4, .color = up.Color.rgba(0, 0, 255, 128) } });
    try state_commands.append(.pop_blend);
    try state_commands.append(.pop_clip);
    var camera = up.Camera2D{ .viewport = .{ .x = 32, .y = 8, .w = 16, .h = 16 } };
    camera_commands.Canvas.init(&state_commands, &camera, .{ .x = 64, .y = 32 }).fillRect(.init(-8, -8, 16, 16), up.Color.white);
    canvas.clear(background);
    try presenter.render(canvas, &sprites, state_commands.commands.items);
    var state_capture = try presenter.capture(std.testing.allocator);
    defer state_capture.deinit();
    try std.testing.expectEqual(background, state_capture.get(7, 8).?);
    try std.testing.expectEqual(alpha, state_capture.get(10, 10).?);
    try std.testing.expectEqual(additive, state_capture.get(14, 14).?);
    try std.testing.expectEqual(up.Color.white, state_capture.get(40, 16).?);
    try std.testing.expectEqual(background, state_capture.get(30, 16).?);
}
