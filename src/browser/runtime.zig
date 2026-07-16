const std = @import("std");

pub const target_triple = "wasm32-freestanding";

pub const HostCallbacks = struct {
    context: *anyopaque,
    on_resize: *const fn (*anyopaque, u32, u32) void,
};

pub const Runtime = struct {
    host: HostCallbacks,
    width: u32,
    height: u32,

    pub fn init(host: HostCallbacks, width: u32, height: u32) !Runtime {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        return .{ .host = host, .width = width, .height = height };
    }

    pub fn resize(self: *Runtime, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        self.width = width;
        self.height = height;
        self.host.on_resize(self.host.context, width, height);
    }
};

test "browser runtime boundary forwards validated resize state" {
    const State = struct {
        width: u32 = 0,
        height: u32 = 0,

        fn resized(context: *anyopaque, width: u32, height: u32) void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.width = width;
            state.height = height;
        }
    };
    var state = State{};
    var runtime = try Runtime.init(.{ .context = &state, .on_resize = State.resized }, 64, 32);
    try runtime.resize(128, 72);
    try std.testing.expectEqual(@as(u32, 128), runtime.width);
    try std.testing.expectEqual(@as(u32, 128), state.width);
    try std.testing.expectEqual(@as(u32, 72), state.height);
    try std.testing.expectError(error.InvalidCanvasSize, runtime.resize(0, 72));
}
