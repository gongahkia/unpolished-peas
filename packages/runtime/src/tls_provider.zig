const std = @import("std");
const core = @import("minna-san-core");
const tls_alpn = @import("tls_alpn.zig");

pub const max_tls_alpn_bytes: usize = 255;
pub const TlsRole = enum(u8) { client = 1, server = 2 };
pub const TlsState = enum(u8) { idle, handshaking, connected, failed, closed };
pub const TlsAlert = enum(u16) { close_notify = 0, unexpected_message = 10, bad_certificate = 42, handshake_failure = 40, internal_error = 80 };
pub const TlsCertificateDecision = enum(c_int) { reject = 0, accept = 1 };
pub const TlsCertificateCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int;
pub const TlsProviderError = tls_alpn.TlsAlpnError || error{ InvalidConfiguration, InvalidState, CertificateRejected, ProviderFailed, BufferTooSmall };
pub const TlsProviderConfig = struct {
    role: TlsRole,
    alpn: []const u8,
    server_name: []const u8 = &.{},
    certificate_context: ?*anyopaque = null,
    certificate_callback: ?TlsCertificateCallback = null,

    pub fn validate(self: TlsProviderConfig) TlsProviderError!void {
        if (self.alpn.len == 0 or self.alpn.len > max_tls_alpn_bytes or self.server_name.len > max_tls_alpn_bytes) return error.InvalidConfiguration;
    }
};
pub const TlsPollOutput = extern struct {
    state: u8 = @intFromEnum(TlsState.handshaking),
    alert: u16 = 0,
    work_completed: usize = 0,
};
pub const TlsIoOutput = extern struct { bytes: usize = 0, alert: u16 = 0 };
pub const TlsProviderVTable = extern struct {
    start: *const fn (?*anyopaque, u8, [*]const u8, usize, [*]const u8, usize, ?*anyopaque, ?TlsCertificateCallback) callconv(.c) c_int,
    poll: *const fn (?*anyopaque, core.TimeNs, *TlsPollOutput) callconv(.c) c_int,
    encrypt: *const fn (?*anyopaque, [*]const u8, usize, [*]u8, usize, *TlsIoOutput) callconv(.c) c_int,
    decrypt: *const fn (?*anyopaque, [*]const u8, usize, [*]u8, usize, *TlsIoOutput) callconv(.c) c_int,
    teardown: *const fn (?*anyopaque) callconv(.c) void,
};

pub const TlsProvider = struct {
    config: TlsProviderConfig,
    context: ?*anyopaque,
    vtable: TlsProviderVTable,
    state: TlsState = .idle,
    last_alert: ?TlsAlert = null,

    pub fn init(config: TlsProviderConfig, context: ?*anyopaque, vtable: TlsProviderVTable) TlsProviderError!TlsProvider {
        try config.validate();
        return .{ .config = config, .context = context, .vtable = vtable };
    }
    pub fn start(self: *TlsProvider) TlsProviderError!void {
        if (self.state != .idle) return error.InvalidState;
        if (self.vtable.start(self.context, @intFromEnum(self.config.role), self.config.alpn.ptr, self.config.alpn.len, self.config.server_name.ptr, self.config.server_name.len, self.config.certificate_context, self.config.certificate_callback) != @intFromEnum(core.CResult.ok)) return self.fail(.handshake_failure);
        self.state = .handshaking;
    }
    pub fn selectAlpn(self: *TlsProvider, offered: []const []const u8, policy: tls_alpn.TlsAlpnRoutePolicy) TlsProviderError![]const u8 {
        if (self.state != .idle) return error.InvalidState;
        const selected = try tls_alpn.select_tls_alpn(offered, policy);
        self.config.alpn = selected;
        return selected;
    }
    pub fn poll(self: *TlsProvider, now_ns: core.TimeNs) TlsProviderError!usize {
        if (self.state != .handshaking) return error.InvalidState;
        var output = TlsPollOutput{};
        if (self.vtable.poll(self.context, now_ns, &output) != @intFromEnum(core.CResult.ok)) return self.fail(.internal_error);
        const state = std.meta.intToEnum(TlsState, output.state) catch return self.fail(.internal_error);
        if (output.alert != 0) self.last_alert = std.meta.intToEnum(TlsAlert, output.alert) catch return self.fail(.internal_error);
        self.state = state;
        if (state == .failed) return error.ProviderFailed;
        return output.work_completed;
    }
    pub fn encrypt(self: *TlsProvider, input: []const u8, output: []u8) TlsProviderError![]u8 {
        return self.io(self.vtable.encrypt, input, output);
    }
    pub fn decrypt(self: *TlsProvider, input: []const u8, output: []u8) TlsProviderError![]u8 {
        return self.io(self.vtable.decrypt, input, output);
    }
    pub fn close(self: *TlsProvider) void {
        if (self.state != .closed) self.vtable.teardown(self.context);
        self.state = .closed;
    }
    fn io(self: *TlsProvider, operation: *const fn (?*anyopaque, [*]const u8, usize, [*]u8, usize, *TlsIoOutput) callconv(.c) c_int, input: []const u8, output: []u8) TlsProviderError![]u8 {
        if (self.state != .connected) return error.InvalidState;
        var result = TlsIoOutput{};
        if (operation(self.context, input.ptr, input.len, output.ptr, output.len, &result) != @intFromEnum(core.CResult.ok)) return self.fail(.internal_error);
        if (result.bytes > output.len) return self.fail(.internal_error);
        if (result.alert != 0) self.last_alert = std.meta.intToEnum(TlsAlert, result.alert) catch return self.fail(.internal_error);
        return output[0..result.bytes];
    }
    fn fail(self: *TlsProvider, alert: TlsAlert) TlsProviderError {
        self.state = .failed;
        self.last_alert = alert;
        return error.ProviderFailed;
    }
};

test "fake TLS providers complete explicit polls with ALPN certificates encrypted I/O alerts and teardown" {
    const Fake = struct {
        polls: usize = 0,
        certificate_checked: bool = false,
        torn_down: bool = false,
        fn certificate(context: ?*anyopaque, name: [*]const u8, len: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.certificate_checked = std.mem.eql(u8, name[0..len], "example.test");
            return @intFromEnum(TlsCertificateDecision.accept);
        }
        fn start(context: ?*anyopaque, _: u8, alpn: [*]const u8, alpn_len: usize, server_name: [*]const u8, server_name_len: usize, certificate_context: ?*anyopaque, callback: ?TlsCertificateCallback) callconv(.c) c_int {
            _ = context;
            if (!std.mem.eql(u8, alpn[0..alpn_len], "h2") or !std.mem.eql(u8, server_name[0..server_name_len], "example.test")) return @intFromEnum(core.CResult.invalid_argument);
            return callback.?(certificate_context, server_name, server_name_len);
        }
        fn poll(context: ?*anyopaque, _: core.TimeNs, output: *TlsPollOutput) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.polls += 1;
            output.* = .{ .state = @intFromEnum(if (self.polls == 1) TlsState.handshaking else TlsState.connected), .work_completed = 1 };
            return @intFromEnum(core.CResult.ok);
        }
        fn io(_: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *TlsIoOutput) callconv(.c) c_int {
            if (output_len < input_len) return @intFromEnum(core.CResult.resource_exhausted);
            @memcpy(output[0..input_len], input[0..input_len]);
            result.* = .{ .bytes = input_len };
            return @intFromEnum(core.CResult.ok);
        }
        fn teardown(context: ?*anyopaque) callconv(.c) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).torn_down = true;
        }
    };
    var fake = Fake{};
    var provider = try TlsProvider.init(.{ .role = .client, .alpn = "http/1.1", .server_name = "example.test", .certificate_context = &fake, .certificate_callback = Fake.certificate }, &fake, .{ .start = Fake.start, .poll = Fake.poll, .encrypt = Fake.io, .decrypt = Fake.io, .teardown = Fake.teardown });
    try std.testing.expectEqualStrings("h2", try provider.selectAlpn(&.{ "http/1.1", "h2" }, .{ .supported = &.{ "h2", "http/1.1" } }));
    try provider.start();
    try std.testing.expectEqual(@as(usize, 1), try provider.poll(0));
    try std.testing.expectEqual(@as(usize, 1), try provider.poll(1));
    var output: [8]u8 = undefined;
    try std.testing.expectEqualStrings("tls", try provider.encrypt("tls", output[0..]));
    try std.testing.expectEqualStrings("tls", try provider.decrypt("tls", output[0..]));
    provider.close();
    try std.testing.expect(fake.certificate_checked and fake.torn_down);
}
