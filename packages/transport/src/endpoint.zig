const std = @import("std");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");

pub const max_endpoint_hostname_bytes: usize = 253;
pub const max_provider_endpoint_bytes: usize = 64;
pub const max_endpoint_text_bytes: usize = max_endpoint_hostname_bytes + "provider:".len;
pub const EndpointKind = enum(u32) { ipv4 = 1, ipv6 = 2, dns = 3, provider = 4 };
pub const EndpointError = error{ InvalidLiteral, InvalidHostname, InvalidProviderEndpoint, InvalidEndpoint, OutputTooSmall };

pub const Endpoint = struct {
    kind: EndpointKind,
    port: u16,
    scope_id: u32 = 0,
    address: [16]u8 = [_]u8{0} ** 16,
    name_len: u16 = 0,
    name: [max_endpoint_hostname_bytes]u8 = [_]u8{0} ** max_endpoint_hostname_bytes,

    pub fn parse(value: []const u8, port: u16) EndpointError!Endpoint {
        const literal = strip_ipv6_brackets(value) orelse return error.InvalidLiteral;
        if (std.mem.startsWith(u8, literal, "provider:")) return from_provider(literal["provider:".len..], port);
        if (ipv4.Ipv4Address.parse(literal, port)) |address| return from_ipv4(address) else |_| {}
        if (ipv6.Ipv6Address.parse(literal, port)) |address| return from_ipv6(address) else |_| {}
        return from_hostname(literal, port);
    }

    pub fn from_ipv4(value: ipv4.Ipv4Address) Endpoint {
        var endpoint = Endpoint{ .kind = .ipv4, .port = value.port };
        @memcpy(endpoint.address[0..4], &value.octets);
        return endpoint;
    }

    pub fn from_ipv6(value: ipv6.Ipv6Address) Endpoint {
        return .{ .kind = .ipv6, .port = value.port, .scope_id = value.scope_id, .address = value.octets };
    }

    pub fn from_hostname(value: []const u8, port: u16) EndpointError!Endpoint {
        var endpoint = Endpoint{ .kind = .dns, .port = port };
        try canonicalize_hostname(value, &endpoint.name, &endpoint.name_len);
        return endpoint;
    }

    pub fn from_provider(value: []const u8, port: u16) EndpointError!Endpoint {
        var endpoint = Endpoint{ .kind = .provider, .port = port };
        if (value.len == 0 or value.len > max_provider_endpoint_bytes) return error.InvalidProviderEndpoint;
        for (value, 0..) |byte, index| {
            if (!is_provider_byte(byte)) return error.InvalidProviderEndpoint;
            endpoint.name[index] = std.ascii.toLower(byte);
        }
        endpoint.name_len = @intCast(value.len);
        return endpoint;
    }

    pub fn to_ipv4(self: Endpoint) ?ipv4.Ipv4Address {
        if (self.kind != .ipv4 or self.scope_id != 0 or self.name_len != 0 or !std.mem.allEqual(u8, self.address[4..], 0)) return null;
        return .{ .octets = self.address[0..4].*, .port = self.port };
    }

    pub fn to_ipv6(self: Endpoint) ?ipv6.Ipv6Address {
        if (self.kind != .ipv6 or self.name_len != 0) return null;
        return .{ .octets = self.address, .port = self.port, .scope_id = self.scope_id };
    }

    pub fn is_valid(self: Endpoint) bool {
        return switch (self.kind) {
            .ipv4 => self.to_ipv4() != null,
            .ipv6 => self.to_ipv6() != null,
            .dns => self.scope_id == 0 and std.mem.allEqual(u8, self.address[0..], 0) and hostname_is_canonical(self.name[0..self.name_len]),
            .provider => self.scope_id == 0 and std.mem.allEqual(u8, self.address[0..], 0) and self.name_len > 0 and self.name_len <= max_provider_endpoint_bytes and provider_is_canonical(self.name[0..self.name_len]),
        };
    }

    pub fn eql(left: Endpoint, right: Endpoint) bool {
        if (left.kind != right.kind or left.port != right.port or left.scope_id != right.scope_id) return false;
        return switch (left.kind) {
            .ipv4 => std.mem.eql(u8, left.address[0..4], right.address[0..4]),
            .ipv6 => std.mem.eql(u8, left.address[0..], right.address[0..]),
            .dns, .provider => left.name_len == right.name_len and std.mem.eql(u8, left.name[0..left.name_len], right.name[0..right.name_len]),
        };
    }

    pub fn format(self: Endpoint, output: []u8) EndpointError![]const u8 {
        if (!self.is_valid()) return error.InvalidEndpoint;
        return switch (self.kind) {
            .ipv4 => format_ipv4(self.address[0..4], output),
            .ipv6 => format_ipv6(self.address, self.scope_id, output),
            .dns => copy_text(self.name[0..self.name_len], output),
            .provider => format_provider(self.name[0..self.name_len], output),
        };
    }
};

fn strip_ipv6_brackets(value: []const u8) ?[]const u8 {
    if (value.len == 0) return value;
    const opens = value[0] == '[';
    const closes = value[value.len - 1] == ']';
    if (opens != closes) return null;
    return if (opens) value[1 .. value.len - 1] else value;
}

fn canonicalize_hostname(value: []const u8, output: *[max_endpoint_hostname_bytes]u8, output_len: *u16) EndpointError!void {
    const hostname = if (value.len > 0 and value[value.len - 1] == '.') value[0 .. value.len - 1] else value;
    if (hostname.len == 0 or hostname.len > max_endpoint_hostname_bytes) return error.InvalidHostname;
    var label_len: usize = 0;
    for (hostname, 0..) |byte, index| {
        if (byte == '.') {
            if (label_len == 0 or label_len > 63 or hostname[index - 1] == '-') return error.InvalidHostname;
            output[index] = byte;
            label_len = 0;
            continue;
        }
        if (!is_hostname_byte(byte) or (label_len == 0 and byte == '-')) return error.InvalidHostname;
        output[index] = std.ascii.toLower(byte);
        label_len += 1;
    }
    if (label_len == 0 or label_len > 63 or hostname[hostname.len - 1] == '-') return error.InvalidHostname;
    output_len.* = @intCast(hostname.len);
}

fn hostname_is_canonical(value: []const u8) bool {
    if (value.len == 0 or value.len > max_endpoint_hostname_bytes) return false;
    var label_len: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte == '.') {
            if (label_len == 0 or label_len > 63 or value[index - 1] == '-') return false;
            label_len = 0;
            continue;
        }
        if (!is_hostname_byte(byte) or std.ascii.isUpper(byte) or (label_len == 0 and byte == '-')) return false;
        label_len += 1;
    }
    return label_len > 0 and label_len <= 63 and value[value.len - 1] != '-';
}

fn provider_is_canonical(value: []const u8) bool {
    for (value) |byte| if (!is_provider_byte(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

fn is_hostname_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-';
}

fn is_provider_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

fn copy_text(input: []const u8, output: []u8) EndpointError![]const u8 {
    if (output.len < input.len) return error.OutputTooSmall;
    @memcpy(output[0..input.len], input);
    return output[0..input.len];
}

fn format_provider(name: []const u8, output: []u8) EndpointError![]const u8 {
    if (output.len < "provider:".len + name.len) return error.OutputTooSmall;
    @memcpy(output[0.."provider:".len], "provider:");
    @memcpy(output["provider:".len .. "provider:".len + name.len], name);
    return output[0 .. "provider:".len + name.len];
}

fn format_ipv4(address: []const u8, output: []u8) EndpointError![]const u8 {
    return std.fmt.bufPrint(output, "{d}.{d}.{d}.{d}", .{ address[0], address[1], address[2], address[3] }) catch error.OutputTooSmall;
}

fn format_ipv6(address: [16]u8, scope_id: u32, output: []u8) EndpointError![]const u8 {
    var groups: [8]u16 = undefined;
    for (0..groups.len) |index| groups[index] = (@as(u16, address[index * 2]) << 8) | address[index * 2 + 1];
    var longest_start: usize = groups.len;
    var longest_len: usize = 0;
    var current_start: usize = 0;
    var current_len: usize = 0;
    for (groups, 0..) |group, index| {
        if (group == 0) {
            if (current_len == 0) current_start = index;
            current_len += 1;
            if (current_len > longest_len) {
                longest_start = current_start;
                longest_len = current_len;
            }
        } else current_len = 0;
    }
    if (longest_len < 2) {
        longest_start = groups.len;
        longest_len = 0;
    }
    var used: usize = 0;
    var index: usize = 0;
    var emitted = false;
    var compressed = false;
    while (index < groups.len) {
        if (index == longest_start) {
            try append_text(output, &used, "::");
            emitted = true;
            compressed = true;
            index += longest_len;
            continue;
        }
        if (emitted and !compressed) try append_text(output, &used, ":");
        const group_text = std.fmt.bufPrint(output[used..], "{x}", .{groups[index]}) catch return error.OutputTooSmall;
        used += group_text.len;
        emitted = true;
        compressed = false;
        index += 1;
    }
    if (scope_id != 0) {
        try append_text(output, &used, "%");
        const scope_text = std.fmt.bufPrint(output[used..], "{d}", .{scope_id}) catch return error.OutputTooSmall;
        used += scope_text.len;
    }
    return output[0..used];
}

fn append_text(output: []u8, used: *usize, text: []const u8) EndpointError!void {
    if (output.len - used.* < text.len) return error.OutputTooSmall;
    @memcpy(output[used.* .. used.* + text.len], text);
    used.* += text.len;
}

test "canonical endpoints parse equivalent IPv6 and DNS forms" {
    const ipv6_first = try Endpoint.parse("2001:0DB8:0:0:0:0:0:1", 443);
    const ipv6_second = try Endpoint.parse("[2001:db8::1]", 443);
    const dns_first = try Endpoint.parse("Api.Example.COM.", 443);
    const dns_second = try Endpoint.parse("api.example.com", 443);
    var output: [max_endpoint_text_bytes]u8 = undefined;
    try std.testing.expect(ipv6_first.eql(ipv6_second));
    try std.testing.expectEqualStrings("2001:db8::1", try ipv6_first.format(output[0..]));
    try std.testing.expect(dns_first.eql(dns_second));
    try std.testing.expectEqualStrings("api.example.com", try dns_first.format(output[0..]));
}

test "canonical endpoints preserve IPv4 providers ports and bounded hostnames" {
    const ip = try Endpoint.parse("127.0.0.1", 0);
    const provider = try Endpoint.parse("provider:MsQuic", 444);
    var output: [max_endpoint_text_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 0), ip.port);
    try std.testing.expectEqual(ipv4.Ipv4Address{ .octets = .{ 127, 0, 0, 1 }, .port = 0 }, ip.to_ipv4().?);
    try std.testing.expectEqualStrings("provider:msquic", try provider.format(output[0..]));
    try std.testing.expectError(error.InvalidHostname, Endpoint.parse("-invalid.example", 1));
    try std.testing.expectError(error.InvalidHostname, Endpoint.parse("a..example", 1));
    try std.testing.expectError(error.InvalidProviderEndpoint, Endpoint.parse("provider:too.long/", 1));
}
