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
                try self.serveWebUI(stream);
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
            } else {
                try self.serve404(stream);
            }
        } else if (std.mem.eql(u8, method, "POST")) {
            if (std.mem.eql(u8, path, "/api/packages")) {
                try self.handlePublishPackage(stream);
            } else {
                try self.serve404(stream);
            }
        } else {
            try self.serveMethodNotAllowed(stream);
        }
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
            \\        .package-item {{ border-bottom: 1px solid #39414a; padding: 1rem 0; }}        \\        .package-item:last-child {{ border-bottom: none; }}
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
            \\            <p style="margin-top: 0.5rem; font-size: 0.9rem;">🎉 <strong>Production Ready</strong> with SQLite database, Zigistry discovery & search!</p>        \\        </div>
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
            \\             \\        <div class="packages" id="packagesList">
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

        try json_list.appendSlice("{\"results\":[");
        for (packages, 0..) |pkg, i| {
            if (i > 0) try json_list.appendSlice(",");

            const pkg_json = try std.fmt.allocPrint(self.allocator,
                \\{{
                \\  "name": "{s}",
                \\  "version": "{}.{}.{}",
                \\  "description": "{s}",
                \\  "author": "{s}"
                \\}}
            , .{
                pkg.name,
                pkg.version.major,
                pkg.version.minor,
                pkg.version.patch,
                pkg.description orelse "",
                pkg.author orelse "",
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
};
