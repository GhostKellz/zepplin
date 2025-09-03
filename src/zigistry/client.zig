const std = @import("std");
const types = @import("../common/types.zig");

pub const ZigistryError = error{
    NetworkError,
    ApiError,
    ParseError,
    RateLimited,
    NotFound,
};

pub const PackageSource = enum {
    zepplin_registry, // Hosted on Zepplin
    github_direct, // Direct GitHub download
    zigistry_indexed, // Found via Zigistry
};

pub const ZigistryPackage = struct {
    name: []const u8,
    description: ?[]const u8,
    github_url: []const u8,
    github_stars: u32,
    zigistry_score: f32,
    topics: [][]const u8,
    last_updated: i64,
    license: ?[]const u8,
    readme_url: ?[]const u8,

    pub fn deinit(self: *ZigistryPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.github_url);
        for (self.topics) |topic| {
            allocator.free(topic);
        }
        allocator.free(self.topics);
        if (self.license) |license| allocator.free(license);
        if (self.readme_url) |url| allocator.free(url);
    }
};

pub const SearchResult = struct {
    name: []const u8,
    description: ?[]const u8,
    source: PackageSource,

    // Zepplin-specific
    hosted_versions: ?[]types.Version,
    download_count: ?u32,

    // Zigistry-specific
    github_url: ?[]const u8,
    github_stars: ?u32,
    zigistry_score: ?f32,
    topics: [][]const u8,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        if (self.hosted_versions) |versions| allocator.free(versions);
        if (self.github_url) |url| allocator.free(url);
        for (self.topics) |topic| {
            allocator.free(topic);
        }
        allocator.free(self.topics);
    }
};

pub const ZigistryClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, base_url: ?[]const u8) ZigistryClient {
        return ZigistryClient{
            .allocator = allocator,
            .base_url = base_url orelse "https://zigistry.dev",
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *ZigistryClient) void {
        self.http_client.deinit();
    }

    pub fn searchPackages(self: *ZigistryClient, query: []const u8, limit: ?usize) ![]ZigistryPackage {
        // For now, return mock data - in a real implementation this would make HTTP requests
        _ = query;
        _ = limit;

        var packages = std.array_list.AlignedManaged(ZigistryPackage, null).init(self.allocator);

        // Mock data based on popular Zig packages
        try packages.append(ZigistryPackage{
            .name = try self.allocator.dupe(u8, "zig-clap"),
            .description = try self.allocator.dupe(u8, "Simple command line argument parsing library"),
            .github_url = try self.allocator.dupe(u8, "https://github.com/Hejsil/zig-clap"),
            .github_stars = 823,
            .zigistry_score = 0.95,
            .topics = try self.createTopics(&[_][]const u8{ "cli", "parser", "arguments" }),
            .last_updated = std.time.timestamp() - 86400 * 7, // 1 week ago
            .license = try self.allocator.dupe(u8, "MIT"),
            .readme_url = try self.allocator.dupe(u8, "https://raw.githubusercontent.com/Hejsil/zig-clap/master/README.md"),
        });

        try packages.append(ZigistryPackage{
            .name = try self.allocator.dupe(u8, "zap"),
            .description = try self.allocator.dupe(u8, "Blazingly fast web framework for Zig"),
            .github_url = try self.allocator.dupe(u8, "https://github.com/zigzap/zap"),
            .github_stars = 1542,
            .zigistry_score = 0.98,
            .topics = try self.createTopics(&[_][]const u8{ "web", "http", "server", "framework" }),
            .last_updated = std.time.timestamp() - 86400 * 2, // 2 days ago
            .license = try self.allocator.dupe(u8, "MIT"),
            .readme_url = try self.allocator.dupe(u8, "https://raw.githubusercontent.com/zigzap/zap/master/README.md"),
        });

        try packages.append(ZigistryPackage{
            .name = try self.allocator.dupe(u8, "raylib-zig"),
            .description = try self.allocator.dupe(u8, "Zig bindings for raylib game development library"),
            .github_url = try self.allocator.dupe(u8, "https://github.com/Not-Nik/raylib-zig"),
            .github_stars = 456,
            .zigistry_score = 0.89,
            .topics = try self.createTopics(&[_][]const u8{ "gamedev", "graphics", "raylib", "bindings" }),
            .last_updated = std.time.timestamp() - 86400 * 5, // 5 days ago
            .license = try self.allocator.dupe(u8, "zlib"),
            .readme_url = try self.allocator.dupe(u8, "https://raw.githubusercontent.com/Not-Nik/raylib-zig/master/README.md"),
        });

        return packages.toOwnedSlice();
    }

    pub fn getPackageInfo(self: *ZigistryClient, name: []const u8) !?ZigistryPackage {
        // Mock implementation - search through our mock data
        const packages = try self.searchPackages("", null);
        defer {
            for (packages) |*pkg| {
                pkg.deinit(self.allocator);
            }
            self.allocator.free(packages);
        }

        for (packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, name)) {
                return ZigistryPackage{
                    .name = try self.allocator.dupe(u8, pkg.name),
                    .description = if (pkg.description) |desc| try self.allocator.dupe(u8, desc) else null,
                    .github_url = try self.allocator.dupe(u8, pkg.github_url),
                    .github_stars = pkg.github_stars,
                    .zigistry_score = pkg.zigistry_score,
                    .topics = try self.duplicateTopics(pkg.topics),
                    .last_updated = pkg.last_updated,
                    .license = if (pkg.license) |license| try self.allocator.dupe(u8, license) else null,
                    .readme_url = if (pkg.readme_url) |url| try self.allocator.dupe(u8, url) else null,
                };
            }
        }

        return null;
    }

    pub fn getTrending(self: *ZigistryClient, category: ?[]const u8, limit: ?usize) ![]ZigistryPackage {
        // Mock implementation - return packages sorted by score
        _ = category;
        const packages = try self.searchPackages("", limit);

        // Sort by zigistry_score (descending) - use heap sort for better performance
        std.sort.heap(ZigistryPackage, packages, {}, struct {
            fn lessThan(_: void, a: ZigistryPackage, b: ZigistryPackage) bool {
                return a.zigistry_score > b.zigistry_score;
            }
        }.lessThan);

        return packages;
    }

    pub fn getCategories(self: *ZigistryClient) ![][]const u8 {
        // Return popular categories
        var categories = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);

        try categories.append(try self.allocator.dupe(u8, "web"));
        try categories.append(try self.allocator.dupe(u8, "cli"));
        try categories.append(try self.allocator.dupe(u8, "gamedev"));
        try categories.append(try self.allocator.dupe(u8, "graphics"));
        try categories.append(try self.allocator.dupe(u8, "crypto"));
        try categories.append(try self.allocator.dupe(u8, "parser"));
        try categories.append(try self.allocator.dupe(u8, "networking"));
        try categories.append(try self.allocator.dupe(u8, "database"));

        return categories.toOwnedSlice();
    }

    fn createTopics(self: *ZigistryClient, topic_strings: []const []const u8) ![][]const u8 {
        var topics = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
        for (topic_strings) |topic| {
            try topics.append(try self.allocator.dupe(u8, topic));
        }
        return topics.toOwnedSlice();
    }

    fn duplicateTopics(self: *ZigistryClient, topics: [][]const u8) ![][]const u8 {
        var new_topics = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
        for (topics) |topic| {
            try new_topics.append(try self.allocator.dupe(u8, topic));
        }
        return new_topics.toOwnedSlice();
    }
};

// HTTP Request helpers (for future real implementation)
pub fn makeGetRequest(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    _ = allocator;
    _ = url;
    // TODO: Implement actual HTTP requests using std.http.Client
    return error.NetworkError;
}

pub fn parseJsonResponse(allocator: std.mem.Allocator, json_data: []const u8) ![]ZigistryPackage {
    _ = allocator;
    _ = json_data;
    // TODO: Implement JSON parsing for Zigistry API responses
    return error.ParseError;
}
