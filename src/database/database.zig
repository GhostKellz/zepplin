const std = @import("std");
const types = @import("../common/types.zig");

// Use zqlite database - post-quantum secure storage
pub const Database = @import("database_zqlite.zig").Database;
