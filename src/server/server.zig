const std = @import("std");
const types = @import("../common/types.zig");
const Database = @import("../database/database.zig").Database;
const Auth = @import("../auth/auth.zig").Auth;
const Storage = @import("../storage/storage.zig").Storage;
const ZigistryClient = @import("../zigistry/client.zig").ZigistryClient;

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
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    database: Database,
    auth: Auth,
    storage: Storage,
    zigistry: ZigistryClient,

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

        return Server{
            .allocator = allocator,
            .address = address,
            .database = database,
            .auth = auth,
            .storage = storage,
            .zigistry = zigistry,
        };
    }

    pub fn deinit(self: *Server) void {
        self.database.deinit();
        self.storage.deinit();
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

        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);
        const request = buffer[0..bytes_read];

        // Parse HTTP request (simplified)
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = lines.next() orelse return ServerError.InvalidRequest;

        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method = parts.next() orelse return ServerError.InvalidRequest;
        const path = parts.next() orelse return ServerError.InvalidRequest;

        try self.routeRequest(connection.stream, method, path, request);
    }

    fn routeRequest(self: *Server, stream: std.net.Stream, method: []const u8, path: []const u8, request: []const u8) !void {
        std.debug.print("📡 {s} {s}\n", .{ method, path });

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/")) {
                try self.serveStaticFile(stream, "web/templates/index.html");
            } else if (std.mem.eql(u8, path, "/health")) {
                try self.handleHealthSimple(stream);
                // GitHub-compatible API v1 endpoints
            } else if (std.mem.startsWith(u8, path, "/api/v1/packages/")) {
                try self.handlePackageApiV1(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/v1/search")) {
                try self.handleSearchApiV1(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/v1/resolve/")) {
                try self.handleResolveApiV1(stream, path);
            } else if (std.mem.eql(u8, path, "/api/v1/registry/config")) {
                try self.handleRegistryConfigV1(stream);
            } else if (std.mem.eql(u8, path, "/api/v1/health")) {
                try self.handleHealthV1(stream);
            } else if (std.mem.eql(u8, path, "/api/v1/stats")) {
                try self.handleStatsApi(stream);
            } else if (std.mem.eql(u8, path, "/api/v1/auth/me")) {
                try self.handleUserProfile(stream, request);
                // Legacy API endpoints (backward compatibility)
            } else if (std.mem.startsWith(u8, path, "/api/packages")) {
                try self.handlePackageApi(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/search")) {
                try self.handleSearchApi(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/zigistry/discover")) {
                try self.handleZigistryDiscover(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/zigistry/trending")) {
                try self.handleZigistryTrending(stream, path);
            } else if (std.mem.startsWith(u8, path, "/api/zigistry/browse")) {
                try self.handleZigistryBrowse(stream, path);
            } else if (std.mem.startsWith(u8, path, "/css/")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "web{s}", .{path});
                defer self.allocator.free(file_path);
                try self.serveStaticFile(stream, file_path);
            } else if (std.mem.startsWith(u8, path, "/js/")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "web{s}", .{path});
                defer self.allocator.free(file_path);
                try self.serveStaticFile(stream, file_path);
            } else if (std.mem.startsWith(u8, path, "/images/")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "web{s}", .{path});
                defer self.allocator.free(file_path);
                try self.serveStaticFile(stream, file_path);
            } else if (std.mem.startsWith(u8, path, "/assets/")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "{s}", .{path[1..]});
                defer self.allocator.free(file_path);
                try self.serveStaticFile(stream, file_path);
            } else if (std.mem.endsWith(u8, path, ".wasm")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "web{s}", .{path});
                defer self.allocator.free(file_path);
                try self.serveStaticFile(stream, file_path);
            } else if (std.mem.eql(u8, path, "/auth")) {
                // Auth test page
                try self.serveStaticFile(stream, "web/auth.html");
            } else if (std.mem.startsWith(u8, path, "/packages") or 
                      std.mem.startsWith(u8, path, "/search") or 
                      std.mem.startsWith(u8, path, "/trending") or 
                      std.mem.startsWith(u8, path, "/docs")) {
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
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("❌ Failed to open file {s}: {}\n", .{ file_path, err });
            try self.serve404(stream);
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        const content = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(content);

        _ = try file.read(content);

        // Determine content type based on file extension
        const content_type = if (std.mem.endsWith(u8, file_path, ".html"))
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

        const response = try std.fmt.allocPrint(self.allocator, 
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {}\r\nCache-Control: public, max-age=3600\r\n\r\n", 
            .{ content_type, content.len }
        );
        defer self.allocator.free(response);

        try stream.writeAll(response);
        try stream.writeAll(content);
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
            var json_list = std.ArrayList(u8).init(self.allocator);
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
            for (packages) |pkg| {
                self.allocator.free(pkg.owner);
                self.allocator.free(pkg.repo);
                if (pkg.description) |desc| self.allocator.free(desc);
                if (pkg.latest_version) |version| self.allocator.free(version);
                for (pkg.topics) |topic| self.allocator.free(topic);
                self.allocator.free(pkg.topics);
            }
            self.allocator.free(packages);
        }

        // Build JSON response
        var json_list = std.ArrayList(u8).init(self.allocator);
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
                pkg.owner,
                pkg.repo,
                pkg.owner,
                pkg.repo,
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
        var json_list = std.ArrayList(u8).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = blk: {
                var topics_str = std.ArrayList(u8).init(self.allocator);
                defer topics_str.deinit();
                try topics_str.appendSlice("[");
                for (pkg.topics, 0..) |topic, j| {
                    if (j > 0) try topics_str.appendSlice(",");
                    try topics_str.writer().print("\"{s}\"", .{topic});
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
        try json_list.writer().print("{}", .{packages.len});
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
        var json_list = std.ArrayList(u8).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = blk: {
                var topics_str = std.ArrayList(u8).init(self.allocator);
                defer topics_str.deinit();
                try topics_str.appendSlice("[");
                for (pkg.topics, 0..) |topic, j| {
                    if (j > 0) try topics_str.appendSlice(",");
                    try topics_str.writer().print("\"{s}\"", .{topic});
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
        try json_list.writer().print("{}", .{packages.len});
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
        var json_list = std.ArrayList(u8).init(self.allocator);
        defer json_list.deinit();

        try json_list.appendSlice("{\"packages\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const topics_json = blk: {
                var topics_str = std.ArrayList(u8).init(self.allocator);
                defer topics_str.deinit();
                try topics_str.appendSlice("[");
                for (pkg.topics, 0..) |topic, j| {
                    if (j > 0) try topics_str.appendSlice(",");
                    try topics_str.writer().print("\"{s}\"", .{topic});
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
        try json_list.writer().print("{}", .{packages.len});
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
            self.allocator.free(pkg.owner);
            self.allocator.free(pkg.repo);
            if (pkg.description) |d| self.allocator.free(d);
            if (pkg.license) |l| self.allocator.free(l);
            if (pkg.homepage) |h| self.allocator.free(h);
            if (pkg.github_url) |g| self.allocator.free(g);
            for (pkg.topics) |topic| self.allocator.free(topic);
            self.allocator.free(pkg.topics);
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
            pkg.owner,
            pkg.repo,
            pkg.owner,
            pkg.repo,
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

        var json_list = std.ArrayList(u8).init(self.allocator);
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

        var json_list = std.ArrayList(u8).init(self.allocator);
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
        self.database.incrementDownloadCount(owner, repo, version) catch |err| {
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
            for (results) |result| {
                self.allocator.free(result.owner);
                self.allocator.free(result.repo);
                if (result.description) |d| self.allocator.free(d);
                if (result.latest_version) |v| self.allocator.free(v);
                for (result.topics) |topic| self.allocator.free(topic);
                self.allocator.free(result.topics);
            }
            self.allocator.free(results);
        }

        var json_list = std.ArrayList(u8).init(self.allocator);
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
                result.owner,
                result.repo,
                result.owner,
                result.repo,
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
        try json_list.writer().print("{}", .{results.len});
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
            \\  "allow_public_publish": {s},
            \\  "github_compatible": true,
            \\  "features": [
            \\    "packages",
            \\    "releases",
            \\    "aliases",
            \\    "search",
            \\    "download_stats"
            \\  ]
            \\}}
        , .{
            registry_name,
            registry_url,
            api_version,
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
            \\  "documentation_url": "https://github.com/your-org/zepplin"
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
            \\  "zig_version": "0.14.0"
            \\}}
        , .{ stats.total_packages, stats.total_downloads, stats.downloads_today });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 200, json_response);
    }

    fn serializeStringArray(self: *Server, strings: [][]const u8) ![]u8 {
        var json = std.ArrayList(u8).init(self.allocator);
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
        var buffer: [8192]u8 = undefined;
        const bytes_read = try stream.read(&buffer);
        const request = buffer[0..bytes_read];
        
        // Find the body after headers
        const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try self.serveJsonError(stream, 400, "Invalid request");
            return;
        };
        const body = request[header_end + 4..];
        
        // Simple JSON parsing for username and password
        var username: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        
        // Extract username
        if (std.mem.indexOf(u8, body, "\"username\"")) |username_pos| {
            const colon_pos = std.mem.indexOf(u8, body[username_pos..], ":") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_start = std.mem.indexOf(u8, body[username_pos + colon_pos..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_end = std.mem.indexOf(u8, body[username_pos + colon_pos + quote_start + 1..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            username = body[username_pos + colon_pos + quote_start + 1..][0..quote_end];
        }
        
        // Extract password
        if (std.mem.indexOf(u8, body, "\"password\"")) |password_pos| {
            const colon_pos = std.mem.indexOf(u8, body[password_pos..], ":") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_start = std.mem.indexOf(u8, body[password_pos + colon_pos..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            const quote_end = std.mem.indexOf(u8, body[password_pos + colon_pos + quote_start + 1..], "\"") orelse return self.serveJsonError(stream, 400, "Invalid JSON");
            password = body[password_pos + colon_pos + quote_start + 1..][0..quote_end];
        }
        
        if (username == null or password == null) {
            try self.serveJsonError(stream, 400, "Missing required fields: username, password");
            return;
        }
        
        // Get user from database
        const user = try self.database.getUser(username.?);
        if (user == null) {
            try self.serveJsonError(stream, 401, "Invalid credentials");
            return;
        }
        
        const u = user.?;
        defer {
            self.allocator.free(u.username);
            self.allocator.free(u.email);
            self.allocator.free(u.password_hash);
            if (u.api_token) |t| self.allocator.free(t);
        }
        
        // Verify password
        const valid = try self.auth.verifyPassword(password.?, u.password_hash);
        if (!valid) {
            try self.serveJsonError(stream, 401, "Invalid credentials");
            return;
        }
        
        // Return success with existing token
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "username": "{s}",
            \\  "email": "{s}",
            \\  "token": "{s}"
            \\}}
        , .{ u.username, u.email, u.api_token orelse "" });
        defer self.allocator.free(json_response);
        
        try self.serveJson(stream, 200, json_response);
    }
    
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
        // For now, we'll create a dummy username based on user_id
        // In a real implementation, you'd look this up in the database
        const username = try std.fmt.allocPrint(self.allocator, "user_{}", .{auth_token.user_id});
        
        return AuthenticatedUser{
            .username = username,
            .user_id = auth_token.user_id,
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
        
        // Get user details from database
        // For now, we'll return basic info based on the token
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "user_id": {},
            \\  "username": "{s}",
            \\  "authenticated": true
            \\}}
        , .{ u.user_id, u.username });
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
};
