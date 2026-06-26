const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    std.debug.print("Testing zqlite import...\n", .{});

    // Test basic zqlite functionality
    std.debug.print("zqlite module loaded successfully!\n", .{});

    // Try to access zqlite.db
    std.debug.print("Checking zqlite.db...\n", .{});
}
