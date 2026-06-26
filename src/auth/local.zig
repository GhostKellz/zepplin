const std = @import("std");
const crypto = std.crypto;
const compat = @import("../common/compat.zig");

/// Local (username/password) authentication: Argon2id password hashing and
/// timing-safe verification. Session tokens are no longer minted here — that is
/// the job of `session.zig`, so this module is purely about credentials.
pub const Auth = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secret_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, secret_key: []const u8) Auth {
        return Auth{
            .allocator = allocator,
            .io = io,
            .secret_key = secret_key,
        };
    }

    pub fn hashPassword(self: *Auth, password: []const u8) ![]u8 {
        var salt: [16]u8 = undefined;
        compat.cryptoRandomBytes(&salt);

        var hash: [32]u8 = undefined;
        try crypto.pwhash.argon2.kdf(
            self.allocator,
            &hash,
            password,
            &salt,
            .{ .t = 3, .m = 65536, .p = 1 },
            .argon2id,
            self.io,
        );

        // Combine salt and hash (16 + 32) and hex-encode for storage. The hash
        // is persisted in a TEXT column via SQL string interpolation, so the
        // stored form must be plain ASCII — raw bytes could contain quotes or
        // NULs that corrupt the statement.
        var raw: [48]u8 = undefined;
        @memcpy(raw[0..16], &salt);
        @memcpy(raw[16..48], &hash);

        const hex = std.fmt.bytesToHex(raw, .lower);
        return self.allocator.dupe(u8, &hex);
    }

    pub fn verifyPassword(self: *Auth, password: []const u8, stored_hash: []const u8) !bool {
        if (stored_hash.len != 96) return false;

        var raw: [48]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, stored_hash) catch return false;

        const salt = raw[0..16];
        const expected_hash = raw[16..48];

        var computed_hash: [32]u8 = undefined;
        try crypto.pwhash.argon2.kdf(
            self.allocator,
            &computed_hash,
            password,
            salt,
            .{ .t = 3, .m = 65536, .p = 1 },
            .argon2id,
            self.io,
        );

        return crypto.timing_safe.eql([32]u8, computed_hash, expected_hash[0..32].*);
    }

    pub fn extractBearerToken(authorization_header: []const u8) ?[]const u8 {
        const bearer_prefix = "Bearer ";
        if (std.mem.startsWith(u8, authorization_header, bearer_prefix)) {
            return authorization_header[bearer_prefix.len..];
        }
        return null;
    }
};

test "extractBearerToken parses the Authorization header" {
    try std.testing.expectEqualStrings("abc123", Auth.extractBearerToken("Bearer abc123").?);
    try std.testing.expect(Auth.extractBearerToken("Basic abc123") == null);
    try std.testing.expect(Auth.extractBearerToken("") == null);
}
