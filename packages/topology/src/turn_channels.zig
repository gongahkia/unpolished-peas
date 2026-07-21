const std = @import("std");
const protocol = @import("minna-san-protocol");

pub const turn_channel_min: u16 = 0x4000;
pub const turn_channel_max: u16 = 0x7fff;
pub const turn_channel_header_bytes: usize = 4;
pub const TurnChannelError = std.mem.Allocator.Error || error{ InvalidConfiguration, InvalidChannel, ChannelCapacityExceeded, ChannelCollision, PeerAlreadyBound, UnknownChannel, BufferTooSmall, MalformedChannelData };
pub const TurnChannelConfig = struct { maximum_channels: usize };
pub const TurnChannelBinding = struct { number: u16, peer: protocol.StunAddress };
pub const TurnChannelData = struct { number: u16, payload: []const u8 };

pub const TurnChannels = struct {
    allocator: std.mem.Allocator,
    config: TurnChannelConfig,
    bindings: std.ArrayListUnmanaged(TurnChannelBinding) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: TurnChannelConfig) TurnChannelError!TurnChannels {
        if (config.maximum_channels == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *TurnChannels) void {
        self.bindings.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn bind(self: *TurnChannels, value: TurnChannelBinding) TurnChannelError!void {
        if (value.number < turn_channel_min or value.number > turn_channel_max) return error.InvalidChannel;
        if (self.by_number(value.number) != null) return error.ChannelCollision;
        for (self.bindings.items) |existing| if (std.meta.eql(existing.peer, value.peer)) return error.PeerAlreadyBound;
        if (self.bindings.items.len == self.config.maximum_channels) return error.ChannelCapacityExceeded;
        try self.bindings.append(self.allocator, value);
    }
    pub fn unbind(self: *TurnChannels, number: u16) TurnChannelError!void {
        const index = self.index_of(number) orelse return error.UnknownChannel;
        _ = self.bindings.orderedRemove(index);
    }
    pub fn unbind_peer(self: *TurnChannels, peer: protocol.StunAddress) bool {
        for (self.bindings.items, 0..) |entry, index| {
            if (!std.meta.eql(entry.peer, peer)) continue;
            _ = self.bindings.orderedRemove(index);
            return true;
        }
        return false;
    }
    pub fn clear(self: *TurnChannels) void {
        self.bindings.clearRetainingCapacity();
    }
    pub fn count(self: TurnChannels) usize {
        return self.bindings.items.len;
    }
    pub fn binding_for_peer(self: TurnChannels, peer: protocol.StunAddress) ?TurnChannelBinding {
        for (self.bindings.items) |entry| if (std.meta.eql(entry.peer, peer)) return entry;
        return null;
    }
    pub fn binding(self: TurnChannels, number: u16) ?TurnChannelBinding {
        const index = self.index_of(number) orelse return null;
        return self.bindings.items[index];
    }
    pub fn encode(self: TurnChannels, data: TurnChannelData, output: []u8) TurnChannelError![]u8 {
        if (self.binding(data.number) == null) return error.UnknownChannel;
        if (data.payload.len > std.math.maxInt(u16) or output.len < turn_channel_header_bytes + data.payload.len) return error.BufferTooSmall;
        std.mem.writeInt(u16, output[0..2], data.number, .big);
        std.mem.writeInt(u16, output[2..4], @intCast(data.payload.len), .big);
        @memcpy(output[4..][0..data.payload.len], data.payload);
        return output[0 .. 4 + data.payload.len];
    }
    pub fn decode(self: TurnChannels, input: []const u8) TurnChannelError!TurnChannelData {
        if (input.len < 4) return error.MalformedChannelData;
        const number = std.mem.readInt(u16, input[0..2], .big);
        const length: usize = std.mem.readInt(u16, input[2..4], .big);
        if (input.len != 4 + length) return error.MalformedChannelData;
        if (self.binding(number) == null) return error.UnknownChannel;
        return .{ .number = number, .payload = input[4..] };
    }
    fn index_of(self: TurnChannels, number: u16) ?usize {
        for (self.bindings.items, 0..) |value, index| if (value.number == number) return index;
        return null;
    }
    fn by_number(self: TurnChannels, number: u16) ?TurnChannelBinding {
        const index = self.index_of(number) orelse return null;
        return self.bindings.items[index];
    }
};

test "TURN channels bind frame and cleanly unbind peers" {
    var channels = try TurnChannels.init(std.testing.allocator, .{ .maximum_channels = 1 });
    defer channels.deinit();
    const peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 1, 2, 3, 4 }, .port = 9 } };
    try channels.bind(.{ .number = turn_channel_min, .peer = peer });
    var bytes: [7]u8 = undefined;
    const encoded = try channels.encode(.{ .number = turn_channel_min, .payload = "abc" }, bytes[0..]);
    try std.testing.expectEqualStrings("abc", (try channels.decode(encoded)).payload);
    try std.testing.expectError(error.ChannelCollision, channels.bind(.{ .number = turn_channel_min, .peer = peer }));
    try channels.unbind(turn_channel_min);
    try std.testing.expectError(error.UnknownChannel, channels.decode(encoded));
}

test "TURN channels reject invalid bounded collisions and malformed frames" {
    var channels = try TurnChannels.init(std.testing.allocator, .{ .maximum_channels = 1 });
    defer channels.deinit();
    const first = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } };
    const second = protocol.StunAddress{ .ipv6 = .{ .octets = .{0} ** 15 ++ .{1}, .port = 2 } };
    try std.testing.expectError(error.InvalidChannel, channels.bind(.{ .number = turn_channel_min - 1, .peer = first }));
    try channels.bind(.{ .number = turn_channel_min, .peer = first });
    try std.testing.expectError(error.PeerAlreadyBound, channels.bind(.{ .number = turn_channel_min + 1, .peer = first }));
    try std.testing.expectError(error.ChannelCapacityExceeded, channels.bind(.{ .number = turn_channel_min + 1, .peer = second }));
    try std.testing.expectError(error.MalformedChannelData, channels.decode(&.{ 0, 1 }));
}

test "bounded TURN channel-data fuzz corpus retains binding and frame limits" {
    var channels = try TurnChannels.init(std.testing.allocator, .{ .maximum_channels = 1 });
    defer channels.deinit();
    try channels.bind(.{ .number = turn_channel_min, .peer = .{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 3478 } } });
    var prng = std.Random.DefaultPrng.init(0xc762_5e18_39ab_d40f);
    const random = prng.random();
    var input: [128]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        const length = random.uintLessThan(usize, input.len + 1);
        random.bytes(input[0..length]);
        if (channels.decode(input[0..length]) catch null) |frame| {
            try std.testing.expectEqual(turn_channel_min, frame.number);
            try std.testing.expectEqual(length - turn_channel_header_bytes, frame.payload.len);
        }
    }
    var encoded: [7]u8 = undefined;
    const frame = try channels.encode(.{ .number = turn_channel_min, .payload = "abc" }, encoded[0..]);
    try std.testing.expectEqualStrings("abc", (try channels.decode(frame)).payload);
    encoded[2] = 0;
    encoded[3] = 4;
    try std.testing.expectError(error.MalformedChannelData, channels.decode(encoded[0..]));
}
