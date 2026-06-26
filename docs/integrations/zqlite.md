# 🚢 ZQLite for Zeppelin Package Manager

> **Getting started guide for leveraging ZQLite as the database engine for your Zig package management tool**

---

## 🎯 Why ZQLite for Package Management?

ZQLite v1.2.2 provides the perfect foundation for a modern Zig package manager:

- **🏃 Fast**: Embedded B-tree storage with Write-Ahead Logging (WAL)
- **🔒 Secure**: Optional post-quantum cryptography for package signatures
- **📦 Embedded**: Zero-configuration, single-file database 
- **🧠 Memory Safe**: Pure Zig implementation
- **⚡ Modern API**: Type-safe queries with ergonomic result handling

---

## 🚀 Quick Integration

### 1. Add ZQLite Dependency

In your `build.zig.zon`:

```zig
.{
    .name = "zeppelin",
    .version = "1.0.0",
    .dependencies = .{
        .zqlite = .{
            .url = "https://github.com/ghostkellz/zqlite/archive/main.tar.gz",
            .hash = "12345...",
        },
    },
}
```

In your `build.zig`:

```zig
const zqlite = b.dependency("zqlite", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zqlite", zqlite.module("zqlite"));
```

### 2. Initialize Package Database

```zig
const std = @import("std");
const zqlite = @import("zqlite");

pub const PackageManager = struct {
    db: *zqlite.Connection,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !PackageManager {
        const db = try zqlite.open(db_path);
        
        // Initialize package management schema
        try db.execute(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    id INTEGER PRIMARY KEY,
            \\    name TEXT UNIQUE NOT NULL,
            \\    version TEXT NOT NULL,
            \\    description TEXT,
            \\    author TEXT,
            \\    license TEXT,
            \\    repository_url TEXT,
            \\    download_url TEXT,
            \\    file_hash TEXT,
            \\    created_at INTEGER DEFAULT (strftime('%s', 'now')),
            \\    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            \\)
        );

        try db.execute(
            \\CREATE TABLE IF NOT EXISTS dependencies (
            \\    id INTEGER PRIMARY KEY,
            \\    package_id INTEGER NOT NULL,
            \\    dependency_name TEXT NOT NULL,
            \\    version_requirement TEXT NOT NULL,
            \\    FOREIGN KEY (package_id) REFERENCES packages(id),
            \\    UNIQUE(package_id, dependency_name)
            \\)
        );

        try db.execute(
            \\CREATE TABLE IF NOT EXISTS installed_packages (
            \\    id INTEGER PRIMARY KEY,
            \\    package_name TEXT NOT NULL,
            \\    installed_version TEXT NOT NULL,
            \\    install_path TEXT NOT NULL,
            \\    installed_at INTEGER DEFAULT (strftime('%s', 'now')),
            \\    UNIQUE(package_name)
            \\)
        );

        return PackageManager{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PackageManager) void {
        self.db.close();
    }
};
```

---

## 📦 Core Package Operations

### Adding Packages to Registry

```zig
pub const Package = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    author: ?[]const u8,
    license: ?[]const u8,
    repository_url: ?[]const u8,
    download_url: []const u8,
    file_hash: []const u8,
    dependencies: []Dependency,

    pub const Dependency = struct {
        name: []const u8,
        version_requirement: []const u8,
    };
};

pub fn addPackage(self: *PackageManager, package: Package) !void {
    // Use transaction for atomic package addition
    try self.db.transaction(Package, addPackageTransaction, package);
}

fn addPackageTransaction(db: *zqlite.Connection, package: Package) !void {
    // Insert package
    const package_id = try db.exec(
        \\INSERT INTO packages 
        \\(name, version, description, author, license, repository_url, download_url, file_hash)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );

    // Add dependencies
    for (package.dependencies) |dep| {
        _ = try db.exec(
            \\INSERT INTO dependencies (package_id, dependency_name, version_requirement)
            \\VALUES (?, ?, ?)
        );
    }
}
```

### Searching Packages

```zig
pub const SearchResult = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    author: ?[]const u8,
};

pub fn searchPackages(self: *PackageManager, query: []const u8) ![]SearchResult {
    var results = std.ArrayList(SearchResult).init(self.allocator);
    defer results.deinit();

    var result_set = try self.db.query(
        \\SELECT name, version, description, author
        \\FROM packages 
        \\WHERE name LIKE ? OR description LIKE ?
        \\ORDER BY name
    );
    defer result_set.deinit();

    while (result_set.next()) |row| {
        const result = SearchResult{
            .name = try self.allocator.dupe(u8, row.getTextByName("name") orelse ""),
            .version = try self.allocator.dupe(u8, row.getTextByName("version") orelse ""),
            .description = if (row.getTextByName("description")) |desc| 
                try self.allocator.dupe(u8, desc) else null,
            .author = if (row.getTextByName("author")) |author| 
                try self.allocator.dupe(u8, author) else null,
        };
        try results.append(result);
    }

    return results.toOwnedSlice();
}
```

### Installing Packages

```zig
pub fn installPackage(self: *PackageManager, name: []const u8, version: []const u8, install_path: []const u8) !void {
    // Check if package exists in registry
    const package_info = try self.getPackageInfo(name, version);
    if (package_info == null) {
        return error.PackageNotFound;
    }

    // Resolve dependencies
    const deps = try self.resolveDependencies(name, version);
    defer self.allocator.free(deps);

    // Install dependencies first
    for (deps) |dep| {
        try self.installPackage(dep.name, dep.version, install_path);
    }

    // Record installation
    _ = try self.db.exec(
        \\INSERT OR REPLACE INTO installed_packages 
        \\(package_name, installed_version, install_path)
        \\VALUES (?, ?, ?)
    );
}

fn resolveDependencies(self: *PackageManager, package_name: []const u8, version: []const u8) ![]Dependency {
    var deps = std.ArrayList(Dependency).init(self.allocator);
    
    var result_set = try self.db.query(
        \\SELECT d.dependency_name, d.version_requirement
        \\FROM dependencies d
        \\JOIN packages p ON d.package_id = p.id
        \\WHERE p.name = ? AND p.version = ?
    );
    defer result_set.deinit();

    while (result_set.next()) |row| {
        const dep = Dependency{
            .name = try self.allocator.dupe(u8, row.getTextByName("dependency_name") orelse ""),
            .version_requirement = try self.allocator.dupe(u8, row.getTextByName("version_requirement") orelse ""),
        };
        try deps.append(dep);
    }

    return deps.toOwnedSlice();
}
```

### Listing Installed Packages

```zig
pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
    install_path: []const u8,
    installed_at: i64,
};

pub fn listInstalled(self: *PackageManager) ![]InstalledPackage {
    var packages = std.ArrayList(InstalledPackage).init(self.allocator);
    
    var result_set = try self.db.query(
        \\SELECT package_name, installed_version, install_path, installed_at
        \\FROM installed_packages
        \\ORDER BY package_name
    );
    defer result_set.deinit();

    while (result_set.next()) |row| {
        const pkg = InstalledPackage{
            .name = try self.allocator.dupe(u8, row.getTextByName("package_name") orelse ""),
            .version = try self.allocator.dupe(u8, row.getTextByName("installed_version") orelse ""),
            .install_path = try self.allocator.dupe(u8, row.getTextByName("install_path") orelse ""),
            .installed_at = row.getIntByName("installed_at") orelse 0,
        };
        try packages.append(pkg);
    }

    return packages.toOwnedSlice();
}
```

---

## 🔒 Advanced Features (Optional)

### Package Signature Verification

Enable crypto features by adding to your root file:

```zig
// Enable ZQLite cryptographic features
pub const zqlite_enable_crypto = true;
```

Then use hybrid signatures for package verification:

```zig
const crypto = zqlite.crypto;

pub fn verifyPackageSignature(self: *PackageManager, package_name: []const u8, signature_data: []const u8) !bool {
    // Initialize crypto engine (in real app, persist this)
    var crypto_engine = try crypto.CryptoEngine.initWithMasterKey(self.allocator, "master_password");
    defer crypto_engine.deinit();

    // Verify hybrid signature (classical + post-quantum)
    const package_data = try self.getPackageContent(package_name);
    defer self.allocator.free(package_data);
    
    return crypto_engine.verifyTransaction(package_data, signature_data);
}

pub fn signPackage(self: *PackageManager, package_name: []const u8, private_key: []const u8) ![]u8 {
    var crypto_engine = try crypto.CryptoEngine.initWithMasterKey(self.allocator, "master_password");
    defer crypto_engine.deinit();

    const package_data = try self.getPackageContent(package_name);
    defer self.allocator.free(package_data);
    
    return crypto_engine.signTransaction(package_data);
}
```

### High-Performance Package Search

Use advanced indexing for faster searches:

```zig
pub fn createSearchIndexes(self: *PackageManager) !void {
    // Full-text search index
    try self.db.execute("CREATE INDEX IF NOT EXISTS idx_packages_search ON packages(name, description)");
    
    // Version-specific lookups
    try self.db.execute("CREATE INDEX IF NOT EXISTS idx_packages_version ON packages(name, version)");
    
    // Dependency resolution
    try self.db.execute("CREATE INDEX IF NOT EXISTS idx_dependencies_lookup ON dependencies(dependency_name, version_requirement)");
    
    // Installation tracking
    try self.db.execute("CREATE INDEX IF NOT EXISTS idx_installed_name ON installed_packages(package_name)");
}
```

---

## 🎯 Integration Patterns

### CLI Integration

```zig
// zeppelin/src/main.zig
const std = @import("std");
const zqlite = @import("zqlite");
const PackageManager = @import("package_manager.zig").PackageManager;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize package manager with local database
    const home = std.os.getenv("HOME") orelse "/tmp";
    const db_path = try std.fmt.allocPrint(allocator, "{s}/.zeppelin/packages.db", .{home});
    defer allocator.free(db_path);

    var pm = try PackageManager.init(allocator, db_path);
    defer pm.deinit();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];
    
    if (std.mem.eql(u8, command, "search")) {
        if (args.len < 3) {
            std.debug.print("Usage: zeppelin search <query>\n", .{});
            return;
        }
        try searchCommand(&pm, args[2]);
    } else if (std.mem.eql(u8, command, "install")) {
        if (args.len < 3) {
            std.debug.print("Usage: zeppelin install <package_name>\n", .{});
            return;
        }
        try installCommand(&pm, args[2]);
    } else if (std.mem.eql(u8, command, "list")) {
        try listCommand(&pm);
    }
}

fn searchCommand(pm: *PackageManager, query: []const u8) !void {
    const results = try pm.searchPackages(query);
    defer {
        for (results) |result| {
            pm.allocator.free(result.name);
            pm.allocator.free(result.version);
            if (result.description) |desc| pm.allocator.free(desc);
            if (result.author) |author| pm.allocator.free(author);
        }
        pm.allocator.free(results);
    }

    std.debug.print("Found {d} packages:\n", .{results.len});
    for (results) |result| {
        std.debug.print("  📦 {s} v{s}", .{ result.name, result.version });
        if (result.description) |desc| {
            std.debug.print(" - {s}", .{desc});
        }
        std.debug.print("\n");
    }
}
```

### Build System Integration

```zig
// In your build.zig
pub fn addPackageDependencies(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read packages from zeppelin database
    const db_path = "zeppelin_packages.db";
    var pm = try PackageManager.init(allocator, db_path);
    defer pm.deinit();

    const installed = try pm.listInstalled();
    defer {
        for (installed) |pkg| {
            allocator.free(pkg.name);
            allocator.free(pkg.version);
            allocator.free(pkg.install_path);
        }
        allocator.free(installed);
    }

    // Add each installed package as a dependency
    for (installed) |pkg| {
        const module = b.addModule(pkg.name, .{
            .root_source_file = b.path(std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{pkg.install_path}) catch unreachable),
        });
        exe.root_module.addImport(pkg.name, module);
    }
}
```

---

## 🚀 Performance Tips

### Batch Operations

```zig
pub fn batchInstallPackages(self: *PackageManager, packages: []const []const u8) !void {
    // Use single transaction for better performance
    try self.db.begin();
    defer self.db.rollback() catch {};

    for (packages) |pkg_name| {
        try self.installPackageInTransaction(pkg_name);
    }

    try self.db.commit();
}
```

### Connection Pooling for Multi-threaded Operations

```zig
pub const PackageManagerPool = struct {
    connections: []PackageManager,
    mutex: std.Thread.Mutex,
    available: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, pool_size: usize) !PackageManagerPool {
        var connections = try allocator.alloc(PackageManager, pool_size);
        var available = std.ArrayList(usize).init(allocator);
        
        for (connections, 0..) |*conn, i| {
            conn.* = try PackageManager.init(allocator, db_path);
            try available.append(i);
        }

        return PackageManagerPool{
            .connections = connections,
            .mutex = std.Thread.Mutex{},
            .available = available,
        };
    }

    pub fn acquire(self: *PackageManagerPool) ?*PackageManager {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.popOrNull()) |index| {
            return &self.connections[index];
        }
        return null;
    }

    pub fn release(self: *PackageManagerPool, conn: *PackageManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find connection index and return to pool
        for (self.connections, 0..) |*pool_conn, i| {
            if (pool_conn == conn) {
                self.available.append(i) catch {};
                break;
            }
        }
    }
};
```

---

## 🧪 Testing Your Integration

```zig
// test/package_manager_test.zig
const std = @import("std");
const testing = std.testing;
const PackageManager = @import("../src/package_manager.zig").PackageManager;

test "package installation flow" {
    const allocator = testing.allocator;
    
    // Use in-memory database for tests
    var pm = try PackageManager.initMemory(allocator);
    defer pm.deinit();

    // Add test package
    const test_pkg = PackageManager.Package{
        .name = "test-lib",
        .version = "1.0.0",
        .description = "A test library",
        .author = "Test Author",
        .license = "MIT",
        .repository_url = "https://github.com/test/test-lib",
        .download_url = "https://github.com/test/test-lib/archive/v1.0.0.tar.gz",
        .file_hash = "abcd1234",
        .dependencies = &[_]PackageManager.Package.Dependency{},
    };
    
    try pm.addPackage(test_pkg);
    
    // Search for package
    const results = try pm.searchPackages("test");
    defer {
        for (results) |result| {
            allocator.free(result.name);
            allocator.free(result.version);
            if (result.description) |desc| allocator.free(desc);
            if (result.author) |author| allocator.free(author);
        }
        allocator.free(results);
    }
    
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings(results[0].name, "test-lib");
}
```

---

## 📚 API Reference Summary

### Core Types

- `zqlite.Connection` - Database connection handle
- `zqlite.Connection.ResultSet` - Query result iterator
- `zqlite.Connection.Row` - Single result row
- `zqlite.Connection.Schema` - Table schema information

### Essential Methods

- `zqlite.open(path)` - Open file database
- `zqlite.openMemory()` - Open in-memory database
- `conn.execute(sql)` - Execute SQL statement
- `conn.exec(sql)` - Execute and return affected rows
- `conn.query(sql)` - Execute query, return ResultSet
- `conn.queryRow(sql)` - Execute query, return single Row
- `conn.transaction(fn, context)` - Execute in transaction
- `conn.getTableNames()` - List all tables
- `conn.getTableSchema(name)` - Get table schema

### Type-Safe Data Access

- `row.getIntByName(column)` - Get integer by column name
- `row.getTextByName(column)` - Get text by column name  
- `row.getRealByName(column)` - Get real number by column name
- `row.getBlobByName(column)` - Get binary data by column name

---

## 🎯 Next Steps

1. **Start Small**: Begin with basic package registry (add, search, list)
2. **Add Dependencies**: Implement dependency resolution and installation
3. **Enhance Performance**: Add indexes and optimize queries
4. **Security**: Enable crypto features for package signatures
5. **Scale**: Add connection pooling for multi-threaded operations

---

**🚀 Ready to build the next-generation Zig package manager with ZQLite!**

*The embedded database that grows with your needs* ✨