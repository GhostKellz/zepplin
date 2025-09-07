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
        const redirect_base = std.process.getEnvVarOwned(allocator, "REDIRECT_BASE_URL") catch "http://localhost:8080";
        
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
        const auth_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/login/oauth/authorize?client_id={s}&redirect_uri={s}&scope={s}",
            .{
                self.config.client_id,
                self.config.redirect_uri,
                self.config.scope,
            }
        );
        
        return auth_url;
    }
    
    pub fn exchangeCodeForToken(self: *GitHubOAuthClient, code: []const u8) !GitHubTokenResponse {
        _ = self;
        _ = code;
        // This would make an HTTP POST request to https://github.com/login/oauth/access_token
        // For now, return a mock response
        return GitHubTokenResponse{
            .access_token = "gho_mocktoken123456789",
            .token_type = "bearer",
            .scope = "read:user,user:email",
        };
    }
    
    pub fn getUser(self: *GitHubOAuthClient, access_token: []const u8) !GitHubUser {
        _ = self;
        _ = access_token;
        // This would make an HTTP GET request to https://api.github.com/user
        // For now, return a mock response
        return GitHubUser{
            .id = 1234567,
            .login = "johndoe",
            .name = "John Doe",
            .email = "john@example.com",
            .avatar_url = "https://avatars.githubusercontent.com/u/1234567",
            .bio = "Software Developer",
            .company = "Example Corp",
            .location = "San Francisco, CA",
            .blog = "https://johndoe.dev",
            .public_repos = 42,
            .followers = 100,
            .following = 50,
            .created_at = "2020-01-01T00:00:00Z",
            .updated_at = "2024-01-01T00:00:00Z",
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