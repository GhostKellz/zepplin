const std = @import("std");
const types = @import("../common/types.zig");

// Use SQLite database - persistent SQL storage
pub const Database = @import("database_sqlite.zig").Database;
