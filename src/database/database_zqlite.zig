const std = @import("std");
const zqlite = @import("zqlite");
const types = @import("../common/types.zig");

pub const Database = struct {
    db: *zqlite.Connection,
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
        var result = self.db.query(sql) catch |err| {
            std.log.warn("Database query failed for package '{s}': {}", .{ name, err });
            return null;
        };
        defer result.deinit();

        // TODO: Fix zqlite Row API - falling back to mock data for now
        
        // Use mock data while we fix the API
        const mock_packages = try self.getMockPackages();
        defer self.allocator.free(mock_packages);

        for (mock_packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, name)) {
                return pkg;
            }
        }

        return null;
    }

    pub fn listPackages(self: *Database, limit: ?usize, offset: ?usize) ![]types.PackageMetadata {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "SELECT name, version, description, author, license, repository FROM packages LIMIT {d} OFFSET {d}", .{ limit orelse 100, offset orelse 0 });

        var result = self.db.query(sql) catch |err| {
            std.log.warn("Database query failed for listPackages: {}", .{err});
            // Fallback to mock data for now
            return self.getMockPackages();
        };
        defer result.deinit();

        var packages = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);
        // TODO: Fix zqlite Row API - using mock data for now
        packages.deinit();
        return self.getMockPackages();
    }

    fn getMockPackages(self: *Database) ![]types.PackageMetadata {
        var packages = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zcrypto"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Pure Zig cryptographic library for GhostChain"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zcrypto",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zsig"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Digital signature library for GhostChain"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zsig",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zwallet"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Wallet library for GhostChain ecosystem"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zwallet",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zqlite"),
            .version = types.Version{ .major = 0, .minor = 4, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Pure Zig SQLite alternative with cryptographic features"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zqlite",
            .dependencies = &[_]types.Dependency{},
        });

        return packages.toOwnedSlice();
    }

    pub fn searchPackages(self: *Database, query: []const u8, limit: ?usize) ![]types.PackageMetadata {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "SELECT name, version, description, author, license, repository FROM packages WHERE name LIKE '%{s}%' OR description LIKE '%{s}%' LIMIT {}", .{ query, query, limit orelse 20 });
        
        var result = self.db.query(sql) catch |err| {
            std.log.warn("Database search query failed: {}", .{err});
            return self.getMockPackages();
        };
        defer result.deinit();

        var packages = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);
        // TODO: Fix zqlite Row API - using mock data with filtering for now
        packages.deinit();
        
        const all_mock_packages = try self.getMockPackages();
        defer self.allocator.free(all_mock_packages);
        
        var filtered = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);
        for (all_mock_packages) |pkg| {
            if (std.mem.indexOf(u8, pkg.name, query) != null or 
                (pkg.description != null and std.mem.indexOf(u8, pkg.description.?, query) != null)) {
                try filtered.append(pkg);
                if (filtered.items.len >= (limit orelse 20)) break;
            }
        }
        return filtered.toOwnedSlice();
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

    // GitHub-compatible API methods
    pub fn getPackageGitHub(self: *Database, owner: []const u8, repo: []const u8) !?types.PackageMetadata {
        const package_name = if (std.mem.eql(u8, owner, repo)) owner else try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, repo });
        defer if (!std.mem.eql(u8, owner, repo)) self.allocator.free(package_name);
        
        return self.getPackage(package_name);
    }

    pub fn getPackageReleases(self: *Database, owner: []const u8, repo: []const u8) ![]types.Release {
        // For now, return mock releases - in production this would query a releases table
        
        var releases = std.array_list.AlignedManaged(types.Release, null).init(self.allocator);
        
        // Mock some releases
        try releases.append(types.Release{
            .id = 1,
            .owner = owner,
            .repo = repo,
            .tag_name = "v1.0.0",
            .name = "Release v1.0.0",
            .draft = false,
            .prerelease = false,
            .created_at = std.time.timestamp(),
            .published_at = std.time.timestamp(),
            .tarball_url = "https://zig.cktech.org/api/v1/packages/example/download/v1.0.0",
            .zipball_url = "https://zig.cktech.org/api/v1/packages/example/download/v1.0.0?format=zip",
        });

        try releases.append(types.Release{
            .id = 2,
            .owner = owner,
            .repo = repo,
            .tag_name = "v0.9.0",
            .name = "Release v0.9.0",
            .draft = false,
            .prerelease = false,
            .created_at = std.time.timestamp() - 86400,
            .published_at = std.time.timestamp() - 86400,
            .tarball_url = "https://zig.cktech.org/api/v1/packages/example/download/v0.9.0",
            .zipball_url = "https://zig.cktech.org/api/v1/packages/example/download/v0.9.0?format=zip",
        });

        return releases.toOwnedSlice();
    }

    // Additional required methods
    pub fn resolveAlias(self: *Database, short_name: []const u8) !?types.Alias {
        // Mock implementation - in production this would query an aliases table
        
        // Mock some aliases
        if (std.mem.eql(u8, short_name, "crypto")) {
            return types.Alias{
                .short_name = try self.allocator.dupe(u8, short_name),
                .owner = try self.allocator.dupe(u8, "cktech"),
                .repo = try self.allocator.dupe(u8, "zcrypto"),
                .created_at = std.time.timestamp(),
                .created_by = try self.allocator.dupe(u8, "system"),
            };
        } else if (std.mem.eql(u8, short_name, "http")) {
            return types.Alias{
                .short_name = try self.allocator.dupe(u8, short_name),
                .owner = try self.allocator.dupe(u8, "karlseguin"),
                .repo = try self.allocator.dupe(u8, "http.zig"),
                .created_at = std.time.timestamp(),
                .created_by = try self.allocator.dupe(u8, "system"),
            };
        } else if (std.mem.eql(u8, short_name, "xev")) {
            return types.Alias{
                .short_name = try self.allocator.dupe(u8, short_name),
                .owner = try self.allocator.dupe(u8, "mitchellh"),
                .repo = try self.allocator.dupe(u8, "libxev"),
                .created_at = std.time.timestamp(),
                .created_by = try self.allocator.dupe(u8, "system"),
            };
        }
        
        return null;
    }

    pub fn getRegistryConfig(self: *Database, key: []const u8) !?[]const u8 {
        // Mock implementation - in production this would query a config table
        _ = self;
        
        if (std.mem.eql(u8, key, "registry_name")) {
            return "Zepplin Registry";
        } else if (std.mem.eql(u8, key, "api_version")) {
            return "v1";
        }
        
        return null;
    }

    pub fn listZiglibsPackages(self: *Database, limit: ?usize, offset: ?usize) ![]types.PackageMetadata {
        // Mock implementation - in production this would query a ziglibs packages table
        _ = limit;
        _ = offset;
        
        var packages = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);
        
        // Mock some ziglibs packages
        try packages.append(types.PackageMetadata{
            .name = "zig-json",
            .version = types.Version{ .major = 1, .minor = 0, .patch = 0 },
            .description = "JSON parser for Zig",
            .author = "ziglibs",
            .owner = "ziglibs",
            .repo = "zig-json",
            .license = "MIT",
            .repository = "https://github.com/ziglibs/zig-json",
            .github_url = "https://github.com/ziglibs/zig-json",
            .github_stars = 45,
            .download_count = 1234,
            .created_at = std.time.timestamp() - 86400 * 30,
            .updated_at = std.time.timestamp() - 86400 * 7,
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = "zig-datetime",
            .version = types.Version{ .major = 0, .minor = 9, .patch = 0 },
            .description = "Date and time utilities for Zig",
            .author = "ziglibs",
            .owner = "ziglibs",
            .repo = "zig-datetime",
            .license = "MIT",
            .repository = "https://github.com/ziglibs/zig-datetime",
            .github_url = "https://github.com/ziglibs/zig-datetime",
            .github_stars = 23,
            .download_count = 567,
            .created_at = std.time.timestamp() - 86400 * 60,
            .updated_at = std.time.timestamp() - 86400 * 14,
            .dependencies = &[_]types.Dependency{},
        });

        return packages.toOwnedSlice();
    }

    pub fn getReleases(self: *Database, owner: []const u8, repo: []const u8) ![]types.Release {
        // Alias for getPackageReleases to match server expectations
        return self.getPackageReleases(owner, repo);
    }

    pub fn getRelease(self: *Database, owner: []const u8, repo: []const u8, tag: []const u8) !?types.Release {
        // Mock implementation - in production would query for specific release
        _ = tag;
        
        const releases = try self.getPackageReleases(owner, repo);
        defer self.allocator.free(releases);
        
        if (releases.len > 0) {
            return releases[0]; // Return first release as mock
        }
        return null;
    }

    pub fn countZiglibsPackages(self: *Database) !u64 {
        // Mock implementation - return count of ziglibs packages
        _ = self;
        return 15; // Mock count
    }

    pub fn userExists(self: *Database, username: []const u8) !bool {
        // Mock implementation - in production would query users table
        _ = self;
        
        // Mock some existing users
        if (std.mem.eql(u8, username, "testuser") or
            std.mem.eql(u8, username, "admin") or
            std.mem.eql(u8, username, "cktech")) {
            return true;
        }
        
        return false;
    }

    pub fn getUser(self: *Database, username: []const u8) !?types.PackageMetadata {
        // Mock implementation - in production would return User type
        _ = self;
        _ = username;
        
        // For now, return null since we don't have a proper User type
        // In production this would query users table and return user data
        return null;
    }

    pub fn addPackageGitHub(self: *Database, package: types.Package) !void {
        // Mock implementation - in production would store GitHub package metadata
        _ = self;
        
        // For now just log the package addition
        std.log.info("Mock: Adding GitHub package: {s}/{s}", .{ package.owner, package.repo });
    }
    
    // Comment operations (mock implementations)
    pub fn addComment(self: *Database, request: types.CommentRequest, user_id: u64, username: []const u8, display_name: ?[]const u8) !u64 {
        // Mock implementation - in production would insert into comments table
        _ = self;
        _ = request;
        _ = user_id;
        _ = username;
        _ = display_name;
        
        // Return a mock comment ID
        return @intCast(@mod(std.time.timestamp(), 1000000));
    }
    
    pub fn getCommentsForPackage(self: *Database, package_id: []const u8) ![]types.Comment {
        // Mock implementation - in production would query comments table
        var comments = std.array_list.AlignedManaged(types.Comment, null).init(self.allocator);
        
        // Mock some comments for demonstration
        if (std.mem.eql(u8, package_id, "mitchellh/libxev") or 
            std.mem.eql(u8, package_id, "ziglibs/zig-json") or
            std.mem.eql(u8, package_id, "cktech/example")) {
            
            try comments.append(types.Comment{
                .id = 1,
                .package_id = try self.allocator.dupe(u8, package_id),
                .user_id = 123,
                .username = try self.allocator.dupe(u8, "developer123"),
                .display_name = try self.allocator.dupe(u8, "John Developer"),
                .content = try self.allocator.dupe(u8, "Great package! Works perfectly with my project."),
                .created_at = std.time.timestamp() - 86400, // 1 day ago
                .updated_at = std.time.timestamp() - 86400,
                .parent_id = null,
            });
            
            try comments.append(types.Comment{
                .id = 2,
                .package_id = try self.allocator.dupe(u8, package_id),
                .user_id = 456,
                .username = try self.allocator.dupe(u8, "coder_jane"),
                .display_name = try self.allocator.dupe(u8, "Jane Coder"),
                .content = try self.allocator.dupe(u8, "Thanks for the excellent documentation. Very helpful!"),
                .created_at = std.time.timestamp() - 3600, // 1 hour ago
                .updated_at = std.time.timestamp() - 3600,
                .parent_id = null,
            });
        }
        
        return comments.toOwnedSlice();
    }
    
    pub fn updateComment(self: *Database, comment_id: u64, user_id: u64, new_content: []const u8) !bool {
        // Mock implementation - in production would update comments table
        _ = self;
        _ = comment_id;
        _ = user_id;
        _ = new_content;
        
        // Mock success
        return true;
    }
    
    pub fn deleteComment(self: *Database, comment_id: u64, user_id: u64) !bool {
        // Mock implementation - in production would mark comment as deleted
        _ = self;
        _ = comment_id;
        _ = user_id;
        
        // Mock success
        return true;
    }
};
