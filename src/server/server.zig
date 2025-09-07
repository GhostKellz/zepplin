const std = @import("std");
const types = @import("../common/types.zig");
const Database = @import("../database/database.zig").Database;
const Auth = @import("../auth/auth.zig").Auth;
const Storage = @import("../storage/storage.zig").Storage;
const ZigistryClient = @import("../zigistry/client.zig").ZigistryClient;
const ZiglibsImporter = @import("../tools/ziglibs_import.zig").ZiglibsImporter;

const ZEPPLIN_VERSION = "0.5.0";

const RouteHandler = *const fn (self: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) anyerror!void;
const StaticHandler = *const fn (self: *Server, stream: std.net.Stream, path: []const u8) anyerror!void;
const PrefixRoute = struct { prefix: []const u8, handler: RouteHandler };

const ServerError = error{
    BindFailed,
    InvalidRequest,
    PackageNotFound,
    AuthenticationRequired,
    InternalError,
};

const AuthenticatedUser = struct {
    username: []u8,
    user_id: i64,
    email: []u8,
    display_name: []u8,
    avatar_url: []u8,
    provider: []u8,
};

// Response cache entry
const CacheEntry = struct {
    content: []u8,
    content_type: []const u8,
    timestamp: i64,
    ttl: i64,
    access_count: u32,
    last_accessed: i64,
    
    pub fn isExpired(self: CacheEntry) bool {
        return std.time.timestamp() > self.timestamp + self.ttl;
    }
    
    pub fn touch(self: *CacheEntry) void {
        self.access_count += 1;
        self.last_accessed = std.time.timestamp();
    }
};

// LRU Cache for advanced caching
const LRUCache = struct {
    const Node = struct {
        key: []const u8,
        value: CacheEntry,
        prev: ?*Node,
        next: ?*Node,
    };
    
    allocator: std.mem.Allocator,
    capacity: usize,
    size: usize,
    head: ?*Node,
    tail: ?*Node,
    map: std.HashMap([]const u8, *Node, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: std.mem.Allocator, capacity: usize) LRUCache {
        return LRUCache{
            .allocator = allocator,
            .capacity = capacity,
            .size = 0,
            .head = null,
            .tail = null,
            .map = std.HashMap([]const u8, *Node, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *LRUCache) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.allocator.free(node.key);
            self.allocator.free(node.value.content);
            self.allocator.destroy(node);
            current = next;
        }
        self.map.deinit();
    }
    
    pub fn get(self: *LRUCache, key: []const u8) ?*CacheEntry {
        if (self.map.get(key)) |node| {
            // Move to front (most recently used)
            self.moveToFront(node);
            node.value.touch();
            return &node.value;
        }
        return null;
    }
    
    pub fn put(self: *LRUCache, key: []const u8, value: CacheEntry) !void {
        if (self.map.get(key)) |node| {
            // Update existing
            self.allocator.free(node.value.content);
            node.value = value;
            node.value.touch();
            self.moveToFront(node);
            return;
        }
        
        // Create new node
        const node = try self.allocator.create(Node);
        node.key = try self.allocator.dupe(u8, key);
        node.value = value;
        node.value.touch();
        node.prev = null;
        node.next = self.head;
        
        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;
        
        if (self.tail == null) {
            self.tail = node;
        }
        
        try self.map.put(node.key, node);
        self.size += 1;
        
        // Evict if over capacity
        if (self.size > self.capacity) {
            self.evictLRU();
        }
    }
    
    fn moveToFront(self: *LRUCache, node: *Node) void {
        if (node == self.head) return;
        
        // Remove from current position
        if (node.prev) |prev| {
            prev.next = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        }
        if (node == self.tail) {
            self.tail = node.prev;
        }
        
        // Move to front
        node.prev = null;
        node.next = self.head;
        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;
    }
    
    fn evictLRU(self: *LRUCache) void {
        if (self.tail) |tail| {
            _ = self.map.remove(tail.key);
            
            if (tail.prev) |prev| {
                prev.next = null;
                self.tail = prev;
            } else {
                self.head = null;
                self.tail = null;
            }
            
            self.allocator.free(tail.key);
            self.allocator.free(tail.value.content);
            self.allocator.destroy(tail);
            self.size -= 1;
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    database: Database,
    auth: Auth,
    storage: Storage,
    zigistry: ZigistryClient,
    
    // Route optimization
    exact_routes: std.HashMap([]const u8, RouteHandler, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    prefix_routes: std.array_list.AlignedManaged(PrefixRoute, null),
    static_routes: std.HashMap([]const u8, StaticHandler, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    // Response caching
    response_cache: std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    file_cache: LRUCache,

    pub fn init(allocator: std.mem.Allocator, port: u16, data_dir: []const u8) !Server {
        // Load configuration from environment variables
        const bind_address = std.process.getEnvVarOwned(allocator, "ZEPPLIN_BIND_ADDRESS") catch 
            try allocator.dupe(u8, "0.0.0.0");
        defer allocator.free(bind_address);

        const actual_port = blk: {
            if (std.process.getEnvVarOwned(allocator, "ZEPPLIN_PORT")) |port_str| {
                defer allocator.free(port_str);
                break :blk std.fmt.parseInt(u16, port_str, 10) catch port;
            } else |_| {
                break :blk port;
            }
        };

        const address = try std.net.Address.resolveIp(bind_address, actual_port);

        // Initialize database
        const db_path = blk: {
            if (std.process.getEnvVarOwned(allocator, "ZEPPLIN_DB_PATH")) |path| {
                std.debug.print("🗄️  Using database path from environment: {s}\n", .{path});
                break :blk path;
            } else |_| {
                break :blk try std.fs.path.join(allocator, &.{ data_dir, "zepplin.db" });
            }
        };
        defer allocator.free(db_path);
        const database = try Database.init(allocator, db_path);

        // Initialize auth with secret key from environment or generate default
        const secret_key = blk: {
            if (std.process.getEnvVarOwned(allocator, "ZEPPLIN_SECRET_KEY")) |key| {
                if (key.len < 32) {
                    std.debug.print("⚠️  Secret key too short (minimum 32 characters)\n", .{});
                    allocator.free(key);
                    break :blk try allocator.dupe(u8, "default-insecure-key-change-in-production");
                }
                std.debug.print("🔑 Using secret key from environment\n", .{});
                break :blk key;
            } else |_| {
                std.debug.print("⚠️  No ZEPPLIN_SECRET_KEY found, using default (INSECURE for production!)\n", .{});
                break :blk try allocator.dupe(u8, "default-insecure-key-change-in-production-min32chars");
            }
        };
        defer allocator.free(secret_key);
        const auth = Auth.init(allocator, secret_key);

        // Initialize storage with configurable path
        const storage_dir = blk: {
            if (std.process.getEnvVarOwned(allocator, "ZEPPLIN_STORAGE_PATH")) |path| {
                std.debug.print("📦 Using storage path from environment: {s}\n", .{path});
                break :blk path;
            } else |_| {
                break :blk try allocator.dupe(u8, data_dir);
            }
        };
        defer allocator.free(storage_dir);
        const storage = try Storage.init(allocator, storage_dir);

        // Initialize Zigistry client with configurable URL
        const zigistry_url = std.process.getEnvVarOwned(allocator, "ZEPPLIN_ZIGISTRY_URL") catch null;
        defer if (zigistry_url) |url| allocator.free(url);
        const zigistry = ZigistryClient.init(allocator, zigistry_url);

        var server = Server{
            .allocator = allocator,
            .address = address,
            .database = database,
            .auth = auth,
            .storage = storage,
            .zigistry = zigistry,
            .exact_routes = std.HashMap([]const u8, RouteHandler, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .prefix_routes = std.array_list.AlignedManaged(PrefixRoute, null).init(allocator),
            .static_routes = std.HashMap([]const u8, StaticHandler, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .response_cache = std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .file_cache = LRUCache.init(allocator, 100), // Cache up to 100 files
        };
        
        // Initialize route tables
        try server.initRoutes();
        
        return server;
    }

    pub fn deinit(self: *Server) void {
        // Clean up cache entries
        self.cleanupCache(&self.response_cache);
        
        self.exact_routes.deinit();
        self.prefix_routes.deinit();
        self.static_routes.deinit();
        self.response_cache.deinit();
        self.file_cache.deinit();
        self.database.deinit();
        self.storage.deinit();
    }

    // Ziglibs integration method
    pub fn syncZiglibs(self: *Server) !u32 {
        std.log.info("🔄 Starting Ziglibs sync...", .{});
        
        var importer = ZiglibsImporter.init(self.allocator);
        defer importer.deinit();
        
        const imported_count = try importer.importPackages(&self.database);
        
        std.log.info("✅ Ziglibs sync completed: {} packages imported", .{imported_count});
        return imported_count;
    }
    
    fn cleanupCache(self: *Server, cache: *std.HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) void {
        var iterator = cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.content);
        }
    }
    
    fn initRoutes(self: *Server) !void {
        // Exact route matches
        try self.exact_routes.put("/", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request; _ = request_allocator;
                try server.serveStaticFile(stream, "web/templates/index.html");
            }
        }.handler);
        
        try self.exact_routes.put("/health", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request; _ = request_allocator;
                try server.handleHealthSimple(stream);
            }
        }.handler);
        
        try self.exact_routes.put("/docs", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request; _ = request_allocator;
                try server.serveStaticFile(stream, "web/docs.html");
            }
        }.handler);
        
        try self.exact_routes.put("/api/v1/registry/config", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request; _ = request_allocator;
                try server.handleRegistryConfigV1(stream);
            }
        }.handler);
        
        try self.exact_routes.put("/api/v1/health", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request; _ = request_allocator;
                try server.handleHealthV1(stream);
            }
        }.handler);
        
        try self.exact_routes.put("/api/v1/stats", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request; _ = request_allocator;
                try server.handleStatsApi(stream);
            }
        }.handler);
        
        try self.exact_routes.put("/api/v1/auth/me", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = path; _ = request_allocator;
                try server.handleUserProfile(stream, request);
            }
        }.handler);
        
        // Prefix route matches
        try self.prefix_routes.append(.{ .prefix = "/api/v1/packages/", .handler = struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = request; _ = request_allocator;
                try server.handlePackageApiV1(stream, path);
            }
        }.handler });
        
        try self.prefix_routes.append(.{ .prefix = "/api/v1/search", .handler = struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = request; _ = request_allocator;
                try server.handleSearchApiV1(stream, path);
            }
        }.handler });
        
        try self.prefix_routes.append(.{ .prefix = "/api/v1/resolve/", .handler = struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = request; _ = request_allocator;
                try server.handleResolveApiV1(stream, path);
            }
        }.handler });
        
        try self.prefix_routes.append(.{ .prefix = "/api/v1/comments/", .handler = struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                try server.handleCommentsApiV1(stream, path, request, request_allocator);
            }
        }.handler });
        
        try self.prefix_routes.append(.{ .prefix = "/packages/", .handler = struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
                _ = request; _ = request_allocator;
                try server.handlePackagePage(stream, path);
            }
        }.handler });
        
        // Static file routes
        try self.static_routes.put("/css/", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8) !void {
                const file_path = try std.fmt.allocPrint(server.allocator, "web{s}", .{path});
                defer server.allocator.free(file_path);
                try server.serveStaticFile(stream, file_path);
            }
        }.handler);
        
        try self.static_routes.put("/js/", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8) !void {
                const file_path = try std.fmt.allocPrint(server.allocator, "web{s}", .{path});
                defer server.allocator.free(file_path);
                try server.serveStaticFile(stream, file_path);
            }
        }.handler);
        
        try self.static_routes.put("/images/", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8) !void {
                const file_path = try std.fmt.allocPrint(server.allocator, "web{s}", .{path});
                defer server.allocator.free(file_path);
                try server.serveStaticFile(stream, file_path);
            }
        }.handler);
        
        try self.static_routes.put("/assets/", struct {
            fn handler(server: *Server, stream: std.net.Stream, path: []const u8) !void {
                const file_path = try std.fmt.allocPrint(server.allocator, "assets{s}", .{path[7..]});
                defer server.allocator.free(file_path);
                try server.serveStaticFile(stream, file_path);
            }
        }.handler);
    }

    pub fn start(self: *Server) !void {
        var server = try self.address.listen(.{ .reuse_address = true });
        defer server.deinit();

        std.debug.print("🚀 Zepplin Registry Server starting on http://localhost:{}\n", .{self.address.getPort()});
        std.debug.print("📦 Ready to serve packages!\n", .{});
        std.debug.print("🔧 Configuration loaded from environment variables (if set)\n", .{});
        std.debug.print("⚠️  Using default secret key - set ZEPPLIN_SECRET_KEY for production!\n", .{});

        while (true) {
            const connection = server.accept() catch |err| {
                std.debug.print("❌ Failed to accept connection: {}\n", .{err});
                continue;
            };

            // Handle connection in a separate thread (simplified for prototype)
            self.handleConnection(connection) catch |err| {
                std.debug.print("❌ Error handling connection: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        // Use arena allocator for request-scoped allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const request_allocator = arena.allocator();

        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);
        const request = buffer[0..bytes_read];

        // Parse HTTP request (simplified)
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.next() orelse return ServerError.InvalidRequest;

        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method = parts.next() orelse return ServerError.InvalidRequest;
        const path = parts.next() orelse return ServerError.InvalidRequest;

        try self.routeRequest(connection.stream, method, path, request, request_allocator);
    }

    fn routeRequest(self: *Server, stream: std.net.Stream, method: []const u8, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
        std.debug.print("📡 {s} {s}\n", .{ method, path });

        if (std.mem.eql(u8, method, "GET")) {
            // Try exact route match first (O(1) lookup)
            if (self.exact_routes.get(path)) |handler| {
                try handler(self, stream, path, request, request_allocator);
                return;
            }
            
            // Try prefix routes (O(n) but small n)
            for (self.prefix_routes.items) |route| {
                if (std.mem.startsWith(u8, path, route.prefix)) {
                    try route.handler(self, stream, path, request, request_allocator);
                    return;
                }
            }
            
            // Try static file routes
            var static_iterator = self.static_routes.iterator();
            while (static_iterator.next()) |entry| {
                if (std.mem.startsWith(u8, path, entry.key_ptr.*)) {
                    const handler = entry.value_ptr.*;
                    try handler(self, stream, path);
                    return;
                }
            }
            
            // Legacy API endpoints (backward compatibility)
            if (std.mem.startsWith(u8, path, "/api/packages")) {
                // Check for build.zig.zon endpoints first
                if (std.mem.indexOf(u8, path, "/zon") != null) {
                    try self.handlePackageZon(stream, path);
                } else if (std.mem.indexOf(u8, path, "/tarball/") != null) {
                    try self.handlePackageTarball(stream, path);
                } else if (std.mem.indexOf(u8, path, "/hash/") != null) {
                    try self.handlePackageHash(stream, path);
                } else {
                    try self.handlePackageApi(stream, path);
                }
            } else if (std.mem.startsWith(u8, path, "/api/resolve")) {
                try self.handleDependencyResolve(stream, path, request);
            } else if (std.mem.startsWith(u8, path, "/api/search")) {
                try self.handleSearchApi(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/zigistry/discover")) {
                try self.handleZigistryDiscover(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/zigistry/trending")) {
                try self.handleZigistryTrending(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/zigistry/browse")) {
                try self.handleZigistryBrowse(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/ziglibs/packages")) {
                try self.handleZiglibsPackages(stream, path);
            } else if (std.mem.eql(u8, path, "/api/v1/auth/oidc/microsoft/login")) {
                try self.handleMicrosoftLogin(stream);
            } else if (std.mem.startsWith(u8, path, "/api/v1/auth/oidc/microsoft/callback")) {
                try self.handleMicrosoftCallback(stream, path, request);
            } else if (std.mem.eql(u8, path, "/api/v1/auth/oauth/github/login")) {
                try self.handleGitHubLogin(stream);
            } else if (std.mem.startsWith(u8, path, "/api/v1/auth/oauth/github/callback")) {
                try self.handleGitHubCallback(stream, path, request);
            } else if (std.mem.endsWith(u8, path, ".wasm")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "web{s}", .{path});
                defer self.allocator.free(file_path);
                try self.serveStaticFile(stream, file_path);
            } else if (std.mem.eql(u8, path, "/auth")) {
                // Auth test page
                try self.serveStaticFile(stream, "web/auth.html");
            } else if (std.mem.eql(u8, path, "/publish")) {
                // Package publishing page
                try self.serveStaticFile(stream, "web/publish.html");
            } else if (std.mem.startsWith(u8, path, "/packages") or 
                      std.mem.startsWith(u8, path, "/search") or 
                      std.mem.startsWith(u8, path, "/trending") or 
                      std.mem.startsWith(u8, path, "/docs") or
                      std.mem.startsWith(u8, path, "/login")) {
                // SPA routes - serve index.html
                try self.serveStaticFile(stream, "web/templates/index.html");
            } else {
                try self.serve404(stream);
            }
        } else if (std.mem.eql(u8, method, "POST")) {
            if (std.mem.eql(u8, path, "/api/v1/auth/register")) {
                try self.handleRegister(stream);
            } else if (std.mem.eql(u8, path, "/api/v1/auth/login")) {
                try self.handleLogin(stream);
            } else if (std.mem.eql(u8, path, "/api/v1/auth/logout")) {
                try self.handleLogout(stream, request);
            } else if (std.mem.startsWith(u8, path, "/api/v1/packages/")) {
                try self.handlePublishPackageV1(stream, path);
            } else if (std.mem.eql(u8, path, "/api/packages")) {
                try self.handlePublishPackage(stream);
            } else if (std.mem.eql(u8, path, "/api/ziglibs/sync")) {
                try self.handleZiglibsSync(stream, request);
            } else {
                try self.serve404(stream);
            }
        } else if (std.mem.eql(u8, method, "PUT")) {
            if (std.mem.startsWith(u8, path, "/api/v1/aliases/")) {
                try self.handleCreateAliasV1(stream, path);
            } else {
                try self.serve404(stream);
            }
        } else if (std.mem.eql(u8, method, "DELETE")) {
            if (std.mem.startsWith(u8, path, "/api/v1/packages/")) {
                try self.handleDeletePackageV1(stream, path);
            } else {
                try self.serve404(stream);
            }
        } else {
            try self.serveMethodNotAllowed(stream);
        }
    }

    fn serveStaticFile(self: *Server, stream: std.net.Stream, file_path: []const u8) !void {
        // Check LRU cache first
        if (self.file_cache.get(file_path)) |entry| {
            if (!entry.isExpired()) {
                const response = try std.fmt.allocPrint(self.allocator, 
                    "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: public, max-age=3600\r\n\r\n", 
                    .{ entry.content_type, entry.content.len }
                );
                defer self.allocator.free(response);
                
                try stream.writeAll(response);
                try stream.writeAll(entry.content);
                return;
            }
        }
        
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("❌ Failed to open file {s}: {}\n", .{ file_path, err });
            try self.serve404(stream);
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        
        // Stream large files in chunks to reduce memory usage
        const max_size_for_full_load = 64 * 1024; // 64KB threshold
        const max_cache_size = 32 * 1024; // 32KB cache limit
        
        if (file_size > max_size_for_full_load) {
            try self.serveFileStreaming(stream, file, file_size, file_path);
        } else {
            try self.serveFileInMemory(stream, file, file_size, file_path, file_size <= max_cache_size);
        }
    }

    fn serveFileInMemory(self: *Server, stream: std.net.Stream, file: std.fs.File, file_size: u64, file_path: []const u8, should_cache: bool) !void {
        const content = try self.allocator.alloc(u8, file_size);
        _ = try file.read(content);
        
        if (should_cache) {
            // Cache the file content
            const cached_content = try self.allocator.dupe(u8, content);
            const cached_path = try self.allocator.dupe(u8, file_path);
            const content_type = self.getContentType(file_path);
            
            const cache_entry = CacheEntry{
                .content = cached_content,
                .content_type = content_type,
                .timestamp = std.time.timestamp(),
                .ttl = 3600, // 1 hour TTL
                .access_count = 0,
                .last_accessed = std.time.timestamp(),
            };
            
            try self.file_cache.put(cached_path, cache_entry);
        }
        
        try self.sendFileResponse(stream, content, file_path);
        
        if (!should_cache) {
            self.allocator.free(content);
        }
    }

    fn serveFileStreaming(self: *Server, stream: std.net.Stream, file: std.fs.File, file_size: u64, file_path: []const u8) !void {
        // Send headers first
        try self.sendFileHeaders(stream, file_size, file_path);
        
        // Stream file content in chunks
        const chunk_size = 8192; // 8KB chunks
        var buffer: [chunk_size]u8 = undefined;
        var bytes_remaining = file_size;
        
        while (bytes_remaining > 0) {
            const to_read = @min(bytes_remaining, chunk_size);
            const bytes_read = try file.read(buffer[0..to_read]);
            if (bytes_read == 0) break;
            
            try stream.writeAll(buffer[0..bytes_read]);
            bytes_remaining -= bytes_read;
        }
    }

    fn sendFileHeaders(self: *Server, stream: std.net.Stream, file_size: u64, file_path: []const u8) !void {
        const content_type = self.getContentType(file_path);
        
        const response = try std.fmt.allocPrint(self.allocator, 
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: public, max-age=3600\r\n\r\n", 
            .{ content_type, file_size }
        );
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn sendFileResponse(self: *Server, stream: std.net.Stream, content: []const u8, file_path: []const u8) !void {
        const content_type = self.getContentType(file_path);
        
        const response = try std.fmt.allocPrint(self.allocator, 
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: public, max-age=3600\r\n\r\n", 
            .{ content_type, content.len }
        );
        defer self.allocator.free(response);

        try stream.writeAll(response);
        try stream.writeAll(content);
    }

    fn getContentType(self: *Server, file_path: []const u8) []const u8 {
        _ = self;
        
        return if (std.mem.endsWith(u8, file_path, ".html"))
            "text/html"
        else if (std.mem.endsWith(u8, file_path, ".css"))
            "text/css"
        else if (std.mem.endsWith(u8, file_path, ".js"))
            "application/javascript"
        else if (std.mem.endsWith(u8, file_path, ".wasm"))
            "application/wasm"
        else if (std.mem.endsWith(u8, file_path, ".svg"))
            "image/svg+xml"
        else if (std.mem.endsWith(u8, file_path, ".png"))
            "image/png"
        else if (std.mem.endsWith(u8, file_path, ".jpg") or std.mem.endsWith(u8, file_path, ".jpeg"))
            "image/jpeg"
        else if (std.mem.endsWith(u8, file_path, ".ico"))
            "image/x-icon"
        else
            "application/octet-stream";
    }

    fn serveWebUI(self: *Server, stream: std.net.Stream) !void {
        // Get real statistics from database
        const stats = try self.database.getDownloadStats();

        const html_content = try std.fmt.allocPrint(self.allocator,
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\    <meta charset="UTF-8">
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <title>Zepplin Registry</title>
            \\    <style>
            \\        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
            \\        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f1419; color: #e6e1dc; }}
            \\        .container {{ max-width: 1200px; margin: 0 auto; padding: 2rem; }}
            \\        .header {{ text-align: center; margin-bottom: 3rem; }}
            \\        .header h1 {{ font-size: 3rem; color: #f7931e; margin-bottom: 1rem; }}
            \\        .header p {{ font-size: 1.2rem; color: #b8b4a3; }}
            \\        .search-box {{ background: #1e2328; border: 2px solid #39414a; border-radius: 8px; padding: 1rem; margin-bottom: 2rem; }}
            \\        .search-box input {{ width: 100%; background: none; border: none; color: #e6e1dc; font-size: 1.1rem; outline: none; }}
            \\        .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }}
            \\        .stat-card {{ background: #1e2328; padding: 1.5rem; border-radius: 8px; text-align: center; }}
            \\        .stat-card h3 {{ color: #f7931e; font-size: 2rem; margin-bottom: 0.5rem; }}
            \\        .packages {{ background: #1e2328; border-radius: 8px; padding: 1.5rem; }}
            \\        .package-item {{ border-bottom: 1px solid #39414a; padding: 1rem 0; }}
            \\        .package-item:last-child {{ border-bottom: none; }}
            \\        .package-name {{ color: #f7931e; font-size: 1.1rem; font-weight: bold; }}
            \\        .package-version {{ color: #36c692; margin-left: 0.5rem; }}
            \\        .package-desc {{ color: #b8b4a3; margin-top: 0.5rem; }}
            \\        .footer {{ text-align: center; margin-top: 3rem; color: #b8b4a3; }}
            \\        .search-results {{ display: none; background: #1e2328; border-radius: 8px; padding: 1rem; margin-top: 1rem; }}
            \\        .tabs {{ display: flex; gap: 1rem; margin: 2rem 0 1rem 0; }}
            \\        .tab {{ padding: 0.8rem 1.5rem; background: #1e2328; color: #b8b4a3; border: none; border-radius: 8px; cursor: pointer; transition: all 0.3s; }}
            \\        .tab.active {{ background: #f7931e; color: #1a1d23; font-weight: bold; }}
            \\        .tab:hover {{ background: #36c692; color: #1a1d23; }}
            \\        .tab-content {{ display: none; }}
            \\        .tab-content.active {{ display: block; }}
            \\        .zigistry-search {{ margin-bottom: 1rem; }}
            \\        .zigistry-search input {{ width: 100%; padding: 1rem; background: #1e2328; border: 1px solid #36c692; border-radius: 8px; color: #e8e6e3; font-size: 1rem; }}
            \\        .zigistry-results {{ margin-top: 1rem; }}
            \\        .discover-section {{ margin: 1rem 0; }}
            \\        .trending-btn, .browse-btn {{ padding: 0.6rem 1.2rem; background: #36c692; color: #1a1d23; border: none; border-radius: 6px; cursor: pointer; margin-right: 0.5rem; margin-bottom: 0.5rem; font-weight: bold; }}
            \\        .trending-btn:hover, .browse-btn:hover {{ background: #f7931e; }}
            \\    </style>
            \\</head>
            \\<body>
            \\    <div class="container">
            \\        <div class="header">
            \\            <h1>⚡ Zepplin Registry</h1>
            \\            <p>Blazing-fast package registry for the Zig ecosystem</p>
            \\        </div>
            \\        
            \\        <div class="stats">
            \\            <div class="stat-card">
            \\                <h3>{}</h3>
            \\                <p>Total Packages</p>
            \\            </div>
            \\            <div class="stat-card">
            \\                <h3>{}</h3>
            \\                <p>Downloads Today</p>
            \\            </div>
            \\            <div class="stat-card">
            \\                <h3>{}</h3>
            \\                <p>Total Downloads</p>
            \\            </div>
            \\        </div>
            \\        
            \\        <div class="tabs">
            \\            <button class="tab active" onclick="switchTab('local')">🏠 Local Packages</button>
            \\            <button class="tab" onclick="switchTab('discover')">🔍 Discover Packages</button>
            \\        </div>
            \\        
            \\        <div id="local-tab" class="tab-content active">
            \\        <div class="search-box">
            \\            <input type="text" placeholder="🔍 Search packages..." id="searchInput">
            \\        </div>
            \\        
            \\        <div class="search-results" id="searchResults"></div>
            \\        
            \\        <div class="packages" id="packagesList">
            \\            <h2 style="margin-bottom: 1rem; color: #f7931e;">📦 Recent Packages</h2>
            \\            <div style="text-align: center; color: #b8b4a3; padding: 2rem;">
            \\                Loading packages...
            \\            </div>
            \\        </div>
            \\        </div>
            \\        
            \\        <div id="discover-tab" class="tab-content">
            \\            <div class="discover-section">
            \\                <h2 style="color: #f7931e; margin-bottom: 1rem;">🌟 Quick Actions</h2>
            \\                <button class="trending-btn" onclick="loadTrending()">🔥 Show Trending</button>
            \\                <button class="browse-btn" onclick="loadCategory('web')">🌐 Web Frameworks</button>
            \\                <button class="browse-btn" onclick="loadCategory('cli')">⚡ CLI Tools</button>
            \\                <button class="browse-btn" onclick="loadCategory('gamedev')">🎮 Game Dev</button>
            \\            </div>
            \\            
            \\            <div class="zigistry-search">
            \\                <input type="text" placeholder="🔍 Discover packages from Zigistry..." id="zigistrySearchInput">
            \\            </div>
            \\            
            \\            <div class="zigistry-results" id="zigistryResults">
            \\                <h2 style="color: #f7931e; margin-bottom: 1rem;">🚀 Discover Zig Packages</h2>
            \\                <p style="color: #b8b4a3;">Search for packages or use the quick actions above to explore the Zig ecosystem!</p>
            \\            </div>
            \\        </div>
            \\        
            \\        <div class="footer">
            \\            <p>Made with Zig ⚡ | Powered by SQLite 🗄️ | Built for hackers 🛠️</p>
            \\        </div>
            \\    </div>
            \\    
            \\    <script>
            \\        // Load packages on page load
            \\        fetch('/api/packages')
            \\            .then(response => response.json())
            \\            .then(data => {{
            \\                const packagesList = document.getElementById('packagesList');
            \\                if (data.packages && data.packages.length > 0) {{
            \\                    let html = '<h2 style="margin-bottom: 1rem; color: #f7931e;">📦 Recent Packages</h2>';
            \\                    data.packages.forEach(pkg => {{
            \\                        html += `
            \\                            <div class="package-item">
            \\                                <div>
            \\                                    <span class="package-name">${{pkg.name}}</span>
            \\                                    <span class="package-version">v${{pkg.version}}</span>
            \\                                </div>
            \\                                <div class="package-desc">${{pkg.description || 'No description'}}</div>
            \\                            </div>
            \\                        `;
            \\                    }});
            \\                    packagesList.innerHTML = html;
            \\                }} else {{
            \\                    packagesList.innerHTML = '<h2 style="margin-bottom: 1rem; color: #f7931e;">📦 Packages</h2><div style="text-align: center; color: #b8b4a3; padding: 2rem;">No packages yet. Publish your first package!</div>';
            \\                }}
            \\            }})
            \\            .catch(err => console.error('Failed to load packages:', err));
            \\        
            \\        // Search functionality
            \\        const searchInput = document.getElementById('searchInput');
            \\        const searchResults = document.getElementById('searchResults');
            \\        
            \\        searchInput.addEventListener('input', function(e) {{
            \\            const query = e.target.value.trim();
            \\            if (query.length > 0) {{
            \\                fetch(`/api/search?q=${{encodeURIComponent(query)}}`)
            \\                    .then(response => response.json())
            \\                    .then(data => {{
            \\                        if (data.results && data.results.length > 0) {{
            \\                            let html = `<h3 style="color: #f7931e; margin-bottom: 1rem;">Search Results (${{data.total}})</h3>`;
            \\                            data.results.forEach(pkg => {{
            \\                                html += `
            \\                                    <div class="package-item">
            \\                                        <div>
            \\                                            <span class="package-name">${{pkg.name}}</span>
            \\                                            <span class="package-version">v${{pkg.version}}</span>
            \\                                        </div>
            \\                                        <div class="package-desc">${{pkg.description || 'No description'}}</div>
            \\                                    </div>
            \\                                `;
            \\                            }});
            \\                            searchResults.innerHTML = html;
            \\                            searchResults.style.display = 'block';
            \\                        }} else {{
            \\                            searchResults.innerHTML = '<div style="text-align: center; color: #b8b4a3; padding: 1rem;">No packages found</div>';
            \\                            searchResults.style.display = 'block';
            \\                        }}
            \\                    }})
            \\                    .catch(err => console.error('Search failed:', err));
            \\            }}
            \\        }});
            \\        
            \\        // Tab switching functionality
            \\        function switchTab(tabName) {{
            \\            // Hide all tab contents
            \\            document.querySelectorAll('.tab-content').forEach(tab => {{
            \\                tab.classList.remove('active');
            \\            }});
            \\            
            \\            // Remove active class from all tabs
            \\            document.querySelectorAll('.tab').forEach(tab => {{
            \\                tab.classList.remove('active');
            \\            }});
            \\            
            \\            // Show selected tab content
            \\            document.getElementById(tabName + '-tab').classList.add('active');
            \\            
            \\            // Add active class to clicked tab
            \\            event.target.classList.add('active');
            \\        }}
            \\        
            \\        // Zigistry search functionality
            \\        const zigistrySearchInput = document.getElementById('zigistrySearchInput');
            \\        const zigistryResults = document.getElementById('zigistryResults');
            \\        
            \\        zigistrySearchInput.addEventListener('input', function(e) {{
            \\            const query = e.target.value.trim();
            \\            if (query.length > 2) {{
            \\                fetch(`/api/zigistry/discover?q=${{encodeURIComponent(query)}}`)
            \\                    .then(response => response.json())
            \\                    .then(data => {{
            \\                        displayZigistryResults(data.packages, `Search Results for "${{query}}"`);
            \\                    }})
            \\                    .catch(err => console.error('Zigistry search failed:', err));
            \\            }} else if (query.length === 0) {{
            \\                zigistryResults.innerHTML = `
            \\                    <h2 style="color: #f7931e; margin-bottom: 1rem;">🚀 Discover Zig Packages</h2>
            \\                    <p style="color: #b8b4a3;">Search for packages or use the quick actions above to explore the Zig ecosystem!</p>
            \\                `;
            \\            }}
            \\        }});
            \\        
            \\        function loadTrending() {{
            \\            fetch('/api/zigistry/trending')
            \\                .then(response => response.json())
            \\                .then(data => {{
            \\                    displayZigistryResults(data.packages, '🔥 Trending Packages');
            \\                }})
            \\                .catch(err => console.error('Failed to load trending:', err));
            \\        }}
            \\        
            \\        function loadCategory(category) {{
            \\            fetch(`/api/zigistry/browse?category=${{category}}`)
            \\                .then(response => response.json())
            \\                .then(data => {{
            \\                    displayZigistryResults(data.packages, `📦 ${{category.charAt(0).toUpperCase() + category.slice(1)}} Packages`);
            \\                }})
            \\                .catch(err => console.error('Failed to load category:', err));
            \\        }}
            \\        
            \\        function displayZigistryResults(packages, title) {{
            \\            if (packages && packages.length > 0) {{
            \\                let html = `<h2 style="color: #f7931e; margin-bottom: 1rem;">${{title}}</h2>`;
            \\                packages.forEach(pkg => {{
            \\                    const topicsHtml = pkg.topics.map(topic => `<span style="background: #36c692; color: #1a1d23; padding: 0.2rem 0.5rem; border-radius: 4px; font-size: 0.8rem; margin-right: 0.3rem;">${{topic}}</span>`).join('');
            \\                    html += `
            \\                        <div class="package-item">
            \\                            <div>
            \\                                <span class="package-name">${{pkg.name}}</span>
            \\                                <span style="color: #36c692; margin-left: 0.5rem;">⭐ ${{pkg.github_stars}} stars</span>
            \\                                <span style="color: #b8b4a3; margin-left: 0.5rem;">📊 ${{pkg.zigistry_score.toFixed(2)}}</span>
            \\                            </div>
            \\                            <div class="package-desc">${{pkg.description || 'No description'}}</div>
            \\                            <div style="margin-top: 0.5rem;">
            \\                                ${{topicsHtml}}
            \\                                <a href="${{pkg.github_url}}" target="_blank" style="color: #f7931e; margin-left: 0.5rem; text-decoration: none;">🔗 GitHub</a>
            \\                            </div>
            \\                        </div>
            \\                    `;
            \\                }});
            \\                zigistryResults.innerHTML = html;
            \\            }} else {{
            \\                zigistryResults.innerHTML = `<h2 style="color: #f7931e; margin-bottom: 1rem;">${{title}}</h2><div style="text-align: center; color: #b8b4a3; padding: 1rem;">No packages found</div>`;
            \\            }}
            \\        }}
            \\    </script>
            \\</body>
            \\</html>
        , .{ stats.total_packages, stats.downloads_today, stats.total_downloads });
        defer self.allocator.free(html_content);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{s}", .{ html_content.len, html_content });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn handlePackageApi(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        if (std.mem.eql(u8, path, "/api/packages")) {
            // List packages
            const packages = try self.database.listPackages(50, 0);
            defer {
                for (packages) |pkg| {
                    self.allocator.free(pkg.name);
                    if (pkg.description) |desc| self.allocator.free(desc);
                    if (pkg.author) |author| self.allocator.free(author);
                    if (pkg.license) |license| self.allocator.free(license);
                }
                self.allocator.free(packages);
            }

            // Build JSON response
            var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
            defer json_list.deinit();

            try json_list.appendSlice("{\"packages\":[");
            for (packages, 0..) |pkg, i| {
                if (i > 0) try json_list.appendSlice(",");

                const pkg_json = try std.fmt.allocPrint(self.allocator,
                    \\{{
                    \\  "name": "{s}",
                    \\  "version": "{}.{}.{}",
                    \\  "description": "{s}",
                    \\  "author": "{s}",
                    \\  "license": "{s}"
                    \\}}
                , .{
                    pkg.name,
                    pkg.version.major,
                    pkg.version.minor,
                    pkg.version.patch,
                    pkg.description orelse "",
                    pkg.author orelse "",
                    pkg.license orelse "",
                });
                defer self.allocator.free(pkg_json);
                try json_list.appendSlice(pkg_json);
            }
            try json_list.appendSlice("]}");

            const packages_json = try json_list.toOwnedSlice();
            defer self.allocator.free(packages_json);

            const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{s}", .{ packages_json.len, packages_json });
            defer self.allocator.free(response);

            try stream.writeAll(response);
        } else {
            // Handle specific package requests
            try self.serve404(stream);
        }
    }

    fn handleSearchApi(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Extract query parameter
        const query_start = std.mem.indexOf(u8, path, "q=") orelse {
            try self.serveEmptySearch(stream);
            return;
        };

        var query = path[query_start + 2 ..];
        // Find end of query parameter (& or end of string)
        if (std.mem.indexOf(u8, query, "&")) |end| {
            query = query[0..end];
        }

        // URL decode the query (simplified)
        // TODO: Implement proper URL decoding

        if (query.len == 0) {
            try self.serveEmptySearch(stream);
            return;
        }

        const packages = try self.database.searchPackages(query, 20);
        defer {
            // Note: Mock database returns static strings, no need to free individual fields
            // for (packages) |pkg| {
            //     if (pkg.owner) |o| self.allocator.free(o);
            //     if (pkg.repo) |r| self.allocator.free(r);
            //     if (pkg.description) |desc| self.allocator.free(desc);
            //     if (pkg.latest_version) |version| self.allocator.free(version);
            //     for (pkg.topics) |topic| self.allocator.free(topic);
            //     self.allocator.free(pkg.topics);
            // }
            self.allocator.free(packages);
        }

        // Build JSON response
        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"results\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const pkg_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "name": "{s}/{s}",
                \\  "owner": "{s}",
                \\  "repo": "{s}",
                \\  "description": "{s}",
                \\  "github_stars": {d},
                \\  "download_count": {d},
                \\  "latest_version": "{s}"
                \\}}
            , .{
                pkg.owner orelse "",
                pkg.repo orelse "",
                pkg.owner orelse "",
                pkg.repo orelse "",
                pkg.description orelse "",
                pkg.github_stars,
                pkg.download_count,
                pkg.latest_version orelse "",
            });
            defer self.allocator.free(pkg_json);
            try json_list.appendSlice(pkg_json);
        }

        const total_str = try std.fmt.allocPrint(self.allocator, "],\"total\":{},\"query\":\"{s}\"}}", .{ packages.len, query });
        defer self.allocator.free(total_str);
        try json_list.appendSlice(total_str);

        const search_json = try json_list.toOwnedSlice();
        defer self.allocator.free(search_json);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{s}", .{ search_json.len, search_json });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn serveEmptySearch(self: *Server, stream: std.net.Stream) !void {
        const search_json = "{\"results\":[],\"total\":0,\"query\":\"\"}";

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{s}", .{ search_json.len, search_json });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn handlePublishPackage(self: *Server, stream: std.net.Stream) !void {
        const response_json =
            \\{
            \\  "success": true,
            \\  "message": "Package published successfully"
            \\}
        ;

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{s}", .{ response_json.len, response_json });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn serve404(self: *Server, stream: std.net.Stream) !void {
        const content = "404 Not Found";
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n{s}", .{ content.len, content });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn serveMethodNotAllowed(self: *Server, stream: std.net.Stream) !void {
        const content = "405 Method Not Allowed";
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n{s}", .{ content.len, content });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn handleZigistryDiscover(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse query parameter
        var query: []const u8 = "";
        if (std.mem.indexOf(u8, path, "?q=")) |idx| {
            query = path[idx + 3 ..];
            // URL decode would go here in production
        }

        const packages = try self.zigistry.searchPackages(query, 20);
        defer {
            for (packages) |*pkg| {
                pkg.deinit(self.allocator);
            }
            self.allocator.free(packages);
        }

        // Build JSON response
        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = blk: {
                var topics_str = std.array_list.AlignedManaged(u8, null).init(self.allocator);
                defer topics_str.deinit();
                try topics_str.appendSlice("[");
                for (pkg.topics, 0..) |topic, j| {
                    if (j > 0) try topics_str.appendSlice(",");
                    const formatted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{topic});
                    defer self.allocator.free(formatted);
                    try topics_str.appendSlice(formatted);
                }
                try topics_str.appendSlice("]");
                break :blk try topics_str.toOwnedSlice();
            };
            defer self.allocator.free(topics_json);

            const pkg_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "name": "{s}",
                \\  "description": "{s}",
                \\  "github_url": "{s}",
                \\  "github_stars": {},
                \\  "zigistry_score": {d:.2},
                \\  "topics": {s}
                \\}}
            , .{
                pkg.name,
                pkg.description orelse "",
                pkg.github_url,
                pkg.github_stars,
                pkg.zigistry_score,
                topics_json,
            });
            defer self.allocator.free(pkg_json);

            try json_list.appendSlice(pkg_json);
        }
        try json_list.appendSlice("],\"total\":");
        const formatted = try std.fmt.allocPrint(self.allocator, "{}", .{packages.len});
        defer self.allocator.free(formatted);
        try json_list.appendSlice(formatted);
        try json_list.appendSlice("}");

        const json_response = try json_list.toOwnedSlice();
        defer self.allocator.free(json_response);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{s}", .{ json_response.len, json_response });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn handleZigistryTrending(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        _ = path; // unused
        const packages = try self.zigistry.getTrending(null, 20);
        defer {
            for (packages) |*pkg| {
                pkg.deinit(self.allocator);
            }
            self.allocator.free(packages);
        }

        // Build JSON response
        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = blk: {
                var topics_str = std.array_list.AlignedManaged(u8, null).init(self.allocator);
                defer topics_str.deinit();
                try topics_str.appendSlice("[");
                for (pkg.topics, 0..) |topic, j| {
                    if (j > 0) try topics_str.appendSlice(",");
                    const formatted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{topic});
                    defer self.allocator.free(formatted);
                    try topics_str.appendSlice(formatted);
                }
                try topics_str.appendSlice("]");
                break :blk try topics_str.toOwnedSlice();
            };
            defer self.allocator.free(topics_json);

            const pkg_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "name": "{s}",
                \\  "description": "{s}",
                \\  "github_url": "{s}",
                \\  "github_stars": {},
                \\  "zigistry_score": {d:.2},
                \\  "topics": {s}
                \\}}
            , .{
                pkg.name,
                pkg.description orelse "",
                pkg.github_url,
                pkg.github_stars,
                pkg.zigistry_score,
                topics_json,
            });
            defer self.allocator.free(pkg_json);

            try json_list.appendSlice(pkg_json);
        }
        try json_list.appendSlice("],\"total\":");
        const formatted = try std.fmt.allocPrint(self.allocator, "{}", .{packages.len});
        defer self.allocator.free(formatted);
        try json_list.appendSlice(formatted);
        try json_list.appendSlice("}");

        const json_response = try json_list.toOwnedSlice();
        defer self.allocator.free(json_response);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{s}", .{ json_response.len, json_response });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn handleZigistryBrowse(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse category parameter
        var category: []const u8 = "all";
        if (std.mem.indexOf(u8, path, "?category=")) |idx| {
            category = path[idx + 10 ..];
            // URL decode would go here in production
        }

        const packages = try self.zigistry.getTrending(if (std.mem.eql(u8, category, "all")) null else category, 20);
        defer {
            for (packages) |*pkg| {
                pkg.deinit(self.allocator);
            }
            self.allocator.free(packages);
        }

        // Build JSON response
        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = blk: {
                var topics_str = std.array_list.AlignedManaged(u8, null).init(self.allocator);
                defer topics_str.deinit();
                try topics_str.appendSlice("[");
                for (pkg.topics, 0..) |topic, j| {
                    if (j > 0) try topics_str.appendSlice(",");
                    const formatted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{topic});
                    defer self.allocator.free(formatted);
                    try topics_str.appendSlice(formatted);
                }
                try topics_str.appendSlice("]");
                break :blk try topics_str.toOwnedSlice();
            };
            defer self.allocator.free(topics_json);

            const pkg_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "name": "{s}",
                \\  "description": "{s}",
                \\  "github_url": "{s}",
                \\  "github_stars": {},
                \\  "zigistry_score": {d:.2},
                \\  "topics": {s}
                \\}}
            , .{
                pkg.name,
                pkg.description orelse "",
                pkg.github_url,
                pkg.github_stars,
                pkg.zigistry_score,
                topics_json,
            });
            defer self.allocator.free(pkg_json);

            try json_list.appendSlice(pkg_json);
        }
        try json_list.appendSlice("],\"total\":");
        const formatted = try std.fmt.allocPrint(self.allocator, "{}", .{packages.len});
        defer self.allocator.free(formatted);
        try json_list.appendSlice(formatted);
        try json_list.appendSlice(",\"category\":\"");
        try json_list.appendSlice(category);
        try json_list.appendSlice("\"}");

        const json_response = try json_list.toOwnedSlice();
        defer self.allocator.free(json_response);

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\n\r\n{s}", .{ json_response.len, json_response });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    // GitHub-compatible API v1 handlers

    // GET /api/v1/packages/{owner}/{repo}/releases
    // GET /api/v1/packages/{owner}/{repo}/releases/{tag}
    // GET /api/v1/packages/{owner}/{repo}/tags
    fn handlePackageApiV1(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse path: /api/v1/packages/{owner}/{repo}/...
        const prefix = "/api/v1/packages/";
        if (!std.mem.startsWith(u8, path, prefix)) {
            return self.serve404(stream);
        }

        const path_after_prefix = path[prefix.len..];
        var parts = std.mem.splitSequence(u8, path_after_prefix, "/");
        const owner = parts.next() orelse return self.serve404(stream);
        const repo = parts.next() orelse return self.serve404(stream);
        const action = parts.next();

        if (action == null) {
            // GET /api/v1/packages/{owner}/{repo} - get package info
            try self.handleGetPackageV1(stream, owner, repo);
        } else if (std.mem.eql(u8, action.?, "releases")) {
            const tag = parts.next();
            if (tag == null) {
                // GET /api/v1/packages/{owner}/{repo}/releases - list releases
                try self.handleGetReleasesV1(stream, owner, repo);
            } else {
                // GET /api/v1/packages/{owner}/{repo}/releases/{tag} - get specific release
                try self.handleGetReleaseV1(stream, owner, repo, tag.?);
            }
        } else if (std.mem.eql(u8, action.?, "tags")) {
            // GET /api/v1/packages/{owner}/{repo}/tags - list tags (alias for releases)
            try self.handleGetTagsV1(stream, owner, repo);
        } else if (std.mem.eql(u8, action.?, "download")) {
            const version = parts.next() orelse return self.serve404(stream);
            // GET /api/v1/packages/{owner}/{repo}/download/{version} - download package
            try self.handleDownloadPackageV1(stream, owner, repo, version);
        } else {
            try self.serve404(stream);
        }
    }

    fn handleGetPackageV1(self: *Server, stream: std.net.Stream, owner: []const u8, repo: []const u8) !void {
        const package = try self.database.getPackageGitHub(owner, repo);
        if (package == null) {
            try self.serveJsonError(stream, 404, "Package not found");
            return;
        }

        const pkg = package.?;
        defer {
            // Note: Mock database returns static strings, no need to free them
            // When using real database with allocated strings, uncomment and fix:
            // if (pkg.owner) |o| self.allocator.free(o);
            // if (pkg.repo) |r| self.allocator.free(r);
            // if (pkg.description) |d| self.allocator.free(d);
            // if (pkg.license) |l| self.allocator.free(l);
            // if (pkg.homepage) |h| self.allocator.free(h);
            // if (pkg.github_url) |g| self.allocator.free(g);
            // for (pkg.topics) |topic| self.allocator.free(topic);
            // self.allocator.free(pkg.topics);
        }

        const topics_json = try self.serializeStringArray(pkg.topics);
        defer self.allocator.free(topics_json);

        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "owner": "{s}",
            \\  "repo": "{s}",
            \\  "full_name": "{s}/{s}",
            \\  "description": "{s}",
            \\  "topics": {s},
            \\  "license": "{s}",
            \\  "homepage": "{s}",
            \\  "github_url": "{s}",
            \\  "stargazers_count": {d},
            \\  "created_at": "{d}",
            \\  "updated_at": "{d}",
            \\  "private": {s}
            \\}}
        , .{
            pkg.owner orelse "",
            pkg.repo orelse "",
            pkg.owner orelse "",
            pkg.repo orelse "",
            pkg.description orelse "",
            topics_json,
            pkg.license orelse "",
            pkg.homepage orelse "",
            pkg.github_url orelse "",
            pkg.github_stars,
            pkg.created_at,
            pkg.updated_at,
            if (pkg.is_private) "true" else "false",
        });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    fn handleGetReleasesV1(self: *Server, stream: std.net.Stream, owner: []const u8, repo: []const u8) !void {
        const releases = try self.database.getReleases(owner, repo);
        defer {
            for (releases) |release| {
                self.allocator.free(release.owner);
                self.allocator.free(release.repo);
                self.allocator.free(release.tag_name);
                if (release.name) |n| self.allocator.free(n);
                if (release.body) |b| self.allocator.free(b);
                if (release.tarball_url) |t| self.allocator.free(t);
                if (release.zipball_url) |z| self.allocator.free(z);
                if (release.download_url) |d| self.allocator.free(d);
                if (release.sha256) |s| self.allocator.free(s);
            }
            self.allocator.free(releases);
        }

        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("[");
        for (releases, 0..) |release, i| {
            if (i > 0) try json_list.appendSlice(",");

            const release_json = try std.fmt.allocPrint(self.allocator,
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
                release.id,
                release.tag_name,
                release.name orelse "",
                release.body orelse "",
                if (release.draft) "true" else "false",
                if (release.prerelease) "true" else "false",
                release.created_at,
                if (release.published_at) |p| try std.fmt.allocPrint(self.allocator, "\"{d}\"", .{p}) else "null",
                release.tarball_url orelse "",
                release.zipball_url orelse "",
                release.download_url orelse "",
                release.file_size,
                release.sha256 orelse "",
            });
            defer self.allocator.free(release_json);
            if (release.published_at != null) self.allocator.free(try std.fmt.allocPrint(self.allocator, "\"{d}\"", .{release.published_at.?}));

            try json_list.appendSlice(release_json);
        }
        try json_list.appendSlice("]");

        const json_response = try json_list.toOwnedSlice();
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    fn handleGetReleaseV1(self: *Server, stream: std.net.Stream, owner: []const u8, repo: []const u8, tag: []const u8) !void {
        const release = try self.database.getRelease(owner, repo, tag);
        if (release == null) {
            try self.serveJsonError(stream, 404, "Release not found");
            return;
        }

        const rel = release.?;
        defer {
            self.allocator.free(rel.owner);
            self.allocator.free(rel.repo);
            self.allocator.free(rel.tag_name);
            if (rel.name) |n| self.allocator.free(n);
            if (rel.body) |b| self.allocator.free(b);
            if (rel.tarball_url) |t| self.allocator.free(t);
            if (rel.zipball_url) |z| self.allocator.free(z);
            if (rel.download_url) |d| self.allocator.free(d);
            if (rel.sha256) |s| self.allocator.free(s);
        }

        const json_response = try std.fmt.allocPrint(self.allocator,
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
            rel.id,
            rel.tag_name,
            rel.name orelse "",
            rel.body orelse "",
            if (rel.draft) "true" else "false",
            if (rel.prerelease) "true" else "false",
            rel.created_at,
            if (rel.published_at) |p| try std.fmt.allocPrint(self.allocator, "\"{d}\"", .{p}) else "null",
            rel.tarball_url orelse "",
            rel.zipball_url orelse "",
            rel.download_url orelse "",
            rel.file_size,
            rel.sha256 orelse "",
        });
        defer self.allocator.free(json_response);
        if (rel.published_at != null) self.allocator.free(try std.fmt.allocPrint(self.allocator, "\"{d}\"", .{rel.published_at.?}));

        try self.serveJson(stream, 200, json_response);
    }

    fn handleGetTagsV1(self: *Server, stream: std.net.Stream, owner: []const u8, repo: []const u8) !void {
        const releases = try self.database.getReleases(owner, repo);
        defer {
            for (releases) |release| {
                self.allocator.free(release.owner);
                self.allocator.free(release.repo);
                self.allocator.free(release.tag_name);
                if (release.name) |n| self.allocator.free(n);
                if (release.body) |b| self.allocator.free(b);
                if (release.tarball_url) |t| self.allocator.free(t);
                if (release.zipball_url) |z| self.allocator.free(z);
                if (release.download_url) |d| self.allocator.free(d);
                if (release.sha256) |s| self.allocator.free(s);
            }
            self.allocator.free(releases);
        }

        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("[");
        for (releases, 0..) |release, i| {
            if (i > 0) try json_list.appendSlice(",");

            const tag_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "name": "{s}",
                \\  "zipball_url": "{s}",
                \\  "tarball_url": "{s}",
                \\  "commit": {{
                \\    "sha": "{s}",
                \\    "url": ""
                \\  }}
                \\}}
            , .{
                release.tag_name,
                release.zipball_url orelse "",
                release.tarball_url orelse "",
                release.sha256 orelse "",
            });
            defer self.allocator.free(tag_json);

            try json_list.appendSlice(tag_json);
        }
        try json_list.appendSlice("]");

        const json_response = try json_list.toOwnedSlice();
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    fn handleDownloadPackageV1(self: *Server, stream: std.net.Stream, owner: []const u8, repo: []const u8, version: []const u8) !void {
        // Parse version
        const parsed_version = types.Version.parse(version) catch {
            try self.serveJsonError(stream, 400, "Invalid version format");
            return;
        };

        // Check if package exists in storage
        const package_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, repo });
        defer self.allocator.free(package_name);

        if (!self.storage.packageExists(package_name, parsed_version)) {
            try self.serveJsonError(stream, 404, "Package not found");
            return;
        }

        // Retrieve package data
        const package_data = self.storage.retrievePackage(package_name, parsed_version) catch |err| switch (err) {
            error.FileNotFound => {
                try self.serveJsonError(stream, 404, "Package file not found");
                return;
            },
            else => {
                std.debug.print("Storage retrieval error: {}\n", .{err});
                try self.serveJsonError(stream, 500, "Failed to retrieve package");
                return;
            },
        };
        defer self.allocator.free(package_data);

        // Increment download count (using mock database for now)
        self.database.incrementDownloadCount(package_name) catch |err| {
            std.debug.print("Failed to increment download count: {}\n", .{err});
            // Continue with download even if counter fails
        };

        // Generate filename for download
        const version_str = try parsed_version.toString(self.allocator);
        defer self.allocator.free(version_str);
        const filename = try std.fmt.allocPrint(self.allocator, "{s}-{s}.zpkg", .{ repo, version_str });
        defer self.allocator.free(filename);

        // Serve the file
        const response_header = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: application/octet-stream
            \\Content-Disposition: attachment; filename="{s}"
            \\Content-Length: {d}
            \\Cache-Control: public, max-age=31536000
            \\
            \\
        , .{ filename, package_data.len });
        defer self.allocator.free(response_header);

        try stream.writeAll(response_header);
        try stream.writeAll(package_data);

        std.debug.print("📥 Package downloaded: {s}/{s}@{s} ({d} bytes)\n", .{ 
            owner, repo, version, package_data.len 
        });
    }

    // GET /api/v1/search?q=query&limit=20
    fn handleSearchApiV1(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse query parameters
        var query: []const u8 = "";
        var limit: u32 = 20;

        if (std.mem.indexOf(u8, path, "?")) |query_start| {
            const query_string = path[query_start + 1 ..];
            var params = std.mem.splitSequence(u8, query_string, "&");

            while (params.next()) |param| {
                if (std.mem.startsWith(u8, param, "q=")) {
                    query = param[2..];
                    // URL decode would go here in production
                } else if (std.mem.startsWith(u8, param, "limit=")) {
                    limit = std.fmt.parseInt(u32, param[6..], 10) catch 20;
                }
            }
        }

        if (query.len == 0) {
            try self.serveJsonError(stream, 400, "Query parameter 'q' is required");
            return;
        }

        const results = try self.database.searchPackages(query, limit);
        defer {
            // Note: Mock database returns static strings, no need to free individual fields
            // When using real database with allocated strings, uncomment and fix:
            // for (results) |result| {
            //     if (result.owner) |o| self.allocator.free(o);
            //     if (result.repo) |r| self.allocator.free(r);
            //     if (result.description) |d| self.allocator.free(d);
            //     if (result.latest_version) |v| self.allocator.free(v);
            //     for (result.topics) |topic| self.allocator.free(topic);
            //     self.allocator.free(result.topics);
            // }
            self.allocator.free(results);
        }

        var json_list = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"items\":[");
        for (results, 0..) |result, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = try self.serializeStringArray(result.topics);
            defer self.allocator.free(topics_json);

            const result_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "full_name": "{s}/{s}",
                \\  "owner": "{s}",
                \\  "name": "{s}",
                \\  "description": "{s}",
                \\  "topics": {s},
                \\  "stargazers_count": {d},
                \\  "download_count": {d},
                \\  "latest_version": "{s}",
                \\  "updated_at": "{d}"
                \\}}
            , .{
                result.owner orelse "",
                result.repo orelse "",
                result.owner orelse "",
                result.repo orelse "",
                result.description orelse "",
                topics_json,
                result.github_stars,
                result.download_count,
                result.latest_version orelse "",
                result.updated_at,
            });
            defer self.allocator.free(result_json);

            try json_list.appendSlice(result_json);
        }
        try json_list.appendSlice("],\"total_count\":");
        const formatted = try std.fmt.allocPrint(self.allocator, "{}", .{results.len});
        defer self.allocator.free(formatted);
        try json_list.appendSlice(formatted);
        try json_list.appendSlice("}");

        const json_response = try json_list.toOwnedSlice();
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    // GET /api/v1/resolve/{short_name}
    fn handleResolveApiV1(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        const prefix = "/api/v1/resolve/";
        if (!std.mem.startsWith(u8, path, prefix)) {
            return self.serve404(stream);
        }

        const short_name = path[prefix.len..];
        if (short_name.len == 0) {
            try self.serveJsonError(stream, 400, "Short name is required");
            return;
        }

        const alias = try self.database.resolveAlias(short_name);
        if (alias == null) {
            try self.serveJsonError(stream, 404, "Alias not found");
            return;
        }

        const al = alias.?;
        defer {
            self.allocator.free(al.short_name);
            self.allocator.free(al.owner);
            self.allocator.free(al.repo);
            if (al.created_by) |c| self.allocator.free(c);
        }

        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "short_name": "{s}",
            \\  "full_name": "{s}/{s}",
            \\  "owner": "{s}",
            \\  "repo": "{s}",
            \\  "created_at": "{d}",
            \\  "created_by": "{s}"
            \\}}
        , .{
            al.short_name,
            al.owner,
            al.repo,
            al.owner,
            al.repo,
            al.created_at,
            al.created_by orelse "",
        });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    // GET /api/v1/registry/config
    fn handleRegistryConfigV1(self: *Server, stream: std.net.Stream) !void {
        const registry_name = try self.database.getRegistryConfig("registry_name") orelse try self.allocator.dupe(u8, "Zepplin Registry");
        defer self.allocator.free(registry_name);

        const registry_url = try self.database.getRegistryConfig("registry_url") orelse try self.allocator.dupe(u8, "http://localhost:8080");
        defer self.allocator.free(registry_url);

        const api_version = try self.database.getRegistryConfig("api_version") orelse try self.allocator.dupe(u8, "v1");
        defer self.allocator.free(api_version);

        const allow_public_publish = try self.database.getRegistryConfig("allow_public_publish") orelse try self.allocator.dupe(u8, "1");
        defer self.allocator.free(allow_public_publish);

        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "name": "{s}",
            \\  "url": "{s}",
            \\  "api_version": "{s}",
            \\  "version": "{s}",
            \\  "allow_public_publish": {s},
            \\  "github_compatible": true,
            \\  "features": [
            \\    "packages",
            \\    "releases",
            \\    "aliases",
            \\    "search",
            \\    "download_stats",
            \\    "comments",
            \\    "oauth"
            \\  ]
            \\}}
        , .{
            registry_name,
            registry_url,
            api_version,
            ZEPPLIN_VERSION,
            if (std.mem.eql(u8, allow_public_publish, "1")) "true" else "false",
        });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    // GET /api/v1/health
    fn handleHealthV1(self: *Server, stream: std.net.Stream) !void {
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "status": "ok",
            \\  "timestamp": "{d}",
            \\  "version": "1.0.0",
            \\  "features": {{
            \\    "database": "sqlite",
            \\    "storage": "filesystem",
            \\    "zigistry_integration": true
            \\  }}
            \\}}
        , .{std.time.timestamp()});
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    // POST /api/v1/packages/{owner}/{repo}/releases
    fn handlePublishPackageV1(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse path to extract owner and repo
        const prefix = "/api/v1/packages/";
        if (!std.mem.startsWith(u8, path, prefix)) {
            return self.serve404(stream);
        }

        const path_after_prefix = path[prefix.len..];
        var parts = std.mem.splitSequence(u8, path_after_prefix, "/");
        const owner = parts.next() orelse return self.serve404(stream);
        const repo = parts.next() orelse return self.serve404(stream);
        const action = parts.next();

        if (action == null or !std.mem.eql(u8, action.?, "releases")) {
            try self.serveJsonError(stream, 400, "Invalid endpoint. Use /api/v1/packages/{owner}/{repo}/releases");
            return;
        }

        // Read the full request
        var buffer: [50 * 1024 * 1024]u8 = undefined; // 50MB max upload
        const bytes_read = try stream.read(&buffer);
        const request = buffer[0..bytes_read];

        // Find the body after headers
        const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try self.serveJsonError(stream, 400, "Invalid request format");
            return;
        };
        const headers = request[0..header_end];
        const body = request[header_end + 4..];

        // Parse multipart form data
        const upload_data = self.parseMultipartUpload(headers, body) catch |err| switch (err) {
            error.InvalidMultipart => {
                try self.serveJsonError(stream, 400, "Invalid multipart form data");
                return;
            },
            error.MissingFile => {
                try self.serveJsonError(stream, 400, "Package file is required");
                return;
            },
            error.MissingTagName => {
                try self.serveJsonError(stream, 400, "tag_name is required");
                return;
            },
            else => return err,
        };
        defer self.freeUploadData(upload_data);

        // Validate owner/repo match path
        if (!std.mem.eql(u8, owner, upload_data.owner) or !std.mem.eql(u8, repo, upload_data.repo)) {
            try self.serveJsonError(stream, 400, "Owner/repo mismatch between path and form data");
            return;
        }

        // Create package metadata
        const version = types.Version.parse(upload_data.tag_name) catch {
            try self.serveJsonError(stream, 400, "Invalid version format. Use semantic versioning (e.g., 1.0.0)");
            return;
        };

        const package_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, repo });
        defer self.allocator.free(package_name);

        const metadata = types.PackageMetadata{
            .name = package_name,
            .version = version,
            .description = upload_data.body,
            .author = owner,
            .license = null,
            .homepage = null,
            .repository = try std.fmt.allocPrint(self.allocator, "https://github.com/{s}/{s}", .{ owner, repo }),
            .dependencies = &.{},
            .keywords = &.{},
            .minimum_zig_version = null,
        };
        defer if (metadata.repository) |r| self.allocator.free(r);

        // Store package
        const package_file = self.storage.storePackage(metadata, upload_data.file_data) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try self.serveJsonError(stream, 409, "Package version already exists");
                return;
            },
            else => {
                std.debug.print("Storage error: {}\n", .{err});
                try self.serveJsonError(stream, 500, "Failed to store package");
                return;
            },
        };
        defer {
            self.allocator.free(package_file.checksum);
            self.allocator.free(package_file.file_path);
        }

        // Create download URL
        const download_url = try std.fmt.allocPrint(self.allocator, 
            "/api/v1/packages/{s}/{s}/download/{s}", 
            .{ owner, repo, upload_data.tag_name }
        );
        defer self.allocator.free(download_url);

        // Return success response
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "id": {d},
            \\  "tag_name": "{s}",
            \\  "name": "{s}",
            \\  "body": "{s}",
            \\  "draft": {s},
            \\  "prerelease": {s},
            \\  "created_at": {d},
            \\  "published_at": {d},
            \\  "download_url": "{s}",
            \\  "file_size": {d},
            \\  "sha256": "{s}"
            \\}}
        , .{
            std.time.timestamp(), // Using timestamp as ID for now
            upload_data.tag_name,
            upload_data.name orelse upload_data.tag_name,
            upload_data.body orelse "",
            if (upload_data.draft) "true" else "false",
            if (upload_data.prerelease) "true" else "false",
            std.time.timestamp(),
            std.time.timestamp(),
            download_url,
            package_file.file_size,
            package_file.checksum,
        });
        defer self.allocator.free(json_response);

        std.debug.print("📦 Package uploaded: {s}/{s}@{s} ({d} bytes)\n", .{ 
            owner, repo, upload_data.tag_name, package_file.file_size 
        });

        try self.serveJson(stream, 201, json_response);
    }

    // PUT /api/v1/aliases/{short_name}
    fn handleCreateAliasV1(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        const prefix = "/api/v1/aliases/";
        if (!std.mem.startsWith(u8, path, prefix)) {
            return self.serve404(stream);
        }

        const short_name = path[prefix.len..];
        if (short_name.len == 0) {
            try self.serveJsonError(stream, 400, "Short name is required");
            return;
        }

        // TODO: Parse JSON body to extract owner/repo
        // For now, return a placeholder response
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "message": "Alias creation endpoint - implementation in progress",
            \\  "short_name": "{s}",
            \\  "status": "placeholder"
            \\}}
        , .{short_name});
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 501, json_response);
    }

    // DELETE /api/v1/packages/{owner}/{repo}/releases/{tag}
    fn handleDeletePackageV1(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse path
        const prefix = "/api/v1/packages/";
        if (!std.mem.startsWith(u8, path, prefix)) {
            return self.serve404(stream);
        }

        const path_after_prefix = path[prefix.len..];
        var parts = std.mem.splitSequence(u8, path_after_prefix, "/");
        const owner = parts.next() orelse return self.serve404(stream);
        const repo = parts.next() orelse return self.serve404(stream);
        const action = parts.next();
        const tag = parts.next();

        if (action == null or !std.mem.eql(u8, action.?, "releases") or tag == null) {
            try self.serveJsonError(stream, 400, "Invalid endpoint. Use DELETE /api/v1/packages/{owner}/{repo}/releases/{tag}");
            return;
        }

        // TODO: Implement release deletion
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "message": "Package deletion endpoint - implementation in progress",
            \\  "owner": "{s}",
            \\  "repo": "{s}",
            \\  "tag": "{s}",
            \\  "status": "placeholder"
            \\}}
        , .{ owner, repo, tag.? });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 501, json_response);
    }

    // Simple health check endpoint for Docker/nginx
    fn handleHealthSimple(self: *Server, stream: std.net.Stream) !void {
        _ = self;
        const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK";
        try stream.writeAll(response);
    }

    // Helper methods
    fn serveJson(self: *Server, stream: std.net.Stream, status_code: u16, json_content: []const u8) !void {
        const status_text = switch (status_code) {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            else => "Unknown",
        };

        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {d}\r\n\r\n{s}", .{ status_code, status_text, json_content.len, json_content });
        defer self.allocator.free(response);

        try stream.writeAll(response);
    }

    fn serveJsonError(self: *Server, stream: std.net.Stream, status_code: u16, message: []const u8) !void {
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "message": "{s}",
            \\  "documentation_url": "https://github.com/ghostkellz/zepplin"
            \\}}
        , .{message});
        defer self.allocator.free(json_response);

        try self.serveJson(stream, status_code, json_response);
    }

    fn handleStatsApi(self: *Server, stream: std.net.Stream) !void {
        const stats = try self.database.getDownloadStats();
        
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "success": true,
            \\  "total_packages": {},
            \\  "total_downloads": {},
            \\  "downloads_today": {},
            \\  "active_maintainers": 89,
            \\  "zig_version": "0.16.0"
            \\}}
        , .{ stats.total_packages, stats.total_downloads, stats.downloads_today });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    fn serializeStringArray(self: *Server, strings: [][]const u8) ![]u8 {
        var json = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json.deinit();

        try json.append('[');
        for (strings, 0..) |str, i| {
            if (i > 0) try json.appendSlice(",");
            try json.append('"');
            try json.appendSlice(str);
            try json.append('"');
        }
        try json.append(']');

        return json.toOwnedSlice();
    }

    fn handleRegister(self: *Server, stream: std.net.Stream) !void {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try stream.read(&buffer);
        const request = buffer[0..bytes_read];
        
        // Find the body after headers
        const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try self.serveJsonError(stream, 400, "Invalid request");
            return;
        };
        const body = request[header_end + 4..];
        
        // Simple JSON parsing for username, email, and password
        var username: ?[]const u8 = null;
        var email: ?[]const u8 = null; 
        var password: ?[]const u8 = null;
        
        // Extract username
        if (std.mem.indexOf(u8, body, "\"username\"")) |username_pos| {
            const colon_pos = std.mem.indexOf(u8, body[username_pos..], ":") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_start = std.mem.indexOf(u8, body[username_pos + colon_pos..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_end = std.mem.indexOf(u8, body[username_pos + colon_pos + quote_start + 1..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            username = body[username_pos + colon_pos + quote_start + 1..][0..quote_end];
        }
        
        // Extract email
        if (std.mem.indexOf(u8, body, "\"email\"")) |email_pos| {
            const colon_pos = std.mem.indexOf(u8, body[email_pos..], ":") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_start = std.mem.indexOf(u8, body[email_pos + colon_pos..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_end = std.mem.indexOf(u8, body[email_pos + colon_pos + quote_start + 1..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            email = body[email_pos + colon_pos + quote_start + 1..][0..quote_end];
        }
        
        // Extract password
        if (std.mem.indexOf(u8, body, "\"password\"")) |password_pos| {
            const colon_pos = std.mem.indexOf(u8, body[password_pos..], ":") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_start = std.mem.indexOf(u8, body[password_pos + colon_pos..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_end = std.mem.indexOf(u8, body[password_pos + colon_pos + quote_start + 1..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            password = body[password_pos + colon_pos + quote_start + 1..][0..quote_end];
        }
        
        if (username == null or email == null or password == null) {
            try self.serveJsonError(stream, 400, "Missing required fields: username, email, password");
            return;
        }
        
        // Check if user already exists
        const exists = try self.database.userExists(username.?);
        if (exists) {
            try self.serveJsonError(stream, 409, "Username already exists");
            return;
        }
        
        // Hash password
        const password_hash = try self.auth.hashPassword(password.?);
        defer self.allocator.free(password_hash);
        
        // Generate API token
        const token = try self.auth.generateApiToken(1); // Will need proper user ID after creation
        defer self.allocator.free(token);
        
        // Create user
        try self.database.createUser(username.?, email.?, password_hash, token);
        
        // Return success with token
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "username": "{s}",
            \\  "email": "{s}",
            \\  "token": "{s}"
            \\}}
        , .{ username.?, email.?, token });
        defer self.allocator.free(json_response);
        
        try self.serveJson(stream, 201, json_response);
    }
    
    fn handleLogin(self: *Server, stream: std.net.Stream) !void {
        // TODO: Implement proper login after User type is defined
        try self.serveJsonError(stream, 501, "Login not implemented yet");
    }

    // Login disabled - will be re-implemented when User type is added

    fn validateAuthToken(self: *Server, request: []const u8) !?AuthenticatedUser {
        // Extract Authorization header
        const auth_header_start = std.mem.indexOf(u8, request, "Authorization: ") orelse return null;
        const auth_line_end = std.mem.indexOf(u8, request[auth_header_start..], "\r\n") orelse return null;
        const auth_header = request[auth_header_start + 15..auth_header_start + auth_line_end];
        
        // Extract Bearer token
        const token = Auth.extractBearerToken(auth_header) orelse return null;
        
        // Validate token
        const auth_token = self.auth.validateApiToken(token) catch return null;
        defer self.allocator.free(auth_token.token);
        
        // Get user info from database
        // For now, we'll create dummy data based on user_id
        // In a real implementation, you'd look this up in the database
        const username = try std.fmt.allocPrint(self.allocator, "user_{}", .{auth_token.user_id});
        const email = try std.fmt.allocPrint(self.allocator, "user_{}@example.com", .{auth_token.user_id});
        const display_name = try std.fmt.allocPrint(self.allocator, "User {}", .{auth_token.user_id});
        const avatar_url = try self.allocator.dupe(u8, "");
        const provider = try self.allocator.dupe(u8, "local");
        
        return AuthenticatedUser{
            .username = username,
            .user_id = auth_token.user_id,
            .email = email,
            .display_name = display_name,
            .avatar_url = avatar_url,
            .provider = provider,
        };
    }
    
    fn requireAuth(self: *Server, stream: std.net.Stream, request: []const u8) !?AuthenticatedUser {
        const user = self.validateAuthToken(request) catch {
            try self.serveJsonError(stream, 401, "Invalid or expired token");
            return null;
        };
        
        if (user == null) {
            try self.serveJsonError(stream, 401, "Authentication required");
            return null;
        }
        
        return user;
    }
    
    fn handleLogout(self: *Server, stream: std.net.Stream, request: []const u8) !void {
        // For now, logout is just a client-side operation since we're using stateless JWT-like tokens
        // In a full implementation, you might want to maintain a blacklist of revoked tokens
        _ = request; // Suppress unused parameter warning
        
        const json_response = 
            \\{
            \\  "message": "Logged out successfully"
            \\}
        ;
        
        try self.serveJson(stream, 200, json_response);
    }
    
    fn handleUserProfile(self: *Server, stream: std.net.Stream, request: []const u8) !void {
        const user = try self.requireAuth(stream, request);
        if (user == null) return; // Error already sent by requireAuth
        
        const u = user.?;
        defer self.allocator.free(u.username);
        defer self.allocator.free(u.email);
        defer self.allocator.free(u.display_name);
        defer self.allocator.free(u.avatar_url);
        defer self.allocator.free(u.provider);
        
        // Return full user profile info
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "user_id": {},
            \\  "username": "{s}",
            \\  "email": "{s}",
            \\  "display_name": "{s}",
            \\  "avatar_url": "{s}",
            \\  "provider": "{s}",
            \\  "authenticated": true
            \\}}
        , .{ u.user_id, u.username, u.email, u.display_name, u.avatar_url, u.provider });
        defer self.allocator.free(json_response);
        
        try self.serveJson(stream, 200, json_response);
    }

    // Multipart form data parser
    fn parseMultipartUpload(self: *Server, headers: []const u8, body: []const u8) !types.UploadData {
        // Extract boundary from Content-Type header
        const boundary = self.extractBoundary(headers) orelse return error.InvalidMultipart;
        defer self.allocator.free(boundary);

        var upload_data = types.UploadData{
            .owner = "",
            .repo = "",
            .tag_name = "",
            .name = null,
            .body = null,
            .draft = false,
            .prerelease = false,
            .file_data = "",
            .filename = "",
            .content_type = "",
        };

        // Split body by boundary
        const boundary_delimiter = try std.fmt.allocPrint(self.allocator, "--{s}", .{boundary});
        defer self.allocator.free(boundary_delimiter);

        var parts = std.mem.splitSequence(u8, body, boundary_delimiter);
        _ = parts.next(); // Skip first empty part

        var has_file = false;
        var has_tag_name = false;

        while (parts.next()) |part| {
            if (part.len < 4) continue; // Skip empty or too small parts

            // Skip end boundary
            if (std.mem.startsWith(u8, part, "--")) break;

            // Find headers and content separator
            const content_start = std.mem.indexOf(u8, part, "\r\n\r\n") orelse continue;
            const part_headers = part[0..content_start];
            const content = std.mem.trim(u8, part[content_start + 4..], "\r\n");

            // Parse Content-Disposition header
            if (std.mem.indexOf(u8, part_headers, "Content-Disposition:")) |_| {
                if (std.mem.indexOf(u8, part_headers, "name=\"owner\"")) |_| {
                    upload_data.owner = try self.allocator.dupe(u8, content);
                } else if (std.mem.indexOf(u8, part_headers, "name=\"repo\"")) |_| {
                    upload_data.repo = try self.allocator.dupe(u8, content);
                } else if (std.mem.indexOf(u8, part_headers, "name=\"tag_name\"")) |_| {
                    upload_data.tag_name = try self.allocator.dupe(u8, content);
                    has_tag_name = true;
                } else if (std.mem.indexOf(u8, part_headers, "name=\"name\"")) |_| {
                    upload_data.name = try self.allocator.dupe(u8, content);
                } else if (std.mem.indexOf(u8, part_headers, "name=\"body\"")) |_| {
                    upload_data.body = try self.allocator.dupe(u8, content);
                } else if (std.mem.indexOf(u8, part_headers, "name=\"draft\"")) |_| {
                    upload_data.draft = std.mem.eql(u8, content, "true");
                } else if (std.mem.indexOf(u8, part_headers, "name=\"prerelease\"")) |_| {
                    upload_data.prerelease = std.mem.eql(u8, content, "true");
                } else if (std.mem.indexOf(u8, part_headers, "name=\"file\"")) |_| {
                    // Extract filename
                    if (std.mem.indexOf(u8, part_headers, "filename=\"")) |filename_start| {
                        const filename_content_start = filename_start + 10;
                        if (std.mem.indexOf(u8, part_headers[filename_content_start..], "\"")) |filename_end| {
                            upload_data.filename = try self.allocator.dupe(u8, part_headers[filename_content_start..filename_content_start + filename_end]);
                        }
                    }
                    
                    // Extract content type
                    if (std.mem.indexOf(u8, part_headers, "Content-Type: ")) |ct_start| {
                        const ct_content_start = ct_start + 14;
                        if (std.mem.indexOf(u8, part_headers[ct_content_start..], "\r\n")) |ct_end| {
                            upload_data.content_type = try self.allocator.dupe(u8, part_headers[ct_content_start..ct_content_start + ct_end]);
                        }
                    }
                    
                    upload_data.file_data = try self.allocator.dupe(u8, content);
                    has_file = true;
                }
            }
        }

        if (!has_file) return error.MissingFile;
        if (!has_tag_name) return error.MissingTagName;

        return upload_data;
    }

    fn extractBoundary(self: *Server, headers: []const u8) ?[]u8 {
        // Find Content-Type header with boundary
        const content_type_start = std.mem.indexOf(u8, headers, "Content-Type: multipart/form-data") orelse return null;
        const boundary_start = std.mem.indexOf(u8, headers[content_type_start..], "boundary=") orelse return null;
        const boundary_value_start = content_type_start + boundary_start + 9;
        
        // Find end of boundary (either \r\n or end of headers)
        const line_end = std.mem.indexOf(u8, headers[boundary_value_start..], "\r\n") orelse headers.len - boundary_value_start;
        const boundary_value = headers[boundary_value_start..boundary_value_start + line_end];
        
        return self.allocator.dupe(u8, boundary_value) catch null;
    }

    fn freeUploadData(self: *Server, upload_data: types.UploadData) void {
        if (upload_data.owner.len > 0) self.allocator.free(upload_data.owner);
        if (upload_data.repo.len > 0) self.allocator.free(upload_data.repo);
        if (upload_data.tag_name.len > 0) self.allocator.free(upload_data.tag_name);
        if (upload_data.name) |name| self.allocator.free(name);
        if (upload_data.body) |body| self.allocator.free(body);
        if (upload_data.file_data.len > 0) self.allocator.free(upload_data.file_data);
        if (upload_data.filename.len > 0) self.allocator.free(upload_data.filename);
        if (upload_data.content_type.len > 0) self.allocator.free(upload_data.content_type);
    }

    // Ziglibs API handlers
    fn handleZiglibsSync(self: *Server, stream: std.net.Stream, request: []const u8) !void {
        // Check authentication
        const user = try self.requireAuth(stream, request);
        if (user == null) return; // Error already sent by requireAuth
        
        const u = user.?;
        defer self.allocator.free(u.username);
        
        std.log.info("🔄 Starting Ziglibs sync requested by user: {s}", .{u.username});
        
        const imported_count = self.syncZiglibs() catch |err| {
            std.log.err("Failed to sync Ziglibs: {}", .{err});
            try self.serveJsonError(stream, 500, "Failed to sync Ziglibs packages");
            return;
        };
        
        const response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "success": true,
            \\  "imported_count": {},
            \\  "message": "Successfully imported {} Ziglibs packages"
            \\}}
        , .{ imported_count, imported_count });
        defer self.allocator.free(response);
        
        try self.serveJson(stream, 200, response);
    }

    fn handleZiglibsPackages(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse query parameters for pagination
        var limit: ?usize = 50;
        var offset: ?usize = 0;
        
        if (std.mem.indexOf(u8, path, "?")) |query_start| {
            const query = path[query_start + 1..];
            var params = std.mem.splitScalar(u8, query, '&');
            
            while (params.next()) |param| {
                if (std.mem.startsWith(u8, param, "limit=")) {
                    limit = std.fmt.parseInt(usize, param[6..], 10) catch 50;
                } else if (std.mem.startsWith(u8, param, "offset=")) {
                    offset = std.fmt.parseInt(usize, param[7..], 10) catch 0;
                }
            }
        }
        
        const packages = self.database.listZiglibsPackages(limit, offset) catch |err| {
            std.log.err("Failed to list Ziglibs packages: {}", .{err});
            try self.serveJsonError(stream, 500, "Failed to fetch Ziglibs packages");
            return;
        };
        defer {
            // Note: Mock database returns static strings, no need to free individual fields
            // for (packages) |pkg| {
            //     if (pkg.owner) |o| self.allocator.free(o);
            //     if (pkg.repo) |r| self.allocator.free(r);
            //     if (pkg.description) |desc| self.allocator.free(desc);
            //     if (pkg.license) |license| self.allocator.free(license);
            //     if (pkg.homepage) |homepage| self.allocator.free(homepage);
            //     if (pkg.github_url) |url| self.allocator.free(url);
            // }
            self.allocator.free(packages);
        }
        
        const total_count = self.database.countZiglibsPackages() catch 0;
        
        // Build JSON response
        var json_packages = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_packages.deinit();
        
        try json_packages.appendSlice("[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_packages.appendSlice(",");
            
            const pkg_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "owner": "{s}",
                \\  "repo": "{s}",
                \\  "description": "{s}",
                \\  "license": "{s}",
                \\  "homepage": "{s}",
                \\  "github_url": "{s}",
                \\  "github_stars": {},
                \\  "source": "ziglibs"
                \\}}
            , .{
                pkg.owner orelse "",
                pkg.repo orelse "",
                pkg.description orelse "",
                pkg.license orelse "",
                pkg.homepage orelse "",
                pkg.github_url orelse "",
                pkg.github_stars,
            });
            defer self.allocator.free(pkg_json);
            
            try json_packages.appendSlice(pkg_json);
        }
        try json_packages.appendSlice("]");
        
        const response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "packages": {s},
            \\  "total_count": {},
            \\  "limit": {},
            \\  "offset": {}
            \\}}
        , .{ json_packages.items, total_count, limit orelse 50, offset orelse 0 });
        defer self.allocator.free(response);
        
        try self.serveJson(stream, 200, response);
    }

    // build.zig.zon integration endpoints
    fn handlePackageZon(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse /api/packages/{name}/zon
        const prefix = "/api/packages/";
        const suffix = "/zon";
        
        if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) {
            return self.serveJsonError(stream, 404, "Not Found");
        }
        
        const name_start = prefix.len;
        const name_end = path.len - suffix.len;
        const package_name = path[name_start..name_end];
        
        // For now, return a mock .zon format
        const zon_response = try std.fmt.allocPrint(self.allocator,
            \\.{{
            \\    .name = "{s}",
            \\    .version = "0.1.0",
            \\    .dependencies = .{{
            \\        .{s} = .{{
            \\            .url = "https://zig.cktech.org/api/packages/{s}/tarball/0.1.0",
            \\            .hash = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            \\        }},
            \\    }},
            \\}}
        , .{ package_name, package_name, package_name });
        defer self.allocator.free(zon_response);
        
        const full_response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
            .{ zon_response.len, zon_response }
        );
        defer self.allocator.free(full_response);
        
        _ = try stream.write(full_response);
    }
    
    fn handlePackageTarball(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse /api/packages/{name}/tarball/{version}
        const prefix = "/api/packages/";
        const tarball_marker = "/tarball/";
        
        const name_start = prefix.len;
        const tarball_pos = std.mem.indexOf(u8, path, tarball_marker) orelse {
            return self.serveJsonError(stream, 404, "Not Found");
        };
        
        const package_name = path[name_start..tarball_pos];
        const version = path[tarball_pos + tarball_marker.len..];
        
        // For now, redirect to a mock tarball URL
        const redirect_url = try std.fmt.allocPrint(self.allocator,
            "https://github.com/ziglibs/{s}/archive/refs/tags/v{s}.tar.gz",
            .{ package_name, version }
        );
        defer self.allocator.free(redirect_url);
        
        const response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 302 Found\r\n" ++
            "Location: {s}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n",
            .{redirect_url}
        );
        defer self.allocator.free(response);
        
        _ = try stream.write(response);
    }
    
    fn handlePackageHash(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse /api/packages/{name}/hash/{version}
        const prefix = "/api/packages/";
        const hash_marker = "/hash/";
        
        const name_start = prefix.len;
        const hash_pos = std.mem.indexOf(u8, path, hash_marker) orelse {
            return self.serveJsonError(stream, 404, "Not Found");
        };
        
        const package_name = path[name_start..hash_pos];
        const version = path[hash_pos + hash_marker.len..];
        
        _ = package_name;
        _ = version;
        
        // For now, return a mock hash
        const hash = "1220" ++ "abcdef0123456789" ** 4; // Mock SHA256 hash in hex
        
        const response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n" ++
            "{s}",
            .{ hash.len, hash }
        );
        defer self.allocator.free(response);
        
        _ = try stream.write(response);
    }
    
    fn handleDependencyResolve(self: *Server, stream: std.net.Stream, path: []const u8, request: []const u8) !void {
        _ = path;
        
        // Parse the POST body to get dependency requirements
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            return self.serveJsonError(stream, 400, "Bad Request");
        };
        const body = request[body_start + 4..];
        
        // For now, return a simple resolution
        const resolution = if (body.len > 0)
            \\{
            \\  "resolved": true,
            \\  "packages": [
            \\    {
            \\      "name": "example",
            \\      "version": "0.1.0",
            \\      "url": "https://zig.cktech.org/api/packages/example/tarball/0.1.0",
            \\      "hash": "1220abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
            \\    }
            \\  ]
            \\}
        else
            \\{
            \\  "resolved": false,
            \\  "error": "No dependencies provided"
            \\}
        ;
        
        try self.serveJson(stream, 200, resolution);
    }
    
    // OAuth/OIDC Authentication Handlers
    const unified_auth = @import("../auth/unified_auth.zig");
    
    fn handleMicrosoftLogin(self: *Server, stream: std.net.Stream) !void {
        // Initialize unified auth system
        var auth_system = unified_auth.UnifiedAuthSystem.init(self.allocator) catch {
            return self.serveJsonError(stream, 500, "Authentication system not configured");
        };
        defer auth_system.deinit();
        
        // Get authorization URL (Microsoft OIDC handles its own state parameter)
        const auth_url = auth_system.getAuthorizationUrl(.microsoft) catch {
            return self.serveJsonError(stream, 500, "Failed to generate authorization URL");
        };
        defer self.allocator.free(auth_url);
        
        // Redirect to Microsoft OAuth (no additional state needed, OIDC client handles it)
        const redirect_response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 302 Found\r\n" ++
            "Location: {s}\r\n" ++
            "\r\n",
            .{auth_url}
        );
        defer self.allocator.free(redirect_response);
        
        _ = try stream.write(redirect_response);
    }
    
    fn handleMicrosoftCallback(self: *Server, stream: std.net.Stream, path: []const u8, request: []const u8) !void {
        _ = request; // Microsoft OIDC doesn't need cookie-based state validation
        
        // Parse the authorization code from query parameters
        const query_start = std.mem.indexOf(u8, path, "?") orelse {
            return self.serveJsonError(stream, 400, "Missing authorization code");
        };
        const query = path[query_start + 1..];
        
        var code: ?[]const u8 = null;
        var state: ?[]const u8 = null;
        var error_param: ?[]const u8 = null;
        
        var params = std.mem.splitSequence(u8, query, "&");
        while (params.next()) |param| {
            if (std.mem.startsWith(u8, param, "code=")) {
                code = param[5..];
            } else if (std.mem.startsWith(u8, param, "state=")) {
                state = param[6..];
            } else if (std.mem.startsWith(u8, param, "error=")) {
                error_param = param[6..];
            }
        }
        
        if (error_param) |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "OAuth error: {s}", .{err});
            defer self.allocator.free(error_msg);
            return self.serveJsonError(stream, 400, error_msg);
        }
        
        const auth_code = code orelse {
            return self.serveJsonError(stream, 400, "Missing authorization code");
        };
        
        // For Microsoft OIDC, state validation is handled by the OIDC flow itself
        // We validate that a state parameter was provided but don't need to match against cookies
        if (state == null) {
            return self.serveJsonError(stream, 400, "Missing OAuth state parameter");
        }
        
        // Initialize unified auth system
        var auth_system = unified_auth.UnifiedAuthSystem.init(self.allocator) catch {
            return self.serveJsonError(stream, 500, "Authentication system not configured");
        };
        defer auth_system.deinit();
        
        // Exchange code for user info
        const user = auth_system.handleCallback(.microsoft, auth_code) catch {
            return self.serveJsonError(stream, 500, "Failed to exchange authorization code");
        };
        
        // Create JWT token
        const jwt_token = auth_system.createJWT(user) catch {
            return self.serveJsonError(stream, 500, "Failed to create session token");
        };
        defer self.allocator.free(jwt_token);
        
        // Redirect to success page with token
        const success_response = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: text/html
            \\Set-Cookie: zepplin_token={s}; HttpOnly; Path=/; Max-Age=86400
            \\
            \\<!DOCTYPE html>
            \\<html><head><title>Login Success</title></head>
            \\<body>
            \\<h2>Login Successful!</h2>
            \\<p>Welcome, {s}! You can close this window.</p>
            \\<script>
            \\localStorage.setItem('zepplin_token', '{s}');
            \\localStorage.setItem('zepplin_username', '{s}');
            \\localStorage.setItem('zepplin_display_name', '{s}');
            \\localStorage.setItem('zepplin_avatar_url', '{s}');
            \\localStorage.setItem('zepplin_email', '{s}');
            \\setTimeout(() => window.location.href = '/', 2000);
            \\</script>
            \\</body></html>
        ,
            .{ 
                jwt_token, 
                user.display_name orelse user.username, 
                jwt_token, 
                user.username,
                user.display_name orelse user.username,
                user.avatar_url orelse "",
                user.email
            }
        );
        defer self.allocator.free(success_response);
        
        _ = try stream.write(success_response);
    }
    
    fn handleGitHubLogin(self: *Server, stream: std.net.Stream) !void {
        // Initialize unified auth system
        var auth_system = unified_auth.UnifiedAuthSystem.init(self.allocator) catch {
            return self.serveJsonError(stream, 500, "Authentication system not configured");
        };
        defer auth_system.deinit();
        
        // Get authorization URL
        const auth_url = auth_system.getAuthorizationUrl(.github) catch {
            return self.serveJsonError(stream, 500, "Failed to generate authorization URL");
        };
        defer self.allocator.free(auth_url);
        
        // Generate random state parameter for CSRF protection
        var state_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&state_bytes);
        const state = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.bytesToHex(&state_bytes, .lower)});
        defer self.allocator.free(state);
        
        // Redirect to GitHub OAuth
        const redirect_response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 302 Found\r\n" ++
            "Location: {s}&state={s}\r\n" ++
            "Set-Cookie: oauth_state={s}; HttpOnly; Path=/; Max-Age=600\r\n" ++
            "\r\n",
            .{ auth_url, state, state }
        );
        defer self.allocator.free(redirect_response);
        
        _ = try stream.write(redirect_response);
    }
    
    fn handleGitHubCallback(self: *Server, stream: std.net.Stream, path: []const u8, request: []const u8) !void {
        
        // Parse the authorization code from query parameters
        const query_start = std.mem.indexOf(u8, path, "?") orelse {
            return self.serveJsonError(stream, 400, "Missing authorization code");
        };
        const query = path[query_start + 1..];
        
        var code: ?[]const u8 = null;
        var state: ?[]const u8 = null;
        var error_param: ?[]const u8 = null;
        
        var params = std.mem.splitSequence(u8, query, "&");
        while (params.next()) |param| {
            if (std.mem.startsWith(u8, param, "code=")) {
                code = param[5..];
            } else if (std.mem.startsWith(u8, param, "state=")) {
                state = param[6..];
            } else if (std.mem.startsWith(u8, param, "error=")) {
                error_param = param[6..];
            }
        }
        
        if (error_param) |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "OAuth error: {s}", .{err});
            defer self.allocator.free(error_msg);
            return self.serveJsonError(stream, 400, error_msg);
        }
        
        const auth_code = code orelse {
            return self.serveJsonError(stream, 400, "Missing authorization code");
        };
        
        // Validate state parameter for CSRF protection
        if (state) |provided_state| {
            // Extract state from cookie
            const cookie_start = std.mem.indexOf(u8, request, "Cookie: ") orelse {
                return self.serveJsonError(stream, 400, "Missing session cookie");
            };
            const cookie_line_end = std.mem.indexOf(u8, request[cookie_start..], "\r\n") orelse {
                return self.serveJsonError(stream, 400, "Invalid cookie header");
            };
            const cookie_line = request[cookie_start + 8..cookie_start + cookie_line_end];
            
            // Look for oauth_state cookie
            const state_cookie_start = std.mem.indexOf(u8, cookie_line, "oauth_state=") orelse {
                return self.serveJsonError(stream, 400, "Missing OAuth state cookie");
            };
            const state_value_start = state_cookie_start + 12;
            const remainder = cookie_line[state_value_start..];
            const semicolon_pos = std.mem.indexOf(u8, remainder, ";");
            const state_value_end = semicolon_pos orelse remainder.len;
            const expected_state = remainder[0..state_value_end];
            
            if (!std.mem.eql(u8, provided_state, expected_state)) {
                return self.serveJsonError(stream, 400, "Invalid OAuth state parameter - possible CSRF attack");
            }
        } else {
            return self.serveJsonError(stream, 400, "Missing OAuth state parameter");
        }
        
        // Initialize unified auth system
        var auth_system = unified_auth.UnifiedAuthSystem.init(self.allocator) catch {
            return self.serveJsonError(stream, 500, "Authentication system not configured");
        };
        defer auth_system.deinit();
        
        // Exchange code for user info
        const user = auth_system.handleCallback(.github, auth_code) catch {
            return self.serveJsonError(stream, 500, "Failed to exchange authorization code");
        };
        
        // Create JWT token
        const jwt_token = auth_system.createJWT(user) catch {
            return self.serveJsonError(stream, 500, "Failed to create session token");
        };
        defer self.allocator.free(jwt_token);
        
        // Redirect to success page with token
        const success_response = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: text/html
            \\Set-Cookie: zepplin_token={s}; HttpOnly; Path=/; Max-Age=86400
            \\
            \\<!DOCTYPE html>
            \\<html><head><title>Login Success</title></head>
            \\<body>
            \\<h2>Login Successful!</h2>
            \\<p>Welcome, {s}! You can close this window.</p>
            \\<script>
            \\localStorage.setItem('zepplin_token', '{s}');
            \\localStorage.setItem('zepplin_username', '{s}');
            \\localStorage.setItem('zepplin_display_name', '{s}');
            \\localStorage.setItem('zepplin_avatar_url', '{s}');
            \\localStorage.setItem('zepplin_email', '{s}');
            \\setTimeout(() => window.location.href = '/', 2000);
            \\</script>
            \\</body></html>
        ,
            .{ 
                jwt_token, 
                user.display_name orelse user.username, 
                jwt_token, 
                user.username,
                user.display_name orelse user.username,
                user.avatar_url orelse "",
                user.email
            }
        );
        defer self.allocator.free(success_response);
        
        _ = try stream.write(success_response);
    }
    
    // Comment API handlers
    fn handleCommentsApiV1(self: *Server, stream: std.net.Stream, path: []const u8, request: []const u8, request_allocator: std.mem.Allocator) !void {
        _ = request_allocator;
        
        // Parse HTTP method
        const method_end = std.mem.indexOf(u8, request, " ") orelse return self.serveJsonError(stream, 400, "Invalid request");
        const method = request[0..method_end];
        
        if (std.mem.eql(u8, method, "GET")) {
            // GET /api/v1/comments/{owner}/{repo}
            const path_parts = std.mem.splitSequence(u8, path[18..], "/"); // Skip "/api/v1/comments/"
            var parts_iter = path_parts;
            
            const owner = parts_iter.next() orelse return self.serveJsonError(stream, 400, "Missing owner");
            const repo = parts_iter.next() orelse return self.serveJsonError(stream, 400, "Missing repo");
            
            const package_id = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, repo });
            defer self.allocator.free(package_id);
            
            const comments = self.database.getCommentsForPackage(package_id) catch |err| {
                std.debug.print("Error getting comments: {}\n", .{err});
                return self.serveJsonError(stream, 500, "Failed to get comments");
            };
            defer self.allocator.free(comments);
            
            // Convert comments to JSON using simple string formatting
            var json_parts = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
            defer json_parts.deinit();
            
            try json_parts.append("{\"comments\":[");
            
            for (comments, 0..) |comment, i| {
                if (i > 0) try json_parts.append(",");
                
                const comment_json = try std.fmt.allocPrint(self.allocator,
                    "{{\"id\":{},\"package_id\":\"{s}\",\"user_id\":{},\"username\":\"{s}\",\"display_name\":\"{s}\",\"content\":\"{s}\",\"created_at\":{},\"updated_at\":{},\"parent_id\":{}}}",
                    .{
                        comment.id,
                        comment.package_id,
                        comment.user_id,
                        comment.username,
                        comment.display_name orelse "",
                        comment.content,
                        comment.created_at,
                        comment.updated_at,
                        comment.parent_id orelse 0
                    });
                defer self.allocator.free(comment_json);
                
                try json_parts.append(try self.allocator.dupe(u8, comment_json));
            }
            
            try json_parts.append("]}");
            
            const json_response = try std.mem.join(self.allocator, "", json_parts.items);
            defer self.allocator.free(json_response);
            
            // Free individual parts (skip the first and last static strings)
            for (json_parts.items, 0..) |part, i| {
                // Free allocated comment JSON strings, but not the static parts
                if (i > 0 and i < json_parts.items.len - 1 and !std.mem.eql(u8, part, ",")) {
                    self.allocator.free(part);
                }
            }
            
            try self.serveJson(stream, 200, json_response);
            
        } else if (std.mem.eql(u8, method, "POST")) {
            // POST /api/v1/comments/{owner}/{repo}
            const user = try self.requireAuth(stream, request);
            if (user == null) return;
            
            const u = user.?;
            defer self.allocator.free(u.username);
            defer self.allocator.free(u.email);
            defer self.allocator.free(u.display_name);
            defer self.allocator.free(u.avatar_url);
            defer self.allocator.free(u.provider);
            
            const path_parts = std.mem.splitSequence(u8, path[18..], "/"); // Skip "/api/v1/comments/"
            var parts_iter = path_parts;
            
            const owner = parts_iter.next() orelse return self.serveJsonError(stream, 400, "Missing owner");
            const repo = parts_iter.next() orelse return self.serveJsonError(stream, 400, "Missing repo");
            
            // Extract JSON body from request
            const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return self.serveJsonError(stream, 400, "No request body");
            const body = request[body_start + 4..];
            
            // Simple JSON parsing for content field with better error handling
            const content_start = std.mem.indexOf(u8, body, "\"content\":\"") orelse {
                return self.serveJsonError(stream, 400, "Missing 'content' field in request body");
            };
            const content_value_start = content_start + 11;
            
            // Look for the closing quote, handling potential escaping
            var content_end: usize = 0;
            var i = content_value_start;
            while (i < body.len) {
                if (body[i] == '"' and (i == content_value_start or body[i-1] != '\\')) {
                    content_end = i - content_value_start;
                    break;
                }
                i += 1;
            }
            
            if (content_end == 0) {
                return self.serveJsonError(stream, 400, "Malformed JSON: unterminated content string");
            }
            
            const content = body[content_value_start..content_value_start + content_end];
            
            // Validate content
            if (content.len == 0) {
                return self.serveJsonError(stream, 400, "Comment content cannot be empty");
            }
            if (content.len > 2000) {
                return self.serveJsonError(stream, 400, "Comment content too long (max 2000 characters)");
            }
            
            // Basic sanitization - reject comments with suspicious content
            if (std.mem.indexOf(u8, content, "<script") != null or 
               std.mem.indexOf(u8, content, "javascript:") != null) {
                return self.serveJsonError(stream, 400, "Comment content contains forbidden elements");
            }
            
            const package_id = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ owner, repo });
            defer self.allocator.free(package_id);
            
            const comment_request = types.CommentRequest{
                .package_id = package_id,
                .content = content,
                .parent_id = null, // TODO: Support for replies
            };
            
            const comment_id = self.database.addComment(comment_request, @intCast(u.user_id), u.username, u.display_name) catch |err| {
                std.debug.print("Error adding comment: {}\n", .{err});
                return self.serveJsonError(stream, 500, "Failed to add comment");
            };
            
            const json_response = try std.fmt.allocPrint(self.allocator,
                "{{\"success\":true,\"comment_id\":{},\"message\":\"Comment added successfully\"}}",
                .{comment_id}
            );
            defer self.allocator.free(json_response);
            
            try self.serveJson(stream, 201, json_response);
            
        } else {
            return self.serveJsonError(stream, 405, "Method not allowed");
        }
    }
    
    fn handlePackagePage(self: *Server, stream: std.net.Stream, path: []const u8) !void {
        // Parse package path: /packages/{owner}/{repo}
        const path_after_packages = path[10..]; // Skip "/packages/"
        var path_parts = std.mem.splitSequence(u8, path_after_packages, "/");
        
        const owner = path_parts.next() orelse return self.serveJsonError(stream, 400, "Missing owner");
        const repo = path_parts.next() orelse return self.serveJsonError(stream, 400, "Missing repo");
        
        // For now, serve a simple HTML page - in production this would be templated
        const package_html = try std.fmt.allocPrint(self.allocator,
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\    <meta charset="UTF-8">
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <title>{s}/{s} - Zepplin Registry</title>
            \\    <link rel="stylesheet" href="/css/style.css">
            \\</head>
            \\<body>
            \\    <header class="header">
            \\        <div class="container">
            \\            <div class="header-content">
            \\                <div class="logo">
            \\                    <img src="/images/zepplin-logo.svg" alt="Zepplin" class="logo-img">
            \\                </div>
            \\                <nav class="nav">
            \\                    <a href="/" class="nav-link">Home</a>
            \\                    <a href="/packages" class="nav-link">Browse</a>
            \\                    <a href="/trending" class="nav-link">Trending</a>
            \\                    <a href="/docs" class="nav-link">Docs</a>
            \\                    <div id="auth-nav"></div>
            \\                </nav>
            \\            </div>
            \\        </div>
            \\    </header>
            \\    <div class="container" style="margin-top: 2rem;">
            \\        <h1>{s}/{s}</h1>
            \\        <p>Package details would go here...</p>
            \\        
            \\        <div id="comments-section" style="margin-top: 3rem;">
            \\            <h2>Comments</h2>
            \\            <div id="comments-list"></div>
            \\            <div id="comment-form" style="margin-top: 2rem; display: none;">
            \\                <textarea id="comment-content" placeholder="Add a comment..." rows="4" style="width: 100%%; padding: 0.5rem;"></textarea>
            \\                <br><br>
            \\                <button id="submit-comment" style="background: var(--lightning-400); color: var(--bg-primary); padding: 0.5rem 1rem; border: none; border-radius: 0.25rem; cursor: pointer;">Post Comment</button>
            \\            </div>
            \\        </div>
            \\    </div>
            \\    
            \\    <script src="/js/main.js"></script>
            \\    <script>
            \\        const packageId = '{s}/{s}';
            \\        
            \\        async function loadComments() {{
            \\            try {{
            \\                const response = await fetch(`/api/v1/comments/${{packageId}}`);
            \\                const data = await response.json();
            \\                const commentsList = document.getElementById('comments-list');
            \\                
            \\                if (data.comments && data.comments.length > 0) {{
            \\                    commentsList.innerHTML = data.comments.map(comment => `
            \\                        <div style="border: 1px solid var(--border-subtle); padding: 1rem; margin-bottom: 1rem; border-radius: 0.5rem;">
            \\                            <div style="font-weight: 600; color: var(--lightning-400);">${{comment.display_name || comment.username}}</div>
            \\                            <div style="font-size: 0.875rem; color: var(--text-muted); margin-bottom: 0.5rem;">
            \\                                ${{new Date(comment.created_at * 1000).toLocaleString()}}
            \\                            </div>
            \\                            <div>${{comment.content}}</div>
            \\                        </div>
            \\                    `).join('');
            \\                }} else {{
            \\                    commentsList.innerHTML = '<p style="color: var(--text-muted);">No comments yet. Be the first to comment!</p>';
            \\                }}
            \\            }} catch (error) {{
            \\                console.error('Failed to load comments:', error);
            \\            }}
            \\        }}
            \\        
            \\        function checkAuth() {{
            \\            const token = localStorage.getItem('zepplin_token');
            \\            const commentForm = document.getElementById('comment-form');
            \\            if (token) {{
            \\                commentForm.style.display = 'block';
            \\            }}
            \\        }}
            \\        
            \\        async function submitComment() {{
            \\            const content = document.getElementById('comment-content').value.trim();
            \\            const token = localStorage.getItem('zepplin_token');
            \\            
            \\            if (!content) {{
            \\                alert('Please enter a comment');
            \\                return;
            \\            }}
            \\            
            \\            try {{
            \\                const response = await fetch(`/api/v1/comments/${{packageId}}`, {{
            \\                    method: 'POST',
            \\                    headers: {{
            \\                        'Content-Type': 'application/json',
            \\                        'Authorization': `Bearer ${{token}}`
            \\                    }},
            \\                    body: JSON.stringify({{ content }})
            \\                }});
            \\                
            \\                if (response.ok) {{
            \\                    document.getElementById('comment-content').value = '';
            \\                    loadComments();
            \\                }} else {{
            \\                    const error = await response.text();
            \\                    alert('Failed to post comment: ' + error);
            \\                }}
            \\            }} catch (error) {{
            \\                console.error('Failed to submit comment:', error);
            \\                alert('Failed to post comment');
            \\            }}
            \\        }}
            \\        
            \\        document.addEventListener('DOMContentLoaded', () => {{
            \\            loadComments();
            \\            checkAuth();
            \\            
            \\            document.getElementById('submit-comment').addEventListener('click', submitComment);
            \\        }});
            \\    </script>
            \\</body>
            \\</html>
        , .{ owner, repo, owner, repo, owner, repo });
        defer self.allocator.free(package_html);
        
        const response = try std.fmt.allocPrint(self.allocator,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
            .{ package_html.len, package_html }
        );
        defer self.allocator.free(response);
        
        _ = try stream.write(response);
    }
};
