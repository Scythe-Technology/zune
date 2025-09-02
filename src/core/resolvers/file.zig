const std = @import("std");

const Bundle = @import("bundle.zig");

const fs = std.fs;

const LuauFile = struct {
    ext: []const u8,
    val: union(enum) {
        handle: std.fs.File,
        contents: []const u8,
    },
};

const LuaFileType = enum {
    Lua,
    Luau,
};

pub const POSSIBLE_EXTENSIONS = [_][]const u8{
    ".luau",
    ".lua",
    fs.path.sep_str ++ "init.luau",
    fs.path.sep_str ++ "init.lua",
};

pub const LARGEST_EXTENSION = blk: {
    var largest: []const u8 = POSSIBLE_EXTENSIONS[0];
    for (POSSIBLE_EXTENSIONS) |ext| {
        if (ext.len > largest.len)
            largest = ext;
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

pub fn findLuauFile(dir: std.fs.Dir, fileName: []const u8) !?LuauFile {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (fileName.len > path_buf.len - LARGEST_EXTENSION.len)
        return error.PathTooLong;

    @memcpy(path_buf[0..fileName.len], fileName);
    const ext_buf = path_buf[fileName.len..];

    for (POSSIBLE_EXTENSIONS) |ext| {
        @memcpy(ext_buf[0..ext.len], ext);
        const result = path_buf[0 .. fileName.len + ext.len];

        const file = dir.openFile(result, .{ .mode = .read_only }) catch |err| switch (err) {
            else => continue,
        };
        errdefer file.close();

        const md = try file.stat();
        if (md.kind != .file) {
            file.close();
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
                .handle => |h| h.close(),
                .contents => {},
            }
        }
    }
};

pub fn searchLuauFile(buf: []u8, dir: std.fs.Dir, fileName: []const u8) !SearchResult {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;

    if (fileName.len > buf.len - LARGEST_EXTENSION.len)
        return error.PathTooLong;

    var results: SearchResult = .{
        .results = undefined,
    };

    const ext_buf = buf[fileName.len..];

    for (POSSIBLE_EXTENSIONS) |ext| {
        @memcpy(ext_buf[0..ext.len], ext);
        const result = buf[0 .. fileName.len + ext.len];

        const file = dir.openFile(result, .{ .mode = .read_only }) catch |err| switch (err) {
            else => continue,
        };
        errdefer file.close();

        const md = try file.stat();
        if (md.kind != .file) {
            file.close();
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

pub fn searchLuauFileBundle(buf: []u8, b: *const Bundle.Map, fileName: []const u8) !SearchResult {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;

    if (fileName.len > buf.len - LARGEST_EXTENSION.len)
        return error.PathTooLong;

    var results: SearchResult = .{
        .results = undefined,
    };

    const ext_buf = buf[fileName.len..];

    for (POSSIBLE_EXTENSIONS) |ext| {
        @memcpy(ext_buf[0..ext.len], ext);
        const result = buf[0 .. fileName.len + ext.len];

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

pub fn getHomeDir(envMap: std.process.EnvMap) ?[]const u8 {
    return envMap.get("HOME") orelse envMap.get("USERPROFILE");
}

pub inline fn shouldFetchHomeDir(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "~") and (path.len <= 1 or (path[1] == '/' or path[1] == '\\'));
}

pub fn resolve(
    allocator: std.mem.Allocator,
    envMap: std.process.EnvMap,
    paths: []const []const u8,
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
            const homeDir = getHomeDir(envMap) orelse return error.HomeDirNotFound;
            const new_path = try fs.path.join(allocator, &.{ homeDir, path[@min(path.len, 2)..] });
            resolvedPaths[i] = new_path;
            allocated[i] = true;
        } else resolvedPaths[i] = path;
    }

    return try fs.path.resolve(allocator, resolvedPaths[0..paths.len]);
}

pub fn resolveBundled(
    allocator: std.mem.Allocator,
    envMap: std.process.EnvMap,
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
