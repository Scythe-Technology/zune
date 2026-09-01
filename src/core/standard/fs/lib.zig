const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const File = @import("../../objects/filesystem/File.zig");

const ext_fs = @import("../../utils/ext_fs.zig");

const Watch = @import("./watch.zig");

const TAG_FS_WATCHER = Zune.Tags.get("FS_WATCHER").?;

const VM = luau.VM;

const fs = std.fs;
const Io = std.Io;

const BufferError = error{FailedToCreateBuffer};
const HardwareError = error{NotSupported};
const UnhandledError = error{UnknownError};
const OpenError = error{ InvalidMode, BadExclusive };

pub const LIB_NAME = "fs";
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => true,
        .freebsd => true,
        else => false,
    };
}

fn lua_readFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const useBuffer = L.Loptboolean(2, false);

    const file: std.Io.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(Io.Dir.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ,
            .creationDisposition = std.os.windows.OPEN_EXISTING,
        }),
        else => try Io.Dir.cwd().openFile(Zune.io(), path, .{
            .mode = .read_only,
        }),
    };
    errdefer file.close(Zune.io());

    return File.AsyncReadContext.queue(
        L,
        file,
        useBuffer,
        1024,
        LuaHelper.MAX_LUAU_SIZE,
        true,
        .File,
        null,
    );
}

fn lua_readFileSync(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator;
    const path = L.Lcheckstring(1);
    const useBuffer = L.Loptboolean(2, false);
    const data = try Io.Dir.cwd().readFileAlloc(Zune.io(), path, allocator, .limited(LuaHelper.MAX_LUAU_SIZE));
    defer allocator.free(data);

    if (useBuffer)
        try L.Zpushbuffer(data)
    else
        try L.pushlstring(data);

    return 1;
}

fn lua_entries(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    var dir = try Io.Dir.cwd().openDir(Zune.io(), path, .{
        .iterate = true,
    });
    defer dir.close(Zune.io());
    var iter = dir.iterate();
    try L.newtable();
    var i: i32 = 1;
    while (try iter.next(Zune.io())) |entry| {
        L.pushinteger(i);
        try L.Zpushvalue(.{
            .name = entry.name,
            .kind = @tagName(entry.kind),
        });
        try L.rawset(-3);
        i += 1;
    }
    return 1;
}

fn lua_writeFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = try L.Zcheckvalue([]const u8, 2, null);

    const file: std.Io.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(Io.Dir.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            .creationDisposition = std.os.windows.CREATE_ALWAYS,
        }),
        else => try Io.Dir.cwd().createFile(Zune.io(), path, .{
            .truncate = true,
        }),
    };
    errdefer file.close(Zune.io());

    return File.AsyncWriteContext.queue(L, file, data, true, 0, .File, null);
}

fn lua_writeFileSync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = try L.Zcheckvalue([]const u8, 2, null);
    try Io.Dir.cwd().writeFile(Zune.io(), .{
        .sub_path = path,
        .data = data,
    });
    return 0;
}

fn lua_makeDir(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const recursive = L.Loptboolean(2, false);
    const cwd = std.Io.Dir.cwd();
    try (if (recursive)
        cwd.createDirPath(Zune.io(), path)
    else
        cwd.createDir(Zune.io(), path, .default_dir));
    return 0;
}

fn lua_deleteFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    try Io.Dir.cwd().deleteFile(Zune.io(), path);
    return 0;
}

fn lua_deleteDir(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const recursive = L.Loptboolean(2, false);
    const cwd = std.Io.Dir.cwd();
    try (if (recursive)
        cwd.deleteTree(Zune.io(), path)
    else
        cwd.deleteDir(Zune.io(), path));
    return 0;
}

fn internal_isDir(srcDir: std.Io.Dir, path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        var dir = srcDir.openDir(Zune.io(), path, .{
            .iterate = true,
        }) catch return false;
        defer dir.close(Zune.io());
        return true;
    }
    const stat = srcDir.statFile(Zune.io(), path, .{}) catch return false;
    return stat.kind == .directory;
}

fn internal_isFile(srcDir: std.Io.Dir, path: []const u8) bool {
    const stat = srcDir.statFile(Zune.io(), path, .{}) catch return false;
    return stat.kind == .file;
}

fn internal_lossyfloat_time(n: i128) f64 {
    return @as(f64, @floatFromInt(n)) / 1_000_000_000.0;
}

fn internal_stat(dir: std.Io.Dir, path: []const u8) !std.Io.Dir.Stat {
    if (comptime builtin.os.tag == .windows) {
        var d = dir.openDir(Zune.io(), path, .{}) catch {
            const file = try dir.openFile(Zune.io(), path, .{});
            defer file.close(Zune.io());
            return try file.stat(Zune.io());
        };
        defer d.close(Zune.io());
        return try d.stat(Zune.io());
    }
    return try dir.statFile(Zune.io(), path, .{});
}

fn lua_stat(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    const path = L.Lcheckstring(1);
    const cwd = std.Io.Dir.cwd();
    const stat = internal_stat(cwd, path) catch {
        try L.Zpushvalue(.{
            .kind = "none",
        });
        return 1;
    };
    try L.Zpushvalue(.{
        .kind = @tagName(stat.kind),
        .changed_at = internal_lossyfloat_time(@intCast(stat.ctime.nanoseconds)),
        .modified_at = internal_lossyfloat_time(@intCast(stat.mtime.nanoseconds)),
        .accessed_at = internal_lossyfloat_time(@intCast((stat.atime orelse std.Io.Timestamp.zero).nanoseconds)),
        .mode = @intFromEnum(stat.permissions),
        .size = @as(f64, @floatFromInt(stat.size)),
    });
    return 1;
}

fn internal_metadata_table(L: *VM.lua.State, metadata: ext_fs.Metadata, isSymlink: bool) !void {
    try L.Zpushvalue(.{
        .created_at = internal_lossyfloat_time(metadata.created() orelse 0),
        .modified_at = internal_lossyfloat_time(metadata.modified()),
        .accessed_at = internal_lossyfloat_time(metadata.accessed()),
        .symlink = isSymlink,
        .size = metadata.size(),
        .kind = @tagName(metadata.kind()),
        .permissions = .{
            .read_only = metadata.permissions().readOnly(),
        },
    });
}

fn lua_metadata(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    const path = L.Lcheckstring(1);
    const allocator = Scheduler.fromState(L).allocator;
    const buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);
    const cwd = std.Io.Dir.cwd();
    if (internal_isDir(cwd, path)) {
        var dir = try cwd.openDir(Zune.io(), path, .{});
        defer dir.close(Zune.io());
        const metadata = try ext_fs.metadata(.{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
        var isLink = builtin.os.tag != .windows;
        if (builtin.os.tag != .windows)
            _ = cwd.readLink(Zune.io(), path, buf) catch |err| switch (err) {
                else => {
                    isLink = false;
                },
            };
        try internal_metadata_table(L, metadata, isLink);
    } else {
        var file = try cwd.openFile(Zune.io(), path, .{
            .mode = .read_only,
        });
        defer file.close(Zune.io());
        const metadata = try ext_fs.metadata(file);
        var isLink = builtin.os.tag != .windows;
        if (builtin.os.tag != .windows)
            _ = cwd.readLink(Zune.io(), path, buf) catch |err| switch (err) {
                else => {
                    isLink = false;
                },
            };
        try internal_metadata_table(L, metadata, isLink);
    }
    return 1;
}

fn lua_move(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const overwrite = L.Loptboolean(3, false);
    const cwd = std.Io.Dir.cwd();
    if (overwrite == false) {
        if (internal_isFile(cwd, toPath) or internal_isDir(cwd, toPath))
            return error.PathAlreadyExists;
    }
    try cwd.rename(fromPath, cwd, toPath, Zune.io());
    return 0;
}

fn copyDir(fromDir: std.Io.Dir, toDir: std.Io.Dir, overwrite: bool) !void {
    var iter = fromDir.iterate();
    while (try iter.next(Zune.io())) |entry| switch (entry.kind) {
        .file => {
            if (overwrite == false and internal_isFile(toDir, entry.name))
                return error.PathAlreadyExists;
            try fromDir.copyFile(entry.name, toDir, entry.name, Zune.io(), .{});
        },
        .directory => {
            toDir.createDir(Zune.io(), entry.name, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            var toEntryDir = try toDir.openDir(Zune.io(), entry.name, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false });
            defer toEntryDir.close(Zune.io());
            var fromEntryDir = try fromDir.openDir(Zune.io(), entry.name, .{ .access_sub_paths = true, .iterate = true, .follow_symlinks = false });
            defer fromEntryDir.close(Zune.io());
            try copyDir(fromEntryDir, toEntryDir, overwrite);
        },
        else => {},
    };
}

fn lua_copy(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const override = L.Loptboolean(3, false);
    const cwd = std.Io.Dir.cwd();
    if (internal_isDir(cwd, fromPath)) {
        var fromDir = try cwd.openDir(Zune.io(), fromPath, .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        defer fromDir.close(Zune.io());
        if (override == false and internal_isDir(cwd, toPath))
            return error.PathAlreadyExists
        else {
            cwd.createDir(Zune.io(), toPath, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return UnhandledError.UnknownError,
            };
        }
        var toDir = try cwd.openDir(Zune.io(), toPath, .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        defer toDir.close(Zune.io());
        try copyDir(fromDir, toDir, override);
    } else {
        if (override == false and internal_isFile(cwd, toPath))
            return error.PathAlreadyExists;

        try cwd.copyFile(fromPath, cwd, toPath, Zune.io(), .{});
    }
    return 0;
}

fn lua_symlink(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const cwd = std.Io.Dir.cwd();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try cwd.realPathFile(Zune.io(), fromPath, &buf);
    const full_path = buf[0..len];

    try cwd.symLink(Zune.io(), full_path, toPath, .{
        // only this applies to windows
        .is_directory = if (comptime builtin.os.tag == .windows)
            internal_isDir(cwd, fromPath)
        else
            false,
    });

    return 0;
}

fn lua_embedFile(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator;
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
        if (comptime Zune.Resolvers.Bundle.PlatformSupported()) {
            if (Zune.STATE.BUNDLE) |*b| {
                try L.Zpushbuffer(try b.loadFile(resolved_path));
                break :blk;
            }
        }
        const contents = try Io.Dir.cwd().readFileAlloc(Zune.io(), resolved_path, allocator, .unlimited);
        defer allocator.free(contents);
        try L.Zpushbuffer(contents);
    }

    return 1;
}
fn listEmbedded(L: *VM.lua.State, comptime kind: enum { script, file }) !i32 {
    try L.createtable(0, 0);
    if (Zune.STATE.BUNDLE) |b| {
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
fn lua_embeddedScripts(L: *VM.lua.State) !i32 {
    return try listEmbedded(L, .script);
}
fn lua_embeddedFiles(L: *VM.lua.State) !i32 {
    return try listEmbedded(L, .file);
}

const LuaWatch = struct {
    state: *WatchState,

    pub fn lua_stop(self: *LuaWatch, L: *VM.lua.State) !i32 {
        if (self.state.state.load(.acquire) != .Alive)
            return L.Zerror("watcher already stopped");
        _ = self.state.state.cmpxchgStrong(.Alive, .Terminating, .acq_rel, .acquire);
        std.debug.assert(self.state.state.load(.acquire) == .Terminating);
        return 0;
    }

    const __index = MethodMap.CreateStaticIndexMap(LuaWatch, TAG_FS_WATCHER, .{
        .{ "stop", lua_stop },
    });

    pub fn __dtor(L: *VM.lua.State, self: *LuaWatch) void {
        _ = self;
        _ = L;
    }
};

fn lua_openFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    var mode: std.Io.File.OpenMode = .read_write;

    const Options = struct {
        mode: ?[:0]const u8 = null,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};
    if (opts.mode) |m| {
        const has_read = std.mem.indexOfScalar(u8, m, 'r');
        const has_write = std.mem.indexOfScalar(u8, m, 'w');
        if (has_read != null and has_write != null) {
            mode = .read_write;
        } else if (has_read != null) {
            mode = .read_only;
        } else if (has_write != null) {
            mode = .write_only;
        } else return OpenError.InvalidMode;
    }

    const file: std.Io.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(Io.Dir.cwd(), path, .{
            .accessMode = switch (mode) {
                .read_only => std.os.windows.GENERIC_READ,
                .read_write => std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
                .write_only => std.os.windows.GENERIC_WRITE,
            },
            .creationDisposition = std.os.windows.OPEN_EXISTING,
        }),
        else => try Io.Dir.cwd().openFile(Zune.io(), path, .{
            .mode = mode,
        }),
    };

    _ = try File.push(L, file, .File, switch (mode) {
        .read_only => .readable(.seek_close),
        .read_write => .readwrite(.seek_close),
        .write_only => .writable(.seek_close),
    });

    return 1;
}

fn lua_createFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    const Mode = switch (comptime builtin.os.tag) {
        .freebsd, .macos, .ios, .tvos, .watchos, .visionos, .dragonfly, .serenity => u16,
        else => u32,
    };

    const Options = struct {
        read: bool = true,
        exclusive: bool = false,
        truncate: bool = true,
        mode: Mode = @intFromEnum(std.Io.File.Permissions.default_file),
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};

    const file: std.Io.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(Io.Dir.cwd(), path, .{
            .accessMode = if (opts.read)
                std.os.windows.GENERIC_WRITE | std.os.windows.GENERIC_READ
            else
                std.os.windows.GENERIC_WRITE,
            .creationDisposition = if (opts.exclusive)
                std.os.windows.CREATE_NEW
            else if (opts.truncate)
                std.os.windows.CREATE_ALWAYS
            else
                std.os.windows.OPEN_ALWAYS,
        }),
        else => try Io.Dir.cwd().createFile(Zune.io(), path, .{
            .read = opts.read,
            .exclusive = opts.exclusive,
            .truncate = opts.truncate,
            .permissions = @enumFromInt(opts.mode),
        }),
    };

    _ = try File.push(L, file, .File, if (opts.read) .readwrite(.seek_close) else .writable(.seek_close));

    return 1;
}

fn lua_getExePath(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .macos, .driverkit, .ios, .tvos, .visionos, .watchos => {}, // Darwin
        .freebsd, .openbsd, .netbsd, .dragonfly => {}, // BSD
        .illumos => {},
        .haiku => {},
        .windows, .linux => {},
        else => return error.UnsupportedPlatform,
    }

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try std.process.executablePath(Zune.io(), &buf)];
    try L.pushlstring(path);
    return 1;
}

fn lua_realPath(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .macos, .ios, .tvos, .visionos, .watchos => {},
        .windows, .linux => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    const path = L.Lcheckstring(1);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = buf[0..try Io.Dir.cwd().realPathFile(Zune.io(), path, &buf)];
    try L.pushlstring(real_path);
    return 1;
}

const WatchState = struct {
    watcher: Watch.FileSystemWatcher,
    callback: LuaHelper.Ref(void),
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    info: ?Watch.WatchInfo = null,
    state: std.atomic.Value(LoopState) = .{ .raw = .Alive },

    pub const LoopState = enum(u8) { Alive, Terminating, Dead };

    pub fn complete(self: *WatchState, scheduler: *Scheduler) void {
        self.mutex.lockUncancelable(Zune.io());
        const state = self.state.load(.acquire);
        if (state == .Dead) {
            defer scheduler.freeSync(self);
            defer if (self.info) |info| info.deinit(self.watcher.allocator);
            defer self.mutex.unlock(Zune.io());
            self.watcher.deinit();
            self.callback.deref(scheduler.global);
            return;
        }
        defer self.mutex.unlock(Zune.io());
        defer self.cond.signal(Zune.io());

        defer scheduler.asyncWaitForSync(self);

        if (state == .Terminating) {
            if (self.info) |info| {
                defer info.deinit(self.watcher.allocator);
                self.info = null;
            }
            return;
        }

        if (self.info) |info| {
            defer info.deinit(self.watcher.allocator);
            for (info.list.items) |item| {
                if (self.callback.hasRef()) {
                    const ML = scheduler.global.newthread() catch @panic("OutOfMemory");
                    _ = self.callback.push(ML);
                    ML.pushlstring(item.name) catch @panic("OutOfMemory");
                    var count: u32 = 0;
                    var values: [6][]const u8 = undefined;
                    if (item.event.created) {
                        values[count] = "created";
                        count += 1;
                    }
                    if (item.event.modify) {
                        values[count] = "modified";
                        count += 1;
                    }
                    if (item.event.delete) {
                        values[count] = "deleted";
                        count += 1;
                    }
                    if (item.event.rename) {
                        values[count] = "renamed";
                        count += 1;
                    }
                    if (item.event.metadata) {
                        values[count] = "metadata";
                        count += 1;
                    }
                    if (item.event.move_from or item.event.move_to) {
                        values[count] = "moved";
                        count += 1;
                    }
                    ML.createtable(@intCast(count), 0) catch @panic("OutOfMemory");
                    for (values[0..count], 1..) |value, i| {
                        ML.pushlstring(value) catch @panic("OutOfMemory");
                        ML.rawseti(-2, @intCast(i)) catch @panic("OutOfMemory");
                    }

                    scheduler.global.pop(1);

                    _ = Scheduler.resumeState(ML, null, 2) catch {};
                }
            }
            self.info = null;
        }
    }

    pub fn threadLoop(self: *WatchState, scheduler: *Scheduler) void {
        while (self.state.load(.acquire) == .Alive) {
            self.mutex.lockUncancelable(Zune.io());
            defer self.mutex.unlock(Zune.io());
            if (self.watcher.next() catch |err| {
                std.debug.print("LuaWatch error: {}\n", .{err});
                break;
            }) |info| {
                self.info = info;
                scheduler.synchronize(self);
                self.cond.waitUncancelable(Zune.io(), &self.mutex);
            }
        }

        self.state.store(.Dead, .release);
        scheduler.synchronize(self);
    }
};

fn lua_watch(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    const scheduler = Scheduler.fromState(L);
    const path = L.Lcheckstring(1);
    try L.Zchecktype(2, .Function);

    const allocator = scheduler.allocator;

    const ref = try L.ref(2) orelse unreachable;
    errdefer L.unref(ref);

    var dir = Io.Dir.cwd().openDir(Zune.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.PathNotFound,
    };
    dir.close(Zune.io());

    var watch = Watch.FileSystemWatcher.init(allocator, Io.Dir.cwd(), path);
    errdefer watch.deinit();

    const state = try scheduler.createSync(WatchState, WatchState.complete);
    errdefer scheduler.freeSync(state);
    state.* = .{
        .watcher = watch,
        .callback = .{ .ref = .{ .registry = ref }, .value = undefined },
    };

    try state.watcher.start();

    const ptr = try L.newuserdatataggedwithmetatable(LuaWatch, TAG_FS_WATCHER);
    ptr.state = state;

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, WatchState.threadLoop, .{ state, scheduler });

    scheduler.asyncWaitForSync(state);

    thread.detach();

    return 1;
}

const Path = struct {
    pub fn lua_join(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator;
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
        const allocator = Scheduler.fromState(L).allocator;
        const from = try L.Zcheckvalue([:0]const u8, 1, null);
        const to = try L.Zcheckvalue([:0]const u8, 2, null);

        const resolved = try fs.path.relative(allocator, "", &Zune.STATE.ENV_MAP, from, to);
        defer allocator.free(resolved);

        try L.pushlstring(resolved);

        return 1;
    }

    pub fn lua_resolve(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator;
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

        L.pushboolean(Zune.glob.match(pattern, path).matches());

        return 1;
    }
};

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaWatch), .{
            .__metatable = "Metatable is locked",
            .__type = "FileSystemWatcher",
        });
        try LuaWatch.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_FS_WATCHER);
        L.setuserdatadtor(LuaWatch, TAG_FS_WATCHER, LuaWatch.__dtor);
    }

    try L.Zpushvalue(.{
        .createFile = lua_createFile,
        .openFile = lua_openFile,
        .readFile = lua_readFileAsync,
        .readFileSync = lua_readFileSync,
        .entries = lua_entries,
        .writeFile = lua_writeFileAsync,
        .writeFileSync = lua_writeFileSync,
        .makeDir = lua_makeDir,
        .deleteFile = lua_deleteFile,
        .deleteDir = lua_deleteDir,
        .stat = lua_stat,
        .metadata = lua_metadata,
        .move = lua_move,
        .copy = lua_copy,
        .symlink = lua_symlink,
        .getExePath = lua_getExePath,
        .realPath = lua_realPath,
        .watch = lua_watch,
        .embedFile = lua_embedFile,
        .embeddedScripts = lua_embeddedScripts,
        .embeddedFiles = lua_embeddedFiles,
    });

    try L.Zpushvalue(.{
        .join = Path.lua_join,
        .relative = Path.lua_relative,
        .resolve = Path.lua_resolve,
        .dirname = Path.lua_dirname,
        .basename = Path.lua_basename,
        .stem = Path.lua_stem,
        .extension = Path.lua_extension,
        .isAbsolute = Path.lua_isAbsolute,
        .globMatch = Path.lua_globMatch,
    });
    L.setreadonly(-1, true);
    try L.rawsetfield(-2, "path");

    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = Watch;
}

test "fs" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/fs.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
