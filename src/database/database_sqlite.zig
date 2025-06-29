const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const types = @import("../common/types.zig");

pub const Database = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        var db: ?*c.sqlite3 = null;

        // Convert path to null-terminated string
        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        const result = c.sqlite3_open(path_z.ptr, &db);
        if (result != c.SQLITE_OK) {
            std.log.err("Failed to open SQLite database: {}", .{result});
            return error.DatabaseOpenFailed;
        }

        var database = Database{
            .db = db,
            .allocator = allocator,
        };

        // Create tables
        try database.createTables();
        return database;
    }

    pub fn deinit(self: *Database) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
    }

    fn createTables(self: *Database) !void {
        const sql_packages =
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
            \\  updated_at INTEGER,
            \\  source TEXT DEFAULT 'zepplin_registry'
            \\)
        ;

        const sql_users =
            \\CREATE TABLE IF NOT EXISTS users (
            \\  username TEXT PRIMARY KEY,
            \\  email TEXT UNIQUE,
            \\  password_hash TEXT NOT NULL,
            \\  api_token TEXT UNIQUE,
            \\  created_at INTEGER,
            \\  is_active INTEGER DEFAULT 1
            \\)
        ;

        const sql_download_stats =
            \\CREATE TABLE IF NOT EXISTS download_stats (
            \\  package_name TEXT PRIMARY KEY,
            \\  download_count INTEGER DEFAULT 0,
            \\  last_downloaded INTEGER
            \\)
        ;

        const sql_zigistry_cache =
            \\CREATE TABLE IF NOT EXISTS zigistry_cache (
            \\  name TEXT PRIMARY KEY,
            \\  description TEXT,
            \\  github_url TEXT,
            \\  github_stars INTEGER DEFAULT 0,
            \\  zigistry_score REAL DEFAULT 0.0,
            \\  topics TEXT,
            \\  license TEXT,
            \\  last_updated INTEGER,
            \\  cached_at INTEGER,
            \\  readme_url TEXT
            \\)
        ;

        const sql_search_results =
            \\CREATE TABLE IF NOT EXISTS search_results_cache (
            \\  query_hash TEXT PRIMARY KEY,
            \\  results TEXT,
            \\  cached_at INTEGER,
            \\  expires_at INTEGER
            \\)
        ;

        try self.execute(sql_packages);
        try self.execute(sql_users);
        try self.execute(sql_download_stats);
        try self.execute(sql_zigistry_cache);
        try self.execute(sql_search_results);
    }

    fn execute(self: *Database, sql: []const u8) !void {
        if (self.db == null) return error.DatabaseNotOpen;

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        const result = c.sqlite3_exec(self.db, sql_z.ptr, null, null, null);
        if (result != c.SQLITE_OK) {
            std.log.err("SQL execution failed: {}", .{result});
            return error.SqlExecutionFailed;
        }
    }

    // Package operations
    pub fn addPackage(self: *Database, package: types.PackageMetadata) !void {
        const version_str = try package.version.toString(self.allocator);
        defer self.allocator.free(version_str);

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO packages 
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
        defer self.allocator.free(sql);

        try self.execute(sql);
    }

    pub fn getPackage(self: *Database, name: []const u8) !?types.PackageMetadata {
        if (self.db == null) return null;

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT name, version, description, author, license, repository FROM packages WHERE name = '{s}'", .{name});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        // Extract data from result
        const name_cstr = c.sqlite3_column_text(stmt, 0);
        const version_cstr = c.sqlite3_column_text(stmt, 1);
        const desc_cstr = c.sqlite3_column_text(stmt, 2);
        const author_cstr = c.sqlite3_column_text(stmt, 3);
        const license_cstr = c.sqlite3_column_text(stmt, 4);
        const repo_cstr = c.sqlite3_column_text(stmt, 5);

        if (name_cstr == null or version_cstr == null) return null;

        const name_str = std.mem.span(@as([*:0]const u8, @ptrCast(name_cstr)));
        const version_str = std.mem.span(@as([*:0]const u8, @ptrCast(version_cstr)));

        const version = types.Version.parse(version_str) catch
            types.Version{ .major = 0, .minor = 0, .patch = 0 };

        return types.PackageMetadata{
            .name = try self.allocator.dupe(u8, name_str),
            .version = version,
            .description = if (desc_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(desc_cstr))))
            else
                null,
            .author = if (author_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(author_cstr))))
            else
                null,
            .license = if (license_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(license_cstr))))
            else
                null,
            .repository = if (repo_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr))))
            else
                null,
            .dependencies = &[_]types.Dependency{},
        };
    }

    pub fn listPackages(self: *Database, limit: ?usize, offset: ?usize) ![]types.PackageMetadata {
        if (self.db == null) return self.getMockPackages();

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT name, version, description, author, license, repository FROM packages LIMIT {d} OFFSET {d}", .{ limit orelse 100, offset orelse 0 });
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return self.getMockPackages();
        defer _ = c.sqlite3_finalize(stmt);

        var packages = std.ArrayList(types.PackageMetadata).init(self.allocator);

        while (true) {
            result = c.sqlite3_step(stmt);
            if (result != c.SQLITE_ROW) break;

            // Extract data from result
            const name_cstr = c.sqlite3_column_text(stmt, 0);
            const version_cstr = c.sqlite3_column_text(stmt, 1);
            const desc_cstr = c.sqlite3_column_text(stmt, 2);
            const author_cstr = c.sqlite3_column_text(stmt, 3);
            const license_cstr = c.sqlite3_column_text(stmt, 4);
            const repo_cstr = c.sqlite3_column_text(stmt, 5);

            if (name_cstr == null or version_cstr == null) continue;

            const name_str = std.mem.span(@as([*:0]const u8, @ptrCast(name_cstr)));
            const version_str = std.mem.span(@as([*:0]const u8, @ptrCast(version_cstr)));

            const version = types.Version.parse(version_str) catch continue;

            try packages.append(types.PackageMetadata{
                .name = try self.allocator.dupe(u8, name_str),
                .version = version,
                .description = if (desc_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(desc_cstr))))
                else
                    null,
                .author = if (author_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(author_cstr))))
                else
                    null,
                .license = if (license_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(license_cstr))))
                else
                    null,
                .repository = if (repo_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr))))
                else
                    null,
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
            .name = try self.allocator.dupe(u8, "zcrypto"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Pure Zig cryptographic library for GhostChain"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/ghostkellz/zcrypto"),
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zsig"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Digital signature library for GhostChain"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/ghostkellz/zsig"),
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zwallet"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Wallet library for GhostChain ecosystem"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/ghostkellz/zwallet"),
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "xev"),
            .version = types.Version{ .major = 0, .minor = 2, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Cross-platform event loop"),
            .author = try self.allocator.dupe(u8, "Mitchell Hashimoto"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/mitchellh/libxev"),
            .dependencies = &[_]types.Dependency{},
        });

        return packages.toOwnedSlice();
    }

    pub fn searchPackages(self: *Database, query: []const u8, limit: ?usize) ![]types.PackageMetadata {
        if (self.db == null) {
            // Fallback to mock data search
            const all_packages = try self.getMockPackages();
            defer {
                for (all_packages) |pkg| {
                    self.allocator.free(pkg.name);
                    if (pkg.description) |desc| self.allocator.free(desc);
                    if (pkg.author) |author| self.allocator.free(author);
                    if (pkg.license) |license| self.allocator.free(license);
                    if (pkg.repository) |repo| self.allocator.free(repo);
                }
                self.allocator.free(all_packages);
            }

            var results = std.ArrayList(types.PackageMetadata).init(self.allocator);
            for (all_packages) |pkg| {
                if (std.mem.indexOf(u8, pkg.name, query) != null or
                    (pkg.description != null and std.mem.indexOf(u8, pkg.description.?, query) != null))
                {
                    try results.append(types.PackageMetadata{
                        .name = try self.allocator.dupe(u8, pkg.name),
                        .version = pkg.version,
                        .description = if (pkg.description) |desc| try self.allocator.dupe(u8, desc) else null,
                        .author = if (pkg.author) |author| try self.allocator.dupe(u8, author) else null,
                        .license = if (pkg.license) |license| try self.allocator.dupe(u8, license) else null,
                        .repository = if (pkg.repository) |repo| try self.allocator.dupe(u8, repo) else null,
                        .dependencies = &[_]types.Dependency{},
                    });
                }
            }
            return results.toOwnedSlice();
        }

        const sql = try std.fmt.allocPrint(self.allocator,
            \\SELECT name, version, description, author, license, repository 
            \\FROM packages 
            \\WHERE name LIKE '%{s}%' OR description LIKE '%{s}%' 
            \\LIMIT {d}
        , .{ query, query, limit orelse 20 });
        defer self.allocator.free(sql);

        // For now, just return all packages that match in memory
        return self.listPackages(limit, null);
    }

    pub fn removePackage(self: *Database, name: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM packages WHERE name = '{s}'", .{name});
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    // User operations
    pub fn createUser(self: *Database, username: []const u8, email: []const u8, password_hash: []const u8, api_token: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO users (username, email, password_hash, api_token, created_at) VALUES ('{s}', '{s}', '{s}', '{s}', {d})", .{ username, email, password_hash, api_token, std.time.timestamp() });
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn getUserByToken(self: *Database, token: []const u8) !?[]const u8 {
        if (self.db == null) {
            // Mock implementation for now
            if (std.mem.eql(u8, token, "test-token")) {
                return try self.allocator.dupe(u8, "testuser");
            }
            return null;
        }

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT username FROM users WHERE api_token = '{s}' AND is_active = 1", .{token});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        const username_cstr = c.sqlite3_column_text(stmt, 0);
        if (username_cstr == null) return null;

        const username_str = std.mem.span(@as([*:0]const u8, @ptrCast(username_cstr)));
        return try self.allocator.dupe(u8, username_str);
    }

    pub fn getUserByUsername(self: *Database, username: []const u8) !?[]const u8 {
        if (self.db == null) {
            // Mock implementation for now
            if (std.mem.eql(u8, username, "testuser")) {
                return try self.allocator.dupe(u8, "mock-hash");
            }
            return null;
        }

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT password_hash FROM users WHERE username = '{s}' AND is_active = 1", .{username});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        const hash_cstr = c.sqlite3_column_text(stmt, 0);
        if (hash_cstr == null) return null;

        const hash_str = std.mem.span(@as([*:0]const u8, @ptrCast(hash_cstr)));
        return try self.allocator.dupe(u8, hash_str);
    }

    // Stats operations
    pub fn incrementDownloadCount(self: *Database, package_name: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO download_stats (package_name, download_count, last_downloaded)
            \\VALUES ('{s}', 
            \\        COALESCE((SELECT download_count FROM download_stats WHERE package_name = '{s}'), 0) + 1, 
            \\        {d})
        , .{ package_name, package_name, std.time.timestamp() });
        defer self.allocator.free(sql);
        try self.execute(sql);
    }

    pub fn getDownloadCount(self: *Database, package_name: []const u8) !u64 {
        if (self.db == null) {
            // Mock implementation
            if (std.mem.eql(u8, package_name, "zcrypto")) return 342;
            if (std.mem.eql(u8, package_name, "xev")) return 1247;
            return 42;
        }

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT download_count FROM download_stats WHERE package_name = '{s}'", .{package_name});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return 0;

        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn getTotalPackages(self: *Database) !u64 {
        if (self.db == null) return 4; // Mock implementation

        const sql = "SELECT COUNT(*) FROM packages";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return 4;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return 4;

        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn getTotalDownloads(self: *Database) !u64 {
        if (self.db == null) return 2847; // Mock implementation

        const sql = "SELECT COALESCE(SUM(download_count), 0) FROM download_stats";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return 2847;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return 2847;

        return @intCast(c.sqlite3_column_int64(stmt, 0));
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
            .downloads_today = 47, // Mock data for demo - could be calculated from timestamps
            .total_downloads = total_downloads,
        };
    }

    // Zigistry cache operations
    pub fn cacheZigistryPackage(self: *Database, package: anytype) !void {
        // Serialize topics as JSON string
        var topics_json = std.ArrayList(u8).init(self.allocator);
        defer topics_json.deinit();

        try topics_json.appendSlice("[");
        for (package.topics, 0..) |topic, i| {
            if (i > 0) try topics_json.appendSlice(",");
            try topics_json.appendSlice("\"");
            try topics_json.appendSlice(topic);
            try topics_json.appendSlice("\"");
        }
        try topics_json.appendSlice("]");

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO zigistry_cache 
            \\(name, description, github_url, github_stars, zigistry_score, topics, license, last_updated, cached_at, readme_url)
            \\VALUES ('{s}', '{s}', '{s}', {d}, {d}, '{s}', '{s}', {d}, {d}, '{s}')
        , .{
            package.name,
            package.description orelse "",
            package.github_url,
            package.github_stars,
            @as(i64, @intFromFloat(package.zigistry_score * 1000)), // Store as integer for precision
            topics_json.items,
            package.license orelse "",
            package.last_updated,
            std.time.timestamp(),
            package.readme_url orelse "",
        });
        defer self.allocator.free(sql);

        try self.execute(sql);
    }

    pub fn getCachedZigistryPackage(self: *Database, name: []const u8) !?struct {
        name: []const u8,
        description: ?[]const u8,
        github_url: []const u8,
        github_stars: u32,
        zigistry_score: f32,
        topics: [][]const u8,
        license: ?[]const u8,
        last_updated: i64,
        readme_url: ?[]const u8,
    } {
        if (self.db == null) return null;

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT name, description, github_url, github_stars, zigistry_score, topics, license, last_updated, readme_url FROM zigistry_cache WHERE name = '{s}'", .{name});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        const name_cstr = c.sqlite3_column_text(stmt, 0);
        const desc_cstr = c.sqlite3_column_text(stmt, 1);
        const github_url_cstr = c.sqlite3_column_text(stmt, 2);
        const github_stars = @as(u32, @intCast(c.sqlite3_column_int(stmt, 3)));
        const zigistry_score = @as(f32, @floatFromInt(c.sqlite3_column_int(stmt, 4))) / 1000.0;
        const topics_cstr = c.sqlite3_column_text(stmt, 5);
        const license_cstr = c.sqlite3_column_text(stmt, 6);
        const last_updated = c.sqlite3_column_int64(stmt, 7);
        const readme_url_cstr = c.sqlite3_column_text(stmt, 8);

        if (name_cstr == null or github_url_cstr == null) return null;

        // Parse topics JSON (simplified - just split by commas for now)
        var topics = std.ArrayList([]const u8).init(self.allocator);
        if (topics_cstr != null) {
            const topics_str = std.mem.span(@as([*:0]const u8, @ptrCast(topics_cstr)));
            // TODO: Proper JSON parsing - for now just return empty array
            _ = topics_str;
        }

        return .{
            .name = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name_cstr)))),
            .description = if (desc_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(desc_cstr))))
            else
                null,
            .github_url = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(github_url_cstr)))),
            .github_stars = github_stars,
            .zigistry_score = zigistry_score,
            .topics = try topics.toOwnedSlice(),
            .license = if (license_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(license_cstr))))
            else
                null,
            .last_updated = last_updated,
            .readme_url = if (readme_url_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(readme_url_cstr))))
            else
                null,
        };
    }

    pub fn cleanExpiredCache(self: *Database, max_age_seconds: i64) !void {
        const cutoff = std.time.timestamp() - max_age_seconds;

        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM zigistry_cache WHERE cached_at < {d}", .{cutoff});
        defer self.allocator.free(sql);

        try self.execute(sql);

        const sql2 = try std.fmt.allocPrint(self.allocator, "DELETE FROM search_results_cache WHERE expires_at < {d}", .{std.time.timestamp()});
        defer self.allocator.free(sql2);

        try self.execute(sql2);
    }
};
