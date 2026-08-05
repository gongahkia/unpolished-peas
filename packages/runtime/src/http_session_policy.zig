const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const timer_wheel = @import("timer_wheel.zig");

pub const HttpSessionPolicyError = protocol.HttpParserError || timer_wheel.TimerWheelError || error{ InvalidConfiguration, TimeOverflow };
pub const HttpSessionPolicyState = enum { idle, headers, body, complete, rejected };
pub const HttpSessionRejection = enum { malformed, header_limit, body_limit, transfer_encoding, header_timeout, body_timeout };
pub const HttpRejectionResponse = struct { status: u16, close_connection: bool = true };
pub const HttpSessionPolicyEvent = union(enum) { parser: protocol.HttpParserEvent, rejected: HttpSessionRejection };
pub const HttpSessionPolicyConfig = struct {
    parser: protocol.HttpParserConfig,
    header_timeout_ns: core.TimeNs,
    body_idle_timeout_ns: core.TimeNs,
    allow_chunked: bool = true,

    pub fn validate(self: HttpSessionPolicyConfig) HttpSessionPolicyError!void {
        try self.parser.validate();
        if (self.header_timeout_ns == 0 or self.body_idle_timeout_ns == 0) return error.InvalidConfiguration;
    }
};

pub const HttpSessionPolicy = struct {
    config: HttpSessionPolicyConfig,
    parser: protocol.HttpParser,
    state: HttpSessionPolicyState = .idle,
    deadline: ?timer_wheel.TimerId = null,

    pub fn init(config: HttpSessionPolicyConfig) HttpSessionPolicyError!HttpSessionPolicy {
        try config.validate();
        return .{ .config = config, .parser = try protocol.HttpParser.init(config.parser) };
    }

    pub fn start(self: *HttpSessionPolicy, timers: *timer_wheel.TimerWheel, now_ns: core.TimeNs) HttpSessionPolicyError!void {
        if (self.state != .idle) return error.InvalidConfiguration;
        self.state = .headers;
        try self.schedule(timers, now_ns, self.config.header_timeout_ns);
    }

    pub fn feed(self: *HttpSessionPolicy, timers: *timer_wheel.TimerWheel, now_ns: core.TimeNs, input: []const u8) HttpSessionPolicyError!struct { consumed: usize, event: ?HttpSessionPolicyEvent } {
        if (self.state == .idle or self.state == .rejected) return error.InvalidConfiguration;
        const parsed = self.parser.feed(input) catch |err| return .{ .consumed = 0, .event = .{ .rejected = self.reject(timers, rejectionForParserError(err)) } };
        const event = parsed.event orelse return .{ .consumed = parsed.consumed, .event = null };
        switch (event) {
            .headers_complete => |framing| switch (framing) {
                .none => {
                    self.cancel(timers);
                    self.state = .complete;
                },
                .content_length => |length| {
                    if (length == 0) {
                        self.cancel(timers);
                        self.state = .complete;
                    } else {
                        self.state = .body;
                        try self.replaceDeadline(timers, now_ns, self.config.body_idle_timeout_ns);
                    }
                },
                .chunked => {
                    if (!self.config.allow_chunked) return .{ .consumed = parsed.consumed, .event = .{ .rejected = self.reject(timers, .transfer_encoding) } };
                    self.state = .body;
                    try self.replaceDeadline(timers, now_ns, self.config.body_idle_timeout_ns);
                },
            },
            .body => if (self.state == .body) try self.replaceDeadline(timers, now_ns, self.config.body_idle_timeout_ns),
            .complete => {
                self.cancel(timers);
                self.state = .complete;
            },
            else => {},
        }
        return .{ .consumed = parsed.consumed, .event = .{ .parser = event } };
    }

    pub fn onTimer(self: *HttpSessionPolicy, timer: timer_wheel.Timer) ?HttpSessionPolicyEvent {
        if (self.deadline == null or timer.id != self.deadline.? or self.state == .complete or self.state == .rejected) return null;
        self.deadline = null;
        return .{ .rejected = self.rejectWithoutTimer(if (self.state == .headers) .header_timeout else .body_timeout) };
    }

    pub fn rejectionResponse(rejection: HttpSessionRejection) HttpRejectionResponse {
        return .{ .status = switch (rejection) {
            .malformed => 400,
            .header_limit, .body_limit => 413,
            .transfer_encoding => 501,
            .header_timeout, .body_timeout => 408,
        } };
    }

    fn schedule(self: *HttpSessionPolicy, timers: *timer_wheel.TimerWheel, now_ns: core.TimeNs, timeout_ns: core.TimeNs) HttpSessionPolicyError!void {
        const deadline = std.math.add(core.TimeNs, now_ns, timeout_ns) catch return error.TimeOverflow;
        self.deadline = try timers.schedule(.session, deadline);
    }

    fn replaceDeadline(self: *HttpSessionPolicy, timers: *timer_wheel.TimerWheel, now_ns: core.TimeNs, timeout_ns: core.TimeNs) HttpSessionPolicyError!void {
        self.cancel(timers);
        try self.schedule(timers, now_ns, timeout_ns);
    }

    fn cancel(self: *HttpSessionPolicy, timers: *timer_wheel.TimerWheel) void {
        if (self.deadline) |id| timers.cancel(id) catch {};
        self.deadline = null;
    }

    fn reject(self: *HttpSessionPolicy, timers: *timer_wheel.TimerWheel, rejection: HttpSessionRejection) HttpSessionRejection {
        self.cancel(timers);
        return self.rejectWithoutTimer(rejection);
    }

    fn rejectWithoutTimer(self: *HttpSessionPolicy, rejection: HttpSessionRejection) HttpSessionRejection {
        self.state = .rejected;
        return rejection;
    }
};

fn rejectionForParserError(err: protocol.HttpParserError) HttpSessionRejection {
    return switch (err) {
        error.LineTooLong, error.HeaderTooLarge, error.HeaderCountExceeded => .header_limit,
        error.BodyTooLarge => .body_limit,
        error.UnsupportedTransferEncoding => .transfer_encoding,
        else => .malformed,
    };
}

test "HTTP session policies bound header bombs and slow bodies with close responses" {
    var timers = try timer_wheel.TimerWheel.init(@import("std").testing.allocator, 2);
    defer timers.deinit();
    var bomb = try HttpSessionPolicy.init(.{ .parser = .{ .kind = .request, .maximum_header_bytes = 8 }, .header_timeout_ns = 5, .body_idle_timeout_ns = 3 });
    try bomb.start(&timers, 0);
    _ = try bomb.feed(&timers, 0, "GET / HTTP/1.1\r\n");
    const rejected = try bomb.feed(&timers, 0, "Header: over-limit\r\n");
    try @import("std").testing.expectEqual(HttpSessionRejection.header_limit, rejected.event.?.rejected);
    try @import("std").testing.expectEqual(HttpRejectionResponse{ .status = 413 }, HttpSessionPolicy.rejectionResponse(rejected.event.?.rejected));

    var slow = try HttpSessionPolicy.init(.{ .parser = .{ .kind = .request, .maximum_body_bytes = 4 }, .header_timeout_ns = 5, .body_idle_timeout_ns = 3 });
    try slow.start(&timers, 0);
    const request = "POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\n";
    const first = try slow.feed(&timers, 0, request);
    const second = try slow.feed(&timers, 0, request[first.consumed..]);
    _ = try slow.feed(&timers, 0, request[first.consumed + second.consumed ..]);
    const due = (try timers.advance(3)).?;
    const timeout = slow.onTimer(due).?;
    try @import("std").testing.expectEqual(HttpSessionRejection.body_timeout, timeout.rejected);
    try @import("std").testing.expectEqual(@as(u16, 408), HttpSessionPolicy.rejectionResponse(timeout.rejected).status);
}
