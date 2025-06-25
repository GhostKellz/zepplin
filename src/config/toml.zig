const std = @import("std");
const types = @import("../common/types.zig");

pub const TomlError = error{
    FileNotFound,
    ParseError,
    InvalidFormat,
    MissingRequiredField,
};

pub const ProjectConfig = struct {
    package: PackageConfig,
    dependencies: std.StringHashMap([]const u8),
    registries: std.StringHashMap([]const u8),

    pub fn deinit(self: *ProjectConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.package.name);
        allocator.free(self.package.version);
        if (self.package.description) |desc| allocator.free(desc);
        if (self.package.author) |author| allocator.free(author);
        if (self.package.license) |license| allocator.free(license);

        var deps_iter = self.dependencies.iterator();
        while (deps_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dependencies.deinit();

        var reg_iter = self.registries.iterator();
        while (reg_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.registries.deinit();
    }
};

pub const PackageConfig = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    minimum_zig_version: ?[]const u8 = null,
};

pub const TomlParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TomlParser {
        return TomlParser{ .allocator = allocator };
    }

    pub fn parseFile(self: *TomlParser, file_path: []const u8) !ProjectConfig {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return TomlError.FileNotFound,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return self.parseString(content);
    }

    pub fn parseString(self: *TomlParser, content: []const u8) !ProjectConfig {
        var config = ProjectConfig{
            .package = undefined,
            .dependencies = std.StringHashMap([]const u8).init(self.allocator),
            .registries = std.StringHashMap([]const u8).init(self.allocator),
        };

        var current_section: enum { none, package, dependencies, registries } = .none;
        var lines = std.mem.split(u8, content, "\n");

        // Package fields
        var name: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        var description: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var license: ?[]const u8 = null;
        var homepage: ?[]const u8 = null;
        var repository: ?[]const u8 = null;
        var minimum_zig_version: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for section headers
            if (std.mem.startsWith(u8, trimmed, "[") and std.mem.endsWith(u8, trimmed, "]")) {
                const section_name = trimmed[1 .. trimmed.len - 1];
                if (std.mem.eql(u8, section_name, "package")) {
                    current_section = .package;
                } else if (std.mem.eql(u8, section_name, "dependencies")) {
                    current_section = .dependencies;
                } else if (std.mem.eql(u8, section_name, "registries")) {
                    current_section = .registries;
                }
                continue;
            }

            // Parse key-value pairs
            const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Remove quotes from value
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }

            switch (current_section) {
                .package => {
                    if (std.mem.eql(u8, key, "name")) {
                        name = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "version")) {
                        version = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "description")) {
                        description = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "author")) {
                        author = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "license")) {
                        license = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "homepage")) {
                        homepage = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "repository")) {
                        repository = try self.allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "minimum_zig_version")) {
                        minimum_zig_version = try self.allocator.dupe(u8, value);
                    }
                },
                .dependencies => {
                    const dep_name = try self.allocator.dupe(u8, key);
                    const dep_version = try self.allocator.dupe(u8, value);
                    try config.dependencies.put(dep_name, dep_version);
                },
                .registries => {
                    const reg_name = try self.allocator.dupe(u8, key);
                    const reg_url = try self.allocator.dupe(u8, value);
                    try config.registries.put(reg_name, reg_url);
                },
                .none => {},
            }
        }

        // Validate required fields
        if (name == null) return TomlError.MissingRequiredField;
        if (version == null) return TomlError.MissingRequiredField;

        config.package = PackageConfig{
            .name = name.?,
            .version = version.?,
            .description = description,
            .author = author,
            .license = license,
            .homepage = homepage,
            .repository = repository,
            .minimum_zig_version = minimum_zig_version,
        };

        return config;
    }

    pub fn generateToml(self: *TomlParser, config: ProjectConfig) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);

        // Package section
        try output.appendSlice("[package]\n");
        try output.appendSlice("name = \"");
        try output.appendSlice(config.package.name);
        try output.appendSlice("\"\n");

        try output.appendSlice("version = \"");
        try output.appendSlice(config.package.version);
        try output.appendSlice("\"\n");

        if (config.package.description) |desc| {
            try output.appendSlice("description = \"");
            try output.appendSlice(desc);
            try output.appendSlice("\"\n");
        }

        if (config.package.author) |author| {
            try output.appendSlice("author = \"");
            try output.appendSlice(author);
            try output.appendSlice("\"\n");
        }

        if (config.package.license) |license| {
            try output.appendSlice("license = \"");
            try output.appendSlice(license);
            try output.appendSlice("\"\n");
        }

        if (config.package.homepage) |homepage| {
            try output.appendSlice("homepage = \"");
            try output.appendSlice(homepage);
            try output.appendSlice("\"\n");
        }

        if (config.package.repository) |repository| {
            try output.appendSlice("repository = \"");
            try output.appendSlice(repository);
            try output.appendSlice("\"\n");
        }

        if (config.package.minimum_zig_version) |min_version| {
            try output.appendSlice("minimum_zig_version = \"");
            try output.appendSlice(min_version);
            try output.appendSlice("\"\n");
        }

        // Dependencies section
        if (config.dependencies.count() > 0) {
            try output.appendSlice("\n[dependencies]\n");
            var deps_iter = config.dependencies.iterator();
            while (deps_iter.next()) |entry| {
                try output.appendSlice(entry.key_ptr.*);
                try output.appendSlice(" = \"");
                try output.appendSlice(entry.value_ptr.*);
                try output.appendSlice("\"\n");
            }
        }

        // Registries section
        if (config.registries.count() > 0) {
            try output.appendSlice("\n[registries]\n");
            var reg_iter = config.registries.iterator();
            while (reg_iter.next()) |entry| {
                try output.appendSlice(entry.key_ptr.*);
                try output.appendSlice(" = \"");
                try output.appendSlice(entry.value_ptr.*);
                try output.appendSlice("\"\n");
            }
        }

        return output.toOwnedSlice();
    }
};
