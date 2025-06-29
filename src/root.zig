//! Zepplin - A lightweight, blazing-fast package manager for the Zig ecosystem
const std = @import("std");

// Export core modules
pub const types = @import("common/types.zig");
pub const cli = @import("cli/cli.zig");
pub const commands = @import("cli/commands.zig");
pub const server = @import("server/server.zig");
pub const database = @import("database/database.zig");
pub const auth = @import("auth/auth.zig");
pub const storage = @import("storage/storage.zig");
pub const config = @import("config/toml.zig");
pub const zigistry = @import("zigistry/client.zig");

pub fn getVersion() []const u8 {
    return "0.1.0";
}

pub fn printBanner() void {
    const banner =
        \\⚡ Zepplin v{s}
        \\Blazing-fast package manager for the Zig ecosystem
        \\
    ;
    std.debug.print(banner, .{getVersion()});
}
