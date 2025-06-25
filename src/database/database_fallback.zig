const std = @import("std");

// Just re-export the in-memory database temporarily to get the system working
// We'll switch back to zqlite once the API issues are resolved
pub const Database = @import("database_inmemory.zig").Database;

// Re-export the Stats structure for compatibility
pub const Stats = Database.Stats;
