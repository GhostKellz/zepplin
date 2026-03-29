const std = @import("std");
const compat = @import("../common/compat.zig");
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
    
    pub fn getMicrosoftConfig(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !OIDCConfig {
        const tenant_id = environ_map.get("AZURE_TENANT_ID") orelse "common";
        const client_id = environ_map.get("AZURE_CLIENT_ID") orelse return error.MissingClientId;
        const client_secret = environ_map.get("AZURE_CLIENT_SECRET") orelse return error.MissingClientSecret;

        // Support both localhost and production URLs
        const redirect_base = environ_map.get("REDIRECT_BASE_URL") orelse "http://localhost:8888";

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
    io: std.Io,
    config: OIDCConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: OIDCConfig) OIDCClient {
        return .{
            .allocator = allocator,
            .io = io,
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
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        // Build token endpoint URL
        const token_url = try std.fmt.allocPrint(self.allocator, "{s}/oauth2/v2.0/token", .{self.config.authority});
        defer self.allocator.free(token_url);
        std.debug.print("🌐 Token URL: {s}\n", .{token_url});

        // URL encode redirect_uri for the POST body
        const encoded_redirect = try urlEncode(self.allocator, self.config.redirect_uri);
        defer self.allocator.free(encoded_redirect);

        // Build request body
        const body = try std.fmt.allocPrint(self.allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={s}&client_id={s}&client_secret={s}",
            .{ code, encoded_redirect, self.config.client_id, self.config.client_secret }
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
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            std.debug.print("❌ Microsoft: Failed to receive response: {}\n", .{err});
            return error.TokenExchangeFailed;
        };
        std.debug.print("📥 Response status: {}\n", .{response.head.status});

        // Read response body using streamRemaining
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        var transfer_buffer: [4096]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        _ = body_reader.streamRemaining(&response_writer.writer) catch |err| {
            std.debug.print("❌ Microsoft: Failed to read body: {}\n", .{err});
            if (response.bodyErr()) |body_err| {
                std.debug.print("❌ Microsoft body error details: {}\n", .{body_err});
            }
            return error.TokenExchangeFailed;
        };

        const response_body = response_writer.written();

        if (response.head.status != .ok) {
            std.debug.print("❌ Token exchange failed with status: {}\n", .{response.head.status});
            std.debug.print("❌ Microsoft error response: {s}\n", .{response_body});
            return error.TokenExchangeFailed;
        }

        // Parse JSON response
        std.debug.print("📄 Parsing Microsoft token response...\n", .{});
        std.debug.print("📄 Response body length: {}\n", .{response_body.len});

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch |err| {
            std.debug.print("❌ Microsoft: JSON parse error: {}\n", .{err});
            std.debug.print("❌ Response was: {s}\n", .{response_body});
            return error.TokenExchangeFailed;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Check for error in response
        if (obj.get("error")) |err_val| {
            std.debug.print("❌ Microsoft OAuth error: {s}\n", .{err_val.string});
            if (obj.get("error_description")) |desc| {
                std.debug.print("❌ Microsoft error description: {s}\n", .{desc.string});
            }
            return error.TokenExchangeFailed;
        }

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
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
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
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) {
            std.debug.print("User info request failed with status: {}\n", .{response.head.status});
            return error.UserInfoFailed;
        }

        // Read response body using streamRemaining
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        var transfer_buffer: [4096]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        _ = body_reader.streamRemaining(&response_writer.writer) catch |err| {
            std.debug.print("Microsoft: Failed to read user info body: {}\n", .{err});
            return error.UserInfoFailed;
        };

        const response_body = response_writer.written();
        
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
    
    pub fn refreshToken(self: *OIDCClient, refresh_token_value: []const u8) !OIDCTokenResponse {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        // Build token endpoint URL
        const token_url = try std.fmt.allocPrint(self.allocator, "{s}/oauth2/v2.0/token", .{self.config.authority});
        defer self.allocator.free(token_url);

        // Build refresh request body
        const body = try std.fmt.allocPrint(
            self.allocator,
            "grant_type=refresh_token&refresh_token={s}&client_id={s}&client_secret={s}&scope={s}",
            .{ refresh_token_value, self.config.client_id, self.config.client_secret, self.config.scope },
        );
        defer self.allocator.free(body);

        const uri = try std.Uri.parse(token_url);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        };

        var req = try client.request(.POST, uri, .{ .extra_headers = &headers });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        var redirect_buffer: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) {
            return error.RefreshTokenFailed;
        }

        // Read response body using streamRemaining
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        var transfer_buffer: [4096]u8 = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

        _ = body_reader.streamRemaining(&response_writer.writer) catch |err| {
            std.debug.print("Microsoft: Failed to read refresh token body: {}\n", .{err});
            return error.RefreshTokenFailed;
        };

        const response_body = response_writer.written();

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        return OIDCTokenResponse{
            .access_token = try self.allocator.dupe(u8, obj.get("access_token").?.string),
            .token_type = try self.allocator.dupe(u8, obj.get("token_type").?.string),
            .expires_in = @intCast(obj.get("expires_in").?.integer),
            .scope = try self.allocator.dupe(u8, obj.get("scope").?.string),
            .id_token = try self.allocator.dupe(u8, obj.get("id_token").?.string),
            .refresh_token = if (obj.get("refresh_token")) |rt| try self.allocator.dupe(u8, rt.string) else null,
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
    compat.cryptoRandomBytes(&random_bytes);
    
    var encoded: [24]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random_bytes);
    return allocator.dupe(u8, std.mem.sliceTo(&encoded, 0));
}

fn generateNonce(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    compat.cryptoRandomBytes(&random_bytes);
    
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
        .exp = compat.timestamp() + 3600,
        .iat = compat.timestamp(),
        .nonce = null,
        .email = "user@example.com",
        .name = "John Doe",
    };
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;

    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try encoded.append(allocator, c);
            },
            ' ' => {
                try encoded.append(allocator, '+');
            },
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