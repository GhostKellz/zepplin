# SQLite Integration for Zepplin

Zepplin uses SQLite as its embedded database backend for persistent storage. This provides excellent performance, ACID compliance, and zero-configuration setup for the package registry.

## 🎯 **Overview**

SQLite is the perfect choice for Zepplin because:
- **Zero Configuration**: No separate database server needed
- **Embedded**: Database file travels with the application
- **ACID Compliance**: Reliable data consistency
- **High Performance**: Excellent for read-heavy workloads like package registries
- **Cross-Platform**: Works everywhere Zig works
- **Mature**: Battle-tested in production applications

## 🏗️ **Database Schema**

### Packages Table
```sql
CREATE TABLE packages (
  name TEXT PRIMARY KEY,
  version TEXT NOT NULL,
  description TEXT,
  author TEXT,
  license TEXT,
  repository TEXT,
  dependencies TEXT,
  file_path TEXT,
  file_size INTEGER,
  checksum TEXT,
  created_at INTEGER,
  updated_at INTEGER
);
```

### Users Table
```sql
CREATE TABLE users (
  username TEXT PRIMARY KEY,
  email TEXT UNIQUE,
  password_hash TEXT NOT NULL,
  api_token TEXT UNIQUE,
  created_at INTEGER,
  is_active INTEGER DEFAULT 1
);
```

### Download Statistics Table
```sql
CREATE TABLE download_stats (
  package_name TEXT PRIMARY KEY,
  download_count INTEGER DEFAULT 0,
  last_downloaded INTEGER
);
```

## 💻 **Implementation Details**

### C Integration
Zepplin uses Zig's excellent C interop to interface with the SQLite C library:

```zig
const c = @cImport({
    @cInclude("sqlite3.h");
});
```

### Database Operations
All database operations use prepared statements for security and performance:

```zig
pub fn getPackage(self: *Database, name: []const u8) !?types.PackageMetadata {
    const sql = try std.fmt.allocPrint(self.allocator, 
        "SELECT name, version, description, author, license, repository FROM packages WHERE name = ?", 
        .{});
    defer self.allocator.free(sql);

    var stmt: ?*c.sqlite3_stmt = null;
    var result = c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null);
    // ... handle result
}
```

### Error Handling
SQLite errors are properly converted to Zig errors:

```zig
if (result != c.SQLITE_OK) {
    std.log.err("SQL execution failed: {}", .{result});
    return error.SqlExecutionFailed;
}
```

## 🚀 **Performance Optimizations**

### Prepared Statements
All queries use prepared statements to avoid SQL parsing overhead.

### Memory Management
String results are properly allocated and managed through Zig's allocator system.

### Connection Pooling
For future enhancement, connection pooling can be implemented for high-concurrency scenarios.

## 🔒 **Security Features**

### SQL Injection Prevention
All user inputs are properly escaped and parameterized.

### Safe String Handling
Null-terminated strings from SQLite are safely converted to Zig strings.

### Input Validation
All inputs are validated before database operations.

## 📊 **Data Models**

### Package Metadata
```zig
pub const PackageMetadata = struct {
    name: []const u8,
    version: Version,
    description: ?[]const u8,
    author: ?[]const u8,
    license: ?[]const u8,
    repository: ?[]const u8,
    dependencies: []Dependency,
};
```

### Download Statistics
```zig
pub const Stats = struct {
    total_packages: u64,
    downloads_today: u64,
    total_downloads: u64,
};
```

## 🛠️ **Development & Testing**

### Database Location
Development database: `./data/zepplin.db`
Production database: Configurable via command line

### Schema Migrations
Tables are created automatically on first run with `CREATE TABLE IF NOT EXISTS`.

### Testing
```bash
# Test database creation
zig build run -- serve 8080

# Check database schema
sqlite3 data/zepplin.db ".schema"

# Examine data
sqlite3 data/zepplin.db "SELECT * FROM packages;"
```

## 🐳 **Deployment**

### Docker
The SQLite database file is mounted as a volume in Docker deployments:

```dockerfile
VOLUME ["/app/data"]
```

### Production Considerations
- Regular database backups recommended
- Monitor database file size growth
- Consider database optimization with `VACUUM` for long-running instances

## 🔧 **Configuration**

### System Requirements
- SQLite3 development libraries (`libsqlite3-dev` on Ubuntu)
- C compiler for linking
- No runtime dependencies beyond the SQLite shared library

### Build Configuration
```zig
// build.zig
exe.linkSystemLibrary("sqlite3");
exe.linkLibC();
```

## 📚 **API Reference**

### Core Database Operations
- `init(allocator, db_path)` - Initialize database connection
- `deinit()` - Close database connection
- `addPackage(metadata)` - Add new package
- `getPackage(name)` - Retrieve package by name
- `listPackages(limit, offset)` - List packages with pagination
- `searchPackages(query, limit)` - Search packages
- `removePackage(name)` - Delete package

### User Management
- `createUser(username, email, password_hash, api_token)` - Create user
- `getUserByToken(token)` - Authenticate by API token
- `getUserByUsername(username)` - Get user by username

### Statistics
- `incrementDownloadCount(package_name)` - Track downloads
- `getDownloadCount(package_name)` - Get download count
- `getTotalPackages()` - Total package count
- `getTotalDownloads()` - Total download count
- `getDownloadStats()` - Aggregate statistics

## 🎉 **Benefits Over zqlite**

1. **Stability**: SQLite is mature and stable (20+ years)
2. **Performance**: Highly optimized C implementation
3. **Ecosystem**: Excellent tooling and documentation
4. **Standards**: SQL standard compliance
5. **Support**: Extensive community and professional support
6. **Portability**: Runs everywhere
7. **Reliability**: Used in production by millions of applications

---

**SQLite integration provides Zepplin with a rock-solid foundation for package storage and management. The combination of Zig's performance and SQLite's reliability creates an excellent platform for the Zig package ecosystem.**
