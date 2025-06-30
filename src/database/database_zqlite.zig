const std = @import("std");
const zqlite = @import("zqlite");
const types = @import("../common/types.zig");

pub const Database = struct {
    db: *zqlite.db.Connection,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        const db = try zqlite.open(db_path);

        // Create packages table
        try db.execute(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\  name TEXT PRIMARY KEY,
            \\  version TEXT NOT NULL,
            \\  description TEXT,
            \\  author TEXT,
            \\  license TEXT,
            \\  repository TEXT,
            \\  dependencies TEXT,
            \\  file_path TEXT,
            \\  file_size INTEGER,
            \\  checksum TEXT,
            \\  created_at INTEGER,
            \\  updated_at INTEGER
            \\)
        );

        // Create users table
        try db.execute(
            \\CREATE TABLE IF NOT EXISTS users (
            \\  username TEXT PRIMARY KEY,
            \\  email TEXT UNIQUE,
            \\  password_hash TEXT NOT NULL,
            \\  api_token TEXT UNIQUE,
            \\  created_at INTEGER,
            \\  is_active INTEGER DEFAULT 1
            \\)
        );

        // Create download stats table
        try db.execute(
            \\CREATE TABLE IF NOT EXISTS download_stats (
            \\  package_name TEXT,
            \\  download_count INTEGER DEFAULT 0,
            \\  last_downloaded INTEGER
            \\)
        );

        return Database{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Database) void {
        self.db.close();
    }

    // Package operations
    pub fn addPackage(self: *Database, package: types.PackageMetadata) !void {
        const version_str = try package.version.toString(self.allocator);
        defer self.allocator.free(version_str);

        var buf: [1024]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..],
            \\INSERT INTO packages 
            \\(name, version, description, author, license, repository, dependencies, 
            \\ file_path, file_size, checksum, created_at, updated_at)
            \\VALUES ('{s}', '{s}', '{s}', '{s}', '{s}', '{s}', '{s}', 
            \\        '', 0, '', {d}, {d})
        , .{
            package.name,
            version_str,
            package.description orelse "",
            package.author orelse "",
            package.license orelse "",
            package.repository orelse "",
            "", // dependencies as JSON string - TODO: serialize properly
            std.time.timestamp(),
            std.time.timestamp(),
        });

        try self.db.execute(sql);
    }

    pub fn getPackage(self: *Database, name: []const u8) !?types.PackageMetadata {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "SELECT name, version, description, author, license, repository FROM packages WHERE name = '{s}'", .{name});

        // Execute query and get results
        const result = self.db.query(sql) catch |err| {
            std.log.warn("Database query failed for package '{s}': {}", .{ name, err });
            return null;
        };
        defer result.deinit();

        if (result.next()) |row| {
            const version = types.Version.parse(row.getString(1) orelse "0.0.0") catch types.Version{ .major = 0, .minor = 0, .patch = 0 };

            return types.PackageMetadata{
                .name = name,
                .version = version,
                .description = row.getString(2),
                .author = row.getString(3),
                .license = row.getString(4),
                .repository = row.getString(5),
                .dependencies = &[_]types.Dependency{},
            };
        }

        return null;
    }

    pub fn listPackages(self: *Database, limit: ?usize, offset: ?usize) ![]types.PackageMetadata {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "SELECT name, version, description, author, license, repository FROM packages LIMIT {d} OFFSET {d}", .{ limit orelse 100, offset orelse 0 });

        const result = self.db.query(sql) catch |err| {
            std.log.warn("Database query failed for listPackages: {}", .{err});
            // Fallback to mock data for now
            return self.getMockPackages();
        };
        defer result.deinit();

        var packages = std.ArrayList(types.PackageMetadata).init(self.allocator);
        while (result.next()) |row| {
            const version = types.Version.parse(row.getString(1) orelse "0.0.0") catch continue;

            try packages.append(types.PackageMetadata{
                .name = row.getString(0) orelse "unknown",
                .version = version,
                .description = row.getString(2),
                .author = row.getString(3),
                .license = row.getString(4),
                .repository = row.getString(5),
                .dependencies = &[_]types.Dependency{},
            });
        }

        // If no packages in DB, return mock data for demo
        if (packages.items.len == 0) {
            packages.deinit();
            return self.getMockPackages();
        }

        return packages.toOwnedSlice();
    }

    fn getMockPackages(self: *Database) ![]types.PackageMetadata {
        var packages = std.ArrayList(types.PackageMetadata).init(self.allocator);

        try packages.append(types.PackageMetadata{
            .name = "zcrypto",
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = "Pure Zig cryptographic library for GhostChain",
            .author = "GhostKellz",
            .license = "MIT",
            .repository = "https://github.com/ghostkellz/zcrypto",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = "zsig",
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = "Digital signature library for GhostChain",
            .author = "GhostKellz",
            .license = "MIT",
            .repository = "https://github.com/ghostkellz/zsig",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = "zwallet",
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = "Wallet library for GhostChain ecosystem",
            .author = "GhostKellz",
            .license = "MIT",
            .repository = "https://github.com/ghostkellz/zwallet",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = "zqlite",
            .version = types.Version{ .major = 0, .minor = 4, .patch = 0 },
            .description = "Pure Zig SQLite alternative with cryptographic features",
            .author = "GhostKellz",
            .license = "MIT",
            .repository = "https://github.com/ghostkellz/zqlite",
            .dependencies = &[_]types.Dependency{},
        });

        return packages.toOwnedSlice();
    }

    pub fn searchPackages(self: *Database, query: []const u8, limit: ?usize) ![]types.PackageMetadata {
        // TODO: Implement actual SQL search with WHERE clause
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "SELECT name, version, description, author, license, repository FROM packages WHERE name LIKE '%{s}%' OR description LIKE '%{s}%'", .{ query, query });
        _ = sql;

        // For now, just return all packages that match in memory
        return self.listPackages(limit, null);
    }

    pub fn removePackage(self: *Database, name: []const u8) !void {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "DELETE FROM packages WHERE name = '{s}'", .{name});
        try self.db.execute(sql);
    }

    // User operations
    pub fn createUser(self: *Database, username: []const u8, email: []const u8, password_hash: []const u8, api_token: []const u8) !void {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "INSERT INTO users (username, email, password_hash, api_token, created_at) VALUES ('{s}', '{s}', '{s}', '{s}', {d})", .{ username, email, password_hash, api_token, std.time.timestamp() });
        try self.db.execute(sql);
    }

    pub fn getUserByToken(self: *Database, token: []const u8) !?[]const u8 {
        // TODO: Implement actual SQL query when zqlite has result parsing
        _ = self;

        // Mock implementation for now
        if (std.mem.eql(u8, token, "test-token")) {
            return "testuser";
        }
        return null;
    }

    pub fn getUserByUsername(self: *Database, username: []const u8) !?[]const u8 {
        // TODO: Implement actual SQL query when zqlite has result parsing
        _ = self;

        // Mock implementation for now
        if (std.mem.eql(u8, username, "testuser")) {
            return "mock-hash";
        }
        return null;
    }

    // Stats operations
    pub fn incrementDownloadCount(self: *Database, package_name: []const u8) !void {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..],
            \\INSERT OR REPLACE INTO download_stats (package_name, download_count, last_downloaded)
            \\VALUES ('{s}', 1, {d})
        , .{ package_name, std.time.timestamp() });
        try self.db.execute(sql);
    }

    pub fn getDownloadCount(self: *Database, package_name: []const u8) !u64 {
        // TODO: Implement actual SQL query with result parsing
        _ = self;
        _ = package_name;
        return 42; // Mock implementation
    }

    pub fn getTotalPackages(self: *Database) !u64 {
        // TODO: Implement SELECT COUNT(*) when result parsing is available
        _ = self;
        return 4; // Mock implementation - matches number of demo packages
    }

    pub fn getTotalDownloads(self: *Database) !u64 {
        // TODO: Implement SELECT SUM(download_count) when result parsing is available
        _ = self;
        return 2847; // Mock implementation
    }

    // Stats structure for web UI
    pub const Stats = struct {
        total_packages: u64,
        downloads_today: u64,
        total_downloads: u64,
    };

    pub fn getDownloadStats(self: *Database) !Stats {
        const total_packages = try self.getTotalPackages();
        const total_downloads = try self.getTotalDownloads();

        return Stats{
            .total_packages = total_packages,
            .downloads_today = 47, // Mock data for demo
            .total_downloads = total_downloads,
        };
    }
};
