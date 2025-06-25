pub const packages = struct {
    pub const @"TokioZ-0.0.0-DgtPReljAgAuGaoLtQCm_E-UA_7j_TAGQ8kkV-mtjz4V" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/TokioZ-0.0.0-DgtPReljAgAuGaoLtQCm_E-UA_7j_TAGQ8kkV-mtjz4V";
        pub const build_zig = @import("TokioZ-0.0.0-DgtPReljAgAuGaoLtQCm_E-UA_7j_TAGQ8kkV-mtjz4V");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zcrypto-0.0.0-rgQAI8fbAwClmk2Me7c0fNLBtFWbukRh3ZgB2_IckfYz" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zcrypto-0.0.0-rgQAI8fbAwClmk2Me7c0fNLBtFWbukRh3ZgB2_IckfYz";
        pub const build_zig = @import("zcrypto-0.0.0-rgQAI8fbAwClmk2Me7c0fNLBtFWbukRh3ZgB2_IckfYz");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zqlite-0.3.0-yzD604CqBAB9vTKM7dMR-DzDew9XCKYFPdwREkPQR5q9" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zqlite-0.3.0-yzD604CqBAB9vTKM7dMR-DzDew9XCKYFPdwREkPQR5q9";
        pub const build_zig = @import("zqlite-0.3.0-yzD604CqBAB9vTKM7dMR-DzDew9XCKYFPdwREkPQR5q9");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zcrypto", "zcrypto-0.0.0-rgQAI8fbAwClmk2Me7c0fNLBtFWbukRh3ZgB2_IckfYz" },
            .{ "tokioz", "TokioZ-0.0.0-DgtPReljAgAuGaoLtQCm_E-UA_7j_TAGQ8kkV-mtjz4V" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zqlite", "zqlite-0.3.0-yzD604CqBAB9vTKM7dMR-DzDew9XCKYFPdwREkPQR5q9" },
};
