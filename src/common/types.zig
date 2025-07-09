const std = @import("std");

// String pool for commonly used strings to reduce allocations
pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: std.mem.Allocator) StringPool {
        return StringPool{
            .allocator = allocator,
            .strings = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *StringPool) void {
        // Free all stored strings
        var iterator = self.strings.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.strings.deinit();
    }
    
    pub fn intern(self: *StringPool, str: []const u8) ![]const u8 {
        if (self.strings.get(str)) |interned| {
            return interned;
        }
        
        const owned = try self.allocator.dupe(u8, str);
        try self.strings.put(owned, owned);
        return owned;
    }
};

/// Package version following semantic versioning
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(version_str: []const u8) !Version {
        var parts = std.mem.splitSequence(u8, version_str, ".");
        const major_str = parts.next() orelse return error.InvalidVersion;
        const minor_str = parts.next() orelse return error.InvalidVersion;
        const patch_str = parts.next() orelse return error.InvalidVersion;

        return Version{
            .major = try std.fmt.parseInt(u32, major_str, 10),
            .minor = try std.fmt.parseInt(u32, minor_str, 10),
            .patch = try std.fmt.parseInt(u32, patch_str, 10),
        };
    }

    pub fn toString(self: Version, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{}.{}.{}", .{ self.major, self.minor, self.patch });
    }
};

/// Package dependency specification
pub const Dependency = struct {
    name: []const u8,
    version: Version,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// Package metadata structure (legacy, for backward compatibility)
pub const PackageMetadata = struct {
    name: []const u8,
    version: Version,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    dependencies: []Dependency = &.{},
    keywords: [][]const u8 = &.{},
    minimum_zig_version: ?[]const u8 = null,

    pub fn toJson(self: PackageMetadata, allocator: std.mem.Allocator) ![]u8 {
        // Optimized JSON serialization using ArrayList for better performance
        var json_buffer = std.ArrayList(u8).init(allocator);
        errdefer json_buffer.deinit();
        
        const writer = json_buffer.writer();
        
        try writer.writeAll("{\n");
        try writer.print("  \"name\": \"{s}\",\n", .{self.name});
        try writer.print("  \"version\": \"{}.{}.{}\",\n", .{self.version.major, self.version.minor, self.version.patch});
        try writer.print("  \"description\": \"{s}\",\n", .{self.description orelse ""});
        try writer.print("  \"author\": \"{s}\",\n", .{self.author orelse ""});
        try writer.print("  \"license\": \"{s}\"", .{self.license orelse ""});
        
        if (self.homepage) |homepage| {
            try writer.print(",\n  \"homepage\": \"{s}\"", .{homepage});
        }
        if (self.repository) |repository| {
            try writer.print(",\n  \"repository\": \"{s}\"", .{repository});
        }
        if (self.keywords.len > 0) {
            try writer.writeAll(",\n  \"keywords\": [");
            for (self.keywords, 0..) |keyword, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{keyword});
            }
            try writer.writeAll("]");
        }
        if (self.minimum_zig_version) |min_version| {
            try writer.print(",\n  \"minimum_zig_version\": \"{s}\"", .{min_version});
        }
        
        try writer.writeAll("\n}");
        return json_buffer.toOwnedSlice();
    }
    
    pub fn toJsonStream(self: PackageMetadata, writer: anytype) !void {
        // Streaming JSON serialization for direct output
        try writer.writeAll("{\n");
        try writer.print("  \"name\": \"{s}\",\n", .{self.name});
        try writer.print("  \"version\": \"{}.{}.{}\",\n", .{self.version.major, self.version.minor, self.version.patch});
        try writer.print("  \"description\": \"{s}\",\n", .{self.description orelse ""});
        try writer.print("  \"author\": \"{s}\",\n", .{self.author orelse ""});
        try writer.print("  \"license\": \"{s}\"", .{self.license orelse ""});
        
        if (self.homepage) |homepage| {
            try writer.print(",\n  \"homepage\": \"{s}\"", .{homepage});
        }
        if (self.repository) |repository| {
            try writer.print(",\n  \"repository\": \"{s}\"", .{repository});
        }
        if (self.keywords.len > 0) {
            try writer.writeAll(",\n  \"keywords\": [");
            for (self.keywords, 0..) |keyword, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{keyword});
            }
            try writer.writeAll("]");
        }
        if (self.minimum_zig_version) |min_version| {
            try writer.print(",\n  \"minimum_zig_version\": \"{s}\"", .{min_version});
        }
        
        try writer.writeAll("\n}");
    }
};

/// GitHub-compatible Package structure
pub const Package = struct {
    owner: []const u8,
    repo: []const u8,
    description: ?[]const u8 = null,
    topics: [][]const u8 = &.{},
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    github_url: ?[]const u8 = null,
    github_stars: u32 = 0,
    created_at: i64,
    updated_at: i64,
    is_private: bool = false,

    pub fn fullName(self: Package, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.owner, self.repo });
    }
};

/// GitHub-compatible Release structure
pub const Release = struct {
    id: u64,
    owner: []const u8,
    repo: []const u8,
    tag_name: []const u8,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    draft: bool = false,
    prerelease: bool = false,
    created_at: i64,
    published_at: ?i64 = null,
    tarball_url: ?[]const u8 = null,
    zipball_url: ?[]const u8 = null,
    download_url: ?[]const u8 = null,
    file_size: u64 = 0,
    sha256: ?[]const u8 = null,

    pub fn toJson(self: Release, allocator: std.mem.Allocator) ![]u8 {
        const published_str = if (self.published_at) |p|
            try std.fmt.allocPrint(allocator, "{d}", .{p})
        else
            try allocator.dupe(u8, "null");
        defer if (self.published_at != null) allocator.free(published_str);

        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "id": {d},
            \\  "tag_name": "{s}",
            \\  "name": "{s}",
            \\  "body": "{s}",
            \\  "draft": {s},
            \\  "prerelease": {s},
            \\  "created_at": "{d}",
            \\  "published_at": {s},
            \\  "tarball_url": "{s}",
            \\  "zipball_url": "{s}",
            \\  "download_url": "{s}",
            \\  "file_size": {d},
            \\  "sha256": "{s}"
            \\}}
        , .{
            self.id,
            self.tag_name,
            self.name orelse "",
            self.body orelse "",
            if (self.draft) "true" else "false",
            if (self.prerelease) "true" else "false",
            self.created_at,
            published_str,
            self.tarball_url orelse "",
            self.zipball_url orelse "",
            self.download_url orelse "",
            self.file_size,
            self.sha256 orelse "",
        });
    }
};

/// Package alias/short name
pub const Alias = struct {
    short_name: []const u8,
    owner: []const u8,
    repo: []const u8,
    created_at: i64,
    created_by: ?[]const u8 = null,

    pub fn resolvedName(self: Alias, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.owner, self.repo });
    }
};

/// Download statistics
pub const DownloadStats = struct {
    owner: []const u8,
    repo: []const u8,
    tag_name: ?[]const u8 = null,
    download_count: u64 = 0,
    last_downloaded: ?i64 = null,
};

/// Registry configuration
pub const RegistryConfig = struct {
    name: []const u8,
    url: []const u8,
    auth_token: ?[]const u8 = null,
    api_version: []const u8 = "v1",
    allow_public_publish: bool = true,
};

/// Search result item
pub const SearchResult = struct {
    owner: []const u8,
    repo: []const u8,
    description: ?[]const u8 = null,
    topics: [][]const u8 = &.{},
    github_stars: u32 = 0,
    download_count: u64 = 0,
    latest_version: ?[]const u8 = null,
    updated_at: i64,
};

/// API response wrapper
pub fn ApiResponse(comptime T: type) type {
    return struct {
        success: bool,
        data: ?T = null,
        error_message: ?[]const u8 = null,
    };
}

/// GitHub-compatible API error response
pub const GitHubError = struct {
    message: []const u8,
    documentation_url: ?[]const u8 = null,
};

/// Upload form data for package publishing
pub const UploadData = struct {
    owner: []const u8,
    repo: []const u8,
    tag_name: []const u8,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    draft: bool = false,
    prerelease: bool = false,
    file_data: []const u8,
    filename: []const u8,
    content_type: []const u8,
};
