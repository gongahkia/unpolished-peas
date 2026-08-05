const std = @import("std");
const capability = @import("capability_negotiation.zig");
const compression = @import("compression_provider.zig");

const min_match: usize = 4;
const final_literal_bytes: usize = 5;
const final_match_distance: usize = 12;
const hash_bits: usize = 12;
const hash_table_size: usize = 1 << hash_bits;

pub const max_lz4_block_bytes: usize = 65_507;
pub const Lz4BlockError = error{ InvalidConfiguration, InputTooLarge, BufferTooSmall, OutputTooSmall, MalformedBlock };

pub const Lz4BlockConfig = struct {
    maximum_uncompressed_bytes: usize = max_lz4_block_bytes,
    maximum_compressed_bytes: usize = max_lz4_block_bytes + 512,
};

pub const Lz4BlockCodec = struct {
    config: Lz4BlockConfig,
    table: [hash_table_size]?usize = .{null} ** hash_table_size,

    pub fn init(config: Lz4BlockConfig) Lz4BlockError!Lz4BlockCodec {
        if (config.maximum_uncompressed_bytes == 0 or config.maximum_compressed_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn provider(self: *Lz4BlockCodec) compression.CompressionProvider {
        return .{ .context = self, .codec = .lz4, .compress_fn = compress_provider, .decompress_fn = decompress_provider };
    }

    pub fn compress(self: *Lz4BlockCodec, input: []const u8, output: []u8) Lz4BlockError![]u8 {
        if (input.len > self.config.maximum_uncompressed_bytes) return error.InputTooLarge;
        self.table = .{null} ** hash_table_size;
        var writer = Writer{ .output = output, .limit = self.config.maximum_compressed_bytes };
        if (input.len < final_match_distance + 1) {
            try writer.sequence(input, null, 0);
            return writer.written();
        }

        var anchor: usize = 0;
        var index: usize = 0;
        const last_match_start = input.len - final_match_distance;
        while (index <= last_match_start) {
            const table_index = hash(input[index .. index + min_match]);
            const candidate = self.table[table_index];
            self.table[table_index] = index;
            if (candidate) |match_start| {
                const offset = index -| match_start;
                if (offset != 0 and offset <= std.math.maxInt(u16) and match_start + min_match <= input.len and std.mem.eql(u8, input[match_start .. match_start + min_match], input[index .. index + min_match])) {
                    var match_length: usize = min_match;
                    while (index + match_length < input.len - final_literal_bytes and input[match_start + match_length] == input[index + match_length]) : (match_length += 1) {}
                    try writer.sequence(input[anchor..index], @intCast(offset), match_length);
                    const match_end = index + match_length;
                    var update_index = index + 1;
                    while (update_index + min_match <= match_end) : (update_index += 1) self.table[hash(input[update_index .. update_index + min_match])] = update_index;
                    index = match_end;
                    anchor = match_end;
                    continue;
                }
            }
            index += 1;
        }
        try writer.sequence(input[anchor..], null, 0);
        return writer.written();
    }

    pub fn decompress(self: Lz4BlockCodec, input: []const u8, output: []u8) Lz4BlockError![]u8 {
        if (input.len > self.config.maximum_compressed_bytes) return error.InputTooLarge;
        var input_index: usize = 0;
        var output_index: usize = 0;
        var saw_match = false;
        var last_match_start: usize = 0;
        while (input_index < input.len) {
            const token = input[input_index];
            input_index += 1;
            const literal_length = try decode_length(token >> 4, input, &input_index);
            if (literal_length > input.len -| input_index) return error.MalformedBlock;
            try copy_literals(input[input_index .. input_index + literal_length], output, &output_index, self.config.maximum_uncompressed_bytes);
            input_index += literal_length;
            if (input_index == input.len) {
                if (output_index >= final_literal_bytes and literal_length < final_literal_bytes) return error.MalformedBlock;
                if (saw_match and (output_index < final_match_distance or last_match_start > output_index - final_match_distance)) return error.MalformedBlock;
                return output[0..output_index];
            }
            if (input.len - input_index < 2) return error.MalformedBlock;
            const offset = @as(u16, input[input_index]) | (@as(u16, input[input_index + 1]) << 8);
            input_index += 2;
            if (offset == 0 or offset > output_index) return error.MalformedBlock;
            const match_length = std.math.add(usize, try decode_length(token & 0x0f, input, &input_index), min_match) catch return error.MalformedBlock;
            last_match_start = output_index;
            saw_match = true;
            try copy_match(output, &output_index, offset, match_length, self.config.maximum_uncompressed_bytes);
        }
        return error.MalformedBlock;
    }

    fn compress_provider(context: *anyopaque, input: []const u8, dictionary: ?compression.CompressionDictionary, output: []u8) compression.CompressionProviderError![]u8 {
        if (dictionary != null) return error.DictionaryRejected;
        const self: *Lz4BlockCodec = @ptrCast(@alignCast(context));
        return self.compress(input, output) catch |err| switch (err) {
            error.BufferTooSmall => error.BufferTooSmall,
            else => error.CompressionFailed,
        };
    }

    fn decompress_provider(context: *anyopaque, input: []const u8, dictionary: ?compression.CompressionDictionary, output: []u8) compression.CompressionProviderError![]u8 {
        if (dictionary != null) return error.DictionaryRejected;
        const self: *Lz4BlockCodec = @ptrCast(@alignCast(context));
        return self.decompress(input, output) catch |err| switch (err) {
            error.OutputTooSmall => error.BufferTooSmall,
            else => error.DecompressionFailed,
        };
    }
};

const Writer = struct {
    output: []u8,
    limit: usize,
    index: usize = 0,

    fn sequence(self: *Writer, literals: []const u8, offset: ?u16, match_length: usize) Lz4BlockError!void {
        const match_extra = if (offset == null) 0 else match_length - min_match;
        const token: u8 = @as(u8, @intCast(@min(literals.len, 15))) << 4 | @as(u8, @intCast(@min(match_extra, 15)));
        try self.write_byte(token);
        if (literals.len >= 15) try self.write_length(literals.len - 15);
        try self.write(literals);
        if (offset) |value| {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, bytes[0..], value, .little);
            try self.write(bytes[0..]);
            if (match_extra >= 15) try self.write_length(match_extra - 15);
        }
    }

    fn write_length(self: *Writer, length: usize) Lz4BlockError!void {
        var remaining = length;
        while (remaining >= 255) {
            try self.write_byte(255);
            remaining -= 255;
        }
        try self.write_byte(@intCast(remaining));
    }

    fn write_byte(self: *Writer, value: u8) Lz4BlockError!void {
        if (self.index == self.output.len or self.index == self.limit) return error.BufferTooSmall;
        self.output[self.index] = value;
        self.index += 1;
    }

    fn write(self: *Writer, value: []const u8) Lz4BlockError!void {
        const end = std.math.add(usize, self.index, value.len) catch return error.BufferTooSmall;
        if (end > self.output.len or end > self.limit) return error.BufferTooSmall;
        @memcpy(self.output[self.index..end], value);
        self.index = end;
    }

    fn written(self: *Writer) []u8 {
        return self.output[0..self.index];
    }
};

fn hash(bytes: []const u8) usize {
    const value = std.mem.readInt(u32, bytes[0..min_match], .little);
    return @intCast((value *% 2_654_435_761) >> @as(u5, @intCast(32 - hash_bits)));
}

fn decode_length(nibble: u8, input: []const u8, input_index: *usize) Lz4BlockError!usize {
    var length: usize = nibble;
    if (nibble != 15) return length;
    while (true) {
        if (input_index.* == input.len) return error.MalformedBlock;
        const extension = input[input_index.*];
        input_index.* += 1;
        length = std.math.add(usize, length, extension) catch return error.MalformedBlock;
        if (extension != 255) return length;
    }
}

fn copy_literals(input: []const u8, output: []u8, output_index: *usize, maximum_output: usize) Lz4BlockError!void {
    const end = std.math.add(usize, output_index.*, input.len) catch return error.OutputTooSmall;
    if (end > output.len or end > maximum_output) return error.OutputTooSmall;
    @memcpy(output[output_index.*..end], input);
    output_index.* = end;
}

fn copy_match(output: []u8, output_index: *usize, offset: u16, length: usize, maximum_output: usize) Lz4BlockError!void {
    const end = std.math.add(usize, output_index.*, length) catch return error.OutputTooSmall;
    if (end > output.len or end > maximum_output) return error.OutputTooSmall;
    const source = output_index.* - offset;
    for (0..length) |index| output[output_index.* + index] = output[source + index];
    output_index.* = end;
}

test "LZ4 block codec emits compressed matches and round-trips through the provider" {
    const source = "abcabcabcabcabcabcXYZ";
    var codec = try Lz4BlockCodec.init(.{ .maximum_uncompressed_bytes = source.len, .maximum_compressed_bytes = source.len + 8 });
    var compressed: [source.len + 8]u8 = undefined;
    const encoded = try codec.compress(source, compressed[0..]);
    try std.testing.expect(encoded.len < source.len);
    var decoded: [source.len]u8 = undefined;
    try std.testing.expectEqualStrings(source, try codec.decompress(encoded, decoded[0..]));
    const literals = "abcdefghijklmnopqrst";
    var literal_codec = try Lz4BlockCodec.init(.{ .maximum_uncompressed_bytes = literals.len, .maximum_compressed_bytes = literals.len + 2 });
    var literal_block: [literals.len + 2]u8 = undefined;
    const literal_encoded = try literal_codec.compress(literals, literal_block[0..]);
    var literal_decoded: [literals.len]u8 = undefined;
    try std.testing.expectEqualStrings(literals, try literal_codec.decompress(literal_encoded, literal_decoded[0..]));
    var session = try compression.CompressionSession.init(.lz4, .{ .maximum_uncompressed_bytes = source.len, .maximum_compressed_bytes = source.len + 8, .maximum_expansion_ratio = 32 }, codec.provider());
    var framed: [compression.compression_header_bytes + source.len + 8]u8 = undefined;
    const packet = try session.compress(source, framed[0..]);
    try std.testing.expectEqualStrings(source, try session.decompress(packet, decoded[0..]));
}

test "LZ4 block codec accepts literal blocks and rejects malformed bounded data" {
    var codec = try Lz4BlockCodec.init(.{ .maximum_uncompressed_bytes = 10, .maximum_compressed_bytes = 10 });
    var output: [5]u8 = undefined;
    var extended_output: [10]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try codec.decompress(&.{ 0x50, 'h', 'e', 'l', 'l', 'o' }, output[0..]));
    try std.testing.expectError(error.MalformedBlock, codec.decompress(&.{ 0, 0, 0 }, output[0..]));
    try std.testing.expectError(error.MalformedBlock, codec.decompress(&.{ 0x10, 'a', 1, 0, 0x50, 'b', 'c', 'd', 'e', 'f' }, extended_output[0..]));
    try std.testing.expectError(error.InputTooLarge, codec.compress("hello world", output[0..]));
    try std.testing.expectError(error.OutputTooSmall, codec.decompress(&.{ 0x50, 'h', 'e', 'l', 'l', 'o' }, output[0..4]));
}
