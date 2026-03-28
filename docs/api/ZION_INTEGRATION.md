# 🔗 Zion v0.7.0+ Integration with Zepplin Registry

> **Complete guide for integrating Zion v0.6.0+ with Zepplin as a custom package registry**

**Zion Repository**: https://github.com/ryleelyman/zion  
**Zepplin Repository**: https://github.com/ghostkellz/zepplin  
**Integration Target**: Zion v0.7.0 (next major release)  
**Registry Compatibility**: GitHub API v3/v4 compatible  

---

## 🎯 **Integration Overview**

### **Current State (Zion v0.6.0)**
Zion v0.6.0 just released with:
- ✅ Improved package resolution
- ✅ Better dependency management  
- ✅ Enhanced CLI experience
- ❌ **No custom registry support** (hardcoded to GitHub)

### **Target State (Zion v0.7.0)**
Zion v0.7.0 should support:
- ✅ **Custom Registry URLs**: Environment variable configuration
- ✅ **Registry Fallback**: Primary → GitHub fallback chain
- ✅ **Alias Resolution**: Server-side short name resolution
- ✅ **Authentication**: API token support for private registries
- ✅ **Registry Discovery**: Automatic registry capability detection

---

## 🔧 **Phase 1: Zion Core Registry Abstraction**

### **1.1 Registry Configuration System**

**File**: `src/config.zig` (or equivalent)

```zig
const std = @import("std");

pub const RegistryConfig = struct {
    name: []const u8,
    base_url: []const u8,
    api_version: []const u8 = "v1",
    auth_token: ?[]const u8 = null,
    priority: u32 = 0, // Lower = higher priority
    enabled: bool = true,
    timeout_ms: u32 = 30000,
    
    pub fn getApiUrl(self: RegistryConfig, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/api/{s}", .{
            std.mem.trimRight(u8, self.base_url, "/"),
            self.api_version
        });
    }
};

pub const ZionConfig = struct {
    allocator: std.mem.Allocator,
    registries: std.ArrayList(RegistryConfig),
    github_username: ?[]const u8 = null,
    cache_dir: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) ZionConfig {
        return ZionConfig{
            .allocator = allocator,
            .registries = std.ArrayList(RegistryConfig).init(allocator),
            .cache_dir = "/tmp/zion-cache", // Default
        };
    }
    
    pub fn loadFromEnvironment(self: *ZionConfig) !void {
        // Primary registry from environment
        if (std.posix.getenv("ZION_REGISTRY_URL")) |registry_url| {
            const auth_token = std.posix.getenv("ZION_REGISTRY_TOKEN");
            
            try self.registries.append(RegistryConfig{
                .name = "custom",
                .base_url = try self.allocator.dupe(u8, registry_url),
                .auth_token = if (auth_token) |token| 
                    try self.allocator.dupe(u8, token) else null,
                .priority = 0, // Highest priority
            });
        }
        
        // Multiple registries support
        if (std.posix.getenv("ZION_REGISTRIES")) |registries_str| {
            var it = std.mem.splitScalar(u8, registries_str, ',');
            var priority: u32 = 1;
            
            while (it.next()) |registry_url| {
                const trimmed = std.mem.trim(u8, registry_url, " ");
                if (trimmed.len > 0) {
                    try self.registries.append(RegistryConfig{
                        .name = try std.fmt.allocPrint(self.allocator, "registry-{}", .{priority}),
                        .base_url = try self.allocator.dupe(u8, trimmed),
                        .priority = priority,
                    });
                    priority += 1;
                }
            }
        }
        
        // Always add GitHub as fallback (lowest priority)
        try self.registries.append(RegistryConfig{
            .name = "github",
            .base_url = try self.allocator.dupe(u8, "https://api.github.com"),
            .api_version = "", // GitHub doesn't use /api/v1 prefix
            .priority = 999, // Lowest priority
        });
        
        // Sort registries by priority
        std.sort.block(RegistryConfig, self.registries.items, {}, struct {
            fn lessThan(context: void, a: RegistryConfig, b: RegistryConfig) bool {
                _ = context;
                return a.priority < b.priority;
            }
        }.lessThan);
        
        // Load other config
        if (std.posix.getenv("ZION_GITHUB_USERNAME")) |username| {
            self.github_username = try self.allocator.dupe(u8, username);
        }
        
        if (std.posix.getenv("ZION_CACHE_DIR")) |cache_dir| {
            self.cache_dir = try self.allocator.dupe(u8, cache_dir);
        }
    }
    
    pub fn deinit(self: *ZionConfig) void {
        for (self.registries.items) |registry| {
            self.allocator.free(registry.name);
            self.allocator.free(registry.base_url);
            if (registry.auth_token) |token| {
                self.allocator.free(token);
            }
        }
        self.registries.deinit();
        
        if (self.github_username) |username| {
            self.allocator.free(username);
        }
        self.allocator.free(self.cache_dir);
    }
};
```

### **1.2 Registry Client Abstraction**

**File**: `src/registry.zig` (new file)

```zig
const std = @import("std");
const config = @import("config.zig");

pub const Package = struct {
    name: []const u8,
    full_name: []const u8,
    description: ?[]const u8,
    version: []const u8,
    tarball_url: []const u8,
    sha256_hash: ?[]const u8,
    published_at: []const u8,
    registry_name: []const u8,
    
    pub fn deinit(self: Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.full_name);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.version);
        allocator.free(self.tarball_url);
        if (self.sha256_hash) |hash| allocator.free(hash);
        allocator.free(self.published_at);
        allocator.free(self.registry_name);
    }
};

pub const Release = struct {
    tag_name: []const u8,
    name: []const u8,
    published_at: []const u8,
    prerelease: bool,
    tarball_url: []const u8,
    zipball_url: ?[]const u8,
    
    pub fn deinit(self: Release, allocator: std.mem.Allocator) void {
        allocator.free(self.tag_name);
        allocator.free(self.name);
        allocator.free(self.published_at);
        allocator.free(self.tarball_url);
        if (self.zipball_url) |url| allocator.free(url);
    }
};

pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    config: config.RegistryConfig,
    http_client: std.http.Client,
    
    pub fn init(allocator: std.mem.Allocator, registry_config: config.RegistryConfig) RegistryClient {
        return RegistryClient{
            .allocator = allocator,
            .config = registry_config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *RegistryClient) void {
        self.http_client.deinit();
    }
    
    /// Resolve short name to full name (e.g., "zcrypto" -> "cktech/zcrypto")
    pub fn resolveAlias(self: *RegistryClient, short_name: []const u8) !?[]const u8 {
        if (std.mem.indexOf(u8, short_name, "/") != null) {
            // Already a full name, return as-is
            return try self.allocator.dupe(u8, short_name);
        }
        
        // Try registry-specific alias resolution
        const api_url = try self.config.getApiUrl(self.allocator);
        defer self.allocator.free(api_url);
        
        const resolve_url = try std.fmt.allocPrint(self.allocator, 
            "{s}/resolve/{s}", .{ api_url, short_name });
        defer self.allocator.free(resolve_url);
        
        const response = self.makeRequest("GET", resolve_url, null) catch |err| switch (err) {
            error.HttpRequestFailed => return null, // 404 or other error
            else => return err,
        };
        defer self.allocator.free(response);
        
        // Parse JSON response
        const parsed = std.json.parseFromSlice(struct {
            full_name: []const u8,
            resolved: bool,
        }, self.allocator, response, .{}) catch return null;
        defer parsed.deinit();
        
        if (parsed.value.resolved) {
            return try self.allocator.dupe(u8, parsed.value.full_name);
        }
        
        return null;
    }
    
    /// Fetch package releases
    pub fn fetchReleases(self: *RegistryClient, owner: []const u8, repo: []const u8) ![]Release {
        const api_url = try self.config.getApiUrl(self.allocator);
        defer self.allocator.free(api_url);
        
        const releases_url = if (std.mem.eql(u8, self.config.name, "github")) 
            try std.fmt.allocPrint(self.allocator, "{s}/repos/{s}/{s}/releases", .{ api_url, owner, repo })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/packages/{s}/{s}/releases", .{ api_url, owner, repo });
        defer self.allocator.free(releases_url);
        
        const response = try self.makeRequest("GET", releases_url, null);
        defer self.allocator.free(response);
        
        // Parse JSON array of releases
        const parsed = try std.json.parseFromSlice([]Release, self.allocator, response, .{});
        defer parsed.deinit();
        
        // Deep clone the releases
        var releases = std.ArrayList(Release).init(self.allocator);
        for (parsed.value) |release| {
            try releases.append(Release{
                .tag_name = try self.allocator.dupe(u8, release.tag_name),
                .name = try self.allocator.dupe(u8, release.name),
                .published_at = try self.allocator.dupe(u8, release.published_at),
                .prerelease = release.prerelease,
                .tarball_url = try self.allocator.dupe(u8, release.tarball_url),
                .zipball_url = if (release.zipball_url) |url| 
                    try self.allocator.dupe(u8, url) else null,
            });
        }
        
        return releases.toOwnedSlice();
    }
    
    /// Fetch package tags (fallback when no releases)
    pub fn fetchTags(self: *RegistryClient, owner: []const u8, repo: []const u8) ![]Release {
        const api_url = try self.config.getApiUrl(self.allocator);
        defer self.allocator.free(api_url);
        
        const tags_url = if (std.mem.eql(u8, self.config.name, "github"))
            try std.fmt.allocPrint(self.allocator, "{s}/repos/{s}/{s}/tags", .{ api_url, owner, repo })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/packages/{s}/{s}/tags", .{ api_url, owner, repo });
        defer self.allocator.free(tags_url);
        
        const response = try self.makeRequest("GET", tags_url, null);
        defer self.allocator.free(response);
        
        // Parse and convert tags to release format
        const parsed = try std.json.parseFromSlice([]struct {
            name: []const u8,
            tarball_url: []const u8,
        }, self.allocator, response, .{});
        defer parsed.deinit();
        
        var releases = std.ArrayList(Release).init(self.allocator);
        for (parsed.value) |tag| {
            try releases.append(Release{
                .tag_name = try self.allocator.dupe(u8, tag.name),
                .name = try std.fmt.allocPrint(self.allocator, "Tag {s}", .{tag.name}),
                .published_at = try self.allocator.dupe(u8, "1970-01-01T00:00:00Z"), // Unknown
                .prerelease = false,
                .tarball_url = try self.allocator.dupe(u8, tag.tarball_url),
                .zipball_url = null,
            });
        }
        
        return releases.toOwnedSlice();
    }
    
    /// Search packages
    pub fn searchPackages(self: *RegistryClient, query: []const u8, language: ?[]const u8) ![]Package {
        const api_url = try self.config.getApiUrl(self.allocator);
        defer self.allocator.free(api_url);
        
        const search_url = if (std.mem.eql(u8, self.config.name, "github"))
            try std.fmt.allocPrint(self.allocator, "{s}/search/repositories?q={s}+language:{s}", 
                .{ api_url, query, language orelse "zig" })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/search?q={s}&language={s}", 
                .{ api_url, query, language orelse "zig" });
        defer self.allocator.free(search_url);
        
        const response = try self.makeRequest("GET", search_url, null);
        defer self.allocator.free(response);
        
        // Parse search results (GitHub vs Zepplin format)
        if (std.mem.eql(u8, self.config.name, "github")) {
            return try self.parseGitHubSearchResults(response);
        } else {
            return try self.parseZepplinSearchResults(response);
        }
    }
    
    /// Make HTTP request with authentication
    fn makeRequest(self: *RegistryClient, method: []const u8, url: []const u8, body: ?[]const u8) ![]const u8 {
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        try headers.append("User-Agent", "Zion Package Manager");
        try headers.append("Accept", "application/json");
        
        // Add authentication if available
        if (self.config.auth_token) |token| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_header);
            try headers.append("Authorization", auth_header);
        }
        
        // Make HTTP request
        var request = try self.http_client.request(.{
            .method = if (std.mem.eql(u8, method, "GET")) .GET else .POST,
            .url = url,
            .headers = headers,
        });
        defer request.deinit();
        
        if (body) |request_body| {
            request.transfer_encoding = .{ .content_length = request_body.len };
            try request.send(.{});
            try request.writeAll(request_body);
        } else {
            try request.send(.{});
        }
        
        try request.finish();
        try request.wait();
        
        if (request.response.status != .ok) {
            return error.HttpRequestFailed;
        }
        
        // Read response body
        const response_body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024); // 1MB max
        return response_body;
    }
    
    fn parseGitHubSearchResults(self: *RegistryClient, response: []const u8) ![]Package {
        const parsed = try std.json.parseFromSlice(struct {
            items: []struct {
                name: []const u8,
                full_name: []const u8,
                description: ?[]const u8,
                updated_at: []const u8,
                clone_url: []const u8,
            },
        }, self.allocator, response, .{});
        defer parsed.deinit();
        
        var packages = std.ArrayList(Package).init(self.allocator);
        for (parsed.value.items) |item| {
            try packages.append(Package{
                .name = try self.allocator.dupe(u8, item.name),
                .full_name = try self.allocator.dupe(u8, item.full_name),
                .description = if (item.description) |desc| 
                    try self.allocator.dupe(u8, desc) else null,
                .version = try self.allocator.dupe(u8, "latest"),
                .tarball_url = try self.allocator.dupe(u8, item.clone_url),
                .sha256_hash = null,
                .published_at = try self.allocator.dupe(u8, item.updated_at),
                .registry_name = try self.allocator.dupe(u8, self.config.name),
            });
        }
        
        return packages.toOwnedSlice();
    }
    
    fn parseZepplinSearchResults(self: *RegistryClient, response: []const u8) ![]Package {
        const parsed = try std.json.parseFromSlice(struct {
            items: []Package,
        }, self.allocator, response, .{});
        defer parsed.deinit();
        
        // Deep clone packages
        var packages = std.ArrayList(Package).init(self.allocator);
        for (parsed.value.items) |pkg| {
            try packages.append(Package{
                .name = try self.allocator.dupe(u8, pkg.name),
                .full_name = try self.allocator.dupe(u8, pkg.full_name),
                .description = if (pkg.description) |desc| 
                    try self.allocator.dupe(u8, desc) else null,
                .version = try self.allocator.dupe(u8, pkg.version),
                .tarball_url = try self.allocator.dupe(u8, pkg.tarball_url),
                .sha256_hash = if (pkg.sha256_hash) |hash| 
                    try self.allocator.dupe(u8, hash) else null,
                .published_at = try self.allocator.dupe(u8, pkg.published_at),
                .registry_name = try self.allocator.dupe(u8, self.config.name),
            });
        }
        
        return packages.toOwnedSlice();
    }
};
```

---

## 🔄 **Phase 2: Multi-Registry Package Resolution**

### **2.1 Registry Manager**

**File**: `src/registry_manager.zig` (new file)

```zig
const std = @import("std");
const config = @import("config.zig");
const registry = @import("registry.zig");

pub const RegistryManager = struct {
    allocator: std.mem.Allocator,
    config: *config.ZionConfig,
    clients: std.ArrayList(registry.RegistryClient),
    
    pub fn init(allocator: std.mem.Allocator, zion_config: *config.ZionConfig) RegistryManager {
        return RegistryManager{
            .allocator = allocator,
            .config = zion_config,
            .clients = std.ArrayList(registry.RegistryClient).init(allocator),
        };
    }
    
    pub fn initClients(self: *RegistryManager) !void {
        for (self.config.registries.items) |reg_config| {
            if (reg_config.enabled) {
                const client = registry.RegistryClient.init(self.allocator, reg_config);
                try self.clients.append(client);
            }
        }
    }
    
    pub fn deinit(self: *RegistryManager) void {
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit();
    }
    
    /// Resolve package name with registry priority
    pub fn resolvePackage(self: *RegistryManager, package_name: []const u8) !?registry.Package {
        std.log.info("Resolving package: {s}", .{package_name});
        
        for (self.clients.items) |*client| {
            std.log.debug("Trying registry: {s}", .{client.config.name});
            
            // First resolve alias if it's a short name
            const full_name = client.resolveAlias(package_name) catch |err| {
                std.log.warn("Failed to resolve alias in {s}: {}", .{client.config.name, err});
                continue;
            };
            defer if (full_name) |name| self.allocator.free(name);
            
            const resolved_name = full_name orelse package_name;
            
            // Parse owner/repo
            var parts = std.mem.splitScalar(u8, resolved_name, '/');
            const owner = parts.next() orelse continue;
            const repo = parts.next() orelse continue;
            
            // Try to fetch releases
            const releases = client.fetchReleases(owner, repo) catch |err| {
                std.log.debug("Failed to fetch releases from {s}: {}", .{client.config.name, err});
                
                // Fallback to tags
                const tags = client.fetchTags(owner, repo) catch |tag_err| {
                    std.log.debug("Failed to fetch tags from {s}: {}", .{client.config.name, tag_err});
                    continue;
                };
                defer {
                    for (tags) |tag| tag.deinit(self.allocator);
                    self.allocator.free(tags);
                }
                
                if (tags.len > 0) {
                    return try self.convertReleaseToPackage(tags[0], resolved_name, client.config.name);
                }
                continue;
            };
            defer {
                for (releases) |release| release.deinit(self.allocator);
                self.allocator.free(releases);
            }
            
            if (releases.len > 0) {
                return try self.convertReleaseToPackage(releases[0], resolved_name, client.config.name);
            }
        }
        
        std.log.warn("Package not found in any registry: {s}", .{package_name});
        return null;
    }
    
    /// Search packages across all registries
    pub fn searchPackages(self: *RegistryManager, query: []const u8, max_results: usize) ![]registry.Package {
        var all_packages = std.ArrayList(registry.Package).init(self.allocator);
        defer all_packages.deinit();
        
        for (self.clients.items) |*client| {
            const packages = client.searchPackages(query, "zig") catch |err| {
                std.log.warn("Search failed in {s}: {}", .{client.config.name, err});
                continue;
            };
            defer {
                for (packages) |pkg| pkg.deinit(self.allocator);
                self.allocator.free(packages);
            }
            
            for (packages) |pkg| {
                // Clone package for our list
                try all_packages.append(registry.Package{
                    .name = try self.allocator.dupe(u8, pkg.name),
                    .full_name = try self.allocator.dupe(u8, pkg.full_name),
                    .description = if (pkg.description) |desc| 
                        try self.allocator.dupe(u8, desc) else null,
                    .version = try self.allocator.dupe(u8, pkg.version),
                    .tarball_url = try self.allocator.dupe(u8, pkg.tarball_url),
                    .sha256_hash = if (pkg.sha256_hash) |hash| 
                        try self.allocator.dupe(u8, hash) else null,
                    .published_at = try self.allocator.dupe(u8, pkg.published_at),
                    .registry_name = try self.allocator.dupe(u8, pkg.registry_name),
                });
                
                if (all_packages.items.len >= max_results) break;
            }
            
            if (all_packages.items.len >= max_results) break;
        }
        
        return all_packages.toOwnedSlice();
    }
    
    /// Get package download URL with SHA256 verification
    pub fn getPackageDownload(self: *RegistryManager, full_name: []const u8, version: []const u8) !?struct {
        url: []const u8,
        sha256_hash: ?[]const u8,
        registry_name: []const u8,
    } {
        // Parse owner/repo
        var parts = std.mem.splitScalar(u8, full_name, '/');
        const owner = parts.next() orelse return null;
        const repo = parts.next() orelse return null;
        
        for (self.clients.items) |*client| {
            const releases = client.fetchReleases(owner, repo) catch continue;
            defer {
                for (releases) |release| release.deinit(self.allocator);
                self.allocator.free(releases);
            }
            
            // Find matching version
            for (releases) |release| {
                if (std.mem.eql(u8, release.tag_name, version)) {
                    return .{
                        .url = try self.allocator.dupe(u8, release.tarball_url),
                        .sha256_hash = null, // Will be in HTTP headers
                        .registry_name = try self.allocator.dupe(u8, client.config.name),
                    };
                }
            }
        }
        
        return null;
    }
    
    fn convertReleaseToPackage(self: *RegistryManager, release: registry.Release, full_name: []const u8, registry_name: []const u8) !registry.Package {
        var parts = std.mem.splitScalar(u8, full_name, '/');
        const owner = parts.next() orelse return error.InvalidPackageName;
        const name = parts.next() orelse return error.InvalidPackageName;
        
        return registry.Package{
            .name = try self.allocator.dupe(u8, name),
            .full_name = try self.allocator.dupe(u8, full_name),
            .description = null,
            .version = try self.allocator.dupe(u8, release.tag_name),
            .tarball_url = try self.allocator.dupe(u8, release.tarball_url),
            .sha256_hash = null,
            .published_at = try self.allocator.dupe(u8, release.published_at),
            .registry_name = try self.allocator.dupe(u8, registry_name),
        };
    }
};
```

---

## 🎯 **Phase 3: CLI Integration**

### **3.1 Updated CLI Commands**

**File**: `src/commands/add.zig` (modify existing)

```zig
const std = @import("std");
const config = @import("../config.zig");
const registry_manager = @import("../registry_manager.zig");

pub fn addCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zion add <package>");
        return;
    }
    
    const package_name = args[0];
    const version = if (args.len > 1) args[1] else null;
    
    // Load configuration
    var zion_config = config.ZionConfig.init(allocator);
    defer zion_config.deinit();
    try zion_config.loadFromEnvironment();
    
    if (zion_config.registries.items.len == 0) {
        std.log.err("No registries configured. Set ZION_REGISTRY_URL or configure GitHub access.");
        return;
    }
    
    // Initialize registry manager
    var manager = registry_manager.RegistryManager.init(allocator, &zion_config);
    defer manager.deinit();
    try manager.initClients();
    
    std.log.info("Resolving package: {s}", .{package_name});
    
    // Resolve package
    const package = try manager.resolvePackage(package_name);
    if (package == null) {
        std.log.err("Package not found: {s}", .{package_name});
        
        // Suggest similar packages
        std.log.info("Searching for similar packages...");
        const search_results = try manager.searchPackages(package_name, 5);
        defer {
            for (search_results) |pkg| pkg.deinit(allocator);
            allocator.free(search_results);
        }
        
        if (search_results.len > 0) {
            std.log.info("Did you mean:");
            for (search_results) |pkg| {
                std.log.info("  {s} - {s}", .{pkg.full_name, pkg.description orelse "No description"});
            }
        }
        return;
    }
    
    defer package.?.deinit(allocator);
    const pkg = package.?;
    
    std.log.info("Found package: {s} ({s}) from {s}", .{pkg.full_name, pkg.version, pkg.registry_name});
    
    // Add to build.zig.zon dependencies
    try addToBuildZon(allocator, pkg, version);
    
    std.log.info("✅ Added {s} to dependencies", .{pkg.full_name});
}

fn addToBuildZon(allocator: std.mem.Allocator, package: registry.Package, version: ?[]const u8) !void {
    // Read current build.zig.zon
    const file_content = std.fs.cwd().readFileAlloc(allocator, "build.zig.zon", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("build.zig.zon not found. Run 'zion init' first.");
            return;
        },
        else => return err,
    };
    defer allocator.free(file_content);
    
    // Parse and modify (simplified - would need proper Zig AST parsing)
    const target_version = version orelse package.version;
    
    // For now, just append to dependencies section
    std.log.info("Add this to your build.zig.zon dependencies:");
    std.log.info(".{s} = .{{", .{package.name});
    std.log.info("    .url = \"{s}\",", .{package.tarball_url});
    std.log.info("    // .hash = \"...\", // Run `zig build` to get hash");
    std.log.info("}},");
}
```

### **3.2 Enhanced Search Command**

**File**: `src/commands/search.zig` (modify existing)

```zig
const std = @import("std");
const config = @import("../config.zig");
const registry_manager = @import("../registry_manager.zig");

pub fn searchCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zion search <query>");
        return;
    }
    
    const query = args[0];
    const max_results = if (args.len > 1) 
        std.fmt.parseInt(usize, args[1], 10) catch 10 
    else 10;
    
    // Load configuration
    var zion_config = config.ZionConfig.init(allocator);
    defer zion_config.deinit();
    try zion_config.loadFromEnvironment();
    
    // Initialize registry manager
    var manager = registry_manager.RegistryManager.init(allocator, &zion_config);
    defer manager.deinit();
    try manager.initClients();
    
    std.log.info("Searching for: {s}", .{query});
    
    const packages = try manager.searchPackages(query, max_results);
    defer {
        for (packages) |pkg| pkg.deinit(allocator);
        allocator.free(packages);
    }
    
    if (packages.len == 0) {
        std.log.info("No packages found for: {s}", .{query});
        return;
    }
    
    std.log.info("Found {} packages:", .{packages.len});
    std.log.info("");
    
    for (packages) |pkg| {
        std.log.info("📦 {s} (v{s}) [{s}]", .{pkg.full_name, pkg.version, pkg.registry_name});
        if (pkg.description) |desc| {
            std.log.info("   {s}", .{desc});
        }
        std.log.info("   Published: {s}", .{pkg.published_at});
        std.log.info("");
    }
    
    std.log.info("Use 'zion add <package>' to install a package.");
}
```

### **3.3 Registry Status Command**

**File**: `src/commands/registry.zig` (new file)

```zig
const std = @import("std");
const config = @import("../config.zig");
const registry = @import("../registry.zig");

pub fn registryCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        return listRegistries(allocator);
    }
    
    const subcommand = args[0];
    
    if (std.mem.eql(u8, subcommand, "list")) {
        return listRegistries(allocator);
    } else if (std.mem.eql(u8, subcommand, "test")) {
        return testRegistries(allocator);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        if (args.len < 2) {
            std.log.err("Usage: zion registry add <url>");
            return;
        }
        return addRegistry(allocator, args[1]);
    } else {
        std.log.err("Unknown subcommand: {s}", .{subcommand});
        std.log.info("Available commands: list, test, add");
    }
}

fn listRegistries(allocator: std.mem.Allocator) !void {
    var zion_config = config.ZionConfig.init(allocator);
    defer zion_config.deinit();
    try zion_config.loadFromEnvironment();
    
    if (zion_config.registries.items.len == 0) {
        std.log.info("No registries configured.");
        std.log.info("Set ZION_REGISTRY_URL to configure a custom registry.");
        return;
    }
    
    std.log.info("Configured registries (priority order):");
    std.log.info("");
    
    for (zion_config.registries.items, 0..) |reg, i| {
        const status = if (reg.enabled) "✅ enabled" else "❌ disabled";
        std.log.info("{}. {s} - {s} {s}", .{i + 1, reg.name, reg.base_url, status});
        std.log.info("   Priority: {} | API: {s} | Auth: {s}", .{
            reg.priority,
            reg.api_version,
            if (reg.auth_token != null) "configured" else "none"
        });
        std.log.info("");
    }
}

fn testRegistries(allocator: std.mem.Allocator) !void {
    var zion_config = config.ZionConfig.init(allocator);
    defer zion_config.deinit();
    try zion_config.loadFromEnvironment();
    
    std.log.info("Testing registry connections...");
    std.log.info("");
    
    for (zion_config.registries.items) |reg_config| {
        if (!reg_config.enabled) continue;
        
        std.log.info("Testing {s} ({s})...", .{reg_config.name, reg_config.base_url});
        
        var client = registry.RegistryClient.init(allocator, reg_config);
        defer client.deinit();
        
        // Test with a simple search
        const test_packages = client.searchPackages("test", "zig") catch |err| {
            std.log.err("❌ Failed: {}", .{err});
            continue;
        };
        defer {
            for (test_packages) |pkg| pkg.deinit(allocator);
            allocator.free(test_packages);
        }
        
        std.log.info("✅ Success - found {} packages", .{test_packages.len});
        
        // Test alias resolution (if not GitHub)
        if (!std.mem.eql(u8, reg_config.name, "github")) {
            const resolved = client.resolveAlias("test") catch null;
            if (resolved) |full_name| {
                defer allocator.free(full_name);
                std.log.info("   Alias resolution: test -> {s}", .{full_name});
            } else {
                std.log.info("   Alias resolution: not available");
            }
        }
    }
    
    std.log.info("");
    std.log.info("Registry testing complete.");
}

fn addRegistry(allocator: std.mem.Allocator, url: []const u8) !void {
    // This would typically modify a config file
    std.log.info("To add a registry, set environment variables:");
    std.log.info("export ZION_REGISTRY_URL=\"{s}\"", .{url});
    std.log.info("export ZION_REGISTRY_TOKEN=\"your-token\" # if authentication required");
    std.log.info("");
    std.log.info("Or add to ZION_REGISTRIES for multiple registries:");
    std.log.info("export ZION_REGISTRIES=\"{s},https://other-registry.com\"", .{url});
}
```

---

## 🔧 **Phase 4: Environment Variable Configuration**

### **4.1 Environment Variables Reference**

```bash
# Primary registry (highest priority)
export ZION_REGISTRY_URL="https://packages.company.com"
export ZION_REGISTRY_TOKEN="your-api-token"

# Multiple registries (comma-separated, priority order)
export ZION_REGISTRIES="https://packages.company.com,https://backup-registry.com"

# Registry-specific tokens (optional)
export ZION_REGISTRY_TOKEN_COMPANY="token-for-company-registry"
export ZION_REGISTRY_TOKEN_BACKUP="token-for-backup-registry"

# GitHub fallback configuration  
export ZION_GITHUB_USERNAME="your-username"
export ZION_GITHUB_TOKEN="ghp_your-github-token"

# Cache and performance
export ZION_CACHE_DIR="/home/user/.cache/zion"
export ZION_REGISTRY_TIMEOUT="30000"  # milliseconds
export ZION_MAX_CONCURRENT_DOWNLOADS="4"

# Debug and logging
export ZION_LOG_LEVEL="info"  # debug, info, warn, error
export ZION_REGISTRY_DEBUG="true"  # verbose registry operations
```

### **4.2 Configuration Priority Order**

1. **Environment Variables** (highest priority)
2. **Project Config** (`zion.toml` in project root)
3. **User Config** (`~/.config/zion/config.toml`)
4. **System Config** (`/etc/zion/config.toml`)
5. **Built-in Defaults** (GitHub only)

### **4.3 Sample Configuration File**

**File**: `~/.config/zion/config.toml`

```toml
[registries]
# Primary registry
[[registries.list]]
name = "company"
url = "https://packages.company.com"
priority = 0
enabled = true
auth_token = "${COMPANY_REGISTRY_TOKEN}"

# Backup registry
[[registries.list]]  
name = "backup"
url = "https://backup-registry.com"
priority = 1
enabled = true

# GitHub fallback
[[registries.list]]
name = "github"
url = "https://api.github.com"
priority = 999
enabled = true
auth_token = "${GITHUB_TOKEN}"

[defaults]
github_username = "your-username"
cache_dir = "~/.cache/zion"
timeout_ms = 30000

[behavior]
auto_fallback = true
require_signatures = false
update_check_interval = "24h"
```

---

## 🧪 **Phase 5: Testing & Validation**

### **5.1 Integration Test Suite**

**File**: `tests/registry_integration_test.zig`

```zig
const std = @import("std");
const testing = std.testing;
const config = @import("../src/config.zig");
const registry_manager = @import("../src/registry_manager.zig");

test "registry resolution priority" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Mock environment setup
    try std.posix.setenv("ZION_REGISTRY_URL", "https://test-registry.com", 1);
    try std.posix.setenv("ZION_REGISTRIES", "https://backup-registry.com", 1);
    
    var zion_config = config.ZionConfig.init(allocator);
    defer zion_config.deinit();
    try zion_config.loadFromEnvironment();
    
    // Should have: test-registry (0), backup-registry (1), github (999)
    try testing.expect(zion_config.registries.items.len == 3);
    try testing.expectEqualStrings("custom", zion_config.registries.items[0].name);
    try testing.expectEqualStrings("https://test-registry.com", zion_config.registries.items[0].base_url);
    try testing.expect(zion_config.registries.items[0].priority == 0);
}

test "alias resolution flow" {
    // Test that alias resolution works correctly
    // Mock HTTP responses for alias resolution
    // Verify fallback behavior
}

test "package search aggregation" {
    // Test searching across multiple registries
    // Verify deduplication and ranking
    // Test result limits and pagination
}

test "github fallback behavior" {
    // Test that GitHub is used as fallback
    // Verify error handling for unreachable registries
    // Test partial failures
}
```

### **5.2 End-to-End CLI Tests**

**File**: `tests/cli_e2e_test.zig`

```zig
test "zion add with custom registry" {
    // Set up test environment
    try std.posix.setenv("ZION_REGISTRY_URL", "https://mock-registry.test", 1);
    
    // Mock registry responses
    // Run: zion add zcrypto
    // Verify package resolution and build.zig.zon update
}

test "zion search across registries" {
    // Set up multiple test registries
    // Run: zion search crypto
    // Verify results from multiple sources
}

test "zion registry commands" {
    // Test: zion registry list
    // Test: zion registry test  
    // Test: zion registry add
}
```

---

## 📦 **Phase 6: Package Publishing Integration**

### **6.1 Publishing to Custom Registry**

**File**: `src/commands/publish.zig` (new file)

```zig
const std = @import("std");
const config = @import("../config.zig");
const registry = @import("../registry.zig");

pub fn publishCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse arguments
    const registry_name = if (args.len > 0) args[0] else "default";
    
    // Load configuration
    var zion_config = config.ZionConfig.init(allocator);
    defer zion_config.deinit();
    try zion_config.loadFromEnvironment();
    
    // Find target registry
    var target_registry: ?config.RegistryConfig = null;
    for (zion_config.registries.items) |reg| {
        if (std.mem.eql(u8, reg.name, registry_name) or 
            (std.mem.eql(u8, registry_name, "default") and reg.priority == 0)) {
            target_registry = reg;
            break;
        }
    }
    
    if (target_registry == null) {
        std.log.err("Registry not found: {s}", .{registry_name});
        return;
    }
    
    const reg = target_registry.?;
    
    if (reg.auth_token == null) {
        std.log.err("Authentication required for publishing to {s}", .{reg.name});
        std.log.info("Set ZION_REGISTRY_TOKEN or configure authentication.");
        return;
    }
    
    std.log.info("Publishing to registry: {s} ({s})", .{reg.name, reg.base_url});
    
    // Build package tarball
    std.log.info("Building package...");
    try buildPackage(allocator);
    
    // Read package metadata
    const metadata = try readPackageMetadata(allocator);
    defer metadata.deinit();
    
    // Upload package
    var client = registry.RegistryClient.init(allocator, reg);
    defer client.deinit();
    
    try uploadPackage(&client, metadata, "package.tar.gz");
    
    std.log.info("✅ Package published successfully!");
    std.log.info("   Package: {s}/{s}", .{metadata.author, metadata.name});
    std.log.info("   Version: {s}", .{metadata.version});
    std.log.info("   Registry: {s}", .{reg.name});
}

const PackageMetadata = struct {
    name: []const u8,
    version: []const u8,
    author: []const u8,
    description: []const u8,
    license: []const u8,
    
    pub fn deinit(self: PackageMetadata) void {
        // Free allocated strings
    }
};

fn buildPackage(allocator: std.mem.Allocator) !void {
    // Run: zig build
    // Create tarball of src/ and build.zig.zon
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"zig", "build"},
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term != .Exited or result.term.Exited != 0) {
        std.log.err("Build failed:");
        std.log.err("{s}", .{result.stderr});
        return error.BuildFailed;
    }
    
    // Create package tarball
    const tar_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"tar", "-czf", "package.tar.gz", "src/", "build.zig", "build.zig.zon"},
    });
    defer allocator.free(tar_result.stdout);
    defer allocator.free(tar_result.stderr);
    
    if (tar_result.term != .Exited or tar_result.term.Exited != 0) {
        return error.TarFailed;
    }
    
    std.log.info("Package built: package.tar.gz");
}

fn readPackageMetadata(allocator: std.mem.Allocator) !PackageMetadata {
    // Parse build.zig.zon for metadata
    const content = try std.fs.cwd().readFileAlloc(allocator, "build.zig.zon", 1024 * 1024);
    defer allocator.free(content);
    
    // Simple parsing - would need proper Zig AST parsing in real implementation
    return PackageMetadata{
        .name = try allocator.dupe(u8, "example"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .author = try allocator.dupe(u8, "user"),
        .description = try allocator.dupe(u8, "Example package"),
        .license = try allocator.dupe(u8, "MIT"),
    };
}

fn uploadPackage(client: *registry.RegistryClient, metadata: PackageMetadata, tarball_path: []const u8) !void {
    // Read tarball
    const tarball_data = try std.fs.cwd().readFileAlloc(client.allocator, tarball_path, 50 * 1024 * 1024); // 50MB max
    defer client.allocator.free(tarball_data);
    
    // Prepare multipart form data
    const boundary = "----ZionPackageUpload";
    
    const metadata_json = try std.json.stringifyAlloc(client.allocator, metadata, .{});
    defer client.allocator.free(metadata_json);
    
    const form_data = try std.fmt.allocPrint(client.allocator,
        "--{s}\r\n" ++
        "Content-Disposition: form-data; name=\"metadata\"\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n" ++
        "{s}\r\n" ++
        "--{s}\r\n" ++
        "Content-Disposition: form-data; name=\"package\"; filename=\"package.tar.gz\"\r\n" ++
        "Content-Type: application/gzip\r\n" ++
        "\r\n" ++
        "{s}\r\n" ++
        "--{s}--\r\n",
        .{ boundary, metadata_json, boundary, tarball_data, boundary }
    );
    defer client.allocator.free(form_data);
    
    // Upload via POST /api/v1/packages
    const api_url = try client.config.getApiUrl(client.allocator);
    defer client.allocator.free(api_url);
    
    const upload_url = try std.fmt.allocPrint(client.allocator, "{s}/packages", .{api_url});
    defer client.allocator.free(upload_url);
    
    const response = try client.makeRequest("POST", upload_url, form_data);
    defer client.allocator.free(response);
    
    std.log.info("Upload response: {s}", .{response});
}
```

---

## 🎯 **Success Criteria & Validation**

### **Integration Test Commands**

These commands should work seamlessly with both Zepplin and GitHub:

```bash
# Configure Zion to use Zepplin
export ZION_REGISTRY_URL="https://packages.example.com"
export ZION_REGISTRY_TOKEN="your-api-token"

# Test package resolution
zion add zcrypto                    # Should resolve via Zepplin alias
zion add cktech/zquic              # Should find in Zepplin first, fallback to GitHub
zion add nonexistent/package       # Should fallback to GitHub, then fail gracefully

# Test search
zion search crypto                 # Should aggregate results from Zepplin + GitHub
zion search --registry=github zig  # Should search only GitHub

# Test registry management
zion registry list                 # Show configured registries
zion registry test                 # Test connectivity to all registries

# Test publishing
zion publish                       # Publish to primary registry
zion publish --registry=github     # Publish to specific registry
```

### **Performance Requirements**

- **Package Resolution**: < 500ms for first lookup, < 100ms for cached
- **Search Results**: < 1s for multi-registry search
- **Download Speed**: > 5MB/s for package downloads
- **Fallback Time**: < 2s to detect registry failure and fallback

### **Compatibility Requirements**

- **Existing Projects**: Zero changes required for pure GitHub usage
- **Environment Override**: `ZION_REGISTRY_URL` immediately redirects all operations
- **Mixed Resolution**: Can resolve some packages from Zepplin, others from GitHub
- **Error Handling**: Graceful degradation when registries are unavailable

---

## 🔄 **Implementation Timeline**

| Phase | Duration | Dependencies | Deliverables |
|-------|----------|--------------|-------------|
| **Phase 1**: Core Abstraction | 1 week | None | Registry config, client abstraction |
| **Phase 2**: Multi-Registry | 1 week | Phase 1 | Registry manager, resolution priority |  
| **Phase 3**: CLI Integration | 1 week | Phase 2 | Updated add/search/registry commands |
| **Phase 4**: Environment Config | 3 days | Phase 3 | Environment variable support |
| **Phase 5**: Testing | 1 week | Phase 4 | Integration tests, CLI validation |
| **Phase 6**: Publishing | 1 week | Phase 5 | Package upload support |

**Total Timeline**: ~6 weeks for full integration  
**MVP Timeline**: ~3 weeks for basic registry support  

---

## 🚦 **Risk Mitigation**

### **Breaking Changes Prevention**
- Maintain backward compatibility with existing `zion` commands
- GitHub remains default if no registry configured
- Gradual rollout with feature flags

### **Network Reliability**
- Implement proper timeouts and retries
- Graceful fallback between registries
- Offline mode for cached packages

### **Authentication Security**
- Secure token storage and transmission
- Support for multiple authentication methods
- Token refresh and validation

### **Performance Optimization**
- Package metadata caching
- Parallel registry queries where possible
- Connection pooling and keep-alive

---

This integration guide provides Zion with the flexibility to work with Zepplin while maintaining full compatibility with existing GitHub-based workflows. The phased approach ensures minimal disruption while adding powerful new capabilities for private and custom package registries.
