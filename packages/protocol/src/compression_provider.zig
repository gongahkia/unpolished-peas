const std = @import("std");
const capability = @import("capability_negotiation.zig");

pub const compression_header_bytes: usize = 10;
pub const CompressionProviderError = error{ CompressionFailed, DecompressionFailed, BufferTooSmall, DictionaryRejected };
pub const CompressionError = CompressionProviderError || error{ InvalidConfiguration, ProviderMismatch, CompressionDisabled, InputTooLarge, OutputTooLarge, MalformedFrame, CodecMismatch, DictionaryMismatch, ExpansionLimitExceeded, ProviderOutputMismatch, InvalidDictionary };

pub const CompressionConfig = struct {
    maximum_uncompressed_bytes: usize,
    maximum_compressed_bytes: usize,
    maximum_expansion_ratio: usize,
};

pub const CompressionDictionary = struct {
    identifier: u32,
    bytes: []const u8,
};

pub const CompressionFrame = struct {
    codec: capability.CompressionCapability,
    dictionary_id: u32,
    uncompressed_length: usize,
    payload: []const u8,
};

pub const CompressionProvider = struct {
    context: *anyopaque,
    codec: capability.CompressionCapability,
    compress_fn: *const fn (*anyopaque, []const u8, ?CompressionDictionary, []u8) CompressionProviderError![]u8,
    decompress_fn: *const fn (*anyopaque, []const u8, ?CompressionDictionary, []u8) CompressionProviderError![]u8,

    pub fn compress(self: CompressionProvider, input: []const u8, dictionary: ?CompressionDictionary, output: []u8) CompressionProviderError![]u8 {
        return self.compress_fn(self.context, input, dictionary, output);
    }

    pub fn decompress(self: CompressionProvider, input: []const u8, dictionary: ?CompressionDictionary, output: []u8) CompressionProviderError![]u8 {
        return self.decompress_fn(self.context, input, dictionary, output);
    }
};

pub const CompressionSession = struct {
    config: CompressionConfig,
    codec: capability.CompressionCapability,
    provider: ?CompressionProvider,
    dictionary: ?CompressionDictionary = null,

    pub fn init(codec: capability.CompressionCapability, config: CompressionConfig, provider: ?CompressionProvider) CompressionError!CompressionSession {
        if (config.maximum_uncompressed_bytes == 0 or config.maximum_uncompressed_bytes > std.math.maxInt(u32) or config.maximum_compressed_bytes == 0 or config.maximum_expansion_ratio == 0) return error.InvalidConfiguration;
        switch (codec) {
            .none => if (provider != null) return error.ProviderMismatch,
            else => {
                const selected = provider orelse return error.ProviderMismatch;
                if (selected.codec != codec) return error.ProviderMismatch;
            },
        }
        return .{ .config = config, .codec = codec, .provider = provider };
    }

    pub fn set_dictionary(self: *CompressionSession, dictionary: CompressionDictionary) CompressionError!void {
        if (self.codec == .none) return error.CompressionDisabled;
        if (dictionary.identifier == 0 or dictionary.bytes.len == 0) return error.InvalidDictionary;
        self.dictionary = dictionary;
    }

    pub fn clear_dictionary(self: *CompressionSession) void {
        self.dictionary = null;
    }

    pub fn compress(self: CompressionSession, input: []const u8, output: []u8) CompressionError![]u8 {
        const provider = self.provider orelse return error.CompressionDisabled;
        if (input.len > self.config.maximum_uncompressed_bytes) return error.InputTooLarge;
        if (output.len < compression_header_bytes) return error.BufferTooSmall;
        const compressed = try provider.compress(input, self.dictionary, output[compression_header_bytes..]);
        if (!is_output_prefix(output[compression_header_bytes..], compressed)) return error.ProviderOutputMismatch;
        if (compressed.len > self.config.maximum_compressed_bytes) return error.OutputTooLarge;
        write_frame_header(output[0..compression_header_bytes], .{
            .codec = self.codec,
            .dictionary_id = if (self.dictionary) |dictionary| dictionary.identifier else 0,
            .uncompressed_length = input.len,
            .payload = compressed,
        });
        return output[0 .. compression_header_bytes + compressed.len];
    }

    pub fn decompress(self: CompressionSession, input: []const u8, output: []u8) CompressionError![]u8 {
        const provider = self.provider orelse return error.CompressionDisabled;
        const frame = try decode_compression_frame(input);
        if (frame.codec != self.codec) return error.CodecMismatch;
        if (frame.payload.len > self.config.maximum_compressed_bytes or frame.uncompressed_length > self.config.maximum_uncompressed_bytes) return error.InputTooLarge;
        const maximum_expanded = std.math.mul(usize, frame.payload.len, self.config.maximum_expansion_ratio) catch return error.ExpansionLimitExceeded;
        if (frame.uncompressed_length > maximum_expanded) return error.ExpansionLimitExceeded;
        if (output.len < frame.uncompressed_length) return error.BufferTooSmall;
        const dictionary = try self.dictionary_for(frame.dictionary_id);
        const decompressed = try provider.decompress(frame.payload, dictionary, output);
        if (!is_output_prefix(output, decompressed) or decompressed.len != frame.uncompressed_length) return error.ProviderOutputMismatch;
        return decompressed;
    }

    fn dictionary_for(self: CompressionSession, identifier: u32) CompressionError!?CompressionDictionary {
        if (identifier == 0) return null;
        const dictionary = self.dictionary orelse return error.DictionaryMismatch;
        if (dictionary.identifier != identifier) return error.DictionaryMismatch;
        return dictionary;
    }
};

pub fn decode_compression_frame(input: []const u8) CompressionError!CompressionFrame {
    if (input.len < compression_header_bytes or input[1] != 0) return error.MalformedFrame;
    const codec = std.meta.intToEnum(capability.CompressionCapability, input[0]) catch return error.MalformedFrame;
    return .{
        .codec = codec,
        .dictionary_id = std.mem.readInt(u32, input[2..6], .big),
        .uncompressed_length = std.mem.readInt(u32, input[6..10], .big),
        .payload = input[compression_header_bytes..],
    };
}

fn write_frame_header(output: []u8, frame: CompressionFrame) void {
    output[0] = @intFromEnum(frame.codec);
    output[1] = 0;
    std.mem.writeInt(u32, output[2..6], frame.dictionary_id, .big);
    std.mem.writeInt(u32, output[6..10], @intCast(frame.uncompressed_length), .big);
}

fn is_output_prefix(output: []u8, result: []u8) bool {
    return output.ptr == result.ptr and result.len <= output.len;
}

test "compression sessions frame opt-in provider output with dictionaries" {
    const Stub = struct {
        saw_dictionary: bool = false,

        fn provider(self: *@This()) CompressionProvider {
            return .{ .context = self, .codec = .lz4, .compress_fn = compress, .decompress_fn = decompress };
        }

        fn compress(context: *anyopaque, input: []const u8, dictionary: ?CompressionDictionary, output: []u8) CompressionProviderError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.saw_dictionary = dictionary != null;
            if (output.len < input.len) return error.BufferTooSmall;
            @memcpy(output[0..input.len], input);
            return output[0..input.len];
        }

        fn decompress(_: *anyopaque, input: []const u8, _: ?CompressionDictionary, output: []u8) CompressionProviderError![]u8 {
            if (output.len < input.len) return error.BufferTooSmall;
            @memcpy(output[0..input.len], input);
            return output[0..input.len];
        }
    };
    var stub = Stub{};
    var session = try CompressionSession.init(.lz4, .{ .maximum_uncompressed_bytes = 8, .maximum_compressed_bytes = 8, .maximum_expansion_ratio = 8 }, stub.provider());
    try std.testing.expectError(error.InvalidDictionary, session.set_dictionary(.{ .identifier = 0, .bytes = "dictionary" }));
    try session.set_dictionary(.{ .identifier = 7, .bytes = "dictionary" });
    var framed: [compression_header_bytes + 8]u8 = undefined;
    const encoded = try session.compress("hello", framed[0..]);
    const frame = try decode_compression_frame(encoded);
    try std.testing.expectEqual(capability.CompressionCapability.lz4, frame.codec);
    try std.testing.expectEqual(@as(u32, 7), frame.dictionary_id);
    try std.testing.expect(stub.saw_dictionary);
    var output: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try session.decompress(encoded, output[0..]));
    session.clear_dictionary();
    try std.testing.expectError(error.DictionaryMismatch, session.decompress(encoded, output[0..]));
}

test "compression sessions enforce provider selection and expansion bounds" {
    var disabled = try CompressionSession.init(.none, .{ .maximum_uncompressed_bytes = 4, .maximum_compressed_bytes = 4, .maximum_expansion_ratio = 4 }, null);
    var output: [compression_header_bytes + 4]u8 = undefined;
    try std.testing.expectError(error.CompressionDisabled, disabled.compress("x", output[0..]));
    try std.testing.expectError(error.InvalidConfiguration, CompressionSession.init(.none, .{ .maximum_uncompressed_bytes = 0, .maximum_compressed_bytes = 1, .maximum_expansion_ratio = 1 }, null));
    try std.testing.expectError(error.ProviderMismatch, CompressionSession.init(.lz4, .{ .maximum_uncompressed_bytes = 1, .maximum_compressed_bytes = 1, .maximum_expansion_ratio = 1 }, null));
    var frame: [compression_header_bytes + 1]u8 = undefined;
    write_frame_header(frame[0..compression_header_bytes], .{ .codec = .lz4, .dictionary_id = 0, .uncompressed_length = 9, .payload = frame[compression_header_bytes..] });
    frame[compression_header_bytes] = 1;
    const Stub = struct {
        fn provider(self: *@This()) CompressionProvider {
            return .{ .context = self, .codec = .lz4, .compress_fn = fail, .decompress_fn = fail };
        }

        fn fail(_: *anyopaque, _: []const u8, _: ?CompressionDictionary, _: []u8) CompressionProviderError![]u8 {
            return error.DecompressionFailed;
        }
    };
    var stub = Stub{};
    const session = try CompressionSession.init(.lz4, .{ .maximum_uncompressed_bytes = 16, .maximum_compressed_bytes = 4, .maximum_expansion_ratio = 8 }, stub.provider());
    var decompressed: [16]u8 = undefined;
    try std.testing.expectError(error.ExpansionLimitExceeded, session.decompress(frame[0..], decompressed[0..]));
    frame[1] = 1;
    try std.testing.expectError(error.MalformedFrame, decode_compression_frame(frame[0..]));
}
