const std = @import("std");
const cli = @import("cli/cli.zig");
const commands = @import("cli/commands.zig");
const server = @import("server/server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        commands.printHelp();
        return;
    }

    // Check if we should start the server
    if (std.mem.eql(u8, args[1], "serve")) {
        const port: u16 = if (args.len > 2)
            std.fmt.parseInt(u16, args[2], 10) catch 8080
        else
            8080;

        const data_dir = if (args.len > 3) args[3] else "./data";

        std.debug.print("🚀 Starting Zepplin Registry Server...\n", .{});
        std.debug.print("📁 Data directory: {s}\n", .{data_dir});
        std.debug.print("🌐 Port: {}\n", .{port});

        // Ensure data directory exists
        std.fs.cwd().makeDir(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.debug.print("✅ Data directory exists: {s}\n", .{data_dir});
            },
            else => {
                std.debug.print("❌ Failed to create data directory: {}\n", .{err});
                return err;
            },
        };

        std.debug.print("🗄️ Initializing database...\n", .{});
        var registry_server = server.Server.init(allocator, port, data_dir) catch |err| {
            std.debug.print("❌ Failed to initialize server: {}\n", .{err});
            return err;
        };
        defer registry_server.deinit();

        std.debug.print("🌐 Starting server on port {}...\n", .{port});
        registry_server.start() catch |err| {
            std.debug.print("❌ Failed to start server: {}\n", .{err});
            return err;
        };
        return;
    }

    // Otherwise, handle CLI commands
    const cli_args = commands.parseArgs(args) catch |err| switch (err) {
        commands.CliError.InvalidCommand => {
            std.debug.print("❌ Invalid command. Use 'zepplin help' for usage.\n", .{});
            return;
        },
        commands.CliError.MissingArgument => {
            std.debug.print("❌ Missing required argument. Use 'zepplin help' for usage.\n", .{});
            return;
        },
        else => return err,
    };

    try cli.executeCommand(allocator, cli_args);
}

test "simple test" {
    var list = std.array_list.AlignedManaged(i32, null).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
