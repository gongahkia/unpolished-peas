pub const packages = struct {
    pub const @"packages/networking" = struct {
        pub const available = true;
        pub const build_root = "/Users/gongahkia/Desktop/coding/projects/minna-san/packages/networking";
        pub const build_zig = @import("packages/networking");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"packages/services" = struct {
        pub const available = true;
        pub const build_root = "/Users/gongahkia/Desktop/coding/projects/minna-san/packages/services";
        pub const build_zig = @import("packages/services");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "networking", "packages/networking" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "networking", "packages/networking" },
    .{ "services", "packages/services" },
};
