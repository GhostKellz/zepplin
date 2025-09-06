const std = @import("std");
const types = @import("../common/types.zig");

/// In-memory database implementation (ready for SQLite upgrade)
/// This provides a working package registry with all the features
/// needed for Zepplin, using HashMaps and ArrayLists for storage.
///
/// The SQLite implementation at database_sqlite.zig provides
/// persistent storage with excellent performance.
pub const Database = struct {
    allocator: std.mem.Allocator,
    packages: std.array_list.AlignedManaged(types.Package, null),
    users: std.StringHashMap(User),
    download_stats: std.StringHashMap(u64),
    comments: std.array_list.AlignedManaged(types.Comment, null),
    comment_id_counter: std.atomic.Atomic(u64),

    const User = struct {
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        api_token: []const u8,
        created_at: i64,
        is_active: bool,
    };

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        // For in-memory storage, db_path is ignored
        _ = db_path;

        var database = Database{
            .allocator = allocator,
            .packages = std.array_list.AlignedManaged(types.Package, null).init(allocator),
            .users = std.StringHashMap(User).init(allocator),
            .download_stats = std.StringHashMap(u64).init(allocator),
            .comments = std.array_list.AlignedManaged(types.Comment, null).init(allocator),
            .comment_id_counter = std.atomic.Atomic(u64).init(1),
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
            .name = "sqlite",
            .version = "3.46.0",
            .description = "Embedded SQL database engine",
            .author = "SQLite Development Team",
            .license = "Public Domain",
            .repository = "https://www.sqlite.org/",
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
        try database.download_stats.put("sqlite", 342);

        return database;
    }

    pub fn deinit(self: *Database) void {
        self.packages.deinit();
        self.users.deinit();
        self.download_stats.deinit();
        
        // Clean up comment memory
        for (self.comments.items) |comment| {
            self.allocator.free(comment.package_id);
            self.allocator.free(comment.username);
            if (comment.display_name) |dn| self.allocator.free(dn);
            self.allocator.free(comment.content);
        }
        self.comments.deinit();
    }

    // Package operations
    pub fn addPackage(self: *Database, package: types.Package) !void {
        // In-memory implementation for testing/fallback
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
        var results = std.array_list.AlignedManaged(types.Package, null).init(self.allocator);
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
        // In-memory implementation for testing/fallback
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
    
    // Comment operations
    pub fn addComment(self: *Database, request: types.CommentRequest, user_id: u64, username: []const u8, display_name: ?[]const u8) !u64 {
        const comment_id = self.comment_id_counter.fetchAdd(1, .monotonic);
        const now = std.time.timestamp();
        
        const comment = types.Comment{
            .id = comment_id,
            .package_id = try self.allocator.dupe(u8, request.package_id),
            .user_id = user_id,
            .username = try self.allocator.dupe(u8, username),
            .display_name = if (display_name) |dn| try self.allocator.dupe(u8, dn) else null,
            .content = try self.allocator.dupe(u8, request.content),
            .created_at = now,
            .updated_at = now,
            .parent_id = request.parent_id,
        };
        
        try self.comments.append(comment);
        return comment_id;
    }
    
    pub fn getCommentsForPackage(self: *Database, package_id: []const u8) ![]types.Comment {
        var result = std.ArrayList(types.Comment).init(self.allocator);
        
        for (self.comments.items) |comment| {
            if (std.mem.eql(u8, comment.package_id, package_id) and !comment.is_deleted) {
                try result.append(comment);
            }
        }
        
        return result.toOwnedSlice();
    }
    
    pub fn updateComment(self: *Database, comment_id: u64, user_id: u64, new_content: []const u8) !bool {
        for (self.comments.items) |*comment| {
            if (comment.id == comment_id and comment.user_id == user_id and !comment.is_deleted) {
                self.allocator.free(comment.content);
                comment.content = try self.allocator.dupe(u8, new_content);
                comment.updated_at = std.time.timestamp();
                return true;
            }
        }
        return false;
    }
    
    pub fn deleteComment(self: *Database, comment_id: u64, user_id: u64) !bool {
        for (self.comments.items) |*comment| {
            if (comment.id == comment_id and comment.user_id == user_id and !comment.is_deleted) {
                comment.is_deleted = true;
                return true;
            }
        }
        return false;
    }
};

// NOTE: This in-memory implementation is used as a fallback.
// For persistent storage, use database_sqlite.zig which provides
// full SQLite integration with excellent performance and reliability.
