const std = @import("std");
const protocol = @import("minna-san-protocol");
const runtime = @import("minna-san-runtime");

fn exerciseHttp(input: []const u8) !void {
    var parser = try protocol.HttpParser.init(.{ .kind = .request, .maximum_start_line_bytes = 32, .maximum_header_bytes = 64, .maximum_headers = 4, .maximum_body_bytes = 8 });
    var offset: usize = 0;
    var steps: usize = 0;
    while (offset < input.len and steps < input.len + 1) : (steps += 1) {
        const result = parser.feed(input[offset..]) catch break;
        try std.testing.expect(result.consumed <= input.len - offset);
        if (result.consumed == 0) break;
        offset += result.consumed;
    }
    try std.testing.expect(offset <= input.len);
    try std.testing.expect(steps <= input.len + 1);
}

fn exerciseWebSocket(input: []const u8) !void {
    var parser = try protocol.WebSocketFrameParser.init(std.testing.allocator, .{ .endpoint = .server, .maximum_frame_bytes = 16, .maximum_chunk_bytes = 8 });
    defer parser.deinit();
    try std.testing.expectEqual(@as(usize, 8), parser.chunk.len);
    var offset: usize = 0;
    var steps: usize = 0;
    const limit = input.len * 3 + 3;
    while (offset < input.len and steps < limit) : (steps += 1) {
        const result = parser.feed(input[offset..]) catch break;
        try std.testing.expect(result.consumed <= input.len - offset);
        offset += result.consumed;
        if (result.consumed == 0 and result.event == null) break;
    }
    try std.testing.expect(offset <= input.len);
    try std.testing.expect(offset == input.len or steps < limit);
}

fn exerciseUpgrade(input: []const u8) void {
    var headers = [_]protocol.HttpHeader{
        .{ .name = "Upgrade", .value = "websocket" },
        .{ .name = "Connection", .value = "Upgrade" },
        .{ .name = "Sec-WebSocket-Version", .value = "13" },
        .{ .name = "Sec-WebSocket-Key", .value = "dGhlIHNhbXBsZSBub25jZQ==" },
        .{ .name = "Sec-WebSocket-Extensions", .value = "" },
    };
    if (input.len != 0) {
        const index = input[0] % headers.len;
        headers[index].value = input;
    }
    _ = runtime.validate_websocket_upgrade(.{}, .{ .method = if (input.len % 2 == 0) "GET" else input, .headers = &headers }) catch {};
}

test "bounded HTTP and WebSocket parser fuzz corpus terminates within configured limits" {
    const http_fixtures = [_][]const u8{
        "GET /chat HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: 18446744073709551615\r\n\r\n",
        "GET / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n",
    };
    const http2_fixtures = [_][]const u8{
        "\x00\x00\x00\x04\x01\x00\x00\x00\x00",
        "\xff\xff\xff\x00\x00\x00\x00\x00\x01",
        "\x00\x00\x00\x09\x04\x00\x00\x00\x00",
        "\x00\x00\x06\x04\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x02",
    };
    const websocket_fixtures = [_][]const u8{
        "\x81\x82\x01\x02\x03\x04ik",
        "\x01\x81\x01\x02\x03\x04i\x80\x81\x01\x02\x03\x04h",
        "\x80\x80\x01\x02\x03\x04",
        "\x82\xff\x80\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04",
    };
    for (http_fixtures) |fixture| try exerciseHttp(fixture);
    for (http2_fixtures) |fixture| _ = protocol.decode_http2_frame(.{}, fixture) catch {};
    for (websocket_fixtures) |fixture| try exerciseWebSocket(fixture);

    var random = std.Random.DefaultPrng.init(0x3c29_7d01_8ef4_b562);
    var input: [128]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        const source = random.random();
        const length = source.uintLessThan(usize, input.len + 1);
        source.bytes(input[0..length]);
        const bytes = input[0..length];
        try exerciseHttp(bytes);
        _ = protocol.decode_http2_frame(.{}, bytes) catch {};
        _ = protocol.decode_compression_frame(bytes) catch {};
        try exerciseWebSocket(bytes);
        exerciseUpgrade(bytes);
    }
}

test "HTTP and WebSocket fuzz targets retain valid upgrade and continuation fixtures" {
    const headers = [_]protocol.HttpHeader{ .{ .name = "Upgrade", .value = "websocket" }, .{ .name = "Connection", .value = "Upgrade" }, .{ .name = "Sec-WebSocket-Version", .value = "13" }, .{ .name = "Sec-WebSocket-Key", .value = "dGhlIHNhbXBsZSBub25jZQ==" } };
    _ = try runtime.validate_websocket_upgrade(.{}, .{ .method = "GET", .headers = &headers });
    try std.testing.expectError(error.ProtocolError, protocol.decode_http2_frame(.{}, "\x00\x00\x00\x09\x00\x00\x00\x00\x00"));
}
