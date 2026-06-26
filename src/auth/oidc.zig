const std = @import("std");
const compat = @import("../common/compat.zig");

/// Generic, provider-agnostic OIDC/OAuth2 authorization-code client.
///
/// Per-provider modules (`entra.zig`, `google.zig`) construct an `OIDCConfig`
/// with the right endpoints and userinfo field mapping; this module performs
/// the actual HTTP exchanges. The userinfo URL and claim field names come from
/// the config, never hardcoded, so the same code handles Microsoft Graph and
/// the standard OIDC userinfo endpoint.

/// Names of the fields to read out of a provider's userinfo JSON. Defaults
/// follow the standard OIDC claim names (Google, Okta, ...). Microsoft Graph
/// overrides these (id/displayName/mail/userPrincipalName).
pub const UserInfoFields = struct {
    sub: []const u8 = "sub",
    email: []const u8 = "email",
    name: []const u8 = "name",
    picture: []const u8 = "picture",
    preferred_username: []const u8 = "preferred_username",
    /// Optional secondary key used for email when the primary key is absent
    /// (e.g. Microsoft's "userPrincipalName").
    email_fallback: ?[]const u8 = null,
};

pub const OIDCConfig = struct {
    /// Stable provider identifier persisted with the user (e.g. "microsoft").
    /// Static literal; not freed by `deinit`.
    provider_name: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    userinfo_url: []const u8,
    scope: []const u8,
    /// Static literals; not freed by `deinit`.
    fields: UserInfoFields,

    /// Frees the heap-allocated endpoint/credential strings. `provider_name`
    /// and `fields` are expected to be static literals and are left untouched.
    pub fn deinit(self: OIDCConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.redirect_uri);
        allocator.free(self.authorize_url);
        allocator.free(self.token_url);
        allocator.free(self.userinfo_url);
        allocator.free(self.scope);
    }
};

pub const OIDCTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: u32,
    scope: []const u8,
    id_token: ?[]const u8,
    refresh_token: ?[]const u8,

    pub fn deinit(self: OIDCTokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        allocator.free(self.scope);
        if (self.id_token) |t| allocator.free(t);
        if (self.refresh_token) |t| allocator.free(t);
    }
};

pub const OIDCUserInfo = struct {
    sub: []const u8,
    email: ?[]const u8,
    name: ?[]const u8,
    picture: ?[]const u8,
    preferred_username: ?[]const u8,

    pub fn deinit(self: OIDCUserInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.sub);
        if (self.email) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.picture) |v| allocator.free(v);
        if (self.preferred_username) |v| allocator.free(v);
    }
};

pub const OIDCClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: OIDCConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: OIDCConfig) OIDCClient {
        return .{ .allocator = allocator, .io = io, .config = config };
    }

    pub fn deinit(self: *OIDCClient) void {
        self.config.deinit(self.allocator);
    }

    /// Build the provider authorization URL (with CSRF state + OIDC nonce).
    pub fn getAuthorizationUrl(self: *OIDCClient) ![]u8 {
        const state = try generateRandomToken(self.allocator);
        defer self.allocator.free(state);
        const nonce = try generateRandomToken(self.allocator);
        defer self.allocator.free(nonce);

        const encoded_redirect = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect);
        const encoded_scope = try urlEncode(self.allocator, self.config.scope);
        defer self.allocator.free(encoded_scope);

        return std.fmt.allocPrint(
            self.allocator,
            "{s}?client_id={s}&response_type=code&redirect_uri={s}&scope={s}&state={s}&nonce={s}",
            .{ self.config.authorize_url, self.config.client_id, encoded_redirect, encoded_scope, state, nonce },
        );
    }

    /// Exchange an authorization code for tokens at the provider token endpoint.
    pub fn exchangeCodeForToken(self: *OIDCClient, code: []const u8) !OIDCTokenResponse {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const encoded_redirect = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&client_secret={s}",
            .{ code, encoded_redirect, self.config.client_id, self.config.client_secret },
        );
        defer self.allocator.free(body);

        const uri = try std.Uri.parse(self.config.token_url);
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        };

        var req = try client.request(.POST, uri, .{ .extra_headers = &headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        var redirect_buffer: [1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            std.debug.print("❌ {s}: failed to receive token response: {}\n", .{ self.config.provider_name, err });
            return error.TokenExchangeFailed;
        };

        const response_body = try self.readBody(&response);
        defer self.allocator.free(response_body);

        if (response.head.status != .ok) {
            std.debug.print("❌ {s} token exchange status {}: {s}\n", .{ self.config.provider_name, response.head.status, response_body });
            return error.TokenExchangeFailed;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            std.debug.print("❌ {s}: token JSON parse error: {}\n", .{ self.config.provider_name, err });
            return error.TokenExchangeFailed;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        if (obj.get("error")) |err_val| {
            std.debug.print("❌ {s} OAuth error: {s}\n", .{ self.config.provider_name, if (err_val == .string) err_val.string else "unknown" });
            return error.TokenExchangeFailed;
        }

        const access_token = obj.get("access_token") orelse return error.TokenExchangeFailed;

        return OIDCTokenResponse{
            .access_token = try self.allocator.dupe(u8, access_token.string),
            .token_type = try self.allocator.dupe(u8, if (obj.get("token_type")) |t| t.string else "Bearer"),
            .expires_in = if (obj.get("expires_in")) |e| @intCast(e.integer) else 0,
            .scope = try self.allocator.dupe(u8, if (obj.get("scope")) |s| s.string else ""),
            .id_token = if (obj.get("id_token")) |t| try self.allocator.dupe(u8, t.string) else null,
            .refresh_token = if (obj.get("refresh_token")) |t| try self.allocator.dupe(u8, t.string) else null,
        };
    }

    /// Fetch and normalize the user profile from the configured userinfo URL.
    pub fn getUserInfo(self: *OIDCClient, access_token: []const u8) !OIDCUserInfo {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(self.config.userinfo_url);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{access_token});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "Zepplin-Registry" },
        };

        var req = try client.request(.GET, uri, .{ .extra_headers = &headers });
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buffer: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        const response_body = try self.readBody(&response);
        defer self.allocator.free(response_body);

        if (response.head.status != .ok) {
            std.debug.print("❌ {s} userinfo status {}: {s}\n", .{ self.config.provider_name, response.head.status, response_body });
            return error.UserInfoFailed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const f = self.config.fields;

        const email = self.dupeStringField(obj, f.email) orelse
            (if (f.email_fallback) |fb| self.dupeStringField(obj, fb) else null);

        return OIDCUserInfo{
            .sub = try self.allocator.dupe(u8, obj.get(f.sub).?.string),
            .email = email,
            .name = self.dupeStringField(obj, f.name),
            .picture = self.dupeStringField(obj, f.picture),
            .preferred_username = self.dupeStringField(obj, f.preferred_username),
        };
    }

    /// Read a non-null string field from a JSON object, duping it. Returns null
    /// if the key is absent or JSON null. Allocation failure is treated as
    /// absent (the field is optional in every caller).
    fn dupeStringField(self: *OIDCClient, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const val = obj.get(key) orelse return null;
        if (val != .string) return null;
        return self.allocator.dupe(u8, val.string) catch null;
    }

    fn readBody(self: *OIDCClient, response: anytype) ![]u8 {
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        var transfer_buffer: [4096]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        _ = body_reader.streamRemaining(&response_writer.writer) catch |err| {
            std.debug.print("❌ {s}: failed to read response body: {}\n", .{ self.config.provider_name, err });
            return error.ResponseReadFailed;
        };

        return self.allocator.dupe(u8, response_writer.written());
    }
};

fn generateRandomToken(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    compat.cryptoRandomBytes(&random_bytes);

    // base64url-no-pad of 16 bytes is exactly 22 chars; size the buffer to that
    // and use the encoder's returned slice so no uninitialized bytes leak into
    // the state/nonce.
    const Encoder = std.base64.url_safe_no_pad.Encoder;
    var encoded: [Encoder.calcSize(16)]u8 = undefined;
    const token = Encoder.encode(&encoded, &random_bytes);
    return allocator.dupe(u8, token);
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try encoded.append(allocator, c),
            ' ' => try encoded.append(allocator, '+'),
            else => {
                const hex_chars = "0123456789ABCDEF";
                try encoded.append(allocator, '%');
                try encoded.append(allocator, hex_chars[(c >> 4) & 0xF]);
                try encoded.append(allocator, hex_chars[c & 0xF]);
            },
        }
    }
    return encoded.toOwnedSlice(allocator);
}
