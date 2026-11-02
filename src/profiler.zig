const std = @import("std");

pub const Scope = enum {
    callback,
    update,
    draw,
    asset,
};

pub const SampleKind = enum { frame, scope, counter };
pub const max_name_bytes: usize = 48;

pub const Sample = struct {
    kind: SampleKind,
    frame: u64,
    timestamp_ns: u64,
    duration_ns: u64 = 0,
    value: f64 = 0,
    name: [max_name_bytes]u8 = undefined,
    name_len: usize,
    name_truncated: bool = false,

    pub fn label(self: *const Sample) []const u8 {
        return self.name[0..self.name_len];
    }
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
    pub const max_samples: usize = 512;

    enabled: bool,
    frame: u64 = 0,
    frame_started_ns: u64 = 0,
    samples: [max_samples]Sample = undefined,
    sample_start: usize = 0,
    sample_count: usize = 0,
    dropped_samples: u32 = 0,
    frame_dropped_samples: u32 = 0,

    pub fn init(enabled: bool) Profiler {
        return .{ .enabled = enabled };
    }

    pub fn beginFrame(self: *Profiler, frame: u64) void {
        if (!self.enabled) return;
        self.frame = frame;
        self.frame_started_ns = nowNs();
        self.frame_dropped_samples = 0;
        self.append(.{ .kind = .frame, .frame = frame, .timestamp_ns = self.frame_started_ns, .name = nameBuffer("frame").bytes, .name_len = "frame".len });
    }

    pub fn scope(self: *Profiler, value: Scope) Timer {
        return .{ .profiler = self, .frame = self.frame, .started_ns = if (self.enabled) nowNs() else 0, .name = @tagName(value) };
    }

    pub fn namedScope(self: *Profiler, name: []const u8) Timer {
        return .{ .profiler = self, .frame = self.frame, .started_ns = if (self.enabled) nowNs() else 0, .name = name };
    }

    pub fn counter(self: *Profiler, name: []const u8, value: f64) void {
        if (!self.enabled) return;
        const copied = nameBuffer(name);
        self.append(.{ .kind = .counter, .frame = self.frame, .timestamp_ns = nowNs(), .value = value, .name = copied.bytes, .name_len = copied.len, .name_truncated = copied.truncated });
    }

    pub fn metrics(self: *const Profiler) Metrics {
        var result = Metrics{ .frame = self.frame, .total_ns = 0, .samples = 0, .dropped_samples = self.frame_dropped_samples, .scopes = [_]ScopeMetrics{.{}} ** scope_count };
        for (0..self.sample_count) |index| {
            const sample = self.sampleAt(index);
            if (sample.frame != self.frame or sample.kind != .scope) continue;
            result.samples += 1;
            result.total_ns +|= sample.duration_ns;
            if (std.meta.stringToEnum(Scope, sample.label())) |scope_value| {
                result.scopes[@intFromEnum(scope_value)].calls +|= 1;
                result.scopes[@intFromEnum(scope_value)].total_ns +|= sample.duration_ns;
            }
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
        var first = true;
        for (0..self.sample_count) |index| {
            if (!first) try out.writeByte(',');
            first = false;
            try writeTraceSample(out, self.sampleAt(index));
        }
        if (self.dropped_samples != 0) {
            if (!first) try out.writeByte(',');
            try out.print("{{\"name\":\"dropped_samples\",\"cat\":\"unpolished-peas\",\"ph\":\"C\",\"ts\":{d},\"pid\":1,\"tid\":1,\"args\":{{\"count\":{d}}}}}", .{ nowNs() / std.time.ns_per_us, self.dropped_samples });
        }
        try out.writeAll("]}");
        try out.flush();
    }

    fn record(self: *Profiler, frame: u64, started_ns: u64, name: []const u8) void {
        if (!self.enabled or frame != self.frame) return;
        const copied = nameBuffer(name);
        self.append(.{ .kind = .scope, .frame = frame, .timestamp_ns = started_ns, .duration_ns = nowNs() -| started_ns, .name = copied.bytes, .name_len = copied.len, .name_truncated = copied.truncated });
    }

    fn append(self: *Profiler, sample: Sample) void {
        if (self.sample_count == max_samples) {
            self.samples[self.sample_start] = sample;
            self.sample_start = (self.sample_start + 1) % max_samples;
            self.dropped_samples +%= 1;
            self.frame_dropped_samples +%= 1;
            return;
        }
        self.samples[(self.sample_start + self.sample_count) % max_samples] = sample;
        self.sample_count += 1;
    }

    fn sampleAt(self: *const Profiler, index: usize) *const Sample {
        return &self.samples[(self.sample_start + index) % max_samples];
    }
};

pub const Timer = struct {
    profiler: *Profiler,
    frame: u64,
    started_ns: u64,
    name: []const u8,

    pub fn end(self: Timer) void {
        self.profiler.record(self.frame, self.started_ns, self.name);
    }
};

const NameBuffer = struct {
    bytes: [max_name_bytes]u8,
    len: usize,
    truncated: bool = false,
};

fn nameBuffer(name: []const u8) NameBuffer {
    const len = @min(name.len, max_name_bytes);
    var result = NameBuffer{ .bytes = undefined, .len = len, .truncated = len != name.len };
    @memcpy(result.bytes[0..len], name[0..len]);
    return result;
}

fn writeTraceSample(out: *std.Io.Writer, sample: *const Sample) !void {
    try out.writeAll("{\"name\":");
    try std.json.Stringify.value(sample.label(), .{}, out);
    try out.writeAll(",\"cat\":\"unpolished-peas\",\"ph\":");
    try std.json.Stringify.value(switch (sample.kind) {
        .frame => "i",
        .scope => "X",
        .counter => "C",
    }, .{}, out);
    try out.print(",\"ts\":{d},\"pid\":1,\"tid\":1", .{sample.timestamp_ns / std.time.ns_per_us});
    switch (sample.kind) {
        .frame => try out.print(",\"s\":\"g\",\"args\":{{\"frame\":{d}}}", .{sample.frame}),
        .scope => try out.print(",\"dur\":{d},\"args\":{{\"frame\":{d},\"truncated\":{s}}}", .{ sample.duration_ns / std.time.ns_per_us, sample.frame, if (sample.name_truncated) "true" else "false" }),
        .counter => try out.print(",\"args\":{{\"value\":{d},\"frame\":{d},\"truncated\":{s}}}", .{ sample.value, sample.frame, if (sample.name_truncated) "true" else "false" }),
    }
    try out.writeByte('}');
}

const scope_count = @typeInfo(Scope).@"enum".fields.len;

fn nowNs() u64 {
    return @intCast(@max(@as(i128, 0), std.time.nanoTimestamp()));
}

test "profiler retains named scopes counters and frame markers across frames" {
    var profiler = Profiler.init(true);
    profiler.beginFrame(7);
    profiler.scope(.update).end();
    profiler.namedScope("game.ai").end();
    profiler.counter("enemies", 12);
    profiler.beginFrame(8);
    profiler.scope(.draw).end();
    const metrics = profiler.metrics();
    try std.testing.expectEqual(@as(u64, 8), metrics.frame);
    try std.testing.expectEqual(@as(usize, 1), metrics.samples);
    try std.testing.expectEqual(@as(u32, 1), metrics.scope(.draw).calls);
    try std.testing.expect(profiler.sample_count >= 6);
}

test "profiler bounds rolling trace history and reports drops" {
    var profiler = Profiler.init(true);
    profiler.beginFrame(1);
    var index: usize = 0;
    while (index < Profiler.max_samples + 4) : (index += 1) profiler.namedScope("work").end();
    try std.testing.expectEqual(Profiler.max_samples, profiler.sample_count);
    try std.testing.expect(profiler.dropped_samples != 0);
    try std.testing.expect(profiler.metrics().dropped_samples != 0);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temp.dir.realpath(".", &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/trace.json", .{root});
    try profiler.writeTrace(path);
    const trace = try temp.dir.readFileAlloc(std.testing.allocator, "trace.json", 256 * 1024);
    defer std.testing.allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"name\":\"dropped_samples\"") != null);
}

test "disabled profiler records no timing work" {
    var profiler = Profiler.init(false);
    profiler.beginFrame(2);
    profiler.scope(.draw).end();
    profiler.namedScope("game.draw").end();
    profiler.counter("draws", 1);
    const metrics = profiler.metrics();
    try std.testing.expectEqual(@as(usize, 0), metrics.samples);
    try std.testing.expectEqual(@as(u32, 0), metrics.dropped_samples);
}

test "profiler exports Chrome trace JSON with named multi-frame events" {
    var profiler = Profiler.init(true);
    profiler.beginFrame(3);
    profiler.namedScope("game.spawn").end();
    profiler.counter("entities", 4);
    profiler.beginFrame(4);
    profiler.scope(.callback).end();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temp.dir.realpath(".", &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/trace.json", .{root});
    try profiler.writeTrace(path);
    const bytes = try temp.dir.readFileAlloc(std.testing.allocator, "trace.json", 16 * 1024);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const events = parsed.value.object.get("traceEvents") orelse return error.InvalidTrace;
    try std.testing.expect(events.array.items.len >= 5);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "game.spawn") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"ph\":\"C\"") != null);
}
