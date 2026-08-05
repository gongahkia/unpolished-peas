const std = @import("std");

const hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const max_stun_credential_bytes: usize = 512;
pub const stun_integrity_tag_bytes: usize = hmac.mac_length;
pub const StunPasswordAlgorithm = enum(u16) { md5 = 0x0001, sha256 = 0x0002, _ };
pub const StunCredentialError = error{ InvalidCredential, UnsupportedAlgorithm, IntegrityMismatch };

pub const StunShortTermCredentials = struct {
    username: []const u8,
    password: []const u8,
};

pub const StunLongTermCredentials = struct {
    username: []const u8,
    password: []const u8,
    realm: []const u8,
    nonce: []const u8,
    algorithm: StunPasswordAlgorithm,
};

pub fn validate_short_term_credentials(value: StunShortTermCredentials) StunCredentialError!void {
    if (value.username.len == 0 or value.password.len == 0 or value.username.len > max_stun_credential_bytes or value.password.len > max_stun_credential_bytes) return error.InvalidCredential;
}

pub fn validate_long_term_credentials(value: StunLongTermCredentials) StunCredentialError!void {
    try validate_short_term_credentials(.{ .username = value.username, .password = value.password });
    if (value.realm.len == 0 or value.nonce.len == 0 or value.realm.len > max_stun_credential_bytes or value.nonce.len > max_stun_credential_bytes) return error.InvalidCredential;
    if (value.algorithm != .sha256) return error.UnsupportedAlgorithm;
}

pub fn stun_short_term_integrity(value: StunShortTermCredentials, message: []const u8) StunCredentialError![stun_integrity_tag_bytes]u8 {
    try validate_short_term_credentials(value);
    return authenticate(value.password, message);
}

pub fn stun_long_term_integrity(value: StunLongTermCredentials, message: []const u8) StunCredentialError![stun_integrity_tag_bytes]u8 {
    try validate_long_term_credentials(value);
    var key: [sha256.digest_length]u8 = undefined;
    var digest = sha256.init(.{});
    digest.update(value.username);
    digest.update(":");
    digest.update(value.realm);
    digest.update(":");
    digest.update(value.password);
    digest.final(&key);
    defer std.crypto.secureZero(u8, &key);
    return authenticate(&key, message);
}

pub fn verify_stun_integrity(message: []const u8, expected: [stun_integrity_tag_bytes]u8, received: [stun_integrity_tag_bytes]u8) StunCredentialError!void {
    _ = message;
    if (!std.crypto.timing_safe.eql([stun_integrity_tag_bytes]u8, expected, received)) return error.IntegrityMismatch;
}

fn authenticate(key: []const u8, message: []const u8) [stun_integrity_tag_bytes]u8 {
    var context = hmac.init(key);
    context.update(message);
    var tag: [stun_integrity_tag_bytes]u8 = undefined;
    context.final(&tag);
    return tag;
}

test "STUN credentials authenticate short and long term HMAC integrity" {
    const short = StunShortTermCredentials{ .username = "a", .password = "password" };
    const long = StunLongTermCredentials{ .username = "a", .password = "password", .realm = "realm", .nonce = "nonce", .algorithm = .sha256 };
    const short_tag = try stun_short_term_integrity(short, "message");
    const long_tag = try stun_long_term_integrity(long, "message");
    try std.testing.expect(!std.crypto.timing_safe.eql([stun_integrity_tag_bytes]u8, short_tag, long_tag));
    try verify_stun_integrity("message", short_tag, short_tag);
    var tampered = short_tag;
    tampered[0] +%= 1;
    try std.testing.expectError(error.IntegrityMismatch, verify_stun_integrity("message", short_tag, tampered));
}

test "STUN credentials reject missing bounded nonce realm and unsupported algorithms" {
    try std.testing.expectError(error.InvalidCredential, validate_short_term_credentials(.{ .username = "", .password = "p" }));
    const valid = StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    try validate_long_term_credentials(valid);
    var invalid = valid;
    invalid.nonce = "";
    try std.testing.expectError(error.InvalidCredential, validate_long_term_credentials(invalid));
    invalid = valid;
    invalid.algorithm = .md5;
    try std.testing.expectError(error.UnsupportedAlgorithm, validate_long_term_credentials(invalid));
}

test "bounded STUN credential fuzz corpus retains input and integrity limits" {
    var prng = std.Random.DefaultPrng.init(0xa482_19bd_67e3_c50f);
    const random = prng.random();
    var bytes: [max_stun_credential_bytes + 1]u8 = undefined;
    var expected: [stun_integrity_tag_bytes]u8 = undefined;
    var received: [stun_integrity_tag_bytes]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        random.bytes(&bytes);
        random.bytes(&expected);
        random.bytes(&received);
        const username = bytes[0..random.uintLessThan(usize, bytes.len + 1)];
        const password = bytes[0..random.uintLessThan(usize, bytes.len + 1)];
        const realm = bytes[0..random.uintLessThan(usize, bytes.len + 1)];
        const nonce = bytes[0..random.uintLessThan(usize, bytes.len + 1)];
        const short = StunShortTermCredentials{ .username = username, .password = password };
        const long = StunLongTermCredentials{ .username = username, .password = password, .realm = realm, .nonce = nonce, .algorithm = @enumFromInt(random.int(u16)) };
        _ = validate_short_term_credentials(short) catch {};
        _ = validate_long_term_credentials(long) catch {};
        _ = stun_short_term_integrity(short, bytes[0..random.uintLessThan(usize, bytes.len + 1)]) catch {};
        _ = stun_long_term_integrity(long, bytes[0..random.uintLessThan(usize, bytes.len + 1)]) catch {};
        verify_stun_integrity(bytes[0..random.uintLessThan(usize, bytes.len + 1)], expected, received) catch {};
    }
    const credentials = StunShortTermCredentials{ .username = "user", .password = "password" };
    const tag = try stun_short_term_integrity(credentials, "message");
    try verify_stun_integrity("message", tag, tag);
    var tampered = tag;
    tampered[0] +%= 1;
    try std.testing.expectError(error.IntegrityMismatch, verify_stun_integrity("message", tag, tampered));
}
