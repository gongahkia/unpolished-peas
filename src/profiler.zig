const std = @import("std");

pub const Scope = enum {
    callback,
    update,
    draw,
    asset,
};

pub const Sample = struct {
    scope: Scope,
    start_ns: u64,
    duration_ns: u64,
};

pub const ScopeMetrics = struct {
    calls: u32 = 0,
    total_ns: u64 = 0,
};

pub const Metrics = struct {
    frame: u64,
    total_ns: u64,
    samples: usize,
    dropped_samples: u32,
    scopes: [scope_count]ScopeMetrics,

    pub fn scope(self: Metrics, value: Scope) ScopeMetrics {
        return self.scopes[@intFromEnum(value)];
    }
};

pub const Profiler = struct {
    pub const max_samples: usize = 64;

    enabled: bool,
    frame: u64 = 0,
    frame_started_ns: u64 = 0,
    samples: [max_samples]Sample = undefined,
    sample_count: usize = 0,
    dropped_samples: u32 = 0,

    pub fn init(enabled: bool) Profiler {
        return .{ .enabled = enabled };
    }

    pub fn beginFrame(self: *Profiler, frame: u64) void {
        if (!self.enabled) return;
        self.frame = frame;
        self.frame_started_ns = nowNs();
        self.sample_count = 0;
        self.dropped_samples = 0;
    }

    pub fn scope(self: *Profiler, value: Scope) Timer {
        return .{ .profiler = self, .scope = value, .frame = self.frame, .started_ns = if (self.enabled) nowNs() else 0 };
    }

    pub fn metrics(self: *const Profiler) Metrics {
        var result = Metrics{
            .frame = self.frame,
            .total_ns = 0,
            .samples = self.sample_count,
            .dropped_samples = self.dropped_samples,
            .scopes = [_]ScopeMetrics{.{}} ** scope_count,
        };
        for (self.samples[0..self.sample_count]) |sample| {
            result.total_ns +|= sample.duration_ns;
            result.scopes[@intFromEnum(sample.scope)].calls +|= 1;
            result.scopes[@intFromEnum(sample.scope)].total_ns +|= sample.duration_ns;
        }
        return result;
    }

    pub fn writeTrace(self: *const Profiler, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        const out = &writer.interface;
        try out.writeAll("{\"displayTimeUnit\":\"ms\",\"traceEvents\":[");
        for (self.samples[0..self.sample_count], 0..) |sample, index| {
            if (index != 0) try out.writeByte(',');
            try out.writeAll("{\"name\":\"");
            try out.writeAll(@tagName(sample.scope));
            try out.writeAll("\",\"cat\":\"unpolished-peas\",\"ph\":\"X\",\"ts\":");
            try out.print("{d}", .{sample.start_ns / std.time.ns_per_us});
            try out.writeAll(",\"dur\":");
            try out.print("{d}", .{sample.duration_ns / std.time.ns_per_us});
            try out.writeAll(",\"pid\":1,\"tid\":1}");
        }
        try out.writeAll("]}");
        try out.flush();
    }

    fn record(self: *Profiler, value: Scope, frame: u64, started_ns: u64) void {
        if (!self.enabled or frame != self.frame) return;
        if (self.sample_count == max_samples) {
            self.dropped_samples +%= 1;
            return;
        }
        const finished_ns = nowNs();
        self.samples[self.sample_count] = .{
            .scope = value,
            .start_ns = started_ns -| self.frame_started_ns,
            .duration_ns = finished_ns -| started_ns,
        };
        self.sample_count += 1;
    }
};

pub const Timer = struct {
    profiler: *Profiler,
    scope: Scope,
    frame: u64,
    started_ns: u64,

    pub fn end(self: Timer) void {
        self.profiler.record(self.scope, self.frame, self.started_ns);
    }
};

const scope_count = @typeInfo(Scope).@"enum".fields.len;

fn nowNs() u64 {
    return @intCast(@max(@as(i128, 0), std.time.nanoTimestamp()));
}

test "profiler tracks explicit bounded scopes" {
    var profiler = Profiler.init(true);
    profiler.beginFrame(7);
    var index: usize = 0;
    while (index < Profiler.max_samples + 1) : (index += 1) {
        const timer = profiler.scope(.update);
        timer.end();
    }
    const metrics = profiler.metrics();
    try std.testing.expectEqual(@as(u64, 7), metrics.frame);
    try std.testing.expectEqual(Profiler.max_samples, metrics.samples);
    try std.testing.expectEqual(@as(u32, 1), metrics.dropped_samples);
    try std.testing.expectEqual(@as(u32, Profiler.max_samples), metrics.scope(.update).calls);
}

test "disabled profiler records no timing work" {
    var profiler = Profiler.init(false);
    profiler.beginFrame(2);
    profiler.scope(.draw).end();
    const metrics = profiler.metrics();
    try std.testing.expectEqual(@as(usize, 0), metrics.samples);
    try std.testing.expectEqual(@as(u32, 0), metrics.dropped_samples);
}

test "profiler exports Chrome trace JSON" {
    var profiler = Profiler.init(true);
    profiler.beginFrame(3);
    profiler.scope(.callback).end();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temp.dir.realpath(".", &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/trace.json", .{root});
    try profiler.writeTrace(path);
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "trace.json", 4096);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const trace_root = parsed.value.object;
    const events = trace_root.get("traceEvents") orelse return error.InvalidTrace;
    try std.testing.expectEqual(@as(usize, 1), events.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"callback\"") != null);
}
