const std = @import("std");
const compat = @import("../common/compat.zig");

/// Single source of truth for session tokens. Standard HS256 JWT
/// (header.payload.signature, base64url-no-pad). Replaces both the old
/// unified_auth JWT helpers and auth.zig's custom HMAC API tokens so that one
/// token format is used everywhere.
const TOKEN_TTL_SECONDS: i64 = 86400; // 24 hours

const DEFAULT_SECRET = "default_secret_change_in_production";

/// Normalized user identity used to mint a token. Owned by the caller; the
/// session manager only reads from it.
pub const SessionUser = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    display_name: ?[]const u8,
    avatar_url: ?[]const u8,
    provider: []const u8,
};

/// Claims decoded from a validated token. Owns its string fields; call
/// `deinit` to release them.
pub const Claims = struct {
    user_id: i64,
    username: []u8,
    email: []u8,
    display_name: []u8,
    avatar_url: []u8,
    provider: []u8,
    iat: i64,
    exp: i64,

    pub fn deinit(self: *Claims, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.email);
        allocator.free(self.display_name);
        allocator.free(self.avatar_url);
        allocator.free(self.provider);
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    jwt_secret: []const u8,

    /// Reads JWT_SECRET once. Falls back to the insecure dev default (with a
    /// warning) so local development keeps working without configuration.
    pub fn init(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !SessionManager {
        const secret = environ_map.get("JWT_SECRET") orelse blk: {
            std.debug.print("⚠️  No JWT_SECRET found, using default (INSECURE for production!)\n", .{});
            break :blk DEFAULT_SECRET;
        };
        return SessionManager{
            .allocator = allocator,
            .jwt_secret = try allocator.dupe(u8, secret),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.allocator.free(self.jwt_secret);
    }

    /// Mint a signed JWT for `user`, valid for TOKEN_TTL_SECONDS. Caller frees.
    pub fn createToken(self: *SessionManager, user: SessionUser) ![]u8 {
        const a = self.allocator;
        const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

        const now = compat.timestamp();
        const exp = now + TOKEN_TTL_SECONDS;

        const payload = try std.fmt.allocPrint(
            a,
            "{{\"sub\":\"{d}\",\"username\":\"{s}\",\"email\":\"{s}\",\"display_name\":\"{s}\",\"avatar_url\":\"{s}\",\"provider\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
            .{
                user.id,
                user.username,
                user.email,
                user.display_name orelse user.username,
                user.avatar_url orelse "",
                user.provider,
                now,
                exp,
            },
        );
        defer a.free(payload);

        const Enc = std.base64.url_safe_no_pad.Encoder;

        const header_enc = try a.alloc(u8, Enc.calcSize(header.len));
        defer a.free(header_enc);
        _ = Enc.encode(header_enc, header);

        const payload_enc = try a.alloc(u8, Enc.calcSize(payload.len));
        defer a.free(payload_enc);
        _ = Enc.encode(payload_enc, payload);

        const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_enc, payload_enc });
        defer a.free(signing_input);

        var signature: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, signing_input, self.jwt_secret);

        var sig_buf: [64]u8 = undefined;
        const sig_enc = Enc.encode(&sig_buf, &signature);

        return std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ header_enc, payload_enc, sig_enc });
    }

    /// Verify signature + expiry and return the decoded claims, or null if the
    /// token is malformed, the signature does not match, or it has expired.
    pub fn validateToken(self: *SessionManager, token: []const u8) !?Claims {
        var parts = std.mem.splitSequence(u8, token, ".");
        const header_b64 = parts.next() orelse return null;
        const payload_b64 = parts.next() orelse return null;
        const signature_b64 = parts.next() orelse return null;
        if (parts.next() != null) return null; // exactly three parts

        const a = self.allocator;

        const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ header_b64, payload_b64 });
        defer a.free(signing_input);

        var expected: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, signing_input, self.jwt_secret);

        var exp_buf: [64]u8 = undefined;
        const expected_enc = std.base64.url_safe_no_pad.Encoder.encode(&exp_buf, &expected);

        if (!std.mem.eql(u8, signature_b64, expected_enc)) return null;

        // Decode the payload to read claims.
        const Dec = std.base64.url_safe_no_pad.Decoder;
        const decoded_len = Dec.calcSizeForSlice(payload_b64) catch return null;
        const payload = try a.alloc(u8, decoded_len);
        defer a.free(payload);
        Dec.decode(payload, payload_b64) catch return null;

        const exp = extractJsonInt(payload, "exp") orelse 0;
        const now = compat.timestamp();
        if (exp > 0 and now > exp) return null;

        return Claims{
            .user_id = extractJsonInt(payload, "sub") orelse 0,
            .username = try a.dupe(u8, extractJsonString(payload, "username") orelse "unknown"),
            .email = try a.dupe(u8, extractJsonString(payload, "email") orelse ""),
            .display_name = try a.dupe(u8, extractJsonString(payload, "display_name") orelse ""),
            .avatar_url = try a.dupe(u8, extractJsonString(payload, "avatar_url") orelse ""),
            .provider = try a.dupe(u8, extractJsonString(payload, "provider") orelse "local"),
            .iat = extractJsonInt(payload, "iat") orelse 0,
            .exp = exp,
        };
    }
};

/// Minimal field-scanning JSON string extractor: finds `"key":"value"` and
/// returns a slice of `value` (no unescaping). Mirrors the OAuth payload shape
/// produced by `createToken`.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < json.len) {
        const quote_pos = std.mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_quote_pos = pos + quote_pos;

        if (abs_quote_pos + 1 + key.len + 1 <= json.len) {
            if (std.mem.eql(u8, json[abs_quote_pos + 1 .. abs_quote_pos + 1 + key.len], key) and
                json[abs_quote_pos + 1 + key.len] == '"')
            {
                const after_key = json[abs_quote_pos + 2 + key.len ..];
                var idx: usize = 0;
                while (idx < after_key.len and (after_key[idx] == ':' or after_key[idx] == ' ' or after_key[idx] == '\n' or after_key[idx] == '\t')) {
                    idx += 1;
                }
                if (idx >= after_key.len or after_key[idx] != '"') return null;
                idx += 1;
                const end_offset = std.mem.indexOf(u8, after_key[idx..], "\"") orelse return null;
                return after_key[idx .. idx + end_offset];
            }
        }
        pos = abs_quote_pos + 1;
    }
    return null;
}

/// Companion to `extractJsonString` for integer (and quoted-integer) values.
fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    var pos: usize = 0;
    while (pos < json.len) {
        const quote_pos = std.mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_quote_pos = pos + quote_pos;

        if (abs_quote_pos + 1 + key.len + 1 <= json.len) {
            if (std.mem.eql(u8, json[abs_quote_pos + 1 .. abs_quote_pos + 1 + key.len], key) and
                json[abs_quote_pos + 1 + key.len] == '"')
            {
                const after_key = json[abs_quote_pos + 2 + key.len ..];
                var idx: usize = 0;
                while (idx < after_key.len and (after_key[idx] == ':' or after_key[idx] == ' ' or after_key[idx] == '\n' or after_key[idx] == '\t')) {
                    idx += 1;
                }
                if (idx >= after_key.len) return null;
                var end_idx: usize = idx;
                while (end_idx < after_key.len and after_key[end_idx] != ',' and after_key[end_idx] != '}' and after_key[end_idx] != '\n' and after_key[end_idx] != ' ') {
                    end_idx += 1;
                }
                const num_str = std.mem.trim(u8, after_key[idx..end_idx], " \t\n\"");
                return std.fmt.parseInt(i64, num_str, 10) catch return null;
            }
        }
        pos = abs_quote_pos + 1;
    }
    return null;
}

test "createToken then validateToken round-trips claims" {
    const allocator = std.testing.allocator;
    var manager = SessionManager{ .allocator = allocator, .jwt_secret = try allocator.dupe(u8, "test-secret") };
    defer manager.deinit();

    const token = try manager.createToken(.{
        .id = 42,
        .username = "alice",
        .email = "alice@example.com",
        .display_name = "Alice",
        .avatar_url = null,
        .provider = "local",
    });
    defer allocator.free(token);

    var claims = (try manager.validateToken(token)) orelse return error.TestUnexpectedNull;
    defer claims.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 42), claims.user_id);
    try std.testing.expectEqualStrings("alice", claims.username);
    try std.testing.expectEqualStrings("alice@example.com", claims.email);
    try std.testing.expectEqualStrings("local", claims.provider);
}

test "validateToken rejects a tampered signature" {
    const allocator = std.testing.allocator;
    var manager = SessionManager{ .allocator = allocator, .jwt_secret = try allocator.dupe(u8, "test-secret") };
    defer manager.deinit();

    const token = try manager.createToken(.{
        .id = 1,
        .username = "bob",
        .email = "bob@example.com",
        .display_name = null,
        .avatar_url = null,
        .provider = "local",
    });
    defer allocator.free(token);

    const tampered = try std.fmt.allocPrint(allocator, "{s}x", .{token});
    defer allocator.free(tampered);

    try std.testing.expect((try manager.validateToken(tampered)) == null);
}
