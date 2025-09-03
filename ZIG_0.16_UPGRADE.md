# Zig 0.16 Upgrade Guide

## Quick Fixes for Common Errors

### Error: `no field or member function named 'addStaticLibrary'`
**OLD:**
```zig
const lib = b.addStaticLibrary(.{
    .name = "libname",
    .target = target,
    .optimize = optimize,
});
```

**NEW:**
```zig
const lib = b.addStaticLibraryWithOptions(.{
    .name = "libname",
    .target = target,
    .optimize = optimize,
});
```

### Error: `no field or member function named 'addExecutable'`
**OLD:**
```zig
const exe = b.addExecutable(.{
    .name = "appname",
    .root_source_file = .{ .path = "src/main.zig" },
    .target = target,
    .optimize = optimize,
});
```

**NEW:**
```zig
const exe = b.addExecutableWithOptions(.{
    .name = "appname",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

### Error: `addCSourceFile` expects struct
**OLD:**
```zig
lib.addCSourceFile("file.c", &.{"-std=c99"});
```

**NEW:**
```zig
lib.addCSourceFile(.{
    .file = b.path("file.c"),
    .flags = &.{"-std=c99"},
});
```

### Error: `.path` field deprecated
**OLD:**
```zig
.root_source_file = .{ .path = "src/main.zig" }
```

**NEW:**
```zig
.root_source_file = b.path("src/main.zig")
```

### Error: `createModule` deprecated
**OLD:**
```zig
const module = b.createModule(.{
    .source_file = .{ .path = "src/lib.zig" },
});
```

**NEW:**
```zig
const module = b.addModule("module_name", .{
    .root_source_file = b.path("src/lib.zig"),
    .target = target,
    .optimize = optimize,
});
```

### Error: `install()` method not found
**OLD:**
```zig
lib.install();
```

**NEW:**
```zig
b.installArtifact(lib);
```

## Complete Example - Fixing a Library Build

**OLD build.zig:**
```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const lib = b.addStaticLibrary(.{
        .name = "mylib",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    
    lib.addCSourceFile("sqlite3.c", &.{"-std=c99"});
    lib.install();
}
```

**NEW build.zig:**
```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    const lib = b.addStaticLibraryWithOptions(.{
        .name = "mylib",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    lib.addCSourceFile(.{
        .file = b.path("sqlite3.c"),
        .flags = &.{"-std=c99"},
    });
    
    b.installArtifact(lib);
}
```

## Quick Sed Commands to Fix Common Issues

```bash
# Fix addStaticLibrary
sed -i 's/b\.addStaticLibrary(/b.addStaticLibraryWithOptions(/g' build.zig

# Fix addExecutable  
sed -i 's/b\.addExecutable(/b.addExecutableWithOptions(/g' build.zig

# Fix .path references (basic - may need manual review)
sed -i 's/\.path = "\([^"]*\)"/b.path("\1")/g' build.zig

# Fix install() calls
sed -i 's/\.install()/b.installArtifact(&)/g' build.zig
```

## For Your Specific Projects

### zqlite
In `build.zig` line 14, change:
- `b.addStaticLibrary(` → `b.addStaticLibraryWithOptions(`

### shroud  
Update all `addStaticLibrary` and file path references

### zsync
Update async library build calls to use new API

## Testing
After making changes, test with:
```bash
zig build
```

If you get more errors, check for:
1. Missing `WithOptions` suffix on build functions
2. Old `.path` syntax instead of `b.path()`
3. Old `install()` instead of `b.installArtifact()`