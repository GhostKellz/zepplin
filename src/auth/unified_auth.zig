const std = @import("std");
const types = @import("../common/types.zig");
const auth_oidc = @import("auth_oidc.zig");
const auth_github = @import("auth_github.zig");

pub const AuthProvider = enum {
    local,
    microsoft,
    github,
    google,
};

pub const AuthSession = struct {
    id: []const u8,
    user_id: u64,
    provider: AuthProvider,
    access_token: []const u8,
    refresh_token: ?[]const u8,
    expires_at: i64,
    created_at: i64,
};

pub const LinkedAccount = struct {
    user_id: u64,
    provider: AuthProvider,
    provider_id: []const u8,
    email: ?[]const u8,
    display_name: ?[]const u8,
    linked_at: i64,
};

pub const UnifiedUser = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    display_name: ?[]const u8,
    avatar_url: ?[]const u8,
    primary_provider: AuthProvider,
    linked_accounts: []LinkedAccount,
    api_token: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const UnifiedAuthSystem = struct {
    allocator: std.mem.Allocator,
    oidc_client: ?auth_oidc.OIDCClient,
    github_client: ?auth_github.GitHubOAuthClient,
    jwt_secret: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) !UnifiedAuthSystem {
        const jwt_secret = std.process.getEnvVarOwned(allocator, "JWT_SECRET") catch "default_secret_change_in_production";
        
        // Initialize OIDC client if configured
        var oidc_client: ?auth_oidc.OIDCClient = null;
        if (std.process.hasEnvVarConstant("AZURE_CLIENT_ID")) {
            const oidc_config = try auth_oidc.OIDCConfig.getMicrosoftConfig(allocator);
            oidc_client = auth_oidc.OIDCClient.init(allocator, oidc_config);
        }
        
        // Initialize GitHub client if configured
        var github_client: ?auth_github.GitHubOAuthClient = null;
        if (std.process.hasEnvVarConstant("GITHUB_CLIENT_ID")) {
            const github_config = try auth_github.GitHubOAuthConfig.fromEnv(allocator);
            github_client = auth_github.GitHubOAuthClient.init(allocator, github_config);
        }
        
        return UnifiedAuthSystem{
            .allocator = allocator,
            .oidc_client = oidc_client,
            .github_client = github_client,
            .jwt_secret = try allocator.dupe(u8, jwt_secret),
        };
    }
    
    pub fn deinit(self: *UnifiedAuthSystem) void {
        if (self.oidc_client) |*client| {
            client.deinit();
        }
        if (self.github_client) |*client| {
            client.deinit();
        }
        self.allocator.free(self.jwt_secret);
    }
    
    
    pub fn getAuthorizationUrl(self: *UnifiedAuthSystem, provider: AuthProvider) ![]u8 {
        switch (provider) {
            .microsoft => {
                if (self.oidc_client) |*client| {
                    return client.getAuthorizationUrl();
                }
                return error.ProviderNotConfigured;
            },
            .github => {
                if (self.github_client) |*client| {
                    return client.getAuthorizationUrl();
                }
                return error.ProviderNotConfigured;
            },
            else => return error.UnsupportedProvider,
        }
    }
    
    pub fn handleCallback(self: *UnifiedAuthSystem, provider: AuthProvider, code: []const u8) !UnifiedUser {
        switch (provider) {
            .microsoft => {
                if (self.oidc_client) |*client| {
                    const token_response = try client.exchangeCodeForToken(code);
                    defer {
                        self.allocator.free(token_response.access_token);
                        self.allocator.free(token_response.token_type);
                        self.allocator.free(token_response.scope);
                        self.allocator.free(token_response.id_token);
                        if (token_response.refresh_token) |rt| self.allocator.free(rt);
                    }
                    
                    const user_info = try client.getUserInfo(token_response.access_token);
                    defer {
                        self.allocator.free(user_info.sub);
                        if (user_info.email) |email| self.allocator.free(email);
                        if (user_info.name) |name| self.allocator.free(name);
                        if (user_info.given_name) |gn| self.allocator.free(gn);
                        if (user_info.family_name) |family_name| self.allocator.free(family_name);
                        if (user_info.preferred_username) |pu| self.allocator.free(pu);
                    }
                    
                    // Create or update user based on OIDC info - duplicate strings for return
                    return UnifiedUser{
                        .id = 1, // Would be generated/fetched from database
                        .username = try self.allocator.dupe(u8, user_info.preferred_username orelse user_info.email orelse "user"),
                        .email = try self.allocator.dupe(u8, user_info.email orelse ""),
                        .display_name = if (user_info.name) |name| try self.allocator.dupe(u8, name) else null,
                        .avatar_url = if (user_info.picture) |pic| try self.allocator.dupe(u8, pic) else null,
                        .primary_provider = .microsoft,
                        .linked_accounts = &[_]LinkedAccount{},
                        .api_token = null,
                        .created_at = std.time.timestamp(),
                        .updated_at = std.time.timestamp(),
                    };
                }
                return error.ProviderNotConfigured;
            },
            .github => {
                if (self.github_client) |*client| {
                    const token_response = try client.exchangeCodeForToken(code);
                    defer {
                        self.allocator.free(token_response.access_token);
                        self.allocator.free(token_response.token_type);
                        self.allocator.free(token_response.scope);
                    }
                    
                    const github_user = try client.getUser(token_response.access_token);
                    defer {
                        self.allocator.free(github_user.login);
                        if (github_user.name) |name| self.allocator.free(name);
                        if (github_user.email) |email| self.allocator.free(email);
                        if (github_user.avatar_url) |avatar| self.allocator.free(avatar);
                        if (github_user.bio) |bio| self.allocator.free(bio);
                        if (github_user.company) |company| self.allocator.free(company);
                        if (github_user.location) |location| self.allocator.free(location);
                        if (github_user.blog) |blog| self.allocator.free(blog);
                        self.allocator.free(github_user.created_at);
                        self.allocator.free(github_user.updated_at);
                    }
                    
                    // Create or update user based on GitHub info - duplicate strings for return
                    return UnifiedUser{
                        .id = github_user.id,
                        .username = try self.allocator.dupe(u8, github_user.login),
                        .email = try self.allocator.dupe(u8, github_user.email orelse ""),
                        .display_name = if (github_user.name) |name| try self.allocator.dupe(u8, name) else null,
                        .avatar_url = if (github_user.avatar_url) |avatar| try self.allocator.dupe(u8, avatar) else null,
                        .primary_provider = .github,
                        .linked_accounts = &[_]LinkedAccount{},
                        .api_token = null,
                        .created_at = std.time.timestamp(),
                        .updated_at = std.time.timestamp(),
                    };
                }
                return error.ProviderNotConfigured;
            },
            else => return error.UnsupportedProvider,
        }
    }
    
    pub fn createJWT(self: *UnifiedAuthSystem, user: UnifiedUser) ![]u8 {
        // Create JWT header
        const header = 
            \\{"alg":"HS256","typ":"JWT"}
        ;
        
        // Create JWT payload
        const payload = try std.fmt.allocPrint(
            self.allocator,
            \\{{
            \\  "sub": "{}",
            \\  "username": "{s}",
            \\  "email": "{s}",
            \\  "display_name": "{s}",
            \\  "avatar_url": "{s}",
            \\  "provider": "{s}",
            \\  "iat": {},
            \\  "exp": {}
            \\}}
        ,
            .{
                user.id,
                user.username,
                user.email,
                user.display_name orelse user.username,
                user.avatar_url orelse "",
                @tagName(user.primary_provider),
                std.time.timestamp(),
                std.time.timestamp() + 86400, // 24 hours
            }
        );
        defer self.allocator.free(payload);
        
        // Base64 encode header and payload
        var header_buf: [256]u8 = undefined;
        var payload_buf: [512]u8 = undefined;
        const header_encoded = std.base64.url_safe_no_pad.Encoder.encode(&header_buf, header);
        const payload_encoded = std.base64.url_safe_no_pad.Encoder.encode(&payload_buf, payload);
        
        // Create signature
        const signing_input = try std.fmt.allocPrint(
            self.allocator,
            "{s}.{s}",
            .{ header_encoded, payload_encoded }
        );
        defer self.allocator.free(signing_input);
        
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(self.jwt_secret);
        hmac.update(signing_input);
        var signature: [32]u8 = undefined;
        hmac.final(&signature);
        
        var sig_buf: [64]u8 = undefined;
        const signature_encoded = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &signature);
        
        // Combine all parts
        return std.fmt.allocPrint(
            self.allocator,
            "{s}.{s}.{s}",
            .{ header_encoded, payload_encoded, signature_encoded }
        );
    }
    
    pub fn validateJWT(self: *UnifiedAuthSystem, token: []const u8) !bool {
        // Split token into parts
        var parts = std.mem.splitSequence(u8, token, ".");
        const header = parts.next() orelse return false;
        const payload = parts.next() orelse return false;
        const signature = parts.next() orelse return false;
        
        // Verify signature
        const signing_input = try std.fmt.allocPrint(
            self.allocator,
            "{s}.{s}",
            .{ header, payload }
        );
        defer self.allocator.free(signing_input);
        
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(self.jwt_secret);
        hmac.update(signing_input);
        var expected_signature: [32]u8 = undefined;
        hmac.final(&expected_signature);
        
        var exp_buf: [64]u8 = undefined;
        const expected_encoded = std.base64.url_safe_no_pad.Encoder.encode(&exp_buf, &expected_signature);
        
        return std.mem.eql(u8, signature, expected_encoded);
    }
    
    pub fn linkAccount(self: *UnifiedAuthSystem, user_id: u64, provider: AuthProvider, code: []const u8) !LinkedAccount {
        _ = self;
        _ = code;
        // This would link an additional provider to an existing user account
        return LinkedAccount{
            .user_id = user_id,
            .provider = provider,
            .provider_id = "provider_123",
            .email = "linked@example.com",
            .display_name = "Linked Account",
            .linked_at = std.time.timestamp(),
        };
    }
    
    pub fn unlinkAccount(self: *UnifiedAuthSystem, user_id: u64, provider: AuthProvider) !void {
        _ = self;
        _ = user_id;
        _ = provider;
        // This would unlink a provider from a user account
    }
    
    pub fn getLinkedProviders(self: *UnifiedAuthSystem, user_id: u64) ![]AuthProvider {
        _ = user_id;
        // This would fetch all linked providers for a user
        return self.allocator.alloc(AuthProvider, 0);
    }
};