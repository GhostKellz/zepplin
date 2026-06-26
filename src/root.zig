//! Zepplin - A lightweight, blazing-fast package manager for the Zig ecosystem
const std = @import("std");

// Export core modules
pub const types = @import("common/types.zig");
pub const cli = @import("cli/cli.zig");
pub const commands = @import("cli/commands.zig");
pub const server = @import("server/server.zig");
pub const database = @import("database/database.zig");
pub const auth = @import("auth/local.zig");
pub const session = @import("auth/session.zig");
pub const oidc = @import("auth/oidc.zig");
pub const entra = @import("auth/entra.zig");
pub const github = @import("auth/github.zig");
pub const storage = @import("storage/storage.zig");
pub const config = @import("config/toml.zig");
pub const zigistry = @import("zigistry/client.zig");

pub fn getVersion() []const u8 {
    return @import("build_options").version;
}

pub fn printBanner() void {
    const banner =
        \\⚡ Zepplin v{s}
        \\Blazing-fast package manager for the Zig ecosystem
        \\
    ;
    std.debug.print(banner, .{getVersion()});
}
