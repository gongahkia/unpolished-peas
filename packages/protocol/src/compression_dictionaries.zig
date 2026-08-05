const std = @import("std");
const capability = @import("capability_negotiation.zig");
const compression = @import("compression_provider.zig");

pub const max_compression_dictionaries: usize = capability.max_compression_dictionary_ids;
pub const CompressionDictionaryError = error{ InvalidDictionary, DuplicateIdentifier, CapacityExceeded, UnknownDictionary, DictionaryMismatch, SessionRejected };

pub const CompressionDictionaryRegistry = struct {
    dictionaries: [max_compression_dictionaries]?compression.CompressionDictionary = .{null} ** max_compression_dictionaries,

    pub fn register(self: *CompressionDictionaryRegistry, dictionary: compression.CompressionDictionary) CompressionDictionaryError!void {
        if (dictionary.identifier == 0 or dictionary.bytes.len == 0) return error.InvalidDictionary;
        if (self.find(dictionary.identifier) != null) return error.DuplicateIdentifier;
        for (&self.dictionaries) |*slot| {
            if (slot.* == null) {
                slot.* = dictionary;
                return;
            }
        }
        return error.CapacityExceeded;
    }

    pub fn unregister(self: *CompressionDictionaryRegistry, identifier: u32) CompressionDictionaryError!void {
        for (&self.dictionaries) |*slot| {
            const dictionary = slot.* orelse continue;
            if (dictionary.identifier == identifier) {
                slot.* = null;
                return;
            }
        }
        return error.UnknownDictionary;
    }

    pub fn offer(self: CompressionDictionaryRegistry) capability.CompressionDictionaryOffer {
        var result = capability.CompressionDictionaryOffer{};
        for (self.dictionaries) |slot| {
            const dictionary = slot orelse continue;
            result.insert(dictionary.identifier) catch unreachable;
        }
        return result;
    }

    pub fn configure_session(self: CompressionDictionaryRegistry, session: *compression.CompressionSession, identifier: ?u32) CompressionDictionaryError!void {
        const requested = identifier orelse {
            session.clear_dictionary();
            return;
        };
        const dictionary = self.find(requested) orelse return error.DictionaryMismatch;
        session.set_dictionary(dictionary) catch return error.SessionRejected;
    }

    pub fn apply_negotiated(self: CompressionDictionaryRegistry, session: *compression.CompressionSession, negotiated: capability.NegotiatedCapabilities) CompressionDictionaryError!void {
        return self.configure_session(session, negotiated.compression_dictionary_id);
    }

    fn find(self: CompressionDictionaryRegistry, identifier: u32) ?compression.CompressionDictionary {
        for (self.dictionaries) |slot| {
            const dictionary = slot orelse continue;
            if (dictionary.identifier == identifier) return dictionary;
        }
        return null;
    }
};

test "registered dictionaries produce negotiated identifiers and configure sessions" {
    const Stub = struct {
        fn provider(self: *@This()) compression.CompressionProvider {
            return .{ .context = self, .codec = .lz4, .compress_fn = reject, .decompress_fn = reject };
        }

        fn reject(_: *anyopaque, _: []const u8, _: ?compression.CompressionDictionary, _: []u8) compression.CompressionProviderError![]u8 {
            return error.DictionaryRejected;
        }
    };
    var registry = CompressionDictionaryRegistry{};
    try registry.register(.{ .identifier = 7, .bytes = "first" });
    try registry.register(.{ .identifier = 9, .bytes = "second" });
    var remote = capability.CompressionDictionaryOffer{};
    try remote.insert(9);
    const negotiated = capability.NegotiatedCapabilities{
        .transport = .udp,
        .channel = .datagram,
        .security = .none,
        .compression = .lz4,
        .compression_dictionary_id = 9,
        .extensions = 0,
    };
    try std.testing.expect(registry.offer().contains(7));
    try std.testing.expect(remote.contains(negotiated.compression_dictionary_id.?));
    var stub = Stub{};
    var session = try compression.CompressionSession.init(.lz4, .{ .maximum_uncompressed_bytes = 8, .maximum_compressed_bytes = 8, .maximum_expansion_ratio = 8 }, stub.provider());
    try registry.apply_negotiated(&session, negotiated);
    try std.testing.expectEqual(@as(?u32, 9), if (session.dictionary) |dictionary| dictionary.identifier else null);
    try std.testing.expectError(error.DictionaryMismatch, registry.configure_session(&session, 11));
    try std.testing.expectError(error.DuplicateIdentifier, registry.register(.{ .identifier = 7, .bytes = "duplicate" }));
    try registry.unregister(9);
    try std.testing.expectError(error.UnknownDictionary, registry.unregister(9));
}

test "dictionary registries reject invalid and bounded registrations" {
    var registry = CompressionDictionaryRegistry{};
    try std.testing.expectError(error.InvalidDictionary, registry.register(.{ .identifier = 0, .bytes = "invalid" }));
    for (1..max_compression_dictionaries + 1) |identifier| try registry.register(.{ .identifier = @intCast(identifier), .bytes = "d" });
    try std.testing.expectError(error.CapacityExceeded, registry.register(.{ .identifier = max_compression_dictionaries + 1, .bytes = "full" }));
}
