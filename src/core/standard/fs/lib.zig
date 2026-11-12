const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Dir = Zune.objects.Dir;
const FileWatcher = Zune.objects.FileWatcher;

const Watcher = @import("./Watcher.zig");

const VM = luau.VM;

const fs = std.fs;
const Io = std.Io;

pub const LIB_NAME = "fs";
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => .Full,
        .freebsd => .Full,
        else => null,
    };
}

pub fn lua_embedFile(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
    const path = L.Lcheckstring(1);
    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    {
        var level: i32 = 1;
        while (true) : (level += 1) {
            if (!L.getinfo(level, "s", &ar))
                return L.Zerror("could not get source");
            if (ar.what == .lua)
                break;
        }
    }

    const from = Zune.Resolvers.Require.getFilePath(ar.source);

    const dirname = std.fs.path.dirname(from) orelse ".";

    const resolved_path = try std.fs.path.resolve(allocator, &.{ dirname, path });
    defer allocator.free(resolved_path);

    blk: {
        if (Zune.State.bundle) |*b| {
            try L.Zpushbuffer(try b.loadFile(resolved_path));
            break :blk;
        }
        const contents = try Io.Dir.cwd().readFileAlloc(Zune.io(), resolved_path, allocator, .unlimited);
        defer allocator.free(contents);
        try L.Zpushbuffer(contents);
    }

    return 1;
}
fn listEmbedded(L: *VM.lua.State, comptime kind: enum { script, file }) !i32 {
    try L.createtable(0, 0);
    if (Zune.State.bundle) |b| {
        var iter = b.map.iterator();
        var count: i32 = 1;
        while (iter.next()) |entry| {
            if (kind == .file and entry.value_ptr.* == .file or
                kind == .script and entry.value_ptr.* == .script)
            {
                defer count += 1;
                try L.pushlstring(entry.key_ptr.*);
                try L.rawseti(-2, count);
            }
        }
    }
    return 1;
}
pub fn lua_embeddedScripts(L: *VM.lua.State) !i32 {
    return try listEmbedded(L, .script);
}
pub fn lua_embeddedFiles(L: *VM.lua.State) !i32 {
    return try listEmbedded(L, .file);
}

fn openTempParent(io: Io) !Io.Dir {
    const keys: []const []const u8 = if (comptime builtin.os.tag == .windows)
        &.{ "TEMP", "TMP" }
    else
        &.{"TMPDIR"};

    for (keys) |key| {
        const value = Zune.State.env_map.get(key) orelse continue;
        if (value.len == 0 or !fs.path.isAbsolute(value))
            continue;
        return Io.Dir.openDirAbsolute(io, value, .{});
    }

    if (comptime builtin.os.tag == .windows)
        return error.FileNotFound;
    return Io.Dir.openDirAbsolute(io, "/tmp", .{});
}

pub fn lua_createTempDir(L: *VM.lua.State) !i32 {
    const Options = struct {
        cleanup: bool = false,
        iterate: bool = false,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 1, null) orelse .{};

    const allocator = Scheduler.fromState(L).allocator();

    var parent = try openTempParent(Zune.io());
    errdefer parent.close(Zune.io());

    const random_bytes_count = 12;
    const sub_path_len = comptime std.base64.url_safe.Encoder.calcSize(random_bytes_count);
    var sub_path_buf: [sub_path_len]u8 = undefined;
    var sub_path: []const u8 = "";

    const opened = blk: while (true) {
        var random_bytes: [random_bytes_count]u8 = undefined;
        Zune.io().random(&random_bytes);
        sub_path = std.base64.url_safe.Encoder.encode(&sub_path_buf, &random_bytes);

        if (parent.createDirPathOpen(Zune.io(), sub_path, .{
            .open_options = .{ .iterate = opts.iterate },
        })) |dir| {
            break :blk dir;
        } else |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        }
    };
    errdefer parent.deleteTree(Zune.io(), sub_path) catch {};
    errdefer opened.close(Zune.io());

    const sub_path_copy: ?[]u8 = if (opts.cleanup) try allocator.dupe(u8, sub_path) else null;
    errdefer if (sub_path_copy) |copy| allocator.free(copy);

    const dir = try Dir.create(L, opened, .{
        .iterate = opts.iterate,
    });
    if (sub_path_copy) |copy| {
        dir.parent = parent;
        dir.sub_path = copy;
        dir.mode.autocleanup = true;
    } else {
        parent.close(Zune.io());
    }

    return 1;
}

pub fn lua_createWatcher(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    _ = try FileWatcher.create(L);
    return 1;
}

pub const lua_path = struct {
    pub const lua_max_path_bytes = std.Io.Dir.max_path_bytes;

    pub fn lua_join(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator();
        const top = L.gettop();
        if (top == 0)
            return 0;
        var paths: std.ArrayList([]const u8) = try .initCapacity(allocator, @min(16, top));
        defer paths.deinit(allocator);
        for (0..top) |i| {
            const path = try L.Zcheckvalue([:0]const u8, @intCast(i + 1), null);
            try paths.append(allocator, path);
        }

        const resolved = try fs.path.join(allocator, paths.items);
        defer allocator.free(resolved);

        try L.pushlstring(resolved);

        return 1;
    }

    pub fn lua_relative(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator();
        const from = try L.Zcheckvalue([:0]const u8, 1, null);
        const to = try L.Zcheckvalue([:0]const u8, 2, null);

        const resolved = try fs.path.relative(allocator, "", &Zune.State.env_map, from, to);
        defer allocator.free(resolved);

        try L.pushlstring(resolved);

        return 1;
    }

    pub fn lua_resolve(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator();
        const top = L.gettop();
        if (top == 0)
            return 0;
        var paths: std.ArrayList([]const u8) = try .initCapacity(allocator, @min(16, top));
        defer paths.deinit(allocator);
        for (0..top) |i| {
            const path = try L.Zcheckvalue([:0]const u8, @intCast(i + 1), null);
            try paths.append(allocator, path);
        }

        const resolved = try fs.path.resolve(allocator, paths.items);
        defer allocator.free(resolved);

        try L.pushlstring(resolved);

        return 1;
    }

    pub fn lua_dirname(L: *VM.lua.State) !i32 {
        const path = try L.Zcheckvalue([:0]const u8, 1, null);
        if (fs.path.dirname(path)) |dirname|
            try L.pushlstring(dirname)
        else
            L.pushnil();
        return 1;
    }

    pub fn lua_basename(L: *VM.lua.State) !i32 {
        const path = try L.Zcheckvalue([:0]const u8, 1, null);
        try L.pushlstring(fs.path.basename(path));
        return 1;
    }

    pub fn lua_stem(L: *VM.lua.State) !i32 {
        const path = try L.Zcheckvalue([:0]const u8, 1, null);
        try L.pushlstring(fs.path.stem(path));
        return 1;
    }

    pub fn lua_extension(L: *VM.lua.State) !i32 {
        const path = try L.Zcheckvalue([:0]const u8, 1, null);
        try L.pushlstring(fs.path.extension(path));
        return 1;
    }

    pub fn lua_isAbsolute(L: *VM.lua.State) !i32 {
        const path = try L.Zcheckvalue([:0]const u8, 1, null);
        L.pushboolean(fs.path.isAbsolute(path));
        return 1;
    }

    pub fn lua_globMatch(L: *VM.lua.State) !i32 {
        const path = try L.Zcheckvalue([:0]const u8, 1, null);
        const pattern = try L.Zcheckvalue([:0]const u8, 2, null);

        L.pushboolean(Zune.Resolvers.Glob.match(pattern, path).matches());

        return 1;
    }
};

test {
    _ = Watcher;
}
