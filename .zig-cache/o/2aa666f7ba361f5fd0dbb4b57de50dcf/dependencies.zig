pub const packages = struct {
    pub const @"shroud-1.2.4-z7C8mXYWBQDnbScUT0wV5HI44ceuV9BYHelv9F-82sqJ" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/shroud-1.2.4-z7C8mXYWBQDnbScUT0wV5HI44ceuV9BYHelv9F-82sqJ";
        pub const build_zig = @import("shroud-1.2.4-z7C8mXYWBQDnbScUT0wV5HI44ceuV9BYHelv9F-82sqJ");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zsync", "zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" },
        };
    };
    pub const @"zqlite-1.2.5-0Cdu4tJ8DgBa7wQAf6Oe7-6XEYcX7BeVpVKoW8PdUfAe" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zqlite-1.2.5-0Cdu4tJ8DgBa7wQAf6Oe7-6XEYcX7BeVpVKoW8PdUfAe";
        pub const build_zig = @import("zqlite-1.2.5-0Cdu4tJ8DgBa7wQAf6Oe7-6XEYcX7BeVpVKoW8PdUfAe");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zsync", "zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" },
        };
    };
    pub const @"zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_";
        pub const build_zig = @import("zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "shroud", "shroud-1.2.4-z7C8mXYWBQDnbScUT0wV5HI44ceuV9BYHelv9F-82sqJ" },
    .{ "zqlite", "zqlite-1.2.5-0Cdu4tJ8DgBa7wQAf6Oe7-6XEYcX7BeVpVKoW8PdUfAe" },
    .{ "zsync", "zsync-0.5.4-KAuheV0SHQBxubuzXagj1oq5B2KE4VhMWTAAAaInwB2_" },
};
