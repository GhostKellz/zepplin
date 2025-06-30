const std = @import("std");

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

/// Package metadata structure
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
        // Simple JSON serialization for now
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "{}.{}.{}",
            \\  "description": "{s}",
            \\  "author": "{s}",
            \\  "license": "{s}"
            \\}}
        , .{
            self.name,
            self.version.major,
            self.version.minor,
            self.version.patch,
            self.description orelse "",
            self.author orelse "",
            self.license orelse "",
        });
    }
};

/// Registry configuration
pub const RegistryConfig = struct {
    name: []const u8,
    url: []const u8,
    auth_token: ?[]const u8 = null,
};

/// Search result for package queries
pub const SearchResult = struct {
    name: []const u8,
    description: ?[]const u8,
    version: ?[]const u8,
    author: ?[]const u8,
    owner: ?[]const u8,
    repo: ?[]const u8,
    license: ?[]const u8,
    repository: ?[]const u8,
    topics: ?[][]const u8,
    github_stars: ?u32,
    latest_version: ?[]const u8,
    created_at: ?i64,
    updated_at: ?i64,
    download_count: ?u64,
    
    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        if (self.version) |ver| allocator.free(ver);
        if (self.author) |auth| allocator.free(auth);
        if (self.owner) |own| allocator.free(own);
        if (self.repo) |r| allocator.free(r);
        if (self.license) |lic| allocator.free(lic);
        if (self.repository) |repo| allocator.free(repo);
        if (self.topics) |topics| {
            for (topics) |topic| {
                allocator.free(topic);
            }
            allocator.free(topics);
        }
        if (self.latest_version) |ver| allocator.free(ver);
    }
};

/// API response wrapper
pub fn ApiResponse(comptime T: type) type {
    return struct {
        success: bool,
        data: ?T = null,
        error_message: ?[]const u8 = null,
    };
}
