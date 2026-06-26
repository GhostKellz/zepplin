#!/bin/sh
# Patch script to make dependencies compatible with Zig 0.16.0-dev

# Find and patch zqlite build.zig
ZQLITE_DIR=$(find /root/.cache/zig/p -name "zqlite-*" -type d 2>/dev/null | head -1)
if [ -n "$ZQLITE_DIR" ]; then
    echo "Patching zqlite at $ZQLITE_DIR"
    # In Zig 0.16, addStaticLibrary requires a struct with all fields
    sed -i 's/const lib = b\.addStaticLibrary(.*/const lib = b.addStaticLibraryWithOptions(.{ .name = "sqlite3", .target = target, .optimize = optimize });/' "$ZQLITE_DIR/build.zig"
    
    # Alternative approach if the above doesn't work
    if ! grep -q "addStaticLibraryWithOptions" "$ZQLITE_DIR/build.zig"; then
        # Try with the new API format
        cat > "$ZQLITE_DIR/build.zig.tmp" << 'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
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
            "-DSQLITE_ENABLE_RTREE",
            "-DSQLITE_ENABLE_GEOPOLY",
            "-DSQLITE_ENABLE_MATH_FUNCTIONS",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    
    lib.linkLibC();
    b.installArtifact(lib);
    
    const module = b.addModule("zqlite", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    module.linkLibrary(lib);
}
EOF
        mv "$ZQLITE_DIR/build.zig.tmp" "$ZQLITE_DIR/build.zig"
    fi
fi

# Patch shroud if needed
SHROUD_DIR=$(find /root/.cache/zig/p -name "shroud-*" -type d 2>/dev/null | head -1)
if [ -n "$SHROUD_DIR" ] && [ -f "$SHROUD_DIR/build.zig" ]; then
    echo "Checking shroud at $SHROUD_DIR"
    # Add any necessary patches for shroud here if needed
fi

echo "Dependency patching complete"