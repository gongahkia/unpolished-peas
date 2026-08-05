const std = @import("std");
const protocol = @import("minna-san-protocol");
const runtime = @import("minna-san-runtime");

pub fn main() !void {
    var arguments = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer arguments.deinit();
    _ = arguments.next();
    const first = arguments.next() orelse return error.InvalidArguments;
    if (std.mem.eql(u8, first, "server")) return serve(arguments.next() orelse return error.InvalidArguments, arguments.next() orelse return error.InvalidArguments, arguments.next() orelse return error.InvalidArguments, arguments.next() == null);
    if (std.mem.eql(u8, first, "client")) return connect(arguments.next() orelse return error.InvalidArguments, arguments.next() orelse return error.InvalidArguments, arguments.next() orelse return error.InvalidArguments, arguments.next() == null);
    const certificate = first;
    const private_key = arguments.next() orelse return error.InvalidArguments;
    const trust_store = arguments.next() orelse return error.InvalidArguments;
    if (arguments.next() != null) return error.InvalidArguments;
    try verifyProtocol("http/1.1", certificate, private_key, trust_store, "GET /public HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\nGET /public HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try verifyProtocol("h2", certificate, private_key, trust_store, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n\x00\x00\x00\x04\x00\x00\x00\x00\x00");
    try verifyProtocol("http/1.1", certificate, private_key, trust_store, "GET /socket HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
    try std.fs.File.stdout().deprecatedWriter().writeAll("openssl-tls=verified-alpn-streaming-and-close\n");
}

fn connect(mode: []const u8, port_text: []const u8, trust_store: []const u8, no_extra_arguments: bool) !void {
    if (!no_extra_arguments) return error.InvalidArguments;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidArguments;
    var trust_store_path: [std.fs.max_path_bytes:0]u8 = undefined;
    const trust_store_z = try sentinelPath(trust_store_path[0..], trust_store);
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(socket);
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    try std.posix.connect(socket, &address.any, address.getOsSockLen());
    const alpn = if (std.mem.eql(u8, mode, "h2")) "h2" else "http/1.1";
    var provider = try runtime.OpenSslTlsProvider.init(.{ .tls = .{ .role = .client, .alpn = alpn, .server_name = "localhost" }, .trust_store_path = trust_store_z });
    defer provider.deinit();
    var stream = TlsSocket{ .socket = socket, .provider = &provider.provider };
    try stream.handshake();
    if (std.mem.eql(u8, mode, "http1")) return connectHttp1(&stream);
    if (std.mem.eql(u8, mode, "h2")) return connectHttp2(&stream);
    if (std.mem.eql(u8, mode, "ws")) return connectWebSocket(&stream);
    return error.InvalidArguments;
}

fn serve(mode: []const u8, certificate: []const u8, private_key: []const u8, no_extra_arguments: bool) !void {
    if (!no_extra_arguments) return error.InvalidArguments;
    var certificate_path: [std.fs.max_path_bytes:0]u8 = undefined;
    var private_key_path: [std.fs.max_path_bytes:0]u8 = undefined;
    const certificate_z = try sentinelPath(certificate_path[0..], certificate);
    const private_key_z = try sentinelPath(private_key_path[0..], private_key);
    const listener = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(listener);
    var address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    try std.posix.listen(listener, 1);
    var address_length = address.getOsSockLen();
    try std.posix.getsockname(listener, &address.any, &address_length);
    var line: [64]u8 = undefined;
    const port_line = try std.fmt.bufPrint(line[0..], "PORT={d}\n", .{address.in.getPort()});
    try std.fs.File.stdout().deprecatedWriter().writeAll(port_line);
    var peer = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var peer_length = peer.getOsSockLen();
    const socket = try std.posix.accept(listener, &peer.any, &peer_length, std.posix.SOCK.CLOEXEC);
    defer std.posix.close(socket);
    const alpn = if (std.mem.eql(u8, mode, "h2")) "h2" else "http/1.1";
    var provider = try runtime.OpenSslTlsProvider.init(.{ .tls = .{ .role = .server, .alpn = alpn, .server_name = "localhost" }, .certificate_path = certificate_z, .private_key_path = private_key_z });
    defer provider.deinit();
    var stream = TlsSocket{ .socket = socket, .provider = &provider.provider };
    try stream.handshake();
    if (std.mem.eql(u8, mode, "http1")) return serveHttp1(&stream);
    if (std.mem.eql(u8, mode, "h2")) return serveHttp2(&stream);
    if (std.mem.eql(u8, mode, "ws")) return serveWebSocket(&stream);
    return error.InvalidArguments;
}

const TlsSocket = struct {
    socket: std.posix.socket_t,
    provider: *runtime.TlsProvider,

    fn handshake(self: *TlsSocket) !void {
        try self.provider.start();
        var wire: [32 * 1024]u8 = undefined;
        var attempts: usize = 0;
        while (self.provider.state != .connected and attempts < 64) : (attempts += 1) {
            try self.flushRecords(wire[0..]);
            const received = try std.posix.recv(self.socket, wire[0..], 0);
            if (received == 0) return error.ConnectionClosed;
            _ = try self.provider.receiveRecord(wire[0..received]);
            if (self.provider.state == .handshaking) _ = try self.provider.poll(@intCast(attempts));
            try self.flushRecords(wire[0..]);
        }
        if (self.provider.state != .connected) return error.HandshakeFailed;
    }

    fn read(self: *TlsSocket, ciphertext: []u8, plaintext: []u8) ![]u8 {
        while (true) {
            const received = try std.posix.recv(self.socket, ciphertext, 0);
            if (received == 0) return error.ConnectionClosed;
            const result = try self.provider.decrypt(ciphertext[0..received], plaintext);
            if (result.len != 0) return result;
            const pending = try self.provider.decrypt(&.{}, plaintext);
            if (pending.len != 0) return pending;
        }
    }

    fn write(self: *TlsSocket, plaintext: []const u8, ciphertext: []u8) !void {
        const encrypted = try self.provider.encrypt(plaintext, ciphertext);
        try sendAll(self.socket, encrypted);
    }

    fn flushRecords(self: *TlsSocket, wire: []u8) !void {
        while (true) {
            const record = try self.provider.drainRecord(wire);
            if (record.len == 0) return;
            try sendAll(self.socket, record);
        }
    }
};

fn serveHttp1(stream: *TlsSocket) !void {
    const Fixture = struct {
        fn route(_: ?*anyopaque, request: runtime.ServiceRequest) runtime.ServiceModuleError!runtime.ServiceRouteResult {
            if (!std.mem.eql(u8, request.route, "/public")) return error.CallbackFailed;
            return .handled;
        }
    };
    var services = try runtime.ServiceRegistry.init(std.heap.page_allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var server = try runtime.HttpServerConnection.init(std.heap.page_allocator, .{ .services = &services, .parser = .{ .kind = .request, .maximum_body_bytes = 64 } });
    defer server.deinit();
    var ciphertext: [32 * 1024]u8 = undefined;
    var plaintext: [32 * 1024]u8 = undefined;
    const request = try stream.read(ciphertext[0..], plaintext[0..]);
    var offset: usize = 0;
    while (offset < request.len) {
        const result = try server.feed(request[offset..]);
        offset += result.consumed;
        if (result.event) |event| switch (event) {
            .response => |response| {
                var encoded: [128]u8 = undefined;
                try stream.write(try runtime.HttpServerConnection.encodeResponse(response, encoded[0..]), ciphertext[0..]);
                return;
            },
            else => {},
        };
        if (result.consumed == 0) break;
    }
    return error.InvalidRequest;
}

fn serveHttp2(stream: *TlsSocket) !void {
    const Fixture = struct {
        fn route(_: ?*anyopaque, request: runtime.ServiceRequest) runtime.ServiceModuleError!runtime.ServiceRouteResult {
            if (!std.mem.eql(u8, request.route, "/public")) return error.CallbackFailed;
            return .handled;
        }
    };
    var services = try runtime.ServiceRegistry.init(std.heap.page_allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var resources = try runtime.ResourceRegistry.init(std.heap.page_allocator, 1);
    defer resources.deinit();
    var session = try runtime.Http2ServerSession.init(std.heap.page_allocator, .{ .services = &services, .resources = &resources, .transport = .tls_alpn, .negotiated_alpn = "h2", .maximum_streams = 1 });
    defer session.deinit();
    var ciphertext: [32 * 1024]u8 = undefined;
    var plaintext: [32 * 1024]u8 = undefined;
    var outbound: [32 * 1024]u8 = undefined;
    while (true) {
        const input = try stream.read(ciphertext[0..], plaintext[0..]);
        const result = try session.feed(input);
        const response = try session.drain(outbound[0..]);
        if (response.len != 0) try stream.write(response, ciphertext[0..]);
        if (result.response != null) return;
    }
}

fn serveWebSocket(stream: *TlsSocket) !void {
    var ciphertext: [32 * 1024]u8 = undefined;
    var plaintext: [32 * 1024]u8 = undefined;
    const request = try stream.read(ciphertext[0..], plaintext[0..]);
    var headers: [8]protocol.HttpHeader = undefined;
    const parsed = try websocketRequest(request, headers[0..]);
    const upgrade = try runtime.validate_websocket_upgrade(.{}, .{ .method = parsed.method, .headers = parsed.headers });
    var response: [256]u8 = undefined;
    try stream.write(try runtime.encode_websocket_upgrade(upgrade, response[0..]), ciphertext[0..]);
}

fn connectHttp1(stream: *TlsSocket) !void {
    var client = try runtime.HttpClientConnection.init(std.heap.page_allocator, .{});
    defer client.deinit();
    var ciphertext: [32 * 1024]u8 = undefined;
    var plaintext: [32 * 1024]u8 = undefined;
    try stream.write(try client.begin(.{ .method = "GET", .target = "/public", .authority = "localhost", .close_after_response = true }), ciphertext[0..]);
    const response = try stream.read(ciphertext[0..], plaintext[0..]);
    var offset: usize = 0;
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        const parsed = try client.feed(response[offset..]);
        offset += parsed.consumed;
        if (parsed.event) |event| switch (event) {
            .response => |value| {
                if (value.status != 200) return error.InvalidResponse;
                return;
            },
            else => {},
        };
    }
    return error.InvalidResponse;
}

fn connectHttp2(stream: *TlsSocket) !void {
    var resources = try runtime.ResourceRegistry.init(std.heap.page_allocator, 1);
    defer resources.deinit();
    var session = try runtime.Http2ClientSession.init(std.heap.page_allocator, .{ .resources = &resources, .transport = .tls_alpn, .negotiated_alpn = "h2", .maximum_streams = 1 });
    defer session.deinit();
    var ciphertext: [32 * 1024]u8 = undefined;
    var plaintext: [32 * 1024]u8 = undefined;
    var outbound: [32 * 1024]u8 = undefined;
    try stream.write(try session.drain(outbound[0..]), ciphertext[0..]);
    _ = try session.feed(try stream.read(ciphertext[0..], plaintext[0..]));
    const acknowledgement = try session.drain(outbound[0..]);
    if (acknowledgement.len != 0) try stream.write(acknowledgement, ciphertext[0..]);
    _ = try session.begin(.{ .method = "GET", .target = "/public", .authority = "localhost" });
    try stream.write(try session.drain(outbound[0..]), ciphertext[0..]);
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const result = try session.feed(try stream.read(ciphertext[0..], plaintext[0..]));
        const pending = try session.drain(outbound[0..]);
        if (pending.len != 0) try stream.write(pending, ciphertext[0..]);
        if (result.response) |response| {
            if (response.status != 200) return error.InvalidResponse;
            return;
        }
    }
    return error.InvalidResponse;
}

fn connectWebSocket(stream: *TlsSocket) !void {
    var ciphertext: [32 * 1024]u8 = undefined;
    var plaintext: [32 * 1024]u8 = undefined;
    try stream.write("GET /socket HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", ciphertext[0..]);
    const response = try stream.read(ciphertext[0..], plaintext[0..]);
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 101 ")) return error.InvalidResponse;
}

fn websocketRequest(input: []const u8, output: []protocol.HttpHeader) !struct { method: []const u8, headers: []const protocol.HttpHeader } {
    const first_end = std.mem.indexOf(u8, input, "\r\n") orelse return error.InvalidRequest;
    const request_line = input[0..first_end];
    const method_end = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequest;
    var count: usize = 0;
    var offset = first_end + 2;
    while (offset < input.len) {
        const end = std.mem.indexOfPos(u8, input, offset, "\r\n") orelse return error.InvalidRequest;
        if (end == offset) break;
        if (count == output.len) return error.InvalidRequest;
        const colon = std.mem.indexOfScalarPos(u8, input, offset, ':') orelse return error.InvalidRequest;
        if (colon >= end) return error.InvalidRequest;
        output[count] = .{ .name = input[offset..colon], .value = std.mem.trim(u8, input[colon + 1 .. end], " ") };
        count += 1;
        offset = end + 2;
    }
    return .{ .method = request_line[0..method_end], .headers = output[0..count] };
}

fn sendAll(socket: std.posix.socket_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const written = try std.posix.send(socket, bytes[sent..], 0);
        if (written == 0) return error.WriteFailed;
        sent += written;
    }
}

fn verifyProtocol(alpn: []const u8, certificate: []const u8, private_key: []const u8, trust_store: []const u8, payload: []const u8) !void {
    var certificate_path: [std.fs.max_path_bytes:0]u8 = undefined;
    var private_key_path: [std.fs.max_path_bytes:0]u8 = undefined;
    var trust_store_path: [std.fs.max_path_bytes:0]u8 = undefined;
    const certificate_z = try sentinelPath(certificate_path[0..], certificate);
    const private_key_z = try sentinelPath(private_key_path[0..], private_key);
    const trust_store_z = try sentinelPath(trust_store_path[0..], trust_store);
    var client = try runtime.OpenSslTlsProvider.init(.{ .tls = .{ .role = .client, .alpn = alpn, .server_name = "localhost" }, .trust_store_path = trust_store_z });
    defer client.deinit();
    var server = try runtime.OpenSslTlsProvider.init(.{ .tls = .{ .role = .server, .alpn = alpn, .server_name = "localhost" }, .certificate_path = certificate_z, .private_key_path = private_key_z });
    defer server.deinit();
    try client.provider.start();
    try server.provider.start();
    var attempts: usize = 0;
    while ((client.provider.state != .connected or server.provider.state != .connected) and attempts < 64) : (attempts += 1) {
        try pump(&client.provider, &server.provider);
        if (client.provider.state == .handshaking) _ = try client.provider.poll(@intCast(attempts));
        if (server.provider.state == .handshaking) _ = try server.provider.poll(@intCast(attempts));
        try pump(&client.provider, &server.provider);
    }
    if (client.provider.state != .connected or server.provider.state != .connected) return error.HandshakeFailed;
    var selected: [8]u8 = undefined;
    if (!std.mem.eql(u8, alpn, try client.selectedAlpn(selected[0..])) or !std.mem.eql(u8, alpn, try server.selectedAlpn(selected[0..]))) return error.AlpnMismatch;
    var encrypted: [32 * 1024]u8 = undefined;
    var decrypted: [32 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const length = @min(@as(usize, 17), payload.len - offset);
        const ciphertext = try client.provider.encrypt(payload[offset .. offset + length], encrypted[0..]);
        const plaintext = try server.provider.decrypt(ciphertext, decrypted[0..]);
        if (!std.mem.eql(u8, payload[offset .. offset + length], plaintext)) return error.PayloadMismatch;
        offset += length;
    }
    const acknowledgement = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    const ciphertext = try server.provider.encrypt(acknowledgement, encrypted[0..]);
    const plaintext = try client.provider.decrypt(ciphertext, decrypted[0..]);
    if (!std.mem.eql(u8, acknowledgement, plaintext)) return error.PayloadMismatch;
}

fn pump(client: *runtime.TlsProvider, server: *runtime.TlsProvider) !void {
    try pumpOne(client, server);
    try pumpOne(server, client);
}

fn pumpOne(source: *runtime.TlsProvider, destination: *runtime.TlsProvider) !void {
    var wire: [32 * 1024]u8 = undefined;
    while (true) {
        const record = try source.drainRecord(wire[0..]);
        if (record.len == 0) return;
        if (try destination.receiveRecord(record) != record.len) return error.RecordTruncated;
    }
}

fn sentinelPath(buffer: []u8, value: []const u8) ![:0]const u8 {
    if (value.len >= buffer.len) return error.InvalidArguments;
    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = 0;
    return buffer[0..value.len :0];
}
