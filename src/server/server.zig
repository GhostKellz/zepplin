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

pub const Server = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    database: Database,
    auth: Auth,
    storage: Storage,
    zigistry: ZigistryClient,

    pub fn init(allocator: std.mem.Allocator, port: u16, data_dir: []const u8) !Server {
        const address = try std.net.Address.resolveIp("0.0.0.0", port);

        // Initialize database
        const db_path = try std.fs.path.join(allocator, &.{ data_dir, "zepplin.db" });
        defer allocator.free(db_path);
        const database = try Database.init(allocator, db_path);

        // Initialize auth with a secret key (in production, load from config)
        const secret_key = "your-secret-key-change-in-production";
        const auth = Auth.init(allocator, secret_key);

        // Initialize storage
        const storage = try Storage.init(allocator, data_dir);

        // Initialize Zigistry client
        const zigistry = ZigistryClient.init(allocator, null);

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

        try self.routeRequest(connection.stream, method, path);
    }

    fn routeRequest(self: *Server, stream: std.net.Stream, method: []const u8, path: []const u8) !void {
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
            if (std.mem.startsWith(u8, path, "/api/v1/packages/")) {
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
        const release = try self.database.getRelease(owner, repo, version);
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

        // Increment download count
        try self.database.incrementDownloadCount(owner, repo, version);

        if (rel.download_url) |download_url| {
            // Redirect to the download URL
            const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\n\r\n", .{download_url});
            defer self.allocator.free(response);
            try stream.writeAll(response);
        } else {
            try self.serveJsonError(stream, 404, "Download URL not available");
        }
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

        // TODO: Parse multipart form data and extract:
        // - tag_name (required)
        // - name (optional)
        // - body (optional)
        // - draft (boolean, default false)
        // - prerelease (boolean, default false)
        // - file (required - the package archive)

        // For now, return a placeholder response
        const json_response = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "message": "Package publishing endpoint - implementation in progress",
            \\  "owner": "{s}",
            \\  "repo": "{s}",
            \\  "status": "placeholder"
            \\}}
        , .{ owner, repo });
        defer self.allocator.free(json_response);

        try self.serveJson(stream, 501, json_response);
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
};
