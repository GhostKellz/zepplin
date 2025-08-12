const std = @import("std");
const types = @import("../common/types.zig");

pub const StorageError = error{
    FileNotFound,
    InvalidPackage,
    ChecksumMismatch,
    StorageError,
    CompressionError,
    ExtractionError,
};

pub const PackageFile = struct {
    metadata: types.PackageMetadata,
    checksum: []const u8,
    file_path: []const u8,
    file_size: u64,
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    storage_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, storage_path: []const u8) !Storage {
        // Ensure storage directory exists
        std.fs.cwd().makeDir(storage_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create subdirectories
        const packages_path = try std.fs.path.join(allocator, &.{ storage_path, "packages" });
        defer allocator.free(packages_path);
        std.fs.cwd().makeDir(packages_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return Storage{
            .allocator = allocator,
            .storage_path = try allocator.dupe(u8, storage_path),
        };
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.storage_path);
    }

    pub fn storePackage(self: *Storage, metadata: types.PackageMetadata, package_data: []const u8) !PackageFile {
        // Use arena allocator for temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        // Create package directory structure: packages/{name}/{version}/
        const version_str = try metadata.version.toString(temp_allocator);

        // Use stack buffer for path construction where possible
        var path_buffer: [512]u8 = undefined;
        const package_dir = try std.fmt.bufPrint(&path_buffer, "{s}/packages/{s}/{s}", .{ self.storage_path, metadata.name, version_str });

        // Create directory recursively
        std.fs.cwd().makePath(package_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Generate filename: {name}-{version}.zpkg
        var filename_buffer: [256]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buffer, "{s}-{s}.zpkg", .{ metadata.name, version_str });

        var file_path_buffer: [768]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buffer, "{s}/{s}", .{ package_dir, filename });

        // Calculate checksum using std library
        var checksum_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(package_data, &checksum_bytes, .{});

        // Convert to hex string manually
        var checksum_buf: [64]u8 = undefined; // SHA256 is 32 bytes, hex is 64 chars
        const hex_chars = "0123456789abcdef";
        for (checksum_bytes, 0..) |byte, i| {
            checksum_buf[i * 2] = hex_chars[byte >> 4];
            checksum_buf[i * 2 + 1] = hex_chars[byte & 0xF];
        }
        const checksum = try self.allocator.dupe(u8, checksum_buf[0..]);

        // Write package file
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(package_data);

        // Store metadata as JSON alongside the package
        const metadata_path = try std.fmt.allocPrint(self.allocator, "{s}.json", .{file_path});
        defer self.allocator.free(metadata_path);

        const metadata_json = try metadata.toJson(self.allocator);
        defer self.allocator.free(metadata_json);

        const metadata_file = try std.fs.cwd().createFile(metadata_path, .{});
        defer metadata_file.close();
        try metadata_file.writeAll(metadata_json);

        return PackageFile{
            .metadata = metadata,
            .checksum = checksum,
            .file_path = file_path,
            .file_size = package_data.len,
        };
    }

    pub fn retrievePackage(self: *Storage, name: []const u8, version: types.Version) ![]u8 {
        const version_str = try version.toString(self.allocator);
        defer self.allocator.free(version_str);

        const filename = try std.fmt.allocPrint(self.allocator, "{s}-{s}.zpkg", .{ name, version_str });
        defer self.allocator.free(filename);

        const package_dir = try std.fs.path.join(self.allocator, &.{ self.storage_path, "packages", name, version_str });
        defer self.allocator.free(package_dir);

        const file_path = try std.fs.path.join(self.allocator, &.{ package_dir, filename });
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return StorageError.FileNotFound,
            else => return err,
        };
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024); // 100MB max
    }

    pub fn verifyPackage(self: *Storage, name: []const u8, version: types.Version, expected_checksum: []const u8) !bool {
        const package_data = try self.retrievePackage(name, version);
        defer self.allocator.free(package_data);

        var hasher = std.crypto.hash.sha256.Sha256.init(.{});
        hasher.update(package_data);
        var checksum_bytes: [32]u8 = undefined;
        hasher.final(&checksum_bytes);

        const actual_checksum = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&checksum_bytes)});
        defer self.allocator.free(actual_checksum);

        return std.mem.eql(u8, expected_checksum, actual_checksum);
    }

    pub fn packageExists(self: *Storage, name: []const u8, version: types.Version) bool {
        const version_str = version.toString(self.allocator) catch return false;
        defer self.allocator.free(version_str);

        const filename = std.fmt.allocPrint(self.allocator, "{s}-{s}.zpkg", .{ name, version_str }) catch return false;
        defer self.allocator.free(filename);

        const package_dir = std.fs.path.join(self.allocator, &.{ self.storage_path, "packages", name, version_str }) catch return false;
        defer self.allocator.free(package_dir);

        const file_path = std.fs.path.join(self.allocator, &.{ package_dir, filename }) catch return false;
        defer self.allocator.free(file_path);

        std.fs.cwd().access(file_path, .{}) catch return false;
        return true;
    }

    pub fn deletePackage(self: *Storage, name: []const u8, version: types.Version) !void {
        const version_str = try version.toString(self.allocator);
        defer self.allocator.free(version_str);

        const package_dir = try std.fs.path.join(self.allocator, &.{ self.storage_path, "packages", name, version_str });
        defer self.allocator.free(package_dir);

        std.fs.cwd().deleteTree(package_dir) catch |err| switch (err) {
            error.FileNotFound => return StorageError.FileNotFound,
            else => return err,
        };
    }

    pub fn compressPackage(self: *Storage, _: []const u8) ![]u8 {
        // TODO: Implement tar.gz compression
        // For now, return placeholder
        return self.allocator.dupe(u8, "compressed_package_data");
    }

    pub fn extractPackage(_: *Storage, _: []const u8, dest_dir: []const u8) !void {
        // TODO: Implement tar.gz extraction
        // For now, just create the directory
        std.fs.cwd().makeDir(dest_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};
