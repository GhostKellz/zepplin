const std = @import("std");

/// GitHub OAuth2 client. GitHub is plain OAuth2 (not OIDC), so it keeps its own
/// authorize/token/user endpoints and returns the normalized `GitHubUser` shape
/// the callback handler maps onto a session user.
pub const GitHubOAuthConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,

    pub fn fromEnv(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !GitHubOAuthConfig {
        const client_id = environ_map.get("GITHUB_CLIENT_ID") orelse return error.MissingClientId;
        const client_secret = environ_map.get("GITHUB_CLIENT_SECRET") orelse return error.MissingClientSecret;
        const redirect_base = environ_map.get("REDIRECT_BASE_URL") orelse "http://localhost:8888";

        return GitHubOAuthConfig{
            .client_id = try allocator.dupe(u8, client_id),
            .client_secret = try allocator.dupe(u8, client_secret),
            .redirect_uri = try std.fmt.allocPrint(allocator, "{s}/api/v1/auth/oauth/github/callback", .{redirect_base}),
            .scope = try allocator.dupe(u8, "read:user user:email"),
        };
    }

    pub fn deinit(self: GitHubOAuthConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.redirect_uri);
        allocator.free(self.scope);
    }
};

pub const GitHubTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    scope: []const u8,

    pub fn deinit(self: GitHubTokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        allocator.free(self.scope);
    }
};

pub const GitHubUser = struct {
    id: u64,
    login: []const u8,
    name: ?[]const u8,
    email: ?[]const u8,
    avatar_url: ?[]const u8,

    pub fn deinit(self: GitHubUser, allocator: std.mem.Allocator) void {
        allocator.free(self.login);
        if (self.name) |v| allocator.free(v);
        if (self.email) |v| allocator.free(v);
        if (self.avatar_url) |v| allocator.free(v);
    }
};

pub const GitHubOAuthClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: GitHubOAuthConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: GitHubOAuthConfig) GitHubOAuthClient {
        return .{ .allocator = allocator, .io = io, .config = config };
    }

    pub fn deinit(self: *GitHubOAuthClient) void {
        self.config.deinit(self.allocator);
    }

    pub fn getAuthorizationUrl(self: *GitHubOAuthClient) ![]u8 {
        const encoded_redirect = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect);
        const encoded_scope = try urlEncode(self.allocator, self.config.scope);
        defer self.allocator.free(encoded_scope);

        return std.fmt.allocPrint(
            self.allocator,
            "https://github.com/login/oauth/authorize?client_id={s}&redirect_uri={s}&scope={s}",
            .{ self.config.client_id, encoded_redirect, encoded_scope },
        );
    }

    pub fn exchangeCodeForToken(self: *GitHubOAuthClient, code: []const u8) !GitHubTokenResponse {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const encoded_redirect = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "client_id={s}&client_secret={s}&code={s}&redirect_uri={s}",
            .{ self.config.client_id, self.config.client_secret, code, encoded_redirect },
        );
        defer self.allocator.free(body);

        const uri = try std.Uri.parse("https://github.com/login/oauth/access_token");
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "Zepplin-Registry" },
        };

        var req = try client.request(.POST, uri, .{ .extra_headers = &headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        var redirect_buffer: [1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            std.debug.print("❌ GitHub: failed to receive token response: {}\n", .{err});
            return error.TokenExchangeFailed;
        };

        const response_body = try self.readBody(&response);
        defer self.allocator.free(response_body);

        if (response.head.status != .ok) {
            std.debug.print("❌ GitHub token exchange status {}: {s}\n", .{ response.head.status, response_body });
            return error.TokenExchangeFailed;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            std.debug.print("❌ GitHub: token JSON parse error: {}\n", .{err});
            return error.TokenExchangeFailed;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        if (obj.get("error")) |err_val| {
            std.debug.print("❌ GitHub OAuth error: {s}\n", .{if (err_val == .string) err_val.string else "unknown"});
            return error.TokenExchangeFailed;
        }

        const access_token = obj.get("access_token") orelse return error.TokenExchangeFailed;
        return GitHubTokenResponse{
            .access_token = try self.allocator.dupe(u8, access_token.string),
            .token_type = try self.allocator.dupe(u8, if (obj.get("token_type")) |t| t.string else "bearer"),
            .scope = try self.allocator.dupe(u8, if (obj.get("scope")) |s| s.string else ""),
        };
    }

    pub fn getUser(self: *GitHubOAuthClient, access_token: []const u8) !GitHubUser {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse("https://api.github.com/user");
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{access_token});
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
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
            std.debug.print("❌ GitHub user request status {}: {s}\n", .{ response.head.status, response_body });
            return error.UserInfoFailed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        return GitHubUser{
            .id = @intCast(obj.get("id").?.integer),
            .login = try self.allocator.dupe(u8, obj.get("login").?.string),
            .name = self.dupeStringField(obj, "name"),
            .email = self.dupeStringField(obj, "email"),
            .avatar_url = self.dupeStringField(obj, "avatar_url"),
        };
    }

    fn dupeStringField(self: *GitHubOAuthClient, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const val = obj.get(key) orelse return null;
        if (val != .string) return null;
        return self.allocator.dupe(u8, val.string) catch null;
    }

    fn readBody(self: *GitHubOAuthClient, response: anytype) ![]u8 {
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        var transfer_buffer: [4096]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        _ = body_reader.streamRemaining(&response_writer.writer) catch |err| {
            std.debug.print("❌ GitHub: failed to read response body: {}\n", .{err});
            return error.ResponseReadFailed;
        };

        return self.allocator.dupe(u8, response_writer.written());
    }
};

/// True when the GitHub provider has the required env configured.
pub fn isConfigured(environ_map: *std.process.Environ.Map) bool {
    return environ_map.get("GITHUB_CLIENT_ID") != null and environ_map.get("GITHUB_CLIENT_SECRET") != null;
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
