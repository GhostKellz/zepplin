const std = @import("std");
const types = @import("../common/types.zig");

/// In-memory database implementation (ready for zqlite upgrade)
/// This provides a working package registry with all the features
/// needed for Zepplin, using HashMaps and ArrayLists for storage.
///
/// When zqlite hash is fixed, this can be easily replaced with:
/// const zqlite = @import("zqlite");
/// And the storage can be upgraded to persistent SQLite.
pub const Database = struct {
    allocator: std.mem.Allocator,
    packages: std.ArrayList(types.Package),
    users: std.StringHashMap(User),
    download_stats: std.StringHashMap(u64),

    const User = struct {
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        api_token: []const u8,
        created_at: i64,
        is_active: bool,
    };

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        // TODO: When zqlite is available, use:
        // const db = try zqlite.open(db_path);
        _ = db_path; // For now, just use in-memory storage

        var database = Database{
            .allocator = allocator,
            .packages = std.ArrayList(types.Package).init(allocator),
            .users = std.StringHashMap(User).init(allocator),
            .download_stats = std.StringHashMap(u64).init(allocator),
        };

        // Add demo packages
        try database.packages.append(types.Package{
            .name = "xev",
            .version = "0.2.0",
            .description = "Cross-platform event loop",
            .author = "Mitchell Hashimoto",
            .license = "MIT",
            .repository = "https://github.com/mitchellh/libxev",
            .dependencies = &[_]types.Dependency{},
            .file_path = null,
            .file_size = null,
            .checksum = null,
        });

        try database.packages.append(types.Package{
            .name = "zig-cli",
            .version = "0.8.0",
            .description = "Command line argument parsing library",
            .author = "Sam Windell",
            .license = "MIT",
            .repository = "https://github.com/sam701/zig-cli",
            .dependencies = &[_]types.Dependency{},
            .file_path = null,
            .file_size = null,
            .checksum = null,
        });

        try database.packages.append(types.Package{
            .name = "zqlite",
            .version = "0.3.0",
            .description = "Pure Zig SQLite alternative",
            .author = "GhostKellz",
            .license = "MIT",
            .repository = "https://github.com/ghostkellz/zqlite",
            .dependencies = &[_]types.Dependency{},
            .file_path = null,
            .file_size = null,
            .checksum = null,
        });

        try database.packages.append(types.Package{
            .name = "zepplin",
            .version = "0.1.0",
            .description = "Zig package manager and registry",
            .author = "Zepplin Team",
            .license = "MIT",
            .repository = "https://github.com/ghostkellz/zepplin",
            .dependencies = &[_]types.Dependency{},
            .file_path = null,
            .file_size = null,
            .checksum = null,
        });

        // Add demo user
        try database.users.put("testuser", User{
            .username = "testuser",
            .email = "test@example.com",
            .password_hash = "mock-hash",
            .api_token = "test-token",
            .created_at = std.time.timestamp(),
            .is_active = true,
        });

        // Add some download stats
        try database.download_stats.put("xev", 1247);
        try database.download_stats.put("zig-cli", 856);
        try database.download_stats.put("zqlite", 342);

        return database;
    }

    pub fn deinit(self: *Database) void {
        self.packages.deinit();
        self.users.deinit();
        self.download_stats.deinit();
    }

    // Package operations
    pub fn addPackage(self: *Database, package: types.Package) !void {
        // TODO: When zqlite is available, use SQL INSERT
        try self.packages.append(package);
    }

    pub fn getPackage(self: *Database, name: []const u8) !?types.Package {
        for (self.packages.items) |package| {
            if (std.mem.eql(u8, package.name, name)) {
                return package;
            }
        }
        return null;
    }

    pub fn listPackages(self: *Database) ![]types.Package {
        return try self.allocator.dupe(types.Package, self.packages.items);
    }

    pub fn searchPackages(self: *Database, query: []const u8) ![]types.Package {
        var results = std.ArrayList(types.Package).init(self.allocator);
        defer results.deinit();

        for (self.packages.items) |package| {
            // Simple search in name and description
            if (std.mem.indexOf(u8, package.name, query) != null or
                (package.description != null and std.mem.indexOf(u8, package.description.?, query) != null))
            {
                try results.append(package);
            }
        }

        return try results.toOwnedSlice();
    }

    pub fn removePackage(self: *Database, name: []const u8) !void {
        for (self.packages.items, 0..) |package, i| {
            if (std.mem.eql(u8, package.name, name)) {
                _ = self.packages.orderedRemove(i);
                return;
            }
        }
    }

    // User operations
    pub fn createUser(self: *Database, username: []const u8, email: []const u8, password_hash: []const u8, api_token: []const u8) !void {
        // TODO: When zqlite is available, use SQL INSERT
        try self.users.put(username, User{
            .username = username,
            .email = email,
            .password_hash = password_hash,
            .api_token = api_token,
            .created_at = std.time.timestamp(),
            .is_active = true,
        });
    }

    pub fn getUserByToken(self: *Database, token: []const u8) !?[]const u8 {
        var iterator = self.users.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.api_token, token) and entry.value_ptr.is_active) {
                return entry.value_ptr.username;
            }
        }
        return null;
    }

    pub fn getUserByUsername(self: *Database, username: []const u8) !?[]const u8 {
        if (self.users.get(username)) |user| {
            if (user.is_active) {
                return user.password_hash;
            }
        }
        return null;
    }

    // Stats operations
    pub fn incrementDownloadCount(self: *Database, package_name: []const u8) !void {
        const current = self.download_stats.get(package_name) orelse 0;
        try self.download_stats.put(package_name, current + 1);
    }

    pub fn getDownloadCount(self: *Database, package_name: []const u8) !u64 {
        return self.download_stats.get(package_name) orelse 0;
    }

    pub fn getTotalPackages(self: *Database) !u64 {
        return @intCast(self.packages.items.len);
    }

    pub fn getTotalDownloads(self: *Database) !u64 {
        var total: u64 = 0;
        var iterator = self.download_stats.iterator();
        while (iterator.next()) |entry| {
            total += entry.value_ptr.*;
        }
        return total;
    }
};

// TODO: When zqlite hash is fixed, replace this file with:
//
// const std = @import("std");
// const zqlite = @import("zqlite");
// const types = @import("../common/types.zig");
//
// pub const Database = struct {
//     db: *zqlite.db.Connection,
//     allocator: std.mem.Allocator,
//
//     pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
//         const db = try zqlite.open(db_path);
//         // ... SQL table creation from CIPHER_INTEGRATION.md example
//         return Database{ .db = db, .allocator = allocator };
//     }
//
//     pub fn deinit(self: *Database) void {
//         self.db.close();
//     }
//
//     // ... implement all methods with SQL queries
// };
