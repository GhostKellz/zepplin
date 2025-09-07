const std = @import("std");
const types = @import("../common/types.zig");

pub const GitHubOAuthConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    
    pub fn fromEnv(allocator: std.mem.Allocator) !GitHubOAuthConfig {
        const client_id = std.process.getEnvVarOwned(allocator, "GITHUB_CLIENT_ID") catch return error.MissingClientId;
        const client_secret = std.process.getEnvVarOwned(allocator, "GITHUB_CLIENT_SECRET") catch return error.MissingClientSecret;
        const redirect_base = std.process.getEnvVarOwned(allocator, "REDIRECT_BASE_URL") catch "http://localhost:8888";
        
        return GitHubOAuthConfig{
            .client_id = try allocator.dupe(u8, client_id),
            .client_secret = try allocator.dupe(u8, client_secret),
            .redirect_uri = try std.fmt.allocPrint(allocator, "{s}/api/v1/auth/oauth/github/callback", .{redirect_base}),
            .scope = try allocator.dupe(u8, "read:user user:email"),
        };
    }
};

pub const GitHubTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    scope: []const u8,
};

pub const GitHubUser = struct {
    id: u64,
    login: []const u8,
    name: ?[]const u8,
    email: ?[]const u8,
    avatar_url: ?[]const u8,
    bio: ?[]const u8,
    company: ?[]const u8,
    location: ?[]const u8,
    blog: ?[]const u8,
    public_repos: u32,
    followers: u32,
    following: u32,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const GitHubEmail = struct {
    email: []const u8,
    primary: bool,
    verified: bool,
    visibility: ?[]const u8,
};

pub const GitHubOAuthClient = struct {
    allocator: std.mem.Allocator,
    config: GitHubOAuthConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: GitHubOAuthConfig) GitHubOAuthClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn deinit(self: *GitHubOAuthClient) void {
        _ = self;
    }
    
    
    pub fn getAuthorizationUrl(self: *GitHubOAuthClient) ![]u8 {
        // URL encode the parameters that need encoding
        const encoded_redirect_uri = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect_uri);
        
        const encoded_scope = try urlEncode(self.allocator, self.config.scope);
        defer self.allocator.free(encoded_scope);
        
        const auth_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/login/oauth/authorize?client_id={s}&redirect_uri={s}&scope={s}",
            .{
                self.config.client_id,
                encoded_redirect_uri,
                encoded_scope,
            }
        );
        
        return auth_url;
    }
    
    pub fn exchangeCodeForToken(self: *GitHubOAuthClient, code: []const u8) !GitHubTokenResponse {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        // Build request body for GitHub OAuth
        const body = try std.fmt.allocPrint(self.allocator,
            "client_id={s}&client_secret={s}&code={s}&redirect_uri={s}",
            .{ self.config.client_id, self.config.client_secret, code, self.config.redirect_uri }
        );
        defer self.allocator.free(body);
        
        const token_url = "https://github.com/login/oauth/access_token";
        const uri = try std.Uri.parse(token_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" }, // Request JSON instead of URL-encoded
            .{ .name = "User-Agent", .value = "Zepplin-Registry" },
        };
        
        var req = try client.request(.POST, uri, .{ .extra_headers = &headers });
        defer req.deinit();
        
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);
        
        var redirect_buffer: [1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);
        
        if (response.head.status != .ok) {
            std.debug.print("GitHub token exchange failed with status: {}\\n", .{response.head.status});
            return error.TokenExchangeFailed;
        }
        
        var transfer_buffer: [4096]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buffer, response.head.transfer_encoding, response.head.content_length);
        const response_body = try body_reader.*.readAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);
        
        // Parse JSON response
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();
        
        const obj = parsed.value.object;
        
        return GitHubTokenResponse{
            .access_token = try self.allocator.dupe(u8, obj.get("access_token").?.string),
            .token_type = try self.allocator.dupe(u8, obj.get("token_type").?.string),
            .scope = try self.allocator.dupe(u8, obj.get("scope").?.string),
        };
    }
    
    pub fn getUser(self: *GitHubOAuthClient, access_token: []const u8) !GitHubUser {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const user_url = "https://api.github.com/user";
        const uri = try std.Uri.parse(user_url);
        
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
        const response = try req.receiveHead(&redirect_buffer);
        
        if (response.head.status != .ok) {
            std.debug.print("GitHub user request failed with status: {}\\n", .{response.head.status});
            return error.UserInfoFailed;
        }
        
        var transfer_buffer: [4096]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buffer, response.head.transfer_encoding, response.head.content_length);
        const response_body = try body_reader.*.readAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);
        
        // Parse JSON response from GitHub API
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();
        
        const obj = parsed.value.object;
        
        return GitHubUser{
            .id = @intCast(obj.get("id").?.integer),
            .login = try self.allocator.dupe(u8, obj.get("login").?.string),
            .name = if (obj.get("name")) |name| if (name != .null) try self.allocator.dupe(u8, name.string) else null else null,
            .email = if (obj.get("email")) |email| if (email != .null) try self.allocator.dupe(u8, email.string) else null else null,
            .avatar_url = if (obj.get("avatar_url")) |avatar| if (avatar != .null) try self.allocator.dupe(u8, avatar.string) else null else null,
            .bio = if (obj.get("bio")) |bio| if (bio != .null) try self.allocator.dupe(u8, bio.string) else null else null,
            .company = if (obj.get("company")) |company| if (company != .null) try self.allocator.dupe(u8, company.string) else null else null,
            .location = if (obj.get("location")) |location| if (location != .null) try self.allocator.dupe(u8, location.string) else null else null,
            .blog = if (obj.get("blog")) |blog| if (blog != .null) try self.allocator.dupe(u8, blog.string) else null else null,
            .public_repos = @intCast(obj.get("public_repos").?.integer),
            .followers = @intCast(obj.get("followers").?.integer),
            .following = @intCast(obj.get("following").?.integer),
            .created_at = try self.allocator.dupe(u8, obj.get("created_at").?.string),
            .updated_at = try self.allocator.dupe(u8, obj.get("updated_at").?.string),
        };
    }
    
    pub fn getUserEmails(self: *GitHubOAuthClient, access_token: []const u8) ![]GitHubEmail {
        _ = access_token;
        // This would make an HTTP GET request to https://api.github.com/user/emails
        // For now, return mock emails
        var emails = try self.allocator.alloc(GitHubEmail, 1);
        emails[0] = GitHubEmail{
            .email = "john@example.com",
            .primary = true,
            .verified = true,
            .visibility = "public",
        };
        return emails;
    }
    
    pub fn getUserOrganizations(self: *GitHubOAuthClient, access_token: []const u8) ![]GitHubOrganization {
        _ = access_token;
        // This would make an HTTP GET request to https://api.github.com/user/orgs
        // For now, return empty array
        return self.allocator.alloc(GitHubOrganization, 0);
    }
};

pub const GitHubOrganization = struct {
    id: u64,
    login: []const u8,
    description: ?[]const u8,
    avatar_url: ?[]const u8,
};

fn generateState(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    
    var encoded: [24]u8 = undefined; // Base64 of 16 bytes is ~22 chars
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random_bytes);
    return allocator.dupe(u8, std.mem.sliceTo(&encoded, 0));
}

// Helper function to parse GitHub's access token response
pub fn parseAccessTokenResponse(allocator: std.mem.Allocator, response: []const u8) !GitHubTokenResponse {
    // GitHub returns URL-encoded response like:
    // access_token=gho_16C7e42F292c6912E7710c838347Ae178B4a&scope=repo%2Cgist&token_type=bearer
    
    var token: ?[]const u8 = null;
    var scope: ?[]const u8 = null;
    var token_type: ?[]const u8 = null;
    
    var iter = std.mem.splitSequence(u8, response, "&");
    while (iter.next()) |param| {
        var param_iter = std.mem.splitSequence(u8, param, "=");
        const key = param_iter.next() orelse continue;
        const value = param_iter.next() orelse continue;
        
        if (std.mem.eql(u8, key, "access_token")) {
            token = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "scope")) {
            // URL decode the scope
            scope = try urlDecode(allocator, value);
        } else if (std.mem.eql(u8, key, "token_type")) {
            token_type = try allocator.dupe(u8, value);
        }
    }
    
    return GitHubTokenResponse{
        .access_token = token orelse return error.MissingAccessToken,
        .token_type = token_type orelse "bearer",
        .scope = scope orelse "",
    };
}

fn urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var decoded = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer decoded.deinit();
    
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hex = encoded[i + 1..i + 3];
            const byte = try std.fmt.parseInt(u8, hex, 16);
            try decoded.append(byte);
            i += 3;
        } else if (encoded[i] == '+') {
            try decoded.append(' ');
            i += 1;
        } else {
            try decoded.append(encoded[i]);
            i += 1;
        }
    }
    
    return decoded.toOwnedSlice();
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var encoded = std.array_list.AlignedManaged(u8, null).init(allocator);
    
    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try encoded.append(c);
            },
            ' ' => {
                try encoded.append('+');
            },
            else => {
                const hex_chars = "0123456789ABCDEF";
                try encoded.append('%');
                try encoded.append(hex_chars[(c >> 4) & 0xF]);
                try encoded.append(hex_chars[c & 0xF]);
            },
        }
    }
    
    return encoded.toOwnedSlice();
}