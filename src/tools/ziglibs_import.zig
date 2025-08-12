const std = @import("std");
const types = @import("../common/types.zig");

pub const ZiglibsImporter = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    
    pub fn init(allocator: std.mem.Allocator) ZiglibsImporter {
        return ZiglibsImporter{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *ZiglibsImporter) void {
        self.http_client.deinit();
    }
    
    pub fn fetchAndParseZiglibs(self: *ZiglibsImporter) ![]types.Package {
        // Fetch the ziglibs repository list
        const url = "https://api.github.com/repos/ziglibs/repository/contents/libs";
        
        std.log.info("🔄 Fetching Ziglibs packages from: {s}", .{url});
        
        // For now, return mock data to test the integration
        // TODO: Implement actual HTTP fetching and JSON parsing
        var packages = std.ArrayList(types.Package).init(self.allocator);
        
        // Mock Ziglibs packages
        const mock_packages = [_]struct {
            owner: []const u8,
            repo: []const u8,
            description: []const u8,
            license: []const u8,
        }{
            .{ .owner = "ziglibs", .repo = "zgl", .description = "Zig OpenGL wrapper", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zig-clap", .description = "Simple command line argument parsing library", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zig-regex", .description = "Regular expressions for Zig", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zig-json", .description = "Fast JSON parser for Zig", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zig-network", .description = "Small network abstraction layer around TCP & UDP", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zigimg", .description = "Image reading/writing library for Zig", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zig-sqlite", .description = "Zig SQLite wrapper", .license = "MIT" },
            .{ .owner = "ziglibs", .repo = "zig-tracy", .description = "Zig bindings for Tracy profiler", .license = "MIT" },
        };
        
        for (mock_packages) |pkg| {
            const package = types.Package{
                .owner = try self.allocator.dupe(u8, pkg.owner),
                .repo = try self.allocator.dupe(u8, pkg.repo),
                .description = try self.allocator.dupe(u8, pkg.description),
                .topics = &.{}, // Empty topics array for now
                .license = try self.allocator.dupe(u8, pkg.license),
                .homepage = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}", .{ pkg.owner, pkg.repo }),
                .github_url = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}", .{ pkg.owner, pkg.repo }),
                .github_stars = 0, // Will be fetched later
                .created_at = std.time.timestamp(),
                .updated_at = std.time.timestamp(),
                .is_private = false,
            };
            
            try packages.append(package);
        }
        
        std.log.info("✅ Found {} Ziglibs packages", .{packages.items.len});
        return packages.toOwnedSlice();
    }
    
    pub fn importPackages(self: *ZiglibsImporter, database: anytype) !u32 {
        const packages = try self.fetchAndParseZiglibs();
        defer {
            for (packages) |pkg| {
                self.allocator.free(pkg.owner);
                self.allocator.free(pkg.repo);
                if (pkg.description) |desc| self.allocator.free(desc);
                // TODO: Free topics array when implemented
                if (pkg.license) |license| self.allocator.free(license);
                if (pkg.homepage) |homepage| self.allocator.free(homepage);
                if (pkg.github_url) |url| self.allocator.free(url);
            }
            self.allocator.free(packages);
        }
        
        var imported_count: u32 = 0;
        for (packages) |pkg| {
            database.addPackageGitHub(pkg) catch |err| {
                std.log.warn("Failed to import package {s}/{s}: {}", .{ pkg.owner, pkg.repo, err });
                continue;
            };
            imported_count += 1;
        }
        
        std.log.info("✅ Successfully imported {} Ziglibs packages", .{imported_count});
        return imported_count;
    }
};
