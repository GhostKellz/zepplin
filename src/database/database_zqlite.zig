const std = @import("std");
const zqlite = @import("zqlite");
const compat = @import("../common/compat.zig");
const types = @import("../common/types.zig");

pub const Database = struct {
    db: *zqlite.db.Connection,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Database {
        const db = try zqlite.open(allocator, db_path);

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

        // Map external OAuth/OIDC identities to a stable local user. Kept as a
        // side table (rather than new columns on `users`) because the engine has
        // no ALTER TABLE: CREATE TABLE IF NOT EXISTS is the only idempotent path
        // and it leaves the existing `users` schema and data untouched.
        try db.execute(
            \\CREATE TABLE IF NOT EXISTS oauth_identities (
            \\  provider TEXT,
            \\  external_id TEXT,
            \\  user_id INTEGER,
            \\  username TEXT,
            \\  email TEXT,
            \\  created_at INTEGER
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

    /// Run a mutating statement and flush it to disk before returning.
    ///
    /// zqlite autocommit statements only touch the in-memory btree/pager cache;
    /// durability happens in `flush()`/`commit()`/`close()`. The server runs an
    /// infinite accept loop and is always terminated by a signal, so `close()`
    /// never executes — without an explicit flush here every write would be lost
    /// on restart. Flushing per write gives a registry the synchronous-durable
    /// behavior callers expect.
    fn executeWrite(self: *Database, sql: []const u8) !void {
        try self.db.execute(sql);
        try self.db.flush();
    }

    // Package operations
    pub fn addPackage(self: *Database, package: types.PackageMetadata) !void {
        const version_str = try package.version.toString(self.allocator);
        defer self.allocator.free(version_str);

        // Every string field originates from the upload request, so each must be
        // escaped before interpolation to avoid SQL injection. version_str is
        // numeric-dotted by construction but escaped for uniformity. Heap-allocated
        // because arbitrary descriptions/repositories overflow a fixed buffer.
        const esc_name = try escapeSql(self.allocator, package.name);
        defer self.allocator.free(esc_name);
        const esc_version = try escapeSql(self.allocator, version_str);
        defer self.allocator.free(esc_version);
        const esc_description = try escapeSql(self.allocator, package.description orelse "");
        defer self.allocator.free(esc_description);
        const esc_author = try escapeSql(self.allocator, package.author orelse "");
        defer self.allocator.free(esc_author);
        const esc_license = try escapeSql(self.allocator, package.license orelse "");
        defer self.allocator.free(esc_license);
        const esc_repository = try escapeSql(self.allocator, package.repository orelse "");
        defer self.allocator.free(esc_repository);

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO packages
            \\(name, version, description, author, license, repository, dependencies,
            \\ file_path, file_size, checksum, created_at, updated_at)
            \\VALUES ('{s}', '{s}', '{s}', '{s}', '{s}', '{s}', '{s}',
            \\        '', 0, '', {d}, {d})
        , .{
            esc_name,
            esc_version,
            esc_description,
            esc_author,
            esc_license,
            esc_repository,
            "", // dependencies as JSON string - TODO: serialize properly
            compat.timestamp(),
            compat.timestamp(),
        });
        defer self.allocator.free(sql);

        try self.executeWrite(sql);
    }

    pub fn getPackage(self: *Database, name: []const u8) !?types.PackageMetadata {
        const esc_name = try escapeSql(self.allocator, name);
        defer self.allocator.free(esc_name);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT name, version, description, author, license, repository FROM packages WHERE name = '{s}'", .{esc_name});
        defer self.allocator.free(sql);

        var result = self.db.query(sql) catch |err| {
            std.log.warn("Database query failed for package '{s}': {}", .{ name, err });
            return null;
        };
        defer result.deinit();

        // Get first row if exists
        if (result.next()) |row_const| {
            var row = row_const;
            defer row.deinit();

            const pkg_name = row.getText(0) orelse return null;
            const version_str = row.getText(1) orelse "0.0.0";
            const description = row.getText(2);
            const author = row.getText(3);
            const license = row.getText(4);
            const repository = row.getText(5);

            // Parse version string
            var version = types.Version{ .major = 0, .minor = 0, .patch = 0 };
            var ver_iter = std.mem.splitSequence(u8, version_str, ".");
            if (ver_iter.next()) |major| version.major = std.fmt.parseInt(u32, major, 10) catch 0;
            if (ver_iter.next()) |minor| version.minor = std.fmt.parseInt(u32, minor, 10) catch 0;
            if (ver_iter.next()) |patch| version.patch = std.fmt.parseInt(u32, patch, 10) catch 0;

            return types.PackageMetadata{
                .name = try self.allocator.dupe(u8, pkg_name),
                .version = version,
                .description = if (description) |d| try self.allocator.dupe(u8, d) else null,
                .author = if (author) |a| try self.allocator.dupe(u8, a) else null,
                .license = if (license) |l| try self.allocator.dupe(u8, l) else null,
                .repository = if (repository) |r| try self.allocator.dupe(u8, r) else null,
                .dependencies = &[_]types.Dependency{},
            };
        }

        return null;
    }

    pub fn listPackages(self: *Database, limit: ?usize, offset: ?usize) ![]types.PackageMetadata {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "SELECT name, version, description, author, license, repository FROM packages LIMIT {d} OFFSET {d}", .{ limit orelse 100, offset orelse 0 });

        var result = self.db.query(sql) catch |err| {
            std.log.warn("Database query failed for listPackages: {}", .{err});
            return self.getMockPackages();
        };
        defer result.deinit();

        var packages: std.ArrayList(types.PackageMetadata) = .empty;

        while (result.next()) |row_const| {
            var row = row_const;
            defer row.deinit();

            const pkg_name = row.getText(0) orelse continue;
            const version_str = row.getText(1) orelse "0.0.0";
            const description = row.getText(2);
            const author = row.getText(3);
            const license = row.getText(4);
            const repository = row.getText(5);

            var version = types.Version{ .major = 0, .minor = 0, .patch = 0 };
            var ver_iter = std.mem.splitSequence(u8, version_str, ".");
            if (ver_iter.next()) |major| version.major = std.fmt.parseInt(u32, major, 10) catch 0;
            if (ver_iter.next()) |minor| version.minor = std.fmt.parseInt(u32, minor, 10) catch 0;
            if (ver_iter.next()) |patch| version.patch = std.fmt.parseInt(u32, patch, 10) catch 0;

            try packages.append(self.allocator, types.PackageMetadata{
                .name = try self.allocator.dupe(u8, pkg_name),
                .version = version,
                .description = if (description) |d| try self.allocator.dupe(u8, d) else null,
                .author = if (author) |a| try self.allocator.dupe(u8, a) else null,
                .license = if (license) |l| try self.allocator.dupe(u8, l) else null,
                .repository = if (repository) |r| try self.allocator.dupe(u8, r) else null,
                .dependencies = &[_]types.Dependency{},
            });
        }

        // If no packages in DB, return mock data for demo
        if (packages.items.len == 0) {
            packages.deinit(self.allocator);
            return self.getMockPackages();
        }

        return packages.toOwnedSlice(self.allocator);
    }

    fn getMockPackages(self: *Database) ![]types.PackageMetadata {
        var packages: std.ArrayList(types.PackageMetadata) = .empty;

        try packages.append(self.allocator, types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zcrypto"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Pure Zig cryptographic library for GhostChain"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zcrypto",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(self.allocator, types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zsig"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Digital signature library for GhostChain"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zsig",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(self.allocator, types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zwallet"),
            .version = types.Version{ .major = 0, .minor = 1, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Wallet library for GhostChain ecosystem"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zwallet",
            .dependencies = &[_]types.Dependency{},
        });

        try packages.append(self.allocator, types.PackageMetadata{
            .name = try self.allocator.dupe(u8, "zqlite"),
            .version = types.Version{ .major = 0, .minor = 4, .patch = 0 },
            .description = try self.allocator.dupe(u8, "Pure Zig SQLite alternative with cryptographic features"),
            .author = try self.allocator.dupe(u8, "GhostKellz"),
            .license = try self.allocator.dupe(u8, "MIT"),
            .repository = "https://github.com/ghostkellz/zqlite",
            .dependencies = &[_]types.Dependency{},
        });

        return packages.toOwnedSlice(self.allocator);
    }

    pub fn searchPackages(self: *Database, query: []const u8, limit: ?usize) ![]types.PackageMetadata {
        const esc_query = try escapeSql(self.allocator, query);
        defer self.allocator.free(esc_query);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT name, version, description, author, license, repository FROM packages WHERE name LIKE '%{s}%' OR description LIKE '%{s}%' LIMIT {}", .{ esc_query, esc_query, limit orelse 20 });
        defer self.allocator.free(sql);

        var result = self.db.query(sql) catch |err| {
            std.log.warn("Database search query failed: {}", .{err});
            // Fall back to filtering mock data
            const all_mock = try self.getMockPackages();
            defer self.allocator.free(all_mock);
            var filtered: std.ArrayList(types.PackageMetadata) = .empty;
            for (all_mock) |pkg| {
                if (std.mem.indexOf(u8, pkg.name, query) != null or
                    (pkg.description != null and std.mem.indexOf(u8, pkg.description.?, query) != null))
                {
                    try filtered.append(self.allocator, pkg);
                    if (filtered.items.len >= (limit orelse 20)) break;
                }
            }
            return filtered.toOwnedSlice(self.allocator);
        };
        defer result.deinit();

        var packages: std.ArrayList(types.PackageMetadata) = .empty;

        while (result.next()) |row_const| {
            var row = row_const;
            defer row.deinit();

            const pkg_name = row.getText(0) orelse continue;
            const version_str = row.getText(1) orelse "0.0.0";
            const description = row.getText(2);
            const author = row.getText(3);
            const license = row.getText(4);
            const repository = row.getText(5);

            var version = types.Version{ .major = 0, .minor = 0, .patch = 0 };
            var ver_iter = std.mem.splitSequence(u8, version_str, ".");
            if (ver_iter.next()) |major| version.major = std.fmt.parseInt(u32, major, 10) catch 0;
            if (ver_iter.next()) |minor| version.minor = std.fmt.parseInt(u32, minor, 10) catch 0;
            if (ver_iter.next()) |patch| version.patch = std.fmt.parseInt(u32, patch, 10) catch 0;

            try packages.append(self.allocator, types.PackageMetadata{
                .name = try self.allocator.dupe(u8, pkg_name),
                .version = version,
                .description = if (description) |d| try self.allocator.dupe(u8, d) else null,
                .author = if (author) |a| try self.allocator.dupe(u8, a) else null,
                .license = if (license) |l| try self.allocator.dupe(u8, l) else null,
                .repository = if (repository) |r| try self.allocator.dupe(u8, r) else null,
                .dependencies = &[_]types.Dependency{},
            });
        }

        if (packages.items.len == 0) {
            packages.deinit(self.allocator);
            // Fall back to filtering mock data
            const all_mock = try self.getMockPackages();
            defer self.allocator.free(all_mock);
            var filtered: std.ArrayList(types.PackageMetadata) = .empty;
            for (all_mock) |pkg| {
                if (std.mem.indexOf(u8, pkg.name, query) != null or
                    (pkg.description != null and std.mem.indexOf(u8, pkg.description.?, query) != null))
                {
                    try filtered.append(self.allocator, pkg);
                    if (filtered.items.len >= (limit orelse 20)) break;
                }
            }
            return filtered.toOwnedSlice(self.allocator);
        }

        return packages.toOwnedSlice(self.allocator);
    }

    pub fn removePackage(self: *Database, name: []const u8) !void {
        const esc_name = try escapeSql(self.allocator, name);
        defer self.allocator.free(esc_name);
        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM packages WHERE name = '{s}'", .{esc_name});
        defer self.allocator.free(sql);
        try self.executeWrite(sql);
    }

    // User operations
    pub fn createUser(self: *Database, username: []const u8, email: []const u8, password_hash: []const u8, api_token: []const u8) !void {
        // username/email come straight from the registration request body, so
        // they must be escaped before interpolation or a quote breaks the
        // statement / allows SQL injection. password_hash (hex) and api_token
        // (base64url JWT) are quote-free by construction.
        const esc_username = try escapeSql(self.allocator, username);
        defer self.allocator.free(esc_username);
        const esc_email = try escapeSql(self.allocator, email);
        defer self.allocator.free(esc_email);

        // Heap-allocated: the api_token is a full JWT (~250+ chars) which, with
        // the hex password hash, overflows any reasonable fixed stack buffer.
        const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO users (username, email, password_hash, api_token, created_at) VALUES ('{s}', '{s}', '{s}', '{s}', {d})", .{ esc_username, esc_email, password_hash, api_token, compat.timestamp() });
        defer self.allocator.free(sql);
        try self.executeWrite(sql);
    }

    /// Credentials needed to authenticate a local login and mint a session.
    /// `id` is derived deterministically from the username so register and
    /// login agree without needing an auto-increment column (the engine has
    /// no usable rowid/AUTOINCREMENT). Caller owns the strings.
    pub const UserAuth = struct {
        id: i64,
        email: []const u8,
        password_hash: []const u8,

        pub fn deinit(self: UserAuth, allocator: std.mem.Allocator) void {
            allocator.free(self.email);
            allocator.free(self.password_hash);
        }
    };

    pub fn getUserAuth(self: *Database, username: []const u8) !?UserAuth {
        const escaped = try escapeSql(self.allocator, username);
        defer self.allocator.free(escaped);

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT email, password_hash FROM users WHERE username = '{s}'", .{escaped});
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        if (result.next()) |row_const| {
            var row = row_const;
            defer row.deinit();
            const email = try self.allocator.dupe(u8, row.getText(0) orelse "");
            errdefer self.allocator.free(email);
            const hash = try self.allocator.dupe(u8, row.getText(1) orelse "");
            return UserAuth{
                .id = deriveUserId("local", username),
                .email = email,
                .password_hash = hash,
            };
        }
        return null;
    }

    /// Stable local user id for a freshly registered (or existing) local user.
    pub fn localUserId(username: []const u8) i64 {
        return deriveUserId("local", username);
    }

    /// Resolve an external identity to a stable local user id, persisting it on
    /// first sight. Returns the same id on subsequent logins for the same
    /// (provider, external_id) pair.
    pub fn findOrCreateOAuthUser(
        self: *Database,
        provider: []const u8,
        external_id: []const u8,
        username: []const u8,
        email: []const u8,
    ) !i64 {
        const esc_provider = try escapeSql(self.allocator, provider);
        defer self.allocator.free(esc_provider);
        const esc_external = try escapeSql(self.allocator, external_id);
        defer self.allocator.free(esc_external);

        const select_sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT user_id FROM oauth_identities WHERE provider = '{s}' AND external_id = '{s}'",
            .{ esc_provider, esc_external },
        );
        defer self.allocator.free(select_sql);

        {
            var result = try self.db.query(select_sql);
            defer result.deinit();
            if (result.next()) |row_const| {
                var row = row_const;
                defer row.deinit();
                if (row.getInt(0)) |id| return id;
            }
        }

        const id = deriveUserId(provider, external_id);

        const esc_username = try escapeSql(self.allocator, username);
        defer self.allocator.free(esc_username);
        const esc_email = try escapeSql(self.allocator, email);
        defer self.allocator.free(esc_email);

        const insert_sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO oauth_identities (provider, external_id, user_id, username, email, created_at) VALUES ('{s}', '{s}', {d}, '{s}', '{s}', {d})",
            .{ esc_provider, esc_external, id, esc_username, esc_email, compat.timestamp() },
        );
        defer self.allocator.free(insert_sql);

        try self.executeWrite(insert_sql);
        return id;
    }

    // Stats operations
    pub fn incrementDownloadCount(self: *Database, package_name: []const u8) !void {
        // package_name is "{owner}/{repo}" taken from the request URL, so it must
        // be escaped before interpolation to avoid SQL injection.
        const esc_name = try escapeSql(self.allocator, package_name);
        defer self.allocator.free(esc_name);
        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT OR REPLACE INTO download_stats (package_name, download_count, last_downloaded)
            \\VALUES ('{s}', 1, {d})
        , .{ esc_name, compat.timestamp() });
        defer self.allocator.free(sql);
        try self.executeWrite(sql);
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
            .created_at = compat.timestamp(),
            .published_at = compat.timestamp(),
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
            .created_at = compat.timestamp() - 86400,
            .published_at = compat.timestamp() - 86400,
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
                .created_at = compat.timestamp(),
                .created_by = try self.allocator.dupe(u8, "system"),
            };
        } else if (std.mem.eql(u8, short_name, "http")) {
            return types.Alias{
                .short_name = try self.allocator.dupe(u8, short_name),
                .owner = try self.allocator.dupe(u8, "karlseguin"),
                .repo = try self.allocator.dupe(u8, "http.zig"),
                .created_at = compat.timestamp(),
                .created_by = try self.allocator.dupe(u8, "system"),
            };
        } else if (std.mem.eql(u8, short_name, "xev")) {
            return types.Alias{
                .short_name = try self.allocator.dupe(u8, short_name),
                .owner = try self.allocator.dupe(u8, "mitchellh"),
                .repo = try self.allocator.dupe(u8, "libxev"),
                .created_at = compat.timestamp(),
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
            .created_at = compat.timestamp() - 86400 * 30,
            .updated_at = compat.timestamp() - 86400 * 7,
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
            .created_at = compat.timestamp() - 86400 * 60,
            .updated_at = compat.timestamp() - 86400 * 14,
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
        const escaped = try escapeSql(self.allocator, username);
        defer self.allocator.free(escaped);

        const sql = try std.fmt.allocPrint(self.allocator, "SELECT username FROM users WHERE username = '{s}'", .{escaped});
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        if (result.next()) |row_const| {
            var row = row_const;
            row.deinit();
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
        return @intCast(@mod(compat.timestamp(), 1000000));
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
                .created_at = compat.timestamp() - 86400, // 1 day ago
                .updated_at = compat.timestamp() - 86400,
                .parent_id = null,
            });
            
            try comments.append(types.Comment{
                .id = 2,
                .package_id = try self.allocator.dupe(u8, package_id),
                .user_id = 456,
                .username = try self.allocator.dupe(u8, "coder_jane"),
                .display_name = try self.allocator.dupe(u8, "Jane Coder"),
                .content = try self.allocator.dupe(u8, "Thanks for the excellent documentation. Very helpful!"),
                .created_at = compat.timestamp() - 3600, // 1 hour ago
                .updated_at = compat.timestamp() - 3600,
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

/// Deterministic, stable positive i64 user id from a namespace + key. Used in
/// place of an auto-increment column (the storage engine assigns no rowid for
/// regular INTEGER PRIMARY KEY columns), so the same identity always maps to
/// the same id across logins.
fn deriveUserId(namespace: []const u8, key: []const u8) i64 {
    var h = std.hash.Wyhash.init(0);
    h.update(namespace);
    h.update(":");
    h.update(key);
    return @intCast(h.final() & 0x7FFF_FFFF_FFFF_FFFF);
}

/// Escape single quotes for inline SQL string literals. Values flowing in from
/// registration and OAuth providers are externally controlled, so doubling
/// quotes prevents them from breaking out of the literal.
fn escapeSql(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == '\'') try out.append(allocator, '\'');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

test "deriveUserId is stable, positive, and namespace-sensitive" {
    const a = deriveUserId("local", "alice");
    try std.testing.expectEqual(a, deriveUserId("local", "alice"));
    try std.testing.expect(a >= 0);
    try std.testing.expect(deriveUserId("github", "alice") != a);
}

test "escapeSql doubles single quotes" {
    const allocator = std.testing.allocator;
    const out = try escapeSql(allocator, "O'Brien");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("O''Brien", out);
}
