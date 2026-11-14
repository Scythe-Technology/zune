const std = @import("std");

const Zune = @import("zune");

const Bundle = @import("bundle.zig");

const fs = std.fs;

const Extension = struct {
    ext: []const u8,
    type: Type,

    pub const Type = enum {
        Lua,
        Luau,
        InitLua,
        InitLuau,
    };
};

const LuauFile = struct {
    ext: Extension,
    val: union(enum) {
        handle: std.Io.File,
        contents: []const u8,
    },
};

const LuaFileType = enum {
    Lua,
    Luau,
};

pub const POSSIBLE_EXTENSIONS = [_]Extension{
    .{ .ext = ".luau", .type = .Luau },
    .{ .ext = ".lua", .type = .Lua },
    .{ .ext = fs.path.sep_str ++ "init.luau", .type = .InitLuau },
    .{ .ext = fs.path.sep_str ++ "init.lua", .type = .InitLua },
};

pub const LARGEST_EXTENSION = blk: {
    var largest: []const u8 = POSSIBLE_EXTENSIONS[0].ext;
    for (POSSIBLE_EXTENSIONS) |ext| {
        if (ext.ext.len > largest.len)
            largest = ext.ext;
    }
    break :blk largest;
};

pub fn getLuaFileType(path: []const u8) ?LuaFileType {
    if (std.mem.endsWith(u8, path, ".lua"))
        return .Lua;
    if (std.mem.endsWith(u8, path, ".luau"))
        return .Luau;
    return null;
}

pub fn findLuauFile(dir: std.Io.Dir, fileName: []const u8) !?LuauFile {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    if (fileName.len > path_buf.len - LARGEST_EXTENSION.len)
        return error.PathTooLong;

    @memcpy(path_buf[0..fileName.len], fileName);
    const ext_buf = path_buf[fileName.len..];

    for (POSSIBLE_EXTENSIONS) |ext| {
        @memcpy(ext_buf[0..ext.ext.len], ext.ext);
        const result = path_buf[0 .. fileName.len + ext.ext.len];

        const file = dir.openFile(Zune.io(), result, .{ .mode = .read_only }) catch |err| switch (err) {
            else => continue,
        };
        errdefer file.close(Zune.io());

        const md = try file.stat(Zune.io());
        if (md.kind != .file) {
            file.close(Zune.io());
            continue;
        }

        return .{
            .val = .{ .handle = file },
            .ext = ext,
        };
    }

    return null;
}

pub const SearchResult = struct {
    results: [POSSIBLE_EXTENSIONS.len]LuauFile,
    count: usize = 0,

    pub inline fn first(self: SearchResult) LuauFile {
        std.debug.assert(self.count > 0);
        return self.results[0];
    }

    pub inline fn slice(self: SearchResult) []const LuauFile {
        return self.results[0..self.count];
    }

    pub fn deinit(self: SearchResult) void {
        for (self.results[0..self.count]) |file| {
            switch (file.val) {
                .handle => |h| h.close(Zune.io()),
                .contents => {},
            }
        }
    }
};

pub fn searchLuauFile(buf: []u8, dir: std.Io.Dir, fileName: []const u8) !SearchResult {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;

    if (fileName.len > buf.len - LARGEST_EXTENSION.len)
        return error.PathTooLong;

    var results: SearchResult = .{
        .results = undefined,
    };

    const ext_buf = buf[fileName.len..];

    for (POSSIBLE_EXTENSIONS) |ext| {
        @memcpy(ext_buf[0..ext.ext.len], ext.ext);
        const result = buf[0 .. fileName.len + ext.ext.len];

        const file = dir.openFile(Zune.io(), result, .{ .mode = .read_only }) catch |err| switch (err) {
            else => continue,
        };
        errdefer file.close(Zune.io());

        const md = try file.stat(Zune.io());
        if (md.kind != .file) {
            file.close(Zune.io());
            continue;
        }

        results.results[results.count] = .{
            .val = .{ .handle = file },
            .ext = ext,
        };
        results.count += 1;
    }

    return results;
}

pub fn searchLuauFileBundle(buf: []u8, b: *Bundle.Map, fileName: []const u8) !SearchResult {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;

    if (fileName.len > buf.len - LARGEST_EXTENSION.len)
        return error.PathTooLong;

    var results: SearchResult = .{
        .results = undefined,
    };

    const ext_buf = buf[fileName.len..];

    for (POSSIBLE_EXTENSIONS) |ext| {
        @memcpy(ext_buf[0..ext.ext.len], ext.ext);
        const result = buf[0 .. fileName.len + ext.ext.len];

        const contents = b.loadScript(result) catch |err| switch (err) {
            else => continue,
        };

        results.results[results.count] = .{
            .val = .{ .contents = contents },
            .ext = ext,
        };
        results.count += 1;
    }

    return results;
}

pub fn getHomeDir(envMap: std.process.Environ.Map) ?[]const u8 {
    return envMap.get("HOME") orelse envMap.get("USERPROFILE");
}

pub inline fn shouldFetchHomeDir(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "~") and (path.len <= 1 or (path[1] == '/' or path[1] == '\\'));
}

pub fn resolve(
    allocator: std.mem.Allocator,
    envMap: std.process.Environ.Map,
    paths: []const []const u8,
) ![:0]u8 {
    std.debug.assert(paths.len <= 2);
    var resolvedPaths: [2][]const u8 = undefined;
    var allocated: [2]bool = undefined;
    @memset(allocated[0..], false);
    std.debug.assert(paths.len <= resolvedPaths.len);

    defer for (resolvedPaths[0..paths.len], 0..) |path, i| {
        if (allocated[i])
            allocator.free(path);
    };

    for (paths, 0..) |path, i| {
        if (shouldFetchHomeDir(path)) {
            const homeDir = getHomeDir(envMap) orelse return error.HomeDirNotFound;
            const new_path = try fs.path.join(allocator, &.{ homeDir, path[@min(path.len, 2)..] });
            resolvedPaths[i] = new_path;
            allocated[i] = true;
        } else resolvedPaths[i] = path;
    }

    var buffer: std.ArrayList(u8) = try .initCapacity(allocator, 1);
    defer buffer.deinit(allocator);

    buffer.appendAssumeCapacity('@');

    try fs.path.resolveAppend(allocator, &buffer, resolvedPaths[0..paths.len]);

    return buffer.toOwnedSliceSentinel(allocator, 0);
}

pub fn resolveBundled(
    allocator: std.mem.Allocator,
    envMap: std.process.Environ.Map,
    paths: []const []const u8,
    map: ?Bundle.Map,
) ![]u8 {
    std.debug.assert(paths.len <= 2);
    var resolvedPaths: [2][]const u8 = undefined;
    var allocated: [2]bool = undefined;
    @memset(allocated[0..], false);
    std.debug.assert(paths.len <= resolvedPaths.len);

    defer for (resolvedPaths[0..paths.len], 0..) |path, i| {
        if (allocated[i])
            allocator.free(path);
    };

    for (paths, 0..) |path, i| {
        if (shouldFetchHomeDir(path)) {
            const homeDir = if (map) |b|
                b.home_dir
            else
                getHomeDir(envMap) orelse return error.HomeDirNotFound;
            const new_path = try fs.path.join(allocator, &.{ homeDir, path[@min(path.len, 2)..] });
            resolvedPaths[i] = new_path;
            allocated[i] = true;
        } else resolvedPaths[i] = path;
    }

    return try fs.path.resolve(allocator, resolvedPaths[0..paths.len]);
}
