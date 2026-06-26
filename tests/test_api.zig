const std = @import("std");
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: zig run test_api.zig -- <endpoint>\n", .{});
        print("Examples:\n", .{});
        print("  zig run test_api.zig -- /api/v1/health\n", .{});
        print("  zig run test_api.zig -- /api/v1/registry/config\n", .{});
        print("  zig run test_api.zig -- '/api/v1/search?q=json'\n", .{});
        print("  zig run test_api.zig -- /api/v1/packages/torvalds/linux/releases\n", .{});
        return;
    }

    const endpoint = args[1];
    const base_url = "http://localhost:8080";

    try testEndpoint(allocator, base_url, endpoint);
}

fn testEndpoint(allocator: std.mem.Allocator, base_url: []const u8, endpoint: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, endpoint });
    defer allocator.free(url);

    print("Testing: {s}\n", .{url});
    print("{s}\n", .{"=" ** 50});
    print("\n", .{});

    // Simple HTTP GET using curl for now
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "curl", "-s", "-H", "Accept: application/json", url },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited == 0) {
        // Pretty print JSON if possible
        const pretty_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "jq", "." },
            .stdin_behavior = .Pipe,
        }) catch {
            // If jq is not available, just print raw output
            print("{s}\n", .{result.stdout});
            return;
        };
        defer allocator.free(pretty_result.stdout);
        defer allocator.free(pretty_result.stderr);

        if (pretty_result.term.Exited == 0 and pretty_result.stdout.len > 0) {
            print("{s}\n", .{pretty_result.stdout});
        } else {
            print("{s}\n", .{result.stdout});
        }
    } else {
        print("Error: {s}\n", .{result.stderr});
    }
}
