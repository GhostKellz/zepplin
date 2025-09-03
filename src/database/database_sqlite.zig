const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const types = @import("../common/types.zig");

pub const Database = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,
    
    // Prepared statements for performance optimization
    insert_package_stmt: ?*c.sqlite3_stmt,
    select_package_stmt: ?*c.sqlite3_stmt,
    search_packages_stmt: ?*c.sqlite3_stmt,
    list_packages_stmt: ?*c.sqlite3_stmt,
    update_package_stmt: ?*c.sqlite3_stmt,

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
            .insert_package_stmt = null,
            .select_package_stmt = null,
            .search_packages_stmt = null,
            .list_packages_stmt = null,
            .update_package_stmt = null,
        };

        // Create tables
        try database.createTables();
        
        // Prepare statements for performance optimization
        try database.prepareStatements();
        
        return database;
    }

    pub fn deinit(self: *Database) void {
        // Clean up prepared statements
        if (self.insert_package_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.select_package_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.search_packages_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.list_packages_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        if (self.update_package_stmt) |stmt| _ = c.sqlite3_finalize(stmt);
        
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
    }

    fn createTables(self: *Database) !void {
        // Core packages table - updated for multi-version support
        const sql_packages =
            \\CREATE TABLE IF NOT EXISTS packages (
            \\  owner TEXT NOT NULL,
            \\  repo TEXT NOT NULL,
            \\  description TEXT,
            \\  topics TEXT,
            \\  category TEXT,
            \\  keywords TEXT,
            \\  license TEXT,
            \\  homepage TEXT,
            \\  github_url TEXT,
            \\  github_stars INTEGER DEFAULT 0,
            \\  downloads INTEGER DEFAULT 0,
            \\  created_at INTEGER,
            \\  updated_at INTEGER,
            \\  is_private INTEGER DEFAULT 0,
            \\  source TEXT DEFAULT 'github',
            \\  PRIMARY KEY (owner, repo)
            \\)
        ;

        // Package releases (versions/tags)
        const sql_releases =
            \\CREATE TABLE IF NOT EXISTS releases (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  owner TEXT NOT NULL,
            \\  repo TEXT NOT NULL,
            \\  tag_name TEXT NOT NULL,
            \\  name TEXT,
            \\  body TEXT,
            \\  draft INTEGER DEFAULT 0,
            \\  prerelease INTEGER DEFAULT 0,
            \\  created_at INTEGER,
            \\  published_at INTEGER,
            \\  tarball_url TEXT,
            \\  zipball_url TEXT,
            \\  download_url TEXT,
            \\  file_size INTEGER DEFAULT 0,
            \\  sha256 TEXT,
            \\  FOREIGN KEY (owner, repo) REFERENCES packages(owner, repo),
            \\  UNIQUE (owner, repo, tag_name)
            \\)
        ;

        // Package aliases and short names
        const sql_aliases =
            \\CREATE TABLE IF NOT EXISTS aliases (
            \\  short_name TEXT PRIMARY KEY,
            \\  owner TEXT NOT NULL,
            \\  repo TEXT NOT NULL,
            \\  created_at INTEGER,
            \\  created_by TEXT,
            \\  FOREIGN KEY (owner, repo) REFERENCES packages(owner, repo)
            \\)
        ;

        // Organizations
        const sql_organizations =
            \\CREATE TABLE IF NOT EXISTS organizations (
            \\  name TEXT PRIMARY KEY,
            \\  display_name TEXT,
            \\  description TEXT,
            \\  avatar_url TEXT,
            \\  website TEXT,
            \\  created_at INTEGER
            \\)
        ;

        // Users table - enhanced
        const sql_users =
            \\CREATE TABLE IF NOT EXISTS users (
            \\  username TEXT PRIMARY KEY,
            \\  email TEXT UNIQUE,
            \\  password_hash TEXT NOT NULL,
            \\  api_token TEXT UNIQUE,
            \\  ed25519_public_key TEXT,
            \\  created_at INTEGER,
            \\  is_active INTEGER DEFAULT 1,
            \\  is_admin INTEGER DEFAULT 0
            \\)
        ;

        // Download statistics
        const sql_download_stats =
            \\CREATE TABLE IF NOT EXISTS download_stats (
            \\  owner TEXT NOT NULL,
            \\  repo TEXT NOT NULL,
            \\  tag_name TEXT,
            \\  download_count INTEGER DEFAULT 0,
            \\  last_downloaded INTEGER,
            \\  PRIMARY KEY (owner, repo, tag_name)
            \\)
        ;

        // Registry configuration
        const sql_registry_config =
            \\CREATE TABLE IF NOT EXISTS registry_config (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT,
            \\  updated_at INTEGER
            \\)
        ;

        // Zigistry cache
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

        // Search results cache
        const sql_search_results =
            \\CREATE TABLE IF NOT EXISTS search_results_cache (
            \\  query_hash TEXT PRIMARY KEY,
            \\  results TEXT,
            \\  cached_at INTEGER,
            \\  expires_at INTEGER
            \\)
        ;

        // Execute all table creation statements
        try self.execute(sql_packages);
        try self.execute(sql_releases);
        try self.execute(sql_aliases);
        try self.execute(sql_organizations);
        try self.execute(sql_users);
        try self.execute(sql_download_stats);
        try self.execute(sql_registry_config);
        try self.execute(sql_zigistry_cache);
        try self.execute(sql_search_results);

        // Create indexes for performance
        try self.execute("CREATE INDEX IF NOT EXISTS idx_releases_owner_repo ON releases(owner, repo)");
        try self.execute("CREATE INDEX IF NOT EXISTS idx_releases_published_at ON releases(published_at DESC)");
        try self.execute("CREATE INDEX IF NOT EXISTS idx_packages_updated_at ON packages(updated_at DESC)");
        try self.execute("CREATE INDEX IF NOT EXISTS idx_download_stats_count ON download_stats(download_count DESC)");

        // Insert default registry configuration
        try self.execute("INSERT OR IGNORE INTO registry_config (key, value, updated_at) VALUES ('registry_name', 'Zepplin Registry', strftime('%s', 'now'))");
        try self.execute("INSERT OR IGNORE INTO registry_config (key, value, updated_at) VALUES ('registry_url', 'http://localhost:8080', strftime('%s', 'now'))");
        try self.execute("INSERT OR IGNORE INTO registry_config (key, value, updated_at) VALUES ('api_version', 'v1', strftime('%s', 'now'))");
        try self.execute("INSERT OR IGNORE INTO registry_config (key, value, updated_at) VALUES ('allow_public_publish', '1', strftime('%s', 'now'))");
    }

    fn prepareStatements(self: *Database) !void {
        if (self.db == null) return error.DatabaseNotOpen;

        // Prepare insert package statement
        const insert_sql = "INSERT OR REPLACE INTO packages (owner, repo, description, topics, license, homepage, github_url, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";
        var result = c.sqlite3_prepare_v2(self.db, insert_sql.ptr, @intCast(insert_sql.len), &self.insert_package_stmt, null);
        if (result != c.SQLITE_OK) return error.PrepareStatementFailed;

        // Prepare select package statement
        const select_sql = "SELECT owner, repo, description, topics, license, homepage, github_url, created_at, updated_at FROM packages WHERE owner = ? AND repo = ?";
        result = c.sqlite3_prepare_v2(self.db, select_sql.ptr, @intCast(select_sql.len), &self.select_package_stmt, null);
        if (result != c.SQLITE_OK) return error.PrepareStatementFailed;

        // Prepare search packages statement
        const search_sql = "SELECT owner, repo, description, topics, license, homepage, github_url, created_at, updated_at FROM packages WHERE owner LIKE ? OR repo LIKE ? OR description LIKE ? ORDER BY updated_at DESC LIMIT ?";
        result = c.sqlite3_prepare_v2(self.db, search_sql.ptr, @intCast(search_sql.len), &self.search_packages_stmt, null);
        if (result != c.SQLITE_OK) return error.PrepareStatementFailed;

        // Prepare list packages statement
        const list_sql = "SELECT owner, repo, description, topics, license, homepage, github_url, created_at, updated_at FROM packages ORDER BY updated_at DESC LIMIT ? OFFSET ?";
        result = c.sqlite3_prepare_v2(self.db, list_sql.ptr, @intCast(list_sql.len), &self.list_packages_stmt, null);
        if (result != c.SQLITE_OK) return error.PrepareStatementFailed;

        // Prepare update package statement
        const update_sql = "UPDATE packages SET description = ?, topics = ?, license = ?, homepage = ?, github_url = ?, updated_at = ? WHERE owner = ? AND repo = ?";
        result = c.sqlite3_prepare_v2(self.db, update_sql.ptr, @intCast(update_sql.len), &self.update_package_stmt, null);
        if (result != c.SQLITE_OK) return error.PrepareStatementFailed;
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

        var packages = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);

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
        var packages = std.array_list.AlignedManaged(types.PackageMetadata, null).init(self.allocator);

        // Cryptography category
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

        // Web category
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zap"),
            .version = types.Version{ .major = 0, .minor = 2, .patch = 1 },
            .description = try self.allocator.dupe(u8, "⚡ Blazingly fast web framework for Zig"),
            .author = try self.allocator.dupe(u8, "renerocksai"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/zigzap/zap"),
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "httpz"),
            .version = types.Version{ .major = 0, .minor = 3, .patch = 0 },
            .description = try self.allocator.dupe(u8, "HTTP/1.1 server for Zig"),
            .author = try self.allocator.dupe(u8, "karlseguin"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/karlseguin/http.zig"),
            .dependencies = &[_]types.Dependency{},
        });

        // System/Tools category
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "xev"),
            .version = types.Version{ .major = 0, .minor = 2, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Cross-platform event loop"),
            .author = try self.allocator.dupe(u8, "Mitchell Hashimoto"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/mitchellh/libxev"),
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "known-folders"),
            .version = types.Version{ .major = 0, .minor = 7, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Provides access to well-known folders on Linux, Windows and macOS"),
            .author = try self.allocator.dupe(u8, "ziglibs"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/ziglibs/known-folders"),
            .dependencies = &[_]types.Dependency{},
        });

        // Database category
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "sqlite"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "SQLite bindings for Zig"),
            .author = try self.allocator.dupe(u8, "vrischmann"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/vrischmann/zig-sqlite"),
            .dependencies = &[_]types.Dependency{},
        });

        // Text processing
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "ziglyph"),
            .version = types.Version{ .major = 0, .minor = 9, .patch = 1 },
            .description = try self.allocator.dupe(u8, "Unicode text processing library for Zig"),
            .author = try self.allocator.dupe(u8, "jecolon"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/jecolon/ziglyph"),
            .dependencies = &[_]types.Dependency{},
        });

        // Parsing
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "mecha"),
            .version = types.Version{ .major = 0, .minor = 5, .patch = 0 },
            .description = try self.allocator.dupe(u8, "A parser combinator library for Zig"),
            .author = try self.allocator.dupe(u8, "Hejsil"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/Hejsil/mecha"),
            .dependencies = &[_]types.Dependency{},
        });

        // CLI
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "clap"),
            .version = types.Version{ .major = 0, .minor = 7, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Command line argument parsing library"),
            .author = try self.allocator.dupe(u8, "Hejsil"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/Hejsil/zig-clap"),
            .dependencies = &[_]types.Dependency{},
        });

        // Graphics
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zgl"),
            .version = types.Version{ .major = 0, .minor = 2, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Zig OpenGL bindings"),
            .author = try self.allocator.dupe(u8, "ziglibs"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/ziglibs/zgl"),
            .dependencies = &[_]types.Dependency{},
        });

        // Math
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zalgebra"),
            .version = types.Version{ .major = 0, .minor = 3, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Linear algebra library for games and graphics"),
            .author = try self.allocator.dupe(u8, "kooparse"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/kooparse/zalgebra"),
            .dependencies = &[_]types.Dependency{},
        });

        // JSON
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "json"),
            .version = types.Version{ .major = 0, .minor = 10, .patch = 0 },
            .description = try self.allocator.dupe(u8, "JSON parser for Zig"),
            .author = try self.allocator.dupe(u8, "getty-zig"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/getty-zig/json"),
            .dependencies = &[_]types.Dependency{},
        });

        // Testing
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "ztest"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Enhanced testing framework for Zig"),
            .author = try self.allocator.dupe(u8, "cktech"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/cktech/ztest"),
            .dependencies = &[_]types.Dependency{},
        });

        // Networking
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "network"),
            .version = types.Version{ .major = 0, .minor = 5, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Cross-platform networking library"),
            .author = try self.allocator.dupe(u8, "MasterQ32"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/MasterQ32/zig-network"),
            .dependencies = &[_]types.Dependency{},
        });

        // Compression
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zstd"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Zstandard compression library bindings"),
            .author = try self.allocator.dupe(u8, "dweiller"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/dweiller/zstd"),
            .dependencies = &[_]types.Dependency{},
        });

        // Data structures
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zigds"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Advanced data structures for Zig"),
            .author = try self.allocator.dupe(u8, "cktech"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/cktech/zigds"),
            .dependencies = &[_]types.Dependency{},
        });

        // Logging
        try packages.append(types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zlog"),
            .version = types.Version{ .major = 0, .minor = 2, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Structured logging library for Zig"),
            .author = try self.allocator.dupe(u8, "cktech"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = try self.allocator.dupe(u8, "https://github.com/cktech/zlog"),
            .dependencies = &[_]types.Dependency{},
        });

        return packages.toOwnedSlice();
    }

    // GitHub-compatible API methods

    // Package operations
    pub fn addPackageGitHub(self: *Database, package: types.Package) !void {
        const topics_json = try self.serializeTopics(package.topics);
        defer self.allocator.free(topics_json);

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO packages 
            \\(owner, repo, description, topics, license, homepage, github_url, github_stars, created_at, updated_at, is_private)
            \\VALUES ('{s}', '{s}', '{s}', '{s}', '{s}', '{s}', '{s}', {d}, {d}, {d}, {d})
        , .{
            package.owner,
            package.repo,
            package.description orelse "",
            topics_json,
            package.license orelse "",
            package.homepage orelse "",
            package.github_url orelse "",
            package.github_stars,
            package.created_at,
            package.updated_at,
            @as(i32, if (package.is_private) 1 else 0),
        });
        defer self.allocator.free(sql);

        try self.execute(sql);
    }

    pub fn getPackageGitHub(self: *Database, owner: []const u8, repo: []const u8) !?types.Package {
        if (self.db == null) return null;

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT owner, repo, description, topics, license, homepage, github_url, github_stars, created_at, updated_at, is_private FROM packages WHERE owner = '{s}' AND repo = '{s}'", .{ owner, repo });
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
        const owner_cstr = c.sqlite3_column_text(stmt, 0);
        const repo_cstr = c.sqlite3_column_text(stmt, 1);
        const desc_cstr = c.sqlite3_column_text(stmt, 2);
        const topics_cstr = c.sqlite3_column_text(stmt, 3);
        const license_cstr = c.sqlite3_column_text(stmt, 4);
        const homepage_cstr = c.sqlite3_column_text(stmt, 5);
        const github_url_cstr = c.sqlite3_column_text(stmt, 6);
        const github_stars = @as(u32, @intCast(c.sqlite3_column_int(stmt, 7)));
        const created_at = c.sqlite3_column_int64(stmt, 8);
        const updated_at = c.sqlite3_column_int64(stmt, 9);
        const is_private = c.sqlite3_column_int(stmt, 10) != 0;

        if (owner_cstr == null or repo_cstr == null) return null;

        const owner_str = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(owner_cstr))));
        const repo_str = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr))));

        const topics = if (topics_cstr != null)
            try self.deserializeTopics(std.mem.span(@as([*:0]const u8, @ptrCast(topics_cstr))))
        else
            @as([][]const u8, &[_][]const u8{});

        return types.Package{
            .owner = owner_str,
            .repo = repo_str,
            .description = if (desc_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(desc_cstr))))
            else
                null,
            .topics = topics,
            .license = if (license_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(license_cstr))))
            else
                null,
            .homepage = if (homepage_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(homepage_cstr))))
            else
                null,
            .github_url = if (github_url_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(github_url_cstr))))
            else
                null,
            .github_stars = github_stars,
            .created_at = created_at,
            .updated_at = updated_at,
            .is_private = is_private,
        };
    }

    // Release operations
    pub fn addRelease(self: *Database, release: types.Release) !u64 {
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO releases 
            \\(owner, repo, tag_name, name, body, draft, prerelease, created_at, published_at, tarball_url, zipball_url, download_url, file_size, sha256)
            \\VALUES ('{s}', '{s}', '{s}', '{s}', '{s}', {d}, {d}, {d}, {?d}, '{s}', '{s}', '{s}', {d}, '{s}')
        , .{
            release.owner,
            release.repo,
            release.tag_name,
            release.name orelse "",
            release.body orelse "",
            if (release.draft) 1 else 0,
            if (release.prerelease) 1 else 0,
            release.created_at,
            release.published_at,
            release.tarball_url orelse "",
            release.zipball_url orelse "",
            release.download_url orelse "",
            release.file_size,
            release.sha256 orelse "",
        });
        defer self.allocator.free(sql);

        try self.execute(sql);

        // Return the last inserted row ID
        return @as(u64, @intCast(c.sqlite3_last_insert_rowid(self.db)));
    }

    pub fn getReleases(self: *Database, owner: []const u8, repo: []const u8) ![]types.Release {
        if (self.db == null) return &[_]types.Release{};

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT id, owner, repo, tag_name, name, body, draft, prerelease, created_at, published_at, tarball_url, zipball_url, download_url, file_size, sha256 FROM releases WHERE owner = '{s}' AND repo = '{s}' ORDER BY published_at DESC", .{ owner, repo });
        defer self.allocator.free(sql);

        var releases = std.array_list.AlignedManaged(types.Release, null).init(self.allocator);
        defer releases.deinit();

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return &[_]types.Release{};
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0)));
            const owner_cstr = c.sqlite3_column_text(stmt, 1);
            const repo_cstr = c.sqlite3_column_text(stmt, 2);
            const tag_cstr = c.sqlite3_column_text(stmt, 3);
            const name_cstr = c.sqlite3_column_text(stmt, 4);
            const body_cstr = c.sqlite3_column_text(stmt, 5);
            const draft = c.sqlite3_column_int(stmt, 6) != 0;
            const prerelease = c.sqlite3_column_int(stmt, 7) != 0;
            const created_at = c.sqlite3_column_int64(stmt, 8);
            const published_at_int = c.sqlite3_column_int64(stmt, 9);
            const published_at = if (published_at_int != 0) published_at_int else null;
            const tarball_cstr = c.sqlite3_column_text(stmt, 10);
            const zipball_cstr = c.sqlite3_column_text(stmt, 11);
            const download_cstr = c.sqlite3_column_text(stmt, 12);
            const file_size = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 13)));
            const sha256_cstr = c.sqlite3_column_text(stmt, 14);

            if (owner_cstr == null or repo_cstr == null or tag_cstr == null) continue;

            const release = types.Release{
                .id = id,
                .owner = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(owner_cstr)))),
                .repo = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr)))),
                .tag_name = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(tag_cstr)))),
                .name = if (name_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name_cstr))))
                else
                    null,
                .body = if (body_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(body_cstr))))
                else
                    null,
                .draft = draft,
                .prerelease = prerelease,
                .created_at = created_at,
                .published_at = published_at,
                .tarball_url = if (tarball_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(tarball_cstr))))
                else
                    null,
                .zipball_url = if (zipball_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(zipball_cstr))))
                else
                    null,
                .download_url = if (download_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(download_cstr))))
                else
                    null,
                .file_size = file_size,
                .sha256 = if (sha256_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(sha256_cstr))))
                else
                    null,
            };

            try releases.append(release);
        }

        return releases.toOwnedSlice();
    }

    pub fn getRelease(self: *Database, owner: []const u8, repo: []const u8, tag: []const u8) !?types.Release {
        if (self.db == null) return null;

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT id, owner, repo, tag_name, name, body, draft, prerelease, created_at, published_at, tarball_url, zipball_url, download_url, file_size, sha256 FROM releases WHERE owner = '{s}' AND repo = '{s}' AND tag_name = '{s}'", .{ owner, repo, tag });
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        const id = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0)));
        const owner_cstr = c.sqlite3_column_text(stmt, 1);
        const repo_cstr = c.sqlite3_column_text(stmt, 2);
        const tag_cstr = c.sqlite3_column_text(stmt, 3);
        const name_cstr = c.sqlite3_column_text(stmt, 4);
        const body_cstr = c.sqlite3_column_text(stmt, 5);
        const draft = c.sqlite3_column_int(stmt, 6) != 0;
        const prerelease = c.sqlite3_column_int(stmt, 7) != 0;
        const created_at = c.sqlite3_column_int64(stmt, 8);
        const published_at_int = c.sqlite3_column_int64(stmt, 9);
        const published_at = if (published_at_int != 0) published_at_int else null;
        const tarball_cstr = c.sqlite3_column_text(stmt, 10);
        const zipball_cstr = c.sqlite3_column_text(stmt, 11);
        const download_cstr = c.sqlite3_column_text(stmt, 12);
        const file_size = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 13)));
        const sha256_cstr = c.sqlite3_column_text(stmt, 14);

        if (owner_cstr == null or repo_cstr == null or tag_cstr == null) return null;

        return types.Release{
            .id = id,
            .owner = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(owner_cstr)))),
            .repo = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr)))),
            .tag_name = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(tag_cstr)))),
            .name = if (name_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name_cstr))))
            else
                null,
            .body = if (body_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(body_cstr))))
            else
                null,
            .draft = draft,
            .prerelease = prerelease,
            .created_at = created_at,
            .published_at = published_at,
            .tarball_url = if (tarball_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(tarball_cstr))))
            else
                null,
            .zipball_url = if (zipball_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(zipball_cstr))))
            else
                null,
            .download_url = if (download_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(download_cstr))))
            else
                null,
            .file_size = file_size,
            .sha256 = if (sha256_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(sha256_cstr))))
            else
                null,
        };
    }

    // Alias operations
    pub fn addAlias(self: *Database, alias: types.Alias) !void {
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO aliases 
            \\(short_name, owner, repo, created_at, created_by)
            \\VALUES ('{s}', '{s}', '{s}', {d}, '{s}')
        , .{
            alias.short_name,
            alias.owner,
            alias.repo,
            alias.created_at,
            alias.created_by orelse "",
        });
        defer self.allocator.free(sql);

        try self.execute(sql);
    }

    pub fn resolveAlias(self: *Database, short_name: []const u8) !?types.Alias {
        if (self.db == null) return null;

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT short_name, owner, repo, created_at, created_by FROM aliases WHERE short_name = '{s}'", .{short_name});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        const short_name_cstr = c.sqlite3_column_text(stmt, 0);
        const owner_cstr = c.sqlite3_column_text(stmt, 1);
        const repo_cstr = c.sqlite3_column_text(stmt, 2);
        const created_at = c.sqlite3_column_int64(stmt, 3);
        const created_by_cstr = c.sqlite3_column_text(stmt, 4);

        if (short_name_cstr == null or owner_cstr == null or repo_cstr == null) return null;

        return types.Alias{
            .short_name = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(short_name_cstr)))),
            .owner = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(owner_cstr)))),
            .repo = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr)))),
            .created_at = created_at,
            .created_by = if (created_by_cstr != null)
                try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(created_by_cstr))))
            else
                null,
        };
    }

    // Search operations
    pub fn searchPackages(self: *Database, query: []const u8, limit: u32) ![]types.SearchResult {
        if (self.db == null) return &[_]types.SearchResult{};

        // Simple search implementation - can be enhanced with full-text search
        const sql = try std.fmt.allocPrint(self.allocator,
            \\SELECT p.owner, p.repo, p.description, p.topics, p.github_stars, p.updated_at,
            \\       COALESCE(ds.download_count, 0) as download_count
            \\FROM packages p
            \\LEFT JOIN download_stats ds ON p.owner = ds.owner AND p.repo = ds.repo AND ds.tag_name IS NULL
            \\WHERE p.owner LIKE '%{s}%' OR p.repo LIKE '%{s}%' OR p.description LIKE '%{s}%' OR p.topics LIKE '%{s}%'
            \\ORDER BY p.github_stars DESC, ds.download_count DESC
            \\LIMIT {d}
        , .{ query, query, query, query, limit });
        defer self.allocator.free(sql);

        var results = std.array_list.AlignedManaged(types.SearchResult, null).init(self.allocator);
        defer results.deinit();

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return &[_]types.SearchResult{};
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const owner_cstr = c.sqlite3_column_text(stmt, 0);
            const repo_cstr = c.sqlite3_column_text(stmt, 1);
            const desc_cstr = c.sqlite3_column_text(stmt, 2);
            const topics_cstr = c.sqlite3_column_text(stmt, 3);
            const github_stars = @as(u32, @intCast(c.sqlite3_column_int(stmt, 4)));
            const updated_at = c.sqlite3_column_int64(stmt, 5);
            const download_count = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 6)));

            if (owner_cstr == null or repo_cstr == null) continue;

            const topics = if (topics_cstr != null)
                try self.deserializeTopics(std.mem.span(@as([*:0]const u8, @ptrCast(topics_cstr))))
            else
                @as([][]const u8, &[_][]const u8{});

            const search_result = types.SearchResult{
                .owner = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(owner_cstr)))),
                .repo = try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo_cstr)))),
                .description = if (desc_cstr != null)
                    try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(desc_cstr))))
                else
                    null,
                .topics = topics,
                .github_stars = github_stars,
                .download_count = download_count,
                .latest_version = null, // TODO: get from releases
                .updated_at = updated_at,
            };

            try results.append(search_result);
        }

        return results.toOwnedSlice();
    }

    // Registry configuration
    pub fn getRegistryConfig(self: *Database, key: []const u8) !?[]u8 {
        if (self.db == null) return null;

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT value FROM registry_config WHERE key = '{s}'", .{key});
        defer self.allocator.free(sql);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null);
        if (result != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        result = c.sqlite3_step(stmt);
        if (result != c.SQLITE_ROW) return null;

        const value_cstr = c.sqlite3_column_text(stmt, 0);
        if (value_cstr == null) return null;

        return try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value_cstr))));
    }

    pub fn setRegistryConfig(self: *Database, key: []const u8, value: []const u8) !void {
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO registry_config 
            \\(key, value, updated_at)
            \\VALUES ('{s}', '{s}', strftime('%s', 'now'))
        , .{ key, value });
        defer self.allocator.free(sql);

        try self.execute(sql);
    }

    // Download statistics
    pub fn incrementDownloadCount(self: *Database, owner: []const u8, repo: []const u8, tag_name: ?[]const u8) !void {
        const tag_clause = if (tag_name) |tag|
            try std.fmt.allocPrint(self.allocator, "'{s}'", .{tag})
        else
            try self.allocator.dupe(u8, "NULL");
        defer self.allocator.free(tag_clause);

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO download_stats (owner, repo, tag_name, download_count, last_downloaded)
            \\VALUES ('{s}', '{s}', {s}, 1, strftime('%s', 'now'))
            \\ON CONFLICT(owner, repo, tag_name) DO UPDATE SET
            \\download_count = download_count + 1,
            \\last_downloaded = strftime('%s', 'now')
        , .{ owner, repo, tag_clause });
        defer self.allocator.free(sql);

        try self.execute(sql);
    }

    // Download statistics methods
    pub fn getDownloadStats(self: *Database) !struct { total_packages: u32, total_downloads: u64, downloads_today: u64 } {
        if (self.db == null) return .{ .total_packages = 0, .total_downloads = 0, .downloads_today = 0 };

        // Get total packages count
        var total_packages: u32 = 0;
        const packages_sql = "SELECT COUNT(*) FROM packages";
        const packages_sql_z = try self.allocator.dupeZ(u8, packages_sql);
        defer self.allocator.free(packages_sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        var result = c.sqlite3_prepare_v2(self.db, packages_sql_z.ptr, -1, &stmt, null);
        if (result == c.SQLITE_OK) {
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                total_packages = @as(u32, @intCast(c.sqlite3_column_int(stmt, 0)));
            }
        }
        _ = c.sqlite3_finalize(stmt);

        // Get total downloads count
        var total_downloads: u64 = 0;
        const downloads_sql = "SELECT COALESCE(SUM(download_count), 0) FROM download_stats";
        const downloads_sql_z = try self.allocator.dupeZ(u8, downloads_sql);
        defer self.allocator.free(downloads_sql_z);

        stmt = null;
        result = c.sqlite3_prepare_v2(self.db, downloads_sql_z.ptr, -1, &stmt, null);
        if (result == c.SQLITE_OK) {
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                total_downloads = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0)));
            }
        }
        _ = c.sqlite3_finalize(stmt);

        // Get today's downloads (simplified - would need date logic in production)
        var downloads_today: u64 = 0;
        const today_sql = "SELECT COALESCE(SUM(download_count), 0) FROM download_stats WHERE last_downloaded >= strftime('%s', 'now', 'start of day')";
        const today_sql_z = try self.allocator.dupeZ(u8, today_sql);
        defer self.allocator.free(today_sql_z);

        stmt = null;
        result = c.sqlite3_prepare_v2(self.db, today_sql_z.ptr, -1, &stmt, null);
        if (result == c.SQLITE_OK) {
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                downloads_today = @as(u64, @intCast(c.sqlite3_column_int64(stmt, 0)));
            }
        }
        _ = c.sqlite3_finalize(stmt);

        return .{ .total_packages = total_packages, .total_downloads = total_downloads, .downloads_today = downloads_today };
    }

    // Helper methods for JSON serialization
    fn serializeTopics(self: *Database, topics: [][]const u8) ![]u8 {
        if (topics.len == 0) return self.allocator.dupe(u8, "[]");

        var json = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json.deinit();

        try json.append('[');
        for (topics, 0..) |topic, i| {
            if (i > 0) try json.appendSlice(",");
            try json.append('"');
            try json.appendSlice(topic);
            try json.append('"');
        }
        try json.append(']');

        return json.toOwnedSlice();
    }

    fn deserializeTopics(self: *Database, json_str: []const u8) ![][]const u8 {
        // Optimized JSON array parsing with state machine
        if (std.mem.eql(u8, json_str, "[]")) return &[_][]const u8{};

        var topics = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
        defer topics.deinit();

        // State machine for efficient parsing
        const ParseState = enum { WaitingForString, InString, WaitingForComma };
        var state = ParseState.WaitingForString;
        var string_start: usize = 0;
        var i: usize = 0;
        
        while (i < json_str.len) {
            const char = json_str[i];
            switch (state) {
                .WaitingForString => {
                    if (char == '"') {
                        state = .InString;
                        string_start = i + 1;
                    }
                },
                .InString => {
                    if (char == '"') {
                        // Handle escaped quotes
                        if (i > 0 and json_str[i - 1] == '\\') {
                            // Skip escaped quote
                        } else {
                            const topic = try self.allocator.dupe(u8, json_str[string_start..i]);
                            try topics.append(topic);
                            state = .WaitingForComma;
                        }
                    }
                },
                .WaitingForComma => {
                    if (char == ',') {
                        state = .WaitingForString;
                    } else if (char == ']') {
                        break;
                    }
                },
            }
            i += 1;
        }

        return topics.toOwnedSlice();
    }

    pub fn createUser(self: *Database, username: []const u8, email: []const u8, password_hash: []const u8, api_token: []const u8) !void {
        const sql = "INSERT INTO users (username, email, password_hash, api_token, created_at) VALUES (?, ?, ?, ?, ?)";
        
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            std.log.err("Failed to prepare user insert: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);
        
        const username_z = try self.allocator.dupeZ(u8, username);
        defer self.allocator.free(username_z);
        const email_z = try self.allocator.dupeZ(u8, email);
        defer self.allocator.free(email_z);
        const password_hash_z = try self.allocator.dupeZ(u8, password_hash);
        defer self.allocator.free(password_hash_z);
        const api_token_z = try self.allocator.dupeZ(u8, api_token);
        defer self.allocator.free(api_token_z);
        
        _ = c.sqlite3_bind_text(stmt, 1, username_z.ptr, -1, null);
        _ = c.sqlite3_bind_text(stmt, 2, email_z.ptr, -1, null);
        _ = c.sqlite3_bind_text(stmt, 3, password_hash_z.ptr, -1, null);
        _ = c.sqlite3_bind_text(stmt, 4, api_token_z.ptr, -1, null);
        _ = c.sqlite3_bind_int64(stmt, 5, std.time.timestamp());
        
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            std.log.err("Failed to create user: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.DatabaseError;
        }
    }
    
    pub fn getUser(self: *Database, username: []const u8) !?struct {
        username: []u8,
        email: []u8,
        password_hash: []u8,
        api_token: ?[]u8,
    } {
        const sql = "SELECT username, email, password_hash, api_token FROM users WHERE username = ?";
        
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);
        
        const username_z = try self.allocator.dupeZ(u8, username);
        defer self.allocator.free(username_z);
        _ = c.sqlite3_bind_text(stmt, 1, username_z.ptr, -1, null);
        
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            return null;
        }
        
        const db_username = c.sqlite3_column_text(stmt, 0);
        const db_email = c.sqlite3_column_text(stmt, 1);
        const db_password_hash = c.sqlite3_column_text(stmt, 2);
        const db_api_token = c.sqlite3_column_text(stmt, 3);
        
        return .{
            .username = try self.allocator.dupe(u8, std.mem.span(db_username)),
            .email = try self.allocator.dupe(u8, std.mem.span(db_email)),
            .password_hash = try self.allocator.dupe(u8, std.mem.span(db_password_hash)),
            .api_token = if (db_api_token != null) try self.allocator.dupe(u8, std.mem.span(db_api_token)) else null,
        };
    }
    
    pub fn userExists(self: *Database, username: []const u8) !bool {
        const sql = "SELECT 1 FROM users WHERE username = ? LIMIT 1";
        
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);
        
        const username_z = try self.allocator.dupeZ(u8, username);
        defer self.allocator.free(username_z);
        _ = c.sqlite3_bind_text(stmt, 1, username_z.ptr, -1, null);
        
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    // Ziglibs-specific database methods
    pub fn listZiglibsPackages(self: *Database, limit: ?usize, offset: ?usize) ![]types.Package {
        const limit_val = limit orelse 50;
        const offset_val = offset orelse 0;
        
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT owner, repo, description, topics, license, homepage, github_url, github_stars, created_at, updated_at FROM packages WHERE source = 'ziglibs' ORDER BY updated_at DESC LIMIT ? OFFSET ?";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);
        
        _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit_val));
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(offset_val));
        
        var packages = std.array_list.AlignedManaged(types.Package, null).init(self.allocator);
        defer packages.deinit();
        
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const owner = c.sqlite3_column_text(stmt, 0);
            const repo = c.sqlite3_column_text(stmt, 1);
            const description = c.sqlite3_column_text(stmt, 2);
            // const topics = c.sqlite3_column_text(stmt, 3); // TODO: Parse topics
            const license = c.sqlite3_column_text(stmt, 4);
            const homepage = c.sqlite3_column_text(stmt, 5);
            const github_url = c.sqlite3_column_text(stmt, 6);
            const github_stars = c.sqlite3_column_int(stmt, 7);
            const created_at = c.sqlite3_column_int64(stmt, 8);
            const updated_at = c.sqlite3_column_int64(stmt, 9);
            
            const package = types.Package{
                .owner = if (owner != null) try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(owner)))) else try self.allocator.dupe(u8, ""),
                .repo = if (repo != null) try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(repo)))) else try self.allocator.dupe(u8, ""),
                .description = if (description != null) try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(description)))) else null,
                .topics = &.{}, // TODO: Parse comma-separated topics from database
                .license = if (license != null) try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(license)))) else null,
                .homepage = if (homepage != null) try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(homepage)))) else null,
                .github_url = if (github_url != null) try self.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(github_url)))) else null,
                .github_stars = @intCast(github_stars),
                .created_at = created_at,
                .updated_at = updated_at,
                .is_private = false,
            };
            
            try packages.append(package);
        }
        
        return packages.toOwnedSlice();
    }

    pub fn countZiglibsPackages(self: *Database) !u32 {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT COUNT(*) FROM packages WHERE source = 'ziglibs'";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DatabaseError;
        }
        defer _ = c.sqlite3_finalize(stmt);
        
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return @intCast(c.sqlite3_column_int(stmt, 0));
        }
        
        return 0;
    }
};
