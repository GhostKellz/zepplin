const std = @import("std");
const cli = @import("cli/cli.zig");
const commands = @import("cli/commands.zig");
const server = @import("server/server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

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
        std.Io.Dir.cwd().createDir(io, data_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.debug.print("✅ Data directory exists: {s}\n", .{data_dir});
            },
            else => {
                std.debug.print("❌ Failed to create data directory: {}\n", .{err});
                return err;
            },
        };

        std.debug.print("🗄️ Initializing database...\n", .{});
        var registry_server = server.Server.init(allocator, io, init.environ_map, port, data_dir) catch |err| {
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

    try cli.executeCommand(allocator, io, cli_args);
}

test "simple test" {
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
