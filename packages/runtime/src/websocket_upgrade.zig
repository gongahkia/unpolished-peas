const std = @import("std");
const protocol = @import("minna-san-protocol");

pub const max_websocket_origins: usize = 16;
pub const max_websocket_subprotocols: usize = 16;
pub const websocket_accept_key_bytes: usize = 28;
pub const WebSocketUpgradeError = error{ InvalidConfiguration, InvalidRequest, UnsupportedVersion, OriginRejected, ExtensionRejected, CallbackRejected };
pub const WebSocketUpgradeCallback = *const fn (?*anyopaque, WebSocketUpgradeRequest) bool;
pub const WebSocketUpgradeRequest = struct { method: []const u8, headers: []const protocol.HttpHeader };
pub const WebSocketUpgrade = struct { accept_key: [websocket_accept_key_bytes]u8, subprotocol: ?[]const u8 };
pub const WebSocketUpgradeConfig = struct {
    allowed_origins: []const []const u8 = &.{},
    allowed_subprotocols: []const []const u8 = &.{},
    allow_extensions: bool = false,
    context: ?*anyopaque = null,
    callback: ?WebSocketUpgradeCallback = null,

    pub fn validate(self: WebSocketUpgradeConfig) WebSocketUpgradeError!void {
        if (self.allowed_origins.len > max_websocket_origins or self.allowed_subprotocols.len > max_websocket_subprotocols) return error.InvalidConfiguration;
        for (self.allowed_origins) |origin| if (origin.len == 0) return error.InvalidConfiguration;
        for (self.allowed_subprotocols) |subprotocol| if (subprotocol.len == 0 or !isTokenSlice(subprotocol)) return error.InvalidConfiguration;
    }
};

pub fn validateWebSocketUpgrade(config: WebSocketUpgradeConfig, request: WebSocketUpgradeRequest) WebSocketUpgradeError!WebSocketUpgrade {
    try config.validate();
    if (!std.mem.eql(u8, request.method, "GET")) return error.InvalidRequest;
    const upgrade = singleHeader(request.headers, "upgrade") orelse return error.InvalidRequest;
    const connection = singleHeader(request.headers, "connection") orelse return error.InvalidRequest;
    const version = singleHeader(request.headers, "sec-websocket-version") orelse return error.InvalidRequest;
    const key = singleHeader(request.headers, "sec-websocket-key") orelse return error.InvalidRequest;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " \t"), "websocket") or !containsToken(connection, "upgrade")) return error.InvalidRequest;
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \t"), "13")) return error.UnsupportedVersion;
    try validateKey(key);
    if (singleHeader(request.headers, "sec-websocket-extensions")) |extensions| if (!config.allow_extensions and std.mem.trim(u8, extensions, " \t").len != 0) return error.ExtensionRejected;
    const origin = singleHeader(request.headers, "origin");
    if (config.allowed_origins.len != 0 and (origin == null or !containsExact(config.allowed_origins, origin.?))) return error.OriginRejected;
    const subprotocol = selectSubprotocol(config.allowed_subprotocols, singleHeader(request.headers, "sec-websocket-protocol"));
    const result = WebSocketUpgrade{ .accept_key = websocketAcceptKey(key), .subprotocol = subprotocol };
    if (config.callback) |callback| if (!callback(config.context, request)) return error.CallbackRejected;
    return result;
}

pub fn websocketUpgradeStatus(err: WebSocketUpgradeError) u16 {
    return switch (err) {
        error.OriginRejected, error.CallbackRejected => 403,
        error.UnsupportedVersion => 426,
        else => 400,
    };
}

pub fn websocket_accept_key(key: []const u8) [websocket_accept_key_bytes]u8 {
    return websocketAcceptKey(key);
}

pub fn encodeWebSocketUpgrade(response: WebSocketUpgrade, output: []u8) WebSocketUpgradeError![]u8 {
    const prefix = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ";
    var stream = std.io.fixedBufferStream(output);
    const writer = stream.writer();
    writer.writeAll(prefix) catch return error.InvalidConfiguration;
    writer.writeAll(&response.accept_key) catch return error.InvalidConfiguration;
    if (response.subprotocol) |subprotocol| {
        writer.writeAll("\r\nSec-WebSocket-Protocol: ") catch return error.InvalidConfiguration;
        writer.writeAll(subprotocol) catch return error.InvalidConfiguration;
    }
    writer.writeAll("\r\n\r\n") catch return error.InvalidConfiguration;
    return stream.getWritten();
}

fn singleHeader(headers: []const protocol.HttpHeader, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (result != null) return null;
        result = header.value;
    }
    return result;
}

fn validateKey(key: []const u8) WebSocketUpgradeError!void {
    var decoded: [16]u8 = undefined;
    const value = std.mem.trim(u8, key, " \t");
    const length = std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidRequest;
    if (length != decoded.len) return error.InvalidRequest;
    std.base64.standard.Decoder.decode(decoded[0..], value) catch return error.InvalidRequest;
}

fn websocketAcceptKey(key: []const u8) [websocket_accept_key_bytes]u8 {
    var input: [96]u8 = undefined;
    const value = std.mem.trim(u8, key, " \t");
    const source = std.fmt.bufPrint(input[0..], "{s}258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .{value}) catch unreachable;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(source, &digest, .{});
    var encoded: [websocket_accept_key_bytes]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(encoded[0..], &digest);
    return encoded;
}

fn containsToken(value: []const u8, expected: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), expected)) return true;
    return false;
}

fn containsExact(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn selectSubprotocol(allowed: []const []const u8, offered: ?[]const u8) ?[]const u8 {
    const value = offered orelse return null;
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (containsExact(allowed, trimmed)) return trimmed;
    }
    return null;
}

fn isTokenSlice(value: []const u8) bool {
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null)) return false;
    return true;
}

test "WebSocket upgrades validate policy and reject invalid requests before session creation" {
    const headers = [_]protocol.HttpHeader{ .{ .name = "Upgrade", .value = "websocket" }, .{ .name = "Connection", .value = "keep-alive, Upgrade" }, .{ .name = "Sec-WebSocket-Version", .value = "13" }, .{ .name = "Sec-WebSocket-Key", .value = "dGhlIHNhbXBsZSBub25jZQ==" }, .{ .name = "Origin", .value = "https://example.test" }, .{ .name = "Sec-WebSocket-Protocol", .value = "chat, superchat" } };
    const upgrade = try validateWebSocketUpgrade(.{ .allowed_origins = &.{"https://example.test"}, .allowed_subprotocols = &.{"superchat"} }, .{ .method = "GET", .headers = &headers });
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &upgrade.accept_key);
    try std.testing.expectEqualStrings("superchat", upgrade.subprotocol.?);
    const invalid = [_]protocol.HttpHeader{ .{ .name = "Upgrade", .value = "websocket" }, .{ .name = "Connection", .value = "Upgrade" }, .{ .name = "Sec-WebSocket-Version", .value = "12" }, .{ .name = "Sec-WebSocket-Key", .value = "dGhlIHNhbXBsZSBub25jZQ==" } };
    try std.testing.expectError(error.UnsupportedVersion, validateWebSocketUpgrade(.{}, .{ .method = "GET", .headers = &invalid }));
}
