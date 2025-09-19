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
        const redirect_base = std.process.getEnvVarOwned(allocator, "REDIRECT_BASE_URL") catch "http://localhost:8888";
        
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
        
        // URL encode the parameters that need encoding
        const encoded_redirect_uri = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect_uri);
        
        const encoded_scope = try urlEncode(self.allocator, self.config.scope);
        defer self.allocator.free(encoded_scope);
        
        const auth_url = switch (self.config.provider) {
            .microsoft => try std.fmt.allocPrint(
                self.allocator,
                "{s}/oauth2/v2.0/authorize?client_id={s}&response_type=code&redirect_uri={s}&scope={s}&state={s}&nonce={s}",
                .{
                    self.config.authority,
                    self.config.client_id,
                    encoded_redirect_uri,
                    encoded_scope,
                    state,
                    nonce,
                }
            ),
            else => return error.UnsupportedProvider,
        };
        
        return auth_url;
    }
    
    pub fn exchangeCodeForToken(self: *OIDCClient, code: []const u8) !OIDCTokenResponse {
        std.debug.print("🔄 Starting Microsoft token exchange...\n", .{});
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        // Build token endpoint URL
        const token_url = try std.fmt.allocPrint(self.allocator, "{s}/oauth2/v2.0/token", .{self.config.authority});
        defer self.allocator.free(token_url);
        std.debug.print("🌐 Token URL: {s}\n", .{token_url});
        
        // Build request body
        const body = try std.fmt.allocPrint(self.allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&client_secret={s}",
            .{ code, self.config.redirect_uri, self.config.client_id, self.config.client_secret }
        );
        defer self.allocator.free(body);
        
        const uri = try std.Uri.parse(token_url);
        
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        };
        
        std.debug.print("📨 Making POST request to Microsoft token endpoint...\n", .{});
        var req = try client.request(.POST, uri, .{ .extra_headers = &headers });
        defer req.deinit();
        
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);
        std.debug.print("📤 Request sent, waiting for response...\n", .{});
        
        var redirect_buffer: [1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);
        std.debug.print("📥 Response status: {}\n", .{response.head.status});
        
        if (response.head.status != .ok) {
            std.debug.print("❌ Token exchange failed with status: {}\n", .{response.head.status});
            return error.TokenExchangeFailed;
        }
        
        var transfer_buffer: [4096]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buffer, response.head.transfer_encoding, response.head.content_length);
        const response_body = try body_reader.*.readAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);
        
        // Parse JSON response
        std.debug.print("📄 Parsing Microsoft token response...\n", .{});
        std.debug.print("📄 Response body: {s}\n", .{response_body});
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();
        
        const obj = parsed.value.object;
        
        std.debug.print("✅ Microsoft token exchange successful\n", .{});
        return OIDCTokenResponse{
            .access_token = try self.allocator.dupe(u8, obj.get("access_token").?.string),
            .token_type = try self.allocator.dupe(u8, obj.get("token_type").?.string),
            .expires_in = @intCast(obj.get("expires_in").?.integer),
            .scope = try self.allocator.dupe(u8, obj.get("scope").?.string),
            .id_token = try self.allocator.dupe(u8, obj.get("id_token").?.string),
            .refresh_token = if (obj.get("refresh_token")) |rt| try self.allocator.dupe(u8, rt.string) else null,
        };
    }
    
    pub fn getUserInfo(self: *OIDCClient, access_token: []const u8) !OIDCUserInfo {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        // Use Microsoft Graph API to get user info
        const userinfo_url = "https://graph.microsoft.com/v1.0/me";
        const uri = try std.Uri.parse(userinfo_url);
        
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{access_token});
        defer self.allocator.free(auth_header);
        
        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
        };
        
        var req = try client.request(.GET, uri, .{ .extra_headers = &headers });
        defer req.deinit();
        
        try req.sendBodiless();
        
        var redirect_buffer: [1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);
        
        if (response.head.status != .ok) {
            std.debug.print("User info request failed with status: {}\n", .{response.head.status});
            return error.UserInfoFailed;
        }
        
        var transfer_buffer: [4096]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buffer, response.head.transfer_encoding, response.head.content_length);
        const response_body = try body_reader.*.readAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);
        
        // Parse JSON response from Microsoft Graph
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();
        
        const obj = parsed.value.object;
        
        return OIDCUserInfo{
            .sub = try self.allocator.dupe(u8, obj.get("id").?.string),
            .email = if (obj.get("mail")) |mail| try self.allocator.dupe(u8, mail.string) else if (obj.get("userPrincipalName")) |upn| try self.allocator.dupe(u8, upn.string) else null,
            .email_verified = true,  // Microsoft accounts are verified
            .name = if (obj.get("displayName")) |name| try self.allocator.dupe(u8, name.string) else null,
            .given_name = if (obj.get("givenName")) |gn| try self.allocator.dupe(u8, gn.string) else null,
            .family_name = if (obj.get("surname")) |surname| try self.allocator.dupe(u8, surname.string) else null,
            .picture = null,  // Would need additional API call for photo
            .preferred_username = if (obj.get("userPrincipalName")) |upn| try self.allocator.dupe(u8, upn.string) else null,
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