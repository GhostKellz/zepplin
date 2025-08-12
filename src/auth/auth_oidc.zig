const std = @import("std");
const types = @import("../common/types.zig");

pub const OIDCProvider = enum {
    microsoft,
    google,
    okta,
};

pub const OIDCConfig = struct {
    provider: OIDCProvider,
    tenant_id: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    authority: []const u8,
    scope: []const u8,
    
    pub fn getMicrosoftConfig(allocator: std.mem.Allocator) !OIDCConfig {
        const tenant_id = std.process.getEnvVarOwned(allocator, "AZURE_TENANT_ID") catch "common";
        const client_id = std.process.getEnvVarOwned(allocator, "AZURE_CLIENT_ID") catch return error.MissingClientId;
        const client_secret = std.process.getEnvVarOwned(allocator, "AZURE_CLIENT_SECRET") catch return error.MissingClientSecret;
        
        // Support both localhost and production URLs
        const redirect_base = std.process.getEnvVarOwned(allocator, "REDIRECT_BASE_URL") catch "http://localhost:8080";
        
        return OIDCConfig{
            .provider = .microsoft,
            .tenant_id = try allocator.dupe(u8, tenant_id),
            .client_id = try allocator.dupe(u8, client_id),
            .client_secret = try allocator.dupe(u8, client_secret),
            .redirect_uri = try std.fmt.allocPrint(allocator, "{s}/api/v1/auth/oidc/microsoft/callback", .{redirect_base}),
            .authority = try std.fmt.allocPrint(allocator, "https://login.microsoftonline.com/{s}", .{tenant_id}),
            .scope = try allocator.dupe(u8, "openid profile email User.Read"),
        };
    }
};

pub const OIDCTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: u32,
    scope: []const u8,
    id_token: []const u8,
    refresh_token: ?[]const u8,
};

pub const OIDCUserInfo = struct {
    sub: []const u8,  // Subject identifier
    email: ?[]const u8,
    email_verified: ?bool,
    name: ?[]const u8,
    given_name: ?[]const u8,
    family_name: ?[]const u8,
    picture: ?[]const u8,
    preferred_username: ?[]const u8,
};

pub const OIDCClient = struct {
    allocator: std.mem.Allocator,
    config: OIDCConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: OIDCConfig) OIDCClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    pub fn deinit(self: *OIDCClient) void {
        _ = self;
    }
    
    pub fn getAuthorizationUrl(self: *OIDCClient) ![]u8 {
        const state = try generateState(self.allocator);
        defer self.allocator.free(state);
        
        const nonce = try generateNonce(self.allocator);
        defer self.allocator.free(nonce);
        
        const auth_url = switch (self.config.provider) {
            .microsoft => try std.fmt.allocPrint(
                self.allocator,
                "{s}/oauth2/v2.0/authorize?client_id={s}&response_type=code&redirect_uri={s}&scope={s}&state={s}&nonce={s}",
                .{
                    self.config.authority,
                    self.config.client_id,
                    self.config.redirect_uri,
                    self.config.scope,
                    state,
                    nonce,
                }
            ),
            else => return error.UnsupportedProvider,
        };
        
        return auth_url;
    }
    
    pub fn exchangeCodeForToken(self: *OIDCClient, code: []const u8) !OIDCTokenResponse {
        _ = self;
        _ = code;
        // This would make an HTTP POST request to the token endpoint
        // For now, return a mock response
        return OIDCTokenResponse{
            .access_token = "mock_access_token",
            .token_type = "Bearer",
            .expires_in = 3600,
            .scope = "openid profile email",
            .id_token = "mock_id_token",
            .refresh_token = "mock_refresh_token",
        };
    }
    
    pub fn getUserInfo(self: *OIDCClient, access_token: []const u8) !OIDCUserInfo {
        _ = self;
        _ = access_token;
        // This would make an HTTP GET request to the userinfo endpoint
        // For now, return a mock response
        return OIDCUserInfo{
            .sub = "1234567890",
            .email = "user@example.com",
            .email_verified = true,
            .name = "John Doe",
            .given_name = "John",
            .family_name = "Doe",
            .picture = null,
            .preferred_username = "johndoe",
        };
    }
    
    pub fn refreshToken(self: *OIDCClient, refresh_token: []const u8) !OIDCTokenResponse {
        _ = self;
        _ = refresh_token;
        // This would make an HTTP POST request to refresh the token
        // For now, return a mock response
        return OIDCTokenResponse{
            .access_token = "new_mock_access_token",
            .token_type = "Bearer",
            .expires_in = 3600,
            .scope = "openid profile email",
            .id_token = "new_mock_id_token",
            .refresh_token = "new_mock_refresh_token",
        };
    }
    
    pub fn validateIdToken(self: *OIDCClient, id_token: []const u8) !bool {
        _ = self;
        _ = id_token;
        // This would validate the JWT signature and claims
        // For now, return true
        return true;
    }
};

fn generateState(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    
    var encoded: [24]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random_bytes);
    return allocator.dupe(u8, std.mem.sliceTo(&encoded, 0));
}

fn generateNonce(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    
    var encoded: [24]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random_bytes);
    return allocator.dupe(u8, std.mem.sliceTo(&encoded, 0));
}

// JWT decoding for ID tokens
pub const JWTClaims = struct {
    iss: []const u8,  // Issuer
    sub: []const u8,  // Subject
    aud: []const u8,  // Audience
    exp: i64,         // Expiration time
    iat: i64,         // Issued at
    nonce: ?[]const u8,
    email: ?[]const u8,
    name: ?[]const u8,
};

pub fn decodeJWT(allocator: std.mem.Allocator, token: []const u8) !JWTClaims {
    _ = allocator;
    _ = token;
    // This would properly decode and validate a JWT
    // For now, return mock claims
    return JWTClaims{
        .iss = "https://login.microsoftonline.com/tenant/v2.0",
        .sub = "1234567890",
        .aud = "client_id",
        .exp = std.time.timestamp() + 3600,
        .iat = std.time.timestamp(),
        .nonce = null,
        .email = "user@example.com",
        .name = "John Doe",
    };
}