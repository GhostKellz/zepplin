const std = @import("std");
const types = @import("../common/types.zig");

pub const CliError = error{
    InvalidCommand,
    MissingArgument,
    PackageNotFound,
    NetworkError,
    AuthenticationFailed,
    InvalidConfiguration,
};

pub const Command = enum {
    init,
    add,
    update,
    build,
    publish,
    login,
    help,
    discover,
    browse,
    trending,

    pub fn fromString(str: []const u8) ?Command {
        if (std.mem.eql(u8, str, "init")) return .init;
        if (std.mem.eql(u8, str, "add")) return .add;
        if (std.mem.eql(u8, str, "update")) return .update;
        if (std.mem.eql(u8, str, "build")) return .build;
        if (std.mem.eql(u8, str, "publish")) return .publish;
        if (std.mem.eql(u8, str, "login")) return .login;
        if (std.mem.eql(u8, str, "help")) return .help;
        if (std.mem.eql(u8, str, "discover")) return .discover;
        if (std.mem.eql(u8, str, "browse")) return .browse;
        if (std.mem.eql(u8, str, "trending")) return .trending;
        return null;
    }
};

pub const CliArgs = struct {
    command: Command,
    package_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    registry_url: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    category: ?[]const u8 = null,
    verbose: bool = false,
};

pub fn parseArgs(args: [][:0]u8) !CliArgs {
    if (args.len < 2) {
        return CliError.MissingArgument;
    }

    const command = Command.fromString(args[1]) orelse return CliError.InvalidCommand;

    var cli_args = CliArgs{ .command = command };

    // Parse additional arguments based on command
    switch (command) {
        .add => {
            if (args.len < 3) return CliError.MissingArgument;
            cli_args.package_name = args[2];
            if (args.len > 3) cli_args.version = args[3];
        },
        .login => {
            if (args.len > 2) cli_args.registry_url = args[2];
        },
        .discover => {
            if (args.len > 2) cli_args.package_name = args[2];
        },
        .browse, .trending => {
            // Parse --category=<name> option
            for (args[2..]) |arg| {
                if (std.mem.startsWith(u8, arg, "--category=")) {
                    cli_args.category = arg[11..]; // Skip "--category="
                }
            }
        },
        else => {},
    }

    return cli_args;
}

pub fn printHelp() void {
    const help_text =
        \\Zepplin - Zig Package Manager
        \\
        \\USAGE:
        \\    zepplin <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    init               Initialize a new Zig project
        \\    add <package>      Add a dependency
        \\    update             Update all dependencies
        \\    build              Build the project with dependencies
        \\    publish            Publish package to registry
        \\    login [registry]   Authenticate with registry
        \\    discover [query]   Discover packages via Zigistry
        \\    browse             Browse packages by category
        \\    trending           Show trending packages
        \\    help               Show this help message
        \\
        \\EXAMPLES:
        \\    zepplin init
        \\    zepplin add xev
        \\    zepplin add xev@1.2.0
        \\    zepplin publish
        \\    zepplin discover "web framework"
        \\    zepplin browse --category=cli
        \\    zepplin trending
        \\
    ;

    std.debug.print("{s}", .{help_text});
}
