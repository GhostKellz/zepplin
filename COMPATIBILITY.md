# Zig 0.16 Compatibility Guide

## Breaking Changes in Zig 0.16.0-dev

This document outlines the changes needed to make Zig projects compatible with Zig 0.16.0-dev.

## Main API Changes

### 1. Build System Changes

#### `addStaticLibrary` API Change
**Old (Zig 0.13-0.15):**
```zig
const lib = b.addStaticLibrary("name", "src/main.zig");
```

**New (Zig 0.16):**
```zig
const lib = b.addStaticLibrary(.{
    .name = "name",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

#### `addExecutable` API Change
**Old:**
```zig
const exe = b.addExecutable("name", "src/main.zig");
```

**New:**
```zig
const exe = b.addExecutable(.{
    .name = "name",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

#### `addModule` API Change
**Old:**
```zig
const module = b.createModule(.{
    .source_file = .{ .path = "src/main.zig" },
});
```

**New:**
```zig
const module = b.addModule("module_name", .{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

#### File Path References
**Old:**
```zig
.source_file = .{ .path = "src/file.zig" }
```

**New:**
```zig
.root_source_file = b.path("src/file.zig")
```

### 2. C Source Files

#### `addCSourceFile` API Change
**Old:**
```zig
lib.addCSourceFile("file.c", &.{"-std=c99"});
```

**New:**
```zig
lib.addCSourceFile(.{
    .file = b.path("file.c"),
    .flags = &.{"-std=c99"},
});
```

### 3. Installation and Artifacts

#### `installArtifact` Change
**Old:**
```zig
lib.install();
```

**New:**
```zig
b.installArtifact(lib);
```

## Fixing Your Dependencies

### For zqlite

In `build.zig`, replace:
```zig
const lib = b.addStaticLibrary("sqlite3", null);
lib.addCSourceFile("sqlite3.c", &.{
    "-std=c99",
    "-DSQLITE_ENABLE_FTS5",
    // ... other flags
});
```

With:
```zig
const lib = b.addStaticLibrary(.{
    .name = "sqlite3",
    .target = target,
    .optimize = optimize,
});

lib.addCSourceFile(.{
    .file = b.path("sqlite3.c"),
    .flags = &.{
        "-std=c99",
        "-DSQLITE_ENABLE_FTS5",
        // ... other flags
    },
});
```

### For shroud

Similar changes apply - update all `addStaticLibrary`, `addExecutable`, and path references to use the new struct-based API.

### For zsync

Update async library build configurations to use the new API format.

## General Migration Steps

1. **Update all build function calls** to use struct literals with named fields
2. **Replace `.path` with `b.path()`** for all file references
3. **Update `addCSourceFile` calls** to use the struct format
4. **Replace `lib.install()` with `b.installArtifact(lib)`**
5. **Ensure `target` and `optimize` are passed** to all build artifacts

## Testing Compatibility

To test if your changes work with both Zig 0.15 and 0.16:

```bash
# Test with Zig 0.16
zig-0.16 build

# Test with Zig 0.15 (if maintaining backward compatibility)
zig-0.15 build
```

## Notes

- Zig 0.16 is still in development, so APIs may continue to change
- The struct-based API provides better type safety and clearer intent
- Most changes are mechanical and can be applied systematically