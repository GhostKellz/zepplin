const std = @import("std");
const oidc = @import("oidc.zig");

/// Google Sign-In configuration built on the shared OIDC core.
///
/// Google implements standard OIDC, so the default userinfo field mapping
/// (sub/email/name/picture/preferred_username) applies unchanged; only the
/// endpoints and credentials differ from other providers.
pub fn getConfig(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !oidc.OIDCConfig {
    const client_id = environ_map.get("GOOGLE_CLIENT_ID") orelse return error.MissingClientId;
    const client_secret = environ_map.get("GOOGLE_CLIENT_SECRET") orelse return error.MissingClientSecret;
    const redirect_base = environ_map.get("REDIRECT_BASE_URL") orelse "http://localhost:8888";

    return oidc.OIDCConfig{
        .provider_name = "google",
        .client_id = try allocator.dupe(u8, client_id),
        .client_secret = try allocator.dupe(u8, client_secret),
        .redirect_uri = try std.fmt.allocPrint(allocator, "{s}/api/v1/auth/oauth/google/callback", .{redirect_base}),
        .authorize_url = try allocator.dupe(u8, "https://accounts.google.com/o/oauth2/v2/auth"),
        .token_url = try allocator.dupe(u8, "https://oauth2.googleapis.com/token"),
        .userinfo_url = try allocator.dupe(u8, "https://openidconnect.googleapis.com/v1/userinfo"),
        .scope = try allocator.dupe(u8, "openid email profile"),
        .fields = .{},
    };
}

/// True when the Google provider has the required env configured.
pub fn isConfigured(environ_map: *std.process.Environ.Map) bool {
    return environ_map.get("GOOGLE_CLIENT_ID") != null and environ_map.get("GOOGLE_CLIENT_SECRET") != null;
}
