const std = @import("std");

pub const max_ack_ranges: usize = 32;
pub const AckRangeError = error{ RangeCapacityExceeded, InvalidRange, BufferTooSmall, MalformedEncoding };

pub const AckRange = struct {
    first: u32,
    last: u32,

    pub fn contains(self: AckRange, sequence: u32) bool {
        return sequence >= self.first and sequence <= self.last;
    }
};

pub const AckRanges = struct {
    ranges: [max_ack_ranges]AckRange = undefined,
    count: usize = 0,

    pub fn insert(self: *AckRanges, sequence: u32) AckRangeError!void {
        var position: usize = 0;
        while (position < self.count and self.ranges[position].first < sequence) : (position += 1) {}
        if (position > 0 and self.ranges[position - 1].contains(sequence)) return;
        if (position < self.count and self.ranges[position].contains(sequence)) return;
        if (self.count == max_ack_ranges) return error.RangeCapacityExceeded;
        var index = self.count;
        while (index > position) : (index -= 1) self.ranges[index] = self.ranges[index - 1];
        self.ranges[position] = .{ .first = sequence, .last = sequence };
        self.count += 1;
        self.merge_at(position);
    }

    pub fn encode(self: AckRanges, output: []u8) AckRangeError![]u8 {
        const total = 1 + self.count * 8;
        if (output.len < total) return error.BufferTooSmall;
        output[0] = @intCast(self.count);
        for (self.ranges[0..self.count], 0..) |range, index| {
            write_u32(output, 1 + index * 8, range.first);
            write_u32(output, 5 + index * 8, range.last);
        }
        return output[0..total];
    }

    pub fn decode(input: []const u8) AckRangeError!AckRanges {
        if (input.len == 0) return error.MalformedEncoding;
        const count: usize = input[0];
        if (count > max_ack_ranges or input.len != 1 + count * 8) return error.MalformedEncoding;
        var result = AckRanges{};
        for (0..count) |index| {
            const range = AckRange{
                .first = read_u32(input, 1 + index * 8),
                .last = read_u32(input, 5 + index * 8),
            };
            if (range.first > range.last or (index > 0 and result.ranges[index - 1].last >= range.first)) return error.InvalidRange;
            result.ranges[index] = range;
            result.count += 1;
        }
        return result;
    }

    fn merge_at(self: *AckRanges, position: usize) void {
        var index = if (position > 0) position - 1 else position;
        while (index + 1 < self.count) {
            const left = self.ranges[index];
            const right = self.ranges[index + 1];
            if (left.last != std.math.maxInt(u32) and left.last + 1 >= right.first) {
                self.ranges[index].last = @max(left.last, right.last);
                var shift = index + 1;
                while (shift + 1 < self.count) : (shift += 1) self.ranges[shift] = self.ranges[shift + 1];
                self.count -= 1;
            } else index += 1;
        }
    }
};

fn write_u32(output: []u8, offset: usize, value: u32) void {
    const bytes: *[4]u8 = @ptrCast(output[offset..].ptr);
    std.mem.writeInt(u32, bytes, value, .big);
}

fn read_u32(input: []const u8, offset: usize) u32 {
    const bytes: *const [4]u8 = @ptrCast(input[offset..].ptr);
    return std.mem.readInt(u32, bytes, .big);
}

test "acknowledgement ranges merge and round-trip through canonical encoding" {
    var ranges = AckRanges{};
    try ranges.insert(7);
    try ranges.insert(5);
    try ranges.insert(6);
    try ranges.insert(10);
    try std.testing.expectEqual(@as(usize, 2), ranges.count);
    try std.testing.expectEqual(AckRange{ .first = 5, .last = 7 }, ranges.ranges[0]);
    var storage: [17]u8 = undefined;
    const decoded = try AckRanges.decode(try ranges.encode(storage[0..]));
    try std.testing.expectEqual(ranges.count, decoded.count);
    try std.testing.expectEqual(ranges.ranges[0], decoded.ranges[0]);
}

test "acknowledgement ranges reject malformed and overlapping encodings" {
    try std.testing.expectError(error.MalformedEncoding, AckRanges.decode(&.{}));
    var malformed: [9]u8 = .{0} ** 9;
    malformed[0] = 1;
    std.mem.writeInt(u32, malformed[1..5], 2, .big);
    std.mem.writeInt(u32, malformed[5..9], 1, .big);
    try std.testing.expectError(error.InvalidRange, AckRanges.decode(malformed[0..]));
}
