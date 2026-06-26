const std = @import("std");
const oidc = @import("oidc.zig");

/// Microsoft Entra ID (Azure AD) configuration built on the shared OIDC core.
///
/// Microsoft Graph (`/me`) does not use the standard OIDC claim names, so the
/// userinfo field mapping is overridden: id/displayName/mail with
/// userPrincipalName as the email fallback and preferred username.
pub fn getConfig(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !oidc.OIDCConfig {
    const tenant_id = environ_map.get("AZURE_TENANT_ID") orelse "common";
    const client_id = environ_map.get("AZURE_CLIENT_ID") orelse return error.MissingClientId;
    const client_secret = environ_map.get("AZURE_CLIENT_SECRET") orelse return error.MissingClientSecret;
    const redirect_base = environ_map.get("REDIRECT_BASE_URL") orelse "http://localhost:8888";

    return oidc.OIDCConfig{
        .provider_name = "microsoft",
        .client_id = try allocator.dupe(u8, client_id),
        .client_secret = try allocator.dupe(u8, client_secret),
        .redirect_uri = try std.fmt.allocPrint(allocator, "{s}/api/v1/auth/oidc/microsoft/callback", .{redirect_base}),
        .authorize_url = try std.fmt.allocPrint(allocator, "https://login.microsoftonline.com/{s}/oauth2/v2.0/authorize", .{tenant_id}),
        .token_url = try std.fmt.allocPrint(allocator, "https://login.microsoftonline.com/{s}/oauth2/v2.0/token", .{tenant_id}),
        .userinfo_url = try allocator.dupe(u8, "https://graph.microsoft.com/v1.0/me"),
        .scope = try allocator.dupe(u8, "openid profile email User.Read"),
        .fields = .{
            .sub = "id",
            .email = "mail",
            .name = "displayName",
            .picture = "picture",
            .preferred_username = "userPrincipalName",
            .email_fallback = "userPrincipalName",
        },
    };
}

/// True when the Microsoft provider has the required env configured.
pub fn isConfigured(environ_map: *std.process.Environ.Map) bool {
    return environ_map.get("AZURE_CLIENT_ID") != null and environ_map.get("AZURE_CLIENT_SECRET") != null;
}
