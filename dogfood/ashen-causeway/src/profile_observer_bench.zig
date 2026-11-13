//! Controlled observer cost, separate from actual-file workload measurements.
const std = @import("std");
const up = @import("unpolished-peas");
const obs = @import("profile_saves.zig");
const Store = up.core.SaveStore;
const Sink = struct {
    calls: usize = 0,
    fn write(p: *anyopaque, _: []const u8, bytes: []const u8) Store.Error!void {
        const self: *@This() = @ptrCast(@alignCast(p));
        self.calls += bytes.len;
        std.mem.doNotOptimizeAway(&self.calls);
    }
    fn size(_: *anyopaque, _: []const u8) Store.Error!usize {
        return 0;
    }
    fn read(_: *anyopaque, _: []const u8, _: []u8) Store.Error!usize {
        return 0;
    }
    fn delete(_: *anyopaque, _: []const u8) Store.Error!void {}
    fn exists(_: *anyopaque, _: []const u8) Store.Error!bool {
        return false;
    }
    const vtable: Store.VTable = .{ .write = write, .read_size = size, .read = read, .delete = delete, .exists = exists };
};
pub fn main() !void {
    if (@import("builtin").mode != .ReleaseFast) return error.ProfileRequiresReleaseFast;
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedOutput;
    const capture = try allocator.create(obs.Capture);
    defer allocator.destroy(capture);
    try capture.init();
    var sink = Sink{};
    var parent = Store.init(&sink, &Sink.vtable);
    var wrapper = obs.Wrapper{ .parent = &parent, .collector = &capture.collector };
    const wrapped = wrapper.capability();
    const Sample = struct { instrumented: bool, calls: usize, elapsed_ns: u64 };
    var samples: [40]Sample = undefined;
    var timer = try std.time.Timer.start();
    for (&samples, 0..) |*sample, index| {
        const enabled = (index % 4 == 1 or index % 4 == 2);
        capture.collector.update_count = 0;
        capture.collector.operation_count = 0;
        timer.reset();
        for (0..200) |tick| {
            if (enabled) {
                const started = capture.collector.beginUpdate(tick);
                try wrapped.write("journey-v1", "baseline work");
                capture.collector.endUpdate(started);
            } else try parent.write("journey-v1", "baseline work");
        }
        sample.* = .{ .instrumented = enabled, .calls = 200, .elapsed_ns = timer.read() };
    }
    if (sink.calls != 40 * 200 * "baseline work".len or capture.collector.dropped_updates != 0 or capture.collector.dropped_operations != 0) return error.ObserverBenchmarkInvalid;
    const json = try std.json.Stringify.valueAlloc(allocator, samples, .{});
    defer allocator.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = json });
}
