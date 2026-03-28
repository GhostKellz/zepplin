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
    io: std.Io,
    storage_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, storage_path: []const u8) !Storage {
        // Ensure storage directory exists
        std.Io.Dir.cwd().createDir(io, storage_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create subdirectories
        const packages_path = try std.Io.Dir.path.join(allocator, &.{ storage_path, "packages" });
        defer allocator.free(packages_path);
        std.Io.Dir.cwd().createDir(io, packages_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return Storage{
            .allocator = allocator,
            .io = io,
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
        std.Io.Dir.cwd().createDirPath(self.io, package_dir) catch {};

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
        const file = try std.Io.Dir.cwd().createFile(self.io, file_path, .{});
        defer file.close(self.io);
        var write_buf: [8192]u8 = undefined;
        var writer = file.writer(self.io, &write_buf);
        try writer.interface.writeAll(package_data);
        try writer.interface.flush();

        // Store metadata as JSON alongside the package
        const metadata_path = try std.fmt.allocPrint(self.allocator, "{s}.json", .{file_path});
        defer self.allocator.free(metadata_path);

        const metadata_json = try metadata.toJson(self.allocator);
        defer self.allocator.free(metadata_json);

        const metadata_file = try std.Io.Dir.cwd().createFile(self.io, metadata_path, .{});
        defer metadata_file.close(self.io);
        var meta_write_buf: [4096]u8 = undefined;
        var meta_writer = metadata_file.writer(self.io, &meta_write_buf);
        try meta_writer.interface.writeAll(metadata_json);
        try meta_writer.interface.flush();

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

        const package_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.storage_path, "packages", name, version_str });
        defer self.allocator.free(package_dir);

        const file_path = try std.Io.Dir.path.join(self.allocator, &.{ package_dir, filename });
        defer self.allocator.free(file_path);

        const file = std.Io.Dir.cwd().openFile(self.io, file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return StorageError.FileNotFound,
            else => return err,
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const contents = try self.allocator.alloc(u8, stat.size);
        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);
        try reader.interface.readSliceAll(contents);
        return contents;
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

        const package_dir = std.Io.Dir.path.join(self.allocator, &.{ self.storage_path, "packages", name, version_str }) catch return false;
        defer self.allocator.free(package_dir);

        const file_path = std.Io.Dir.path.join(self.allocator, &.{ package_dir, filename }) catch return false;
        defer self.allocator.free(file_path);

        std.Io.Dir.cwd().access(self.io, file_path, .{}) catch return false;
        return true;
    }

    pub fn deletePackage(self: *Storage, name: []const u8, version: types.Version) !void {
        const version_str = try version.toString(self.allocator);
        defer self.allocator.free(version_str);

        const package_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.storage_path, "packages", name, version_str });
        defer self.allocator.free(package_dir);

        std.Io.Dir.cwd().deleteTree(self.io, package_dir) catch |err| switch (err) {
            error.FileNotFound => return StorageError.FileNotFound,
            else => return err,
        };
    }

    pub fn compressPackage(self: *Storage, source_dir: []const u8) ![]u8 {
        // Create tar archive from directory contents
        var tar_data: std.ArrayList(u8) = .empty;
        errdefer tar_data.deinit(self.allocator);

        // Walk directory and add files to tar
        var dir = std.Io.Dir.cwd().openDir(self.io, source_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open source directory {s}: {}\n", .{ source_dir, err });
            return StorageError.StorageError;
        };
        defer dir.close(self.io);

        var walker = try dir.walk(self.allocator, self.io);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                // Read file contents
                const file = dir.openFile(self.io, entry.path, .{}) catch continue;
                defer file.close(self.io);

                const stat = try file.stat(self.io);
                const file_data = try self.allocator.alloc(u8, stat.size);
                defer self.allocator.free(file_data);

                var read_buf: [8192]u8 = undefined;
                var reader = file.reader(self.io, &read_buf);
                try reader.interface.readSliceAll(file_data);

                // Write tar header
                try self.writeTarHeader(&tar_data, entry.path, stat.size);
                // Write file data
                try tar_data.appendSlice(self.allocator, file_data);
                // Pad to 512-byte boundary
                const padding = (512 - (stat.size % 512)) % 512;
                for (0..padding) |_| {
                    try tar_data.append(self.allocator, 0);
                }
            }
        }

        // Write tar end marker (two 512-byte blocks of zeros)
        for (0..1024) |_| {
            try tar_data.append(self.allocator, 0);
        }

        // Compress with gzip
        const tar_slice = tar_data.items;
        var compressed: std.ArrayList(u8) = .empty;
        errdefer compressed.deinit(self.allocator);

        // Write gzip header
        try compressed.appendSlice(self.allocator, &[_]u8{
            0x1f, 0x8b, // Magic number
            0x08, // Compression method (deflate)
            0x00, // Flags
            0x00, 0x00, 0x00, 0x00, // Modification time
            0x00, // Extra flags
            0xff, // OS (unknown)
        });

        // Compress using deflate
        var deflate_compressor = std.compress.deflate.compressor(
            .raw,
            WriterContext{ .list = &compressed, .allocator = self.allocator },
            .{},
        );
        try deflate_compressor.interface.writeAll(tar_slice);
        try deflate_compressor.interface.flush();

        // Write gzip trailer (CRC32 and original size)
        const crc = std.hash.crc.Crc32IsoHdlc.hash(tar_slice);
        const size: u32 = @intCast(tar_slice.len);
        try compressed.appendSlice(self.allocator, &std.mem.toBytes(crc));
        try compressed.appendSlice(self.allocator, &std.mem.toBytes(size));

        tar_data.deinit(self.allocator);
        return compressed.toOwnedSlice(self.allocator);
    }

    fn writeTarHeader(self: *Storage, tar_data: *std.ArrayList(u8), path: []const u8, size: u64) !void {
        var header: [512]u8 = [_]u8{0} ** 512;

        // Name (100 bytes)
        const name_len = @min(path.len, 100);
        @memcpy(header[0..name_len], path[0..name_len]);

        // Mode (8 bytes) - regular file with rw-r--r--
        @memcpy(header[100..107], "0000644");
        header[107] = 0;

        // UID (8 bytes)
        @memcpy(header[108..115], "0000000");
        header[115] = 0;

        // GID (8 bytes)
        @memcpy(header[116..123], "0000000");
        header[123] = 0;

        // Size (12 bytes) - octal
        var size_buf: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&size_buf, "{o:0>11}", .{size}) catch {
            @memcpy(&size_buf, "00000000000");
        };
        @memcpy(header[124..135], size_buf[0..11]);
        header[135] = 0;

        // Mtime (12 bytes) - current time in octal
        const now: u64 = @intCast(@max(0, std.time.timestamp()));
        var mtime_buf: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&mtime_buf, "{o:0>11}", .{now}) catch {
            @memcpy(&mtime_buf, "00000000000");
        };
        @memcpy(header[136..147], mtime_buf[0..11]);
        header[147] = 0;

        // Checksum placeholder (8 bytes of spaces for calculation)
        @memcpy(header[148..156], "        ");

        // Type flag - regular file
        header[156] = '0';

        // Calculate and write checksum
        var checksum: u32 = 0;
        for (header) |byte| {
            checksum += byte;
        }
        var checksum_buf: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&checksum_buf, "{o:0>6}", .{checksum}) catch {
            @memcpy(&checksum_buf, "000000");
        };
        @memcpy(header[148..154], checksum_buf[0..6]);
        header[154] = 0;
        header[155] = ' ';

        try tar_data.appendSlice(self.allocator, &header);
    }

    pub fn extractPackage(self: *Storage, compressed_data: []const u8, dest_dir: []const u8) !void {
        // Create destination directory
        std.Io.Dir.cwd().createDirPath(self.io, dest_dir) catch {};

        // Decompress gzip
        if (compressed_data.len < 10) {
            return StorageError.CompressionError;
        }

        // Verify gzip magic
        if (compressed_data[0] != 0x1f or compressed_data[1] != 0x8b) {
            return StorageError.CompressionError;
        }

        // Skip gzip header (minimum 10 bytes)
        var header_end: usize = 10;

        // Check for extra field
        if (compressed_data[3] & 0x04 != 0) {
            if (compressed_data.len < header_end + 2) return StorageError.CompressionError;
            const xlen = @as(u16, compressed_data[header_end]) | (@as(u16, compressed_data[header_end + 1]) << 8);
            header_end += 2 + xlen;
        }

        // Check for original filename
        if (compressed_data[3] & 0x08 != 0) {
            while (header_end < compressed_data.len and compressed_data[header_end] != 0) {
                header_end += 1;
            }
            header_end += 1;
        }

        // Check for comment
        if (compressed_data[3] & 0x10 != 0) {
            while (header_end < compressed_data.len and compressed_data[header_end] != 0) {
                header_end += 1;
            }
            header_end += 1;
        }

        // Check for header CRC
        if (compressed_data[3] & 0x02 != 0) {
            header_end += 2;
        }

        if (header_end >= compressed_data.len) {
            return StorageError.CompressionError;
        }

        // Decompress deflate data (exclude 8-byte gzip trailer)
        const deflate_data = compressed_data[header_end .. compressed_data.len - 8];

        var tar_data: std.ArrayList(u8) = .empty;
        defer tar_data.deinit(self.allocator);

        var fbs = std.io.fixedBufferStream(deflate_data);
        var decompressor = std.compress.deflate.decompressor(.raw, fbs.reader());

        while (true) {
            var buf: [4096]u8 = undefined;
            const read = decompressor.interface.read(&buf) catch |err| {
                std.debug.print("Decompression error: {}\n", .{err});
                return StorageError.CompressionError;
            };
            if (read == 0) break;
            try tar_data.appendSlice(self.allocator, buf[0..read]);
        }

        // Extract tar contents
        try self.extractTar(tar_data.items, dest_dir);
    }

    fn extractTar(self: *Storage, tar_data: []const u8, dest_dir: []const u8) !void {
        var offset: usize = 0;

        while (offset + 512 <= tar_data.len) {
            const header = tar_data[offset .. offset + 512];

            // Check for end of archive (two zero blocks)
            var all_zero = true;
            for (header) |byte| {
                if (byte != 0) {
                    all_zero = false;
                    break;
                }
            }
            if (all_zero) break;

            // Parse header
            const name_end = std.mem.indexOfScalar(u8, header[0..100], 0) orelse 100;
            const name = header[0..name_end];

            if (name.len == 0) {
                offset += 512;
                continue;
            }

            // Parse size (octal)
            const size_str = header[124..135];
            var size: u64 = 0;
            for (size_str) |c| {
                if (c >= '0' and c <= '7') {
                    size = size * 8 + (c - '0');
                }
            }

            // Type flag
            const type_flag = header[156];

            offset += 512;

            if (type_flag == '0' or type_flag == 0) {
                // Regular file
                if (offset + size > tar_data.len) {
                    return StorageError.ExtractionError;
                }

                const file_data = tar_data[offset .. offset + size];

                // Create file path
                const file_path = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, name });
                defer self.allocator.free(file_path);

                // Ensure parent directory exists
                if (std.fs.path.dirname(file_path)) |parent| {
                    std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
                }

                // Write file
                const file = std.Io.Dir.cwd().createFile(self.io, file_path, .{}) catch |err| {
                    std.debug.print("Failed to create file {s}: {}\n", .{ file_path, err });
                    continue;
                };
                defer file.close(self.io);

                var write_buf: [8192]u8 = undefined;
                var writer = file.writer(self.io, &write_buf);
                try writer.interface.writeAll(file_data);
                try writer.interface.flush();

                // Move past file data, padded to 512 bytes
                const padded_size = ((size + 511) / 512) * 512;
                offset += padded_size;
            } else if (type_flag == '5') {
                // Directory
                const dir_path = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, name });
                defer self.allocator.free(dir_path);
                std.Io.Dir.cwd().createDirPath(self.io, dir_path) catch {};
            } else {
                // Skip unknown types, move past data
                const padded_size = ((size + 511) / 512) * 512;
                offset += padded_size;
            }
        }
    }

    pub fn createTarGz(self: *Storage, files: []const FileEntry) ![]u8 {
        var tar_data: std.ArrayList(u8) = .empty;
        errdefer tar_data.deinit(self.allocator);

        for (files) |entry| {
            try self.writeTarHeader(&tar_data, entry.path, entry.data.len);
            try tar_data.appendSlice(self.allocator, entry.data);

            // Pad to 512-byte boundary
            const padding = (512 - (entry.data.len % 512)) % 512;
            for (0..padding) |_| {
                try tar_data.append(self.allocator, 0);
            }
        }

        // Write tar end marker
        for (0..1024) |_| {
            try tar_data.append(self.allocator, 0);
        }

        // Compress with gzip
        var compressed: std.ArrayList(u8) = .empty;
        errdefer compressed.deinit(self.allocator);

        // Write gzip header
        try compressed.appendSlice(self.allocator, &[_]u8{
            0x1f, 0x8b, 0x08, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0xff,
        });

        // Compress using deflate
        var deflate_compressor = std.compress.deflate.compressor(
            .raw,
            WriterContext{ .list = &compressed, .allocator = self.allocator },
            .{},
        );
        try deflate_compressor.interface.writeAll(tar_data.items);
        try deflate_compressor.interface.flush();

        // Write gzip trailer
        const crc = std.hash.crc.Crc32IsoHdlc.hash(tar_data.items);
        const size: u32 = @intCast(tar_data.items.len);
        try compressed.appendSlice(self.allocator, &std.mem.toBytes(crc));
        try compressed.appendSlice(self.allocator, &std.mem.toBytes(size));

        tar_data.deinit(self.allocator);
        return compressed.toOwnedSlice(self.allocator);
    }
};

pub const FileEntry = struct {
    path: []const u8,
    data: []const u8,
};

const WriterContext = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn write(self: WriterContext, bytes: []const u8) !usize {
        try self.list.appendSlice(self.allocator, bytes);
        return bytes.len;
    }
};
