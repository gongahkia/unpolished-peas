const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const Input = @import("input.zig").Input;
const Renderer2D = @import("advanced_2d.zig").Renderer2D;
const SaveStore = @import("save_data.zig").SaveStore;
const Audio = @import("audio.zig").Audio;

pub const GamePhase = enum { init, update, draw, deinit };

pub const GameFailure = struct {
    phase: GamePhase,
    cause: anyerror,
};

pub const GameContext = struct {
    input: *const Input,
    /// Host-owned allocator for game-owned resources such as RenderSurface,
    /// Image, Atlas, and Font. It remains absent from deliberately bare core
    /// contexts, so a game must request it explicitly before allocating.
    allocator: ?std.mem.Allocator = null,
    canvas: ?*Canvas = null,
    renderer: ?*Renderer2D = null,
    /// Host-provided persistence for small game-owned blobs. It is absent from
    /// bare core contexts and must be explicitly checked by games that use it.
    save_data: ?*SaveStore = null,
    /// Host-provided audio service for short WAV effects and one incrementally
    /// decoded music stream. It is present in normal native, browser, and
    /// headless protocol runs, but playback can still be blocked or
    /// unavailable; inspect `Audio.availability` or handle play errors.
    audio: ?*Audio = null,
    /// The explicit seed selected by the host for this simulation run.
    ///
    /// It is optional because existing games may not need deterministic random
    /// initialization. A game that does should read it during `init` and own a
    /// `DeterministicRng` in its own state.
    simulation_seed: ?u64 = null,
    elapsed_seconds: f32 = 0,
    interpolation_alpha: f32 = 0,

    pub fn init(input: *const Input) GameContext {
        return .{ .input = input };
    }

    pub fn withRuntime(input: *const Input, canvas: *Canvas) GameContext {
        return .{ .input = input, .canvas = canvas };
    }

    pub fn withRenderer(input: *const Input, canvas: *Canvas, renderer: *Renderer2D) GameContext {
        return .{ .input = input, .canvas = canvas, .renderer = renderer };
    }

    pub fn requireCanvas(self: GameContext) !*Canvas {
        return self.canvas orelse error.CanvasUnavailable;
    }

    pub fn requireAllocator(self: GameContext) !std.mem.Allocator {
        return self.allocator orelse error.AllocatorUnavailable;
    }

    pub fn requireRenderer2D(self: GameContext) !*Renderer2D {
        return self.renderer orelse error.Renderer2DUnavailable;
    }

    pub fn requireSaveData(self: GameContext) !*SaveStore {
        return self.save_data orelse error.SaveDataUnavailable;
    }

    pub fn requireAudio(self: GameContext) !*Audio {
        return self.audio orelse error.AudioUnavailable;
    }
};

pub fn GameProtocol(comptime Game: type) type {
    return struct {
        const Self = @This();
        const InitCallback = *const fn (*Game, *GameContext) anyerror!void;
        const UpdateCallback = *const fn (*Game, *GameContext, f32) anyerror!void;
        const DrawCallback = *const fn (*Game, *GameContext) anyerror!void;
        const DeinitCallback = *const fn (*Game, *GameContext) anyerror!void;

        comptime {
            const init_callback: InitCallback = Game.init;
            const update_callback: UpdateCallback = Game.update;
            const draw_callback: DrawCallback = Game.draw;
            _ = init_callback;
            _ = update_callback;
            _ = draw_callback;
            if (@hasDecl(Game, "deinit")) {
                const deinit_callback: DeinitCallback = Game.deinit;
                _ = deinit_callback;
            }
        }

        game: *Game,
        initialized: bool = false,
        last_failure: ?GameFailure = null,

        pub fn bind(game: *Game) Self {
            return .{ .game = game };
        }

        pub fn init(self: *Self, context: *GameContext) !void {
            if (self.initialized) return error.AlreadyInitialized;
            self.last_failure = null;
            context.elapsed_seconds = 0;
            context.interpolation_alpha = 0;
            Game.init(self.game, context) catch |err| {
                self.last_failure = .{ .phase = .init, .cause = err };
                return err;
            };
            self.initialized = true;
        }

        pub fn update(self: *Self, context: *GameContext, elapsed_seconds: f32) !void {
            if (!self.initialized) return error.NotInitialized;
            if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds < 0) return error.InvalidElapsedSeconds;
            self.last_failure = null;
            context.elapsed_seconds = elapsed_seconds;
            context.interpolation_alpha = 0;
            Game.update(self.game, context, elapsed_seconds) catch |err| {
                self.last_failure = .{ .phase = .update, .cause = err };
                return err;
            };
        }

        pub fn draw(self: *Self, context: *GameContext, interpolation_alpha: f32) !void {
            if (!self.initialized) return error.NotInitialized;
            if (!std.math.isFinite(interpolation_alpha) or interpolation_alpha < 0 or interpolation_alpha > 1) return error.InvalidInterpolationAlpha;
            self.last_failure = null;
            context.interpolation_alpha = interpolation_alpha;
            Game.draw(self.game, context) catch |err| {
                self.last_failure = .{ .phase = .draw, .cause = err };
                return err;
            };
        }

        /// Calls an optional game-owned cleanup callback once. Hosts invoke
        /// this before they release context capabilities, so a protocol game
        /// can safely deinitialize resources created through `ctx.allocator`.
        pub fn deinit(self: *Self, context: *GameContext) !void {
            if (!self.initialized) return;
            self.last_failure = null;
            if (@hasDecl(Game, "deinit")) Game.deinit(self.game, context) catch |err| {
                self.last_failure = .{ .phase = .deinit, .cause = err };
                return err;
            };
            self.initialized = false;
        }

        pub fn lastFailure(self: Self) ?GameFailure {
            return self.last_failure;
        }
    };
}

pub const StepClock = struct {
    step_seconds: f32,
    max_steps_per_frame: u32 = 5,
    accumulator: f32 = 0,

    pub fn init(fixed_hz: u32) StepClock {
        std.debug.assert(fixed_hz > 0);
        return .{ .step_seconds = 1 / @as(f32, @floatFromInt(fixed_hz)) };
    }

    pub fn push(self: *StepClock, dt_seconds: f32) u32 {
        self.accumulator += self.frameDelta(dt_seconds);

        var steps: u32 = 0;
        while (self.accumulator >= self.step_seconds and steps < self.max_steps_per_frame) {
            self.accumulator -= self.step_seconds;
            steps += 1;
        }
        if (steps == self.max_steps_per_frame and self.accumulator >= self.step_seconds) {
            self.accumulator = 0;
        }
        return steps;
    }

    pub fn frameDelta(self: StepClock, dt_seconds: f32) f32 {
        if (!(dt_seconds > 0)) return 0;
        const max_dt = self.step_seconds * @as(f32, @floatFromInt(self.max_steps_per_frame));
        return @min(dt_seconds, max_dt);
    }

    pub fn alpha(self: StepClock) f32 {
        if (self.step_seconds == 0) return 0;
        return self.accumulator / self.step_seconds;
    }
};

test "fixed clock accumulates clamped deltas and reports alpha" {
    var clock = StepClock.init(10);
    clock.max_steps_per_frame = 3;
    try std.testing.expectEqual(@as(f32, 0), clock.frameDelta(-1));
    try std.testing.expectEqual(@as(u32, 0), clock.push(0.05));
    try std.testing.expect(std.math.approxEqAbs(f32, 0.5, clock.alpha(), 0.0001));
    try std.testing.expectEqual(@as(u32, 1), clock.push(0.1));
    try std.testing.expect(std.math.approxEqAbs(f32, 0.5, clock.alpha(), 0.0001));
    try std.testing.expectEqual(@as(u32, 3), clock.push(1));
    try std.testing.expect(std.math.approxEqAbs(f32, 0.5, clock.alpha(), 0.0001));
}

test "game protocol owns callback ordering but borrows game state and context" {
    const Game = struct {
        init_calls: u8 = 0,
        update_calls: u8 = 0,
        draw_calls: u8 = 0,
        elapsed_seconds: f32 = 0,
        alpha: f32 = 0,

        pub fn init(self: *@This(), context: *GameContext) !void {
            self.init_calls += 1;
            try std.testing.expect(!context.input.isDown(.action));
        }

        pub fn update(self: *@This(), context: *GameContext, elapsed_seconds: f32) !void {
            self.update_calls += 1;
            self.elapsed_seconds = elapsed_seconds;
            try std.testing.expectEqual(elapsed_seconds, context.elapsed_seconds);
        }

        pub fn draw(self: *@This(), context: *GameContext) !void {
            self.draw_calls += 1;
            self.alpha = context.interpolation_alpha;
        }
    };
    var input = Input{};
    var context = GameContext.init(&input);
    var game = Game{};
    var protocol = GameProtocol(Game).bind(&game);

    try protocol.init(&context);
    try protocol.update(&context, 1.0 / 60.0);
    try protocol.draw(&context, 0.5);
    try std.testing.expectEqual(@as(u8, 1), game.init_calls);
    try std.testing.expectEqual(@as(u8, 1), game.update_calls);
    try std.testing.expectEqual(@as(u8, 1), game.draw_calls);
    try std.testing.expectEqual(@as(f32, 1.0 / 60.0), game.elapsed_seconds);
    try std.testing.expectEqual(@as(f32, 0.5), game.alpha);
    try std.testing.expect(protocol.lastFailure() == null);
    try std.testing.expectError(error.AlreadyInitialized, protocol.init(&context));
    try std.testing.expectEqual(@as(u8, 1), game.init_calls);
}

test "game protocol retains callback phase and original failure" {
    const Game = struct {
        pub fn init(_: *@This(), _: *GameContext) !void {}

        pub fn update(_: *@This(), _: *GameContext, _: f32) !void {
            return error.UpdateFailed;
        }

        pub fn draw(_: *@This(), _: *GameContext) !void {}
    };
    var input = Input{};
    var context = GameContext.init(&input);
    var game = Game{};
    var protocol = GameProtocol(Game).bind(&game);

    try std.testing.expectError(error.NotInitialized, protocol.update(&context, 1.0 / 60.0));
    try protocol.init(&context);
    try std.testing.expectError(error.UpdateFailed, protocol.update(&context, 1.0 / 60.0));
    const failure = protocol.lastFailure().?;
    try std.testing.expectEqual(GamePhase.update, failure.phase);
    try std.testing.expectEqual(error.UpdateFailed, failure.cause);
    try std.testing.expectError(error.InvalidElapsedSeconds, protocol.update(&context, -1));
    try std.testing.expectError(error.InvalidInterpolationAlpha, protocol.draw(&context, 1.1));

    const InitFailureGame = struct {
        pub fn init(_: *@This(), _: *GameContext) !void {
            return error.InitFailed;
        }

        pub fn update(_: *@This(), _: *GameContext, _: f32) !void {}
        pub fn draw(_: *@This(), _: *GameContext) !void {}
    };
    var init_failure_game = InitFailureGame{};
    var init_failure_protocol = GameProtocol(InitFailureGame).bind(&init_failure_game);
    try std.testing.expectError(error.InitFailed, init_failure_protocol.init(&context));
    try std.testing.expectEqual(GamePhase.init, init_failure_protocol.lastFailure().?.phase);

    const DrawFailureGame = struct {
        pub fn init(_: *@This(), _: *GameContext) !void {}
        pub fn update(_: *@This(), _: *GameContext, _: f32) !void {}

        pub fn draw(_: *@This(), _: *GameContext) !void {
            return error.DrawFailed;
        }
    };
    var draw_failure_game = DrawFailureGame{};
    var draw_failure_protocol = GameProtocol(DrawFailureGame).bind(&draw_failure_game);
    try draw_failure_protocol.init(&context);
    try std.testing.expectError(error.DrawFailed, draw_failure_protocol.draw(&context, 0));
    try std.testing.expectEqual(GamePhase.draw, draw_failure_protocol.lastFailure().?.phase);
}

test "runtime context exposes canvas and allocator capabilities" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    var input = Input{};
    var context = GameContext.withRuntime(&input, &canvas);
    context.allocator = std.testing.allocator;
    try std.testing.expect((try context.requireCanvas()) == &canvas);
    _ = try context.requireAllocator();
    const bare = GameContext.init(&input);
    try std.testing.expectError(error.CanvasUnavailable, bare.requireCanvas());
    try std.testing.expectError(error.AllocatorUnavailable, bare.requireAllocator());
    try std.testing.expectError(error.Renderer2DUnavailable, bare.requireRenderer2D());
    try std.testing.expectError(error.SaveDataUnavailable, bare.requireSaveData());
}

test "game protocol calls optional deinit once after initialization" {
    const Game = struct {
        calls: u8 = 0,

        pub fn init(self: *@This(), _: *GameContext) !void {
            self.calls += 1;
        }

        pub fn update(_: *@This(), _: *GameContext, _: f32) !void {}
        pub fn draw(_: *@This(), _: *GameContext) !void {}

        pub fn deinit(self: *@This(), _: *GameContext) !void {
            self.calls += 1;
        }
    };
    var input = Input{};
    var context = GameContext.init(&input);
    var game = Game{};
    var protocol = GameProtocol(Game).bind(&game);
    try protocol.init(&context);
    try protocol.deinit(&context);
    try protocol.deinit(&context);
    try std.testing.expectEqual(@as(u8, 2), game.calls);
}

test "game context retains an explicit simulation seed" {
    var input = Input{};
    var context = GameContext.init(&input);
    try std.testing.expectEqual(@as(?u64, null), context.simulation_seed);
    context.simulation_seed = 42;
    try std.testing.expectEqual(@as(?u64, 42), context.simulation_seed);
}
