const std = @import("std");
const compat = @import("../common/compat.zig");
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
    io: std.Io,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: ?[]const u8) ZigistryClient {
        return ZigistryClient{
            .allocator = allocator,
            .io = io,
            .base_url = base_url orelse "https://zigistry.dev",
        };
    }

    pub fn deinit(self: *ZigistryClient) void {
        _ = self;
    }

    pub fn searchPackages(self: *ZigistryClient, query: []const u8, limit: ?usize) ![]ZigistryPackage {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        // Build search URL with query parameters
        const encoded_query = try urlEncode(self.allocator, query);
        defer self.allocator.free(encoded_query);

        const actual_limit = limit orelse 20;
        const search_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/packages?q={s}&limit={d}",
            .{ self.base_url, encoded_query, actual_limit },
        );
        defer self.allocator.free(search_url);

        const response_body = self.makeHttpRequest(&client, search_url) catch |err| {
            std.debug.print("Zigistry search failed: {}\n", .{err});
            // Return empty results on network failure
            return self.allocator.alloc(ZigistryPackage, 0);
        };
        defer self.allocator.free(response_body);

        return self.parsePackagesResponse(response_body) catch |err| {
            std.debug.print("Zigistry parse failed: {}\n", .{err});
            return self.allocator.alloc(ZigistryPackage, 0);
        };
    }

    pub fn getPackageInfo(self: *ZigistryClient, name: []const u8) !?ZigistryPackage {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const encoded_name = try urlEncode(self.allocator, name);
        defer self.allocator.free(encoded_name);

        const package_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/packages/{s}",
            .{ self.base_url, encoded_name },
        );
        defer self.allocator.free(package_url);

        const response_body = self.makeHttpRequest(&client, package_url) catch |err| {
            std.debug.print("Zigistry package info failed: {}\n", .{err});
            return null;
        };
        defer self.allocator.free(response_body);

        return self.parseSinglePackageResponse(response_body) catch |err| {
            std.debug.print("Zigistry package parse failed: {}\n", .{err});
            return null;
        };
    }

    pub fn getTrending(self: *ZigistryClient, category: ?[]const u8, limit: ?usize) ![]ZigistryPackage {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const actual_limit = limit orelse 20;
        var trending_url: []u8 = undefined;

        if (category) |cat| {
            const encoded_cat = try urlEncode(self.allocator, cat);
            defer self.allocator.free(encoded_cat);
            trending_url = try std.fmt.allocPrint(
                self.allocator,
                "{s}/api/packages/trending?category={s}&limit={d}",
                .{ self.base_url, encoded_cat, actual_limit },
            );
        } else {
            trending_url = try std.fmt.allocPrint(
                self.allocator,
                "{s}/api/packages/trending?limit={d}",
                .{ self.base_url, actual_limit },
            );
        }
        defer self.allocator.free(trending_url);

        const response_body = self.makeHttpRequest(&client, trending_url) catch |err| {
            std.debug.print("Zigistry trending failed: {}\n", .{err});
            return self.allocator.alloc(ZigistryPackage, 0);
        };
        defer self.allocator.free(response_body);

        return self.parsePackagesResponse(response_body) catch |err| {
            std.debug.print("Zigistry trending parse failed: {}\n", .{err});
            return self.allocator.alloc(ZigistryPackage, 0);
        };
    }

    pub fn getCategories(self: *ZigistryClient) ![][]const u8 {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const categories_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/categories",
            .{self.base_url},
        );
        defer self.allocator.free(categories_url);

        const response_body = self.makeHttpRequest(&client, categories_url) catch |err| {
            std.debug.print("Zigistry categories failed: {}\n", .{err});
            // Return default categories on failure
            return self.getDefaultCategories();
        };
        defer self.allocator.free(response_body);

        return self.parseCategoriesResponse(response_body) catch |err| {
            std.debug.print("Zigistry categories parse failed: {}\n", .{err});
            return self.getDefaultCategories();
        };
    }

    fn makeHttpRequest(self: *ZigistryClient, client: *std.http.Client, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);

        const headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "Zepplin-Registry/0.6.2" },
        };

        var req = try client.request(.GET, uri, .{ .extra_headers = &headers });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buffer: [1024]u8 = undefined;
        const response = try req.receiveHead(&redirect_buffer);

        if (response.head.status == .not_found) {
            return ZigistryError.NotFound;
        }

        if (response.head.status == .too_many_requests) {
            return ZigistryError.RateLimited;
        }

        if (response.head.status != .ok) {
            std.debug.print("Zigistry API returned status: {}\n", .{response.head.status});
            return ZigistryError.ApiError;
        }

        var transfer_buffer: [8192]u8 = undefined;
        const body_reader = req.reader.bodyReader(&transfer_buffer, response.head.transfer_encoding, response.head.content_length);
        return body_reader.*.readAlloc(self.allocator, 2 * 1024 * 1024);
    }

    fn parsePackagesResponse(self: *ZigistryClient, response_body: []const u8) ![]ZigistryPackage {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        // Handle both array response and object with "packages" field
        const packages_array = switch (parsed.value) {
            .array => |arr| arr,
            .object => |obj| if (obj.get("packages")) |pkgs| switch (pkgs) {
                .array => |arr| arr,
                else => return ZigistryError.ParseError,
            } else return ZigistryError.ParseError,
            else => return ZigistryError.ParseError,
        };

        var packages: std.ArrayList(ZigistryPackage) = .empty;
        errdefer {
            for (packages.items) |*pkg| {
                pkg.deinit(self.allocator);
            }
            packages.deinit(self.allocator);
        }

        for (packages_array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const pkg = try self.parsePackageObject(obj);
            try packages.append(self.allocator, pkg);
        }

        return packages.toOwnedSlice(self.allocator);
    }

    fn parseSinglePackageResponse(self: *ZigistryClient, response_body: []const u8) !ZigistryPackage {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        if (parsed.value != .object) {
            return ZigistryError.ParseError;
        }

        return self.parsePackageObject(parsed.value.object);
    }

    fn parsePackageObject(self: *ZigistryClient, obj: std.json.ObjectMap) !ZigistryPackage {
        // Required fields
        const name = obj.get("name") orelse return ZigistryError.ParseError;
        if (name != .string) return ZigistryError.ParseError;

        // GitHub URL - check multiple possible field names
        var github_url_str: []const u8 = "";
        if (obj.get("github_url")) |url| {
            if (url == .string) github_url_str = url.string;
        } else if (obj.get("repo_url")) |url| {
            if (url == .string) github_url_str = url.string;
        } else if (obj.get("url")) |url| {
            if (url == .string) github_url_str = url.string;
        }

        // Optional fields with defaults
        const description = if (obj.get("description")) |d| switch (d) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => null,
        } else null;

        const github_stars: u32 = if (obj.get("stars")) |s| switch (s) {
            .integer => |i| @intCast(i),
            else => 0,
        } else if (obj.get("github_stars")) |s| switch (s) {
            .integer => |i| @intCast(i),
            else => 0,
        } else 0;

        const zigistry_score: f32 = if (obj.get("score")) |s| switch (s) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        } else if (obj.get("zigistry_score")) |s| switch (s) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        } else 0.0;

        const last_updated: i64 = if (obj.get("updated_at")) |u| switch (u) {
            .integer => |i| i,
            else => compat.timestamp(),
        } else if (obj.get("last_updated")) |u| switch (u) {
            .integer => |i| i,
            else => compat.timestamp(),
        } else compat.timestamp();

        const license = if (obj.get("license")) |l| switch (l) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => null,
        } else null;

        const readme_url = if (obj.get("readme_url")) |r| switch (r) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => null,
        } else null;

        // Parse topics array
        var topics: std.ArrayList([]const u8) = .empty;
        if (obj.get("topics")) |t| {
            if (t == .array) {
                for (t.array.items) |topic_item| {
                    if (topic_item == .string) {
                        try topics.append(self.allocator, try self.allocator.dupe(u8, topic_item.string));
                    }
                }
            }
        } else if (obj.get("tags")) |t| {
            if (t == .array) {
                for (t.array.items) |topic_item| {
                    if (topic_item == .string) {
                        try topics.append(self.allocator, try self.allocator.dupe(u8, topic_item.string));
                    }
                }
            }
        }

        return ZigistryPackage{
            .name = try self.allocator.dupe(u8, name.string),
            .description = description,
            .github_url = try self.allocator.dupe(u8, github_url_str),
            .github_stars = github_stars,
            .zigistry_score = zigistry_score,
            .topics = try topics.toOwnedSlice(self.allocator),
            .last_updated = last_updated,
            .license = license,
            .readme_url = readme_url,
        };
    }

    fn parseCategoriesResponse(self: *ZigistryClient, response_body: []const u8) ![][]const u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{});
        defer parsed.deinit();

        const categories_array = switch (parsed.value) {
            .array => |arr| arr,
            .object => |obj| if (obj.get("categories")) |cats| switch (cats) {
                .array => |arr| arr,
                else => return self.getDefaultCategories(),
            } else return self.getDefaultCategories(),
            else => return self.getDefaultCategories(),
        };

        var categories: std.ArrayList([]const u8) = .empty;

        for (categories_array.items) |item| {
            if (item == .string) {
                try categories.append(self.allocator, try self.allocator.dupe(u8, item.string));
            } else if (item == .object) {
                if (item.object.get("name")) |name| {
                    if (name == .string) {
                        try categories.append(self.allocator, try self.allocator.dupe(u8, name.string));
                    }
                }
            }
        }

        if (categories.items.len == 0) {
            categories.deinit(self.allocator);
            return self.getDefaultCategories();
        }

        return categories.toOwnedSlice(self.allocator);
    }

    fn getDefaultCategories(self: *ZigistryClient) ![][]const u8 {
        var categories: std.ArrayList([]const u8) = .empty;

        try categories.append(self.allocator, try self.allocator.dupe(u8, "web"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "cli"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "gamedev"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "graphics"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "crypto"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "parser"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "networking"));
        try categories.append(self.allocator, try self.allocator.dupe(u8, "database"));

        return categories.toOwnedSlice(self.allocator);
    }

    fn createTopics(self: *ZigistryClient, topic_strings: []const []const u8) ![][]const u8 {
        var topics: std.ArrayList([]const u8) = .empty;
        for (topic_strings) |topic| {
            try topics.append(self.allocator, try self.allocator.dupe(u8, topic));
        }
        return topics.toOwnedSlice(self.allocator);
    }

    fn duplicateTopics(self: *ZigistryClient, topics_in: [][]const u8) ![][]const u8 {
        var new_topics: std.ArrayList([]const u8) = .empty;
        for (topics_in) |topic| {
            try new_topics.append(self.allocator, try self.allocator.dupe(u8, topic));
        }
        return new_topics.toOwnedSlice(self.allocator);
    }
};

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;

    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try encoded.append(allocator, c);
            },
            ' ' => {
                try encoded.append(allocator, '+');
            },
            else => {
                const hex_chars = "0123456789ABCDEF";
                try encoded.append(allocator, '%');
                try encoded.append(allocator, hex_chars[(c >> 4) & 0xF]);
                try encoded.append(allocator, hex_chars[c & 0xF]);
            },
        }
    }

    return encoded.toOwnedSlice(allocator);
}
