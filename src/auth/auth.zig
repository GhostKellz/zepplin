const std = @import("std");
const crypto = std.crypto;

pub const AuthError = error{
    InvalidToken,
    TokenExpired,
    InvalidCredentials,
    TokenGenerationFailed,
    HashingFailed,
};

pub const AuthToken = struct {
    token: []const u8,
    user_id: i64,
    expires_at: i64,

    pub fn isValid(self: AuthToken) bool {
        const now = std.time.timestamp();
        return now < self.expires_at;
    }
};

pub const Auth = struct {
    allocator: std.mem.Allocator,
    secret_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, secret_key: []const u8) Auth {
        return Auth{
            .allocator = allocator,
            .secret_key = secret_key,
        };
    }

    pub fn hashPassword(self: *Auth, password: []const u8) ![]u8 {
        var salt: [16]u8 = undefined;
        crypto.random.bytes(&salt);

        var hash: [32]u8 = undefined;
        try crypto.pwhash.argon2.kdf(
            self.allocator,
            &hash,
            password,
            &salt,
            .{ .t = 3, .m = 65536, .p = 1 },
            .argon2id,
        );

        // Combine salt and hash for storage
        const result = try self.allocator.alloc(u8, 48); // 16 + 32
        @memcpy(result[0..16], &salt);
        @memcpy(result[16..48], &hash);

        return result;
    }

    pub fn verifyPassword(self: *Auth, password: []const u8, stored_hash: []const u8) !bool {
        if (stored_hash.len != 48) return false;

        const salt = stored_hash[0..16];
        const expected_hash = stored_hash[16..48];

        var computed_hash: [32]u8 = undefined;
        try crypto.pwhash.argon2.kdf(
            self.allocator,
            &computed_hash,
            password,
            salt,
            .{ .t = 3, .m = 65536, .p = 1 },
            .argon2id,
        );

        return crypto.utils.timingSafeEql([32]u8, computed_hash, expected_hash[0..32].*);
    }

    pub fn generateApiToken(self: *Auth, user_id: i64) ![]u8 {
        const now = std.time.timestamp();
        const expires_at = now + (30 * 24 * 60 * 60); // 30 days

        // Create token payload
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"user_id\":{},\"exp\":{}}}", .{ user_id, expires_at });
        defer self.allocator.free(payload);

        // Simple HMAC-based token (in production, use JWT)
        var hmac: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&hmac, payload, self.secret_key);

        // Encode as base64
        const token_data = try self.allocator.alloc(u8, payload.len + 32);
        @memcpy(token_data[0..payload.len], payload);
        @memcpy(token_data[payload.len..], &hmac);

        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(token_data.len);
        const token = try self.allocator.alloc(u8, encoded_len);
        _ = encoder.encode(token, token_data);

        self.allocator.free(token_data);
        return token;
    }

    pub fn validateApiToken(self: *Auth, token: []const u8) !AuthToken {
        const decoder = std.base64.standard.Decoder;
        const decoded_len = try decoder.calcSizeForSlice(token);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);

        try decoder.decode(decoded, token);

        if (decoded.len < 32) return AuthError.InvalidToken;

        const payload = decoded[0 .. decoded.len - 32];
        const expected_hmac = decoded[decoded.len - 32 ..];

        // Verify HMAC
        var computed_hmac: [32]u8 = undefined;
        crypto.auth.hmac.sha2.HmacSha256.create(&computed_hmac, payload, self.secret_key);

        if (!crypto.timing_safe.eql([32]u8, computed_hmac, expected_hmac[0..32].*)) {
            return AuthError.InvalidToken;
        }

        // Parse payload (simplified JSON parsing)
        var user_id: i64 = 0;
        var expires_at: i64 = 0;

        // Simple JSON parsing for "user_id" and "exp"
        var iter = std.mem.splitScalar(u8, payload, ',');
        while (iter.next()) |part| {
            if (std.mem.indexOf(u8, part, "user_id")) |_| {
                const colon_pos = std.mem.indexOf(u8, part, ":") orelse continue;
                const value_str = std.mem.trim(u8, part[colon_pos + 1 ..], " {}\"");
                user_id = std.fmt.parseInt(i64, value_str, 10) catch continue;
            } else if (std.mem.indexOf(u8, part, "exp")) |_| {
                const colon_pos = std.mem.indexOf(u8, part, ":") orelse continue;
                const value_str = std.mem.trim(u8, part[colon_pos + 1 ..], " {}\"");
                expires_at = std.fmt.parseInt(i64, value_str, 10) catch continue;
            }
        }

        if (user_id == 0 or expires_at == 0) return AuthError.InvalidToken;

        const auth_token = AuthToken{
            .token = try self.allocator.dupe(u8, token),
            .user_id = user_id,
            .expires_at = expires_at,
        };

        if (!auth_token.isValid()) return AuthError.TokenExpired;

        return auth_token;
    }

    pub fn extractBearerToken(authorization_header: []const u8) ?[]const u8 {
        const bearer_prefix = "Bearer ";
        if (std.mem.startsWith(u8, authorization_header, bearer_prefix)) {
            return authorization_header[bearer_prefix.len..];
        }
        return null;
    }
};
