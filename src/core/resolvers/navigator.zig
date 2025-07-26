const std = @import("std");
const builtin = @import("builtin");

const Config = @import("config.zig");

const fs = std.fs;

const PathType = enum {
    RelativeToCurrent,
    RelativeToParent,
    Aliased,
    Unsupported,

    pub fn get(path: []const u8) PathType {
        if (path.len == 0)
            return .Unsupported;
        switch (path[0]) {
            '.' => switch (if (path.len == 1) return .Unsupported else path[1]) {
                '/', '\\' => return .RelativeToCurrent,
                '.' => switch (if (path.len == 2) return .Unsupported else path[2]) {
                    '/', '\\' => return .RelativeToParent,
                    else => return .Unsupported,
                },
                else => return .Unsupported,
            },
            '@' => return .Aliased,
            else => return .Unsupported,
        }
    }
};

pub const INIT_SUFFIXES: []const [:0]const u8 = &.{
    "/init.luau",
    "/init.lua",
    "\\init.luau",
    "\\init.lua",
};
pub const SUFFIXES: []const [:0]const u8 = &.{
    ".luau",
    ".lua",
};

pub fn extractAlias(path: []const u8) ![]const u8 {
    std.debug.assert(path.len >= 1);
    const aliasStart = 1; // Ignore the '@' alias prefix
    const aliasEnd = std.mem.indexOfAny(u8, path[aliasStart..], "/\\") orelse (path.len - aliasStart);
    return path[aliasStart .. aliasStart + aliasEnd];
}

pub fn isInitSuffix(path: []const u8) bool {
    inline for (INIT_SUFFIXES) |suffix| {
        if (std.mem.eql(u8, path, suffix[1..]))
            return true;
    }
    return false;
}

pub fn removeSuffix(path: []const u8) []const u8 {
    for (INIT_SUFFIXES ++ SUFFIXES) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) {
            return path[0 .. path.len - suffix.len];
        }
    }
    return path;
}

pub fn getLuaurcPath(buf: []u8, path: []const u8) []const u8 {
    std.debug.assert(buf.len >= path.len + 8);
    var written: usize = 0;
    if (path.len > 0) {
        @memcpy(buf[0..path.len], path);
        written += path.len;
        switch (path[path.len - 1]) {
            '/', '\\' => written -= 1,
            else => {},
        }
    }
    const END = fs.path.sep_str ++ ".luaurc";
    @memcpy(buf[written .. written + END.len], END);
    const out = buf[0 .. written + END.len];
    if (comptime builtin.os.tag == .windows)
        std.mem.replaceScalar(u8, out, '/', fs.path.sep);
    return out;
}

fn joinPathScalar(out: []u8, scalar: u8, path: []const u8) []u8 {
    std.debug.assert(out.len >= path.len + 2);
    out[0] = scalar;
    if (path.len == 0)
        return out[0..1];
    switch (path[0]) {
        '/', '\\' => {
            @memcpy(out[1 .. path.len + 1], path);
            return out[0 .. path.len + 1];
        },
        else => {
            out[1] = fs.path.sep;
            @memcpy(out[2 .. path.len + 2], path);
            return out[0 .. path.len + 2];
        },
    }
}

fn joinPath(allocator: std.mem.Allocator, path: []const u8, path2: []const u8) ![]u8 {
    var size: usize = 0;
    const non_empty_path = path.len > 0;
    const non_empty_path2 = path2.len > 0;
    size += path.len;
    size += path2.len;
    var sep: ?u8 = null;
    var offset: usize = 0;
    if (non_empty_path and non_empty_path2) {
        switch (path[path.len - 1]) {
            '/', '\\' => {},
            else => {
                size += 1;
                sep = fs.path.sep;
            },
        }
        switch (path2[0]) {
            '/', '\\' => {
                size -= 1;
                offset = 1;
            },
            else => {},
        }
    }
    const buf = try allocator.alloc(u8, size);
    var written: usize = 0;
    if (non_empty_path) {
        @memcpy(buf[0..path.len], path);
        written += path.len;
    }
    if (sep) |s| {
        buf[written] = s;
        written += 1;
    }
    if (non_empty_path2) {
        @memcpy(buf[written..][0 .. path2.len - offset], path2[offset..]);
        written += path2.len - offset;
    }
    std.debug.assert(written == buf.len);
    return buf[0..written];
}

pub fn dirname(path: []const u8) ?[]const u8 {
    // This code is based on std.fs.path.dirnameWindows but modified to work on all platforms
    if (path.len == 0)
        return null;

    const root_slice = fs.path.diskDesignator(path);
    if (path.len == root_slice.len)
        return null;

    const have_root_slash = path.len > root_slice.len and (path[root_slice.len] == '/' or path[root_slice.len] == '\\');

    var end_index: usize = path.len - 1;

    while (path[end_index] == '/' or path[end_index] == '\\') {
        if (end_index == 0)
            return null;
        end_index -= 1;
    }

    while (path[end_index] != '/' and path[end_index] != '\\') {
        if (end_index == 0)
            return null;
        end_index -= 1;
    }

    if (have_root_slash and end_index == root_slice.len) {
        end_index += 1;
    }

    if (end_index == 0)
        return null;

    return path[0..end_index];
}

pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0)
        return false;
    if (comptime builtin.os.tag == .windows) {
        return fs.path.isAbsolute(path);
    } else {
        switch (path[0]) {
            '/', '\\' => return true,
            else => return false,
        }
    }
}

var path_buffer: [(std.fs.max_path_bytes * 4) + 32]u8 = undefined;
var PATH_ALLOCATOR = std.heap.FixedBufferAllocator.init(&path_buffer);

/// Resolves the `script` path from provided `from` path and `path`.
///
/// Features:
/// - result path would be OS-specific, i.e. it would use `/` on Unix-like systems and `\` on Windows.
///
/// This functions does not:
/// - resolve the file itself, but rather the path to the file.
/// - search for the file, such as `.luau`, `.lua`, `/init.luau` or `/init.lua`.
/// - check if the path has `.luau` or `.lua` suffixes, the caller is responsible redundant file extension checks accordance to the RFC.
///
/// The function would assume you are operating with `cwd` (current working directory) as the base path.
///
/// Examples:
/// - `src/main.luau` navigating to `./utils.luau` will result in `src/utils.luau`.
/// - `src/main.luau` navigating to `../utils.luau` will result in `utils.luau`.
/// - `src/main.luau` navigating to `@alias/utils.luau` will resolve the `@alias` alias from the `src/.luaurc` or `.luaurc` configuration file.
///
/// Designed with and for the luau specification:
/// - [Amended Require Syntax and Resolution Semantics](https://rfcs.luau.org/amended-require-resolution.html)
/// - [Abstract module paths and `init.luau`](https://rfcs.luau.org/abstract-module-paths-and-init-dot-luau.html)
/// - [Configure analysis via .luaurc](https://rfcs.luau.org/config-luaurc.html)
///
pub fn navigate(allocator: std.mem.Allocator, context: anytype, from: []const u8, path: []const u8, out_err: ?*?[]const u8) ![]u8 {
    if (from.len > fs.max_path_bytes or path.len > fs.max_path_bytes)
        return error.PathTooLong;

    const path_type = PathType.get(path);
    if (path_type == .Unsupported)
        return error.PathUnsupported;

    defer PATH_ALLOCATOR.reset();

    const path_allocator = PATH_ALLOCATOR.allocator();

    const chunk_size = @max(from.len, path.len);
    const chunk_buf: []u8 = try path_allocator.alloc(u8, (chunk_size * 2) + 10);

    const buf = chunk_buf[0 .. chunk_size + 8];
    const path_buf = chunk_buf[chunk_size + 8 ..][0 .. chunk_size + 2];

    switch (path_type) {
        .Aliased => {
            const alias_name = try std.ascii.allocLowerString(path_allocator, try extractAlias(path));

            const adjusted = removeSuffix(from);
            var parent: ?[]const u8 = dirname(adjusted) orelse
                if (isInitSuffix(from)) ".." else null;

            const absolute = isAbsolute(from);
            if (absolute and parent == null)
                return error.PathNotFound;

            parent = if (!absolute) joinPathScalar(path_buf, '.', parent orelse "") else parent.?;

            var foundAlias: ?[]const u8 = null;
            var config: ?Config = null;
            defer if (config) |*c| context.freeConfig(c);
            while (parent) |parent_path| : (parent = dirname(parent_path)) {
                blk: {
                    if (parent_path.len + 8 > buf.len)
                        return error.PathTooLong;
                    const config_path = getLuaurcPath(buf, parent_path);
                    if (config) |*c|
                        context.freeConfig(c);
                    config = null;
                    config = context.getConfig(config_path, out_err) catch |err| switch (@as(anyerror, @errorCast(err))) {
                        error.NotPresent => break :blk,
                        else => return err,
                    };

                    if (config.?.aliases.get(alias_name)) |value| {
                        foundAlias = value;
                        break;
                    }
                }
            }
            if (foundAlias == null) {
                if (!std.mem.eql(u8, alias_name, "self")) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try std.fmt.allocPrint(allocator, "@{s} is not a valid alias", .{alias_name});
                    return error.AliasNotFound;
                }

                const ext_path = joinPathScalar(path_buf, '.', path[alias_name.len + 1 ..]);
                std.mem.replaceScalar(u8, ext_path, '\\', '/');
                return try context.resolvePathAlloc(
                    allocator,
                    adjusted,
                    ext_path,
                );
            }
            const alias_value = foundAlias.?;
            if (alias_value.len > fs.max_path_bytes)
                return error.PathTooLong;

            switch (PathType.get(alias_value)) {
                .RelativeToCurrent, .RelativeToParent => {},
                .Aliased => {
                    if (out_err) |ptr_out|
                        ptr_out.* = try std.fmt.allocPrint(allocator, "alias \"@{s}\" cannot point to an aliased path (\"{s}\")", .{ alias_name, alias_value });
                    return error.AliasPathNotSupported;
                },
                .Unsupported => if (!isAbsolute(alias_value)) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try std.fmt.allocPrint(allocator, "could not jump to alias \"{s}\"", .{alias_value});
                    return error.AliasJumpFail;
                },
            }

            const ext_path = try joinPath(path_allocator, alias_value, path[alias_name.len + 1 ..]);
            std.mem.replaceScalar(u8, ext_path, '\\', '/');
            return try context.resolvePathAlloc(
                allocator,
                if (parent) |dir| dir else from,
                ext_path,
            );
        },
        .RelativeToCurrent, .RelativeToParent => {
            const adjusted = removeSuffix(from);
            const parent: ?[]const u8 = dirname(adjusted) orelse
                if (isInitSuffix(from)) ".." else null;

            const absolute = isAbsolute(from);
            if (absolute and parent == null)
                return error.PathNotFound;

            const section = buf[0..path.len];
            @memcpy(section, path);
            std.mem.replaceScalar(u8, section, '\\', '/');

            return try context.resolvePathAlloc(
                allocator,
                if (!absolute) joinPathScalar(path_buf, '.', parent orelse "") else parent.?,
                section,
            );
        },
        .Unsupported => unreachable,
    }
}

fn OSPath(comptime path: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, path, '/');
    var static: []const u8 = iter.first();
    while (iter.next()) |component| {
        static = static ++ fs.path.sep_str ++ component;
    }
    return static;
}

fn navigateTest(allocator: std.mem.Allocator, context: anytype, comptime expected: []const u8, from: []const u8, path: []const u8) !void {
    const result = try navigate(allocator, context, from, path, null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(comptime OSPath(expected), result);
}

fn navigateTestError(allocator: std.mem.Allocator, context: anytype, from: []const u8, path: []const u8, err: ?[]const u8) !void {
    var err_out: ?[]const u8 = null;
    defer if (err_out) |e| allocator.free(e);
    if (navigate(allocator, context, from, path, &err_out)) |_|
        unreachable
    else |caught| {
        if (err) |expected_err|
            try std.testing.expectEqualStrings(expected_err, err_out orelse @panic("Expected error not found"));
        return caught;
    }
}

test "empty context" {
    const allocator = std.testing.allocator;
    const EmptyContext = struct {
        pub fn getConfig(_: []const u8, _: ?*?[]const u8) !Config {
            unreachable;
        }
        pub fn freeConfig(_: *Config) void {
            unreachable;
        }
        pub fn resolvePathAlloc(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
            return fs.path.resolve(a, &.{ from, to });
        }
    };

    try navigateTest(allocator, EmptyContext, "test", "./script/init.luau", "./test");
    try navigateTest(allocator, EmptyContext, "test", "script/init.luau", "./test");
    try navigateTest(allocator, EmptyContext, "script/test", "script/main.luau", "./test");
    try navigateTest(allocator, EmptyContext, "script/test", "./script/main.luau", "./test");
    try navigateTest(allocator, EmptyContext, "../test", "init.luau", "./test");

    try navigateTest(allocator, EmptyContext, "/test", "/script/init.luau", "./test");
    try navigateTest(allocator, EmptyContext, "/script/test", "/script/main.luau", "./test");

    try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "/init.luau", "./test", null));
    try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "/", "./main", null));
    try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "/", "@alias/", null));

    if (comptime builtin.os.tag == .windows) {
        try navigateTest(allocator, EmptyContext, "C:/test", "C:/script/init.luau", "./test");
        try navigateTest(allocator, EmptyContext, "C:/script/test", "C:/script/main.luau", "./test");

        try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "C:/init.luau", "./test", null));
        try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "C:/", "./main", null));
        try std.testing.expectError(error.PathNotFound, navigateTestError(allocator, EmptyContext, "C:/", "@alias/", null));
    }
}

test "home context" {
    const allocator = std.testing.allocator;
    const HomeContext = struct {
        allocator: std.mem.Allocator,
        pub fn getConfig(self: *@This(), path: []const u8, _: ?*?[]const u8) !Config {
            if (!std.mem.eql(u8, path, comptime OSPath("./.luaurc")) and !std.mem.eql(u8, path, comptime OSPath("/.luaurc")))
                std.testing.expectEqualStrings(comptime OSPath("/.luaurc"), path) catch @panic("Path mismatch");

            var config: Config = .{};
            errdefer config.deinit(self.allocator);

            const key = try allocator.dupe(u8, "packages");
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, "./packages");
            errdefer allocator.free(value);

            try config.aliases.put(self.allocator, key, value);

            return config;
        }
        pub fn freeConfig(self: *@This(), config: *Config) void {
            config.deinit(self.allocator);
        }
        pub fn resolvePathAlloc(_: *@This(), a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
            return fs.path.resolve(a, &.{ from, to });
        }
    };

    var context: HomeContext = .{
        .allocator = allocator,
    };
    try navigateTest(allocator, &context, "packages/json", "script/init.luau", "@packages/json");
    try navigateTest(allocator, &context, "packages/json", "main.luau", "@packages/json");
    try navigateTest(allocator, &context, "packages", "main.luau", "@packages");
    try navigateTest(allocator, &context, "packages", "main.luau", "@packages/");

    try navigateTest(allocator, &context, "script/test", "script/init.luau", "@self/test");
    try navigateTest(allocator, &context, "main/test", "main.luau", "@self/test");
    try navigateTest(allocator, &context, "src/child", "src/init.luau", "@self/child");
    try navigateTest(allocator, &context, "main", "main.luau", "@self");
    try navigateTest(allocator, &context, "main/sub/child", "main.luau", "@self/sub/child");
    try navigateTest(allocator, &context, "test", "main.luau", "@self/../test");

    try navigateTest(allocator, &context, "/packages/json", "/script/init.luau", "@packages/json");
    try navigateTest(allocator, &context, "/packages/json", "/main.luau", "@packages/json");
    try navigateTest(allocator, &context, "/packages", "/main.luau", "@packages");
    try navigateTest(allocator, &context, "/packages", "/main.luau", "@packages/");
}

test "broken config" {
    const allocator = std.testing.allocator;
    const BrokenConfig = struct {
        pub fn getConfig(_: []const u8, err: ?*?[]const u8) !Config {
            std.testing.expectError(error.SyntaxError, Config.parse(std.testing.allocator, "{", err)) catch @panic("Expected syntax error");
            return error.SyntaxError;
        }
        pub fn freeConfig(_: *Config) void {}
        pub fn resolvePathAlloc(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
            return fs.path.resolve(a, &.{ from, to });
        }
    };
    try navigateTest(allocator, BrokenConfig, "/main", "/src", "./main");
    try navigateTest(allocator, BrokenConfig, "main", "src", "./main");

    try std.testing.expectError(error.SyntaxError, navigateTestError(allocator, BrokenConfig, "/src", "@alias/", ".luaurc: Expected field key at line 1"));
    try std.testing.expectError(error.SyntaxError, navigateTestError(allocator, BrokenConfig, "src", "@alias/", ".luaurc: Expected field key at line 1"));
}

test "config tree" {
    const allocator = std.testing.allocator;
    const ConfigTree = std.StaticStringMap([:0]const u8).initComptime(.{
        .{
            OSPath("./script/.luaurc"),
            \\{
            \\  "aliases": {
            \\    "packages": "./packages",
            \\  }
            \\}
        },
        .{
            OSPath("./foo/bar/.luaurc"),
            \\{
            \\  "aliases": {
            \\    "sample": "/sample",
            \\  }
            \\}
        },
        .{
            OSPath("./foo/.luaurc"),
            \\{
            \\  "aliases": {
            \\    "sample": "/unknown",
            \\  }
            \\}
        },
    });

    const ConfigContext = struct {
        pub fn getConfig(path: []const u8, err: ?*?[]const u8) !Config {
            return Config.parse(std.testing.allocator, ConfigTree.get(path) orelse return error.NotPresent, err);
        }
        pub fn freeConfig(config: *Config) void {
            config.deinit(std.testing.allocator);
        }
        pub fn resolvePathAlloc(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
            return fs.path.resolve(a, &.{ from, to });
        }
    };

    try navigateTest(allocator, ConfigContext, "script/packages/main", "script/main.luau", "@packages/main");
    try navigateTest(allocator, ConfigContext, "script/packages/main", "script/very/long/child/tree/main.luau", "@packages/main");
    try navigateTest(allocator, ConfigContext, "/unknown", "foo/main.luau", "@sample");
    try navigateTest(allocator, ConfigContext, "/sample", "foo/bar/main.luau", "@sample");

    try std.testing.expectError(error.AliasNotFound, navigateTestError(allocator, ConfigContext, "script/main.luau", "@alias/", "@alias is not a valid alias"));
    try std.testing.expectError(error.AliasNotFound, navigateTestError(allocator, ConfigContext, "foo/bar/main.luau", "@packages/", "@packages is not a valid alias"));
    try std.testing.expectError(error.AliasNotFound, navigateTestError(allocator, ConfigContext, "foo/main.luau", "@packages/", "@packages is not a valid alias"));
}
