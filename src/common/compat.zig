const std = @import("std");
const builtin = @import("builtin");

/// Write all data to a network stream using direct syscall
pub fn streamWriteAll(stream: std.Io.net.Stream, io: std.Io, data: []const u8) !void {
    _ = io;
    const fd = stream.socket.handle;
    var written: usize = 0;
    while (written < data.len) {
        const remaining = data[written..];
        const result = std.os.linux.write(fd, remaining.ptr, remaining.len);
        const signed_result: isize = @bitCast(result);
        if (signed_result < 0) {
            std.debug.print("❌ Write error: {}\n", .{signed_result});
            return error.WriteFailed;
        }
        if (result == 0) {
            return error.WriteFailed;
        }
        written += result;
    }
}

/// Get current unix timestamp in seconds (compatibility for Zig 0.16.0)
pub fn timestamp() i64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.REALTIME, &ts);
            return ts.sec;
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            return ts.sec;
        },
        .windows => {
            // Windows: use GetSystemTimeAsFileTime
            var ft: std.os.windows.FILETIME = undefined;
            std.os.windows.kernel32.GetSystemTimeAsFileTime(&ft);
            const ft_64 = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
            // Convert from 100-nanosecond intervals since 1601 to seconds since 1970
            const epoch_diff: u64 = 116444736000000000; // 100-ns intervals
            return @intCast(@divFloor(ft_64 - epoch_diff, 10000000));
        },
        else => {
            return 0;
        },
    }
}

/// Get current unix timestamp in milliseconds
pub fn milliTimestamp() i64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.REALTIME, &ts);
            return ts.sec * 1000 + @divFloor(ts.nsec, 1000000);
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            return ts.sec * 1000 + @divFloor(ts.nsec, 1000000);
        },
        else => {
            return timestamp() * 1000;
        },
    }
}

/// Get cryptographically secure random bytes (compatibility for Zig 0.16.0)
pub fn cryptoRandomBytes(buffer: []u8) void {
    switch (builtin.os.tag) {
        .linux => {
            var filled: usize = 0;
            while (filled < buffer.len) {
                const result = std.os.linux.getrandom(buffer.ptr + filled, buffer.len - filled, 0);
                if (result > 0) {
                    filled += result;
                } else if (result == 0) {
                    // Interrupted, retry
                    continue;
                } else {
                    // Error, fill with zeros (shouldn't happen)
                    @memset(buffer[filled..], 0);
                    return;
                }
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Use arc4random_buf on Apple platforms
            std.c.arc4random_buf(buffer.ptr, buffer.len);
        },
        .windows => {
            // On Windows, use RtlGenRandom (SystemFunction036)
            _ = std.os.windows.advapi32.SystemFunction036(buffer.ptr, @intCast(buffer.len));
        },
        else => {
            // Fallback: fill with timestamp-based pseudo-random (not secure!)
            var seed = @as(u64, @intCast(timestamp()));
            for (buffer) |*byte| {
                seed = seed *% 6364136223846793005 +% 1442695040888963407;
                byte.* = @truncate(seed >> 32);
            }
        },
    }
}
