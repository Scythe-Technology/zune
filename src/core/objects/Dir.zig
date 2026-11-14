const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const File = Zune.objects.File;

const VM = luau.VM;

const Dir = @This();

pub const OBJECT_TAG = Zune.Tags.get("FS_DIR").?;
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows, .wasi => .Full,
        .freebsd, .openbsd, .netbsd => .Full,
        else => null,
    };
}

pub const OpenMode = packed struct {
    opened: bool = true,
    iterate: bool = false,
    owned: bool = true,
    /// Set by `fs.createTempDir` when the caller passes `cleanup`.
    /// Close and `__dtor` then delete the directory. A normal directory never sets this.
    autocleanup: bool = false,

    pub const closed: OpenMode = .{ .opened = false, .owned = false };

    pub inline fn isOpen(self: OpenMode) bool {
        return self.opened;
    }
};

fn emptyParent() std.Io.Dir {
    return .{
        .handle = switch (comptime builtin.os.tag) {
            .windows => std.os.windows.INVALID_HANDLE_VALUE,
            else => -1,
        },
    };
}

dir: std.Io.Dir,
mode: OpenMode = .{},
/// Parent of a temporary directory. Valid only while `mode.autocleanup` is set.
parent: std.Io.Dir = emptyParent(),
/// Name of this directory inside `parent`. Owned by the scheduler allocator.
/// Valid only while `mode.autocleanup` is set.
sub_path: []u8 = &.{},
staged: Scheduler.Async.Staged = .{},
ref: Scripting.CountedReference = .{},

fn asyncCallback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const async: *Scheduler.Async = Scheduler.Async.fromCompletion(completion);
    const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));
    defer async.deinit(scheduler);

    const L = async.ref.value;

    const dir: *Dir = @ptrCast(@alignCast(completion.userdata));

    dir.ref.deref(L);
    dir.staged.remove(async);

    switch (async.op) {
        .file_create,
        => |*e| {
            defer scheduler.allocator().free(e.op.path);

            if (L.status() != .Yield)
                return;

            const result = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            const file: std.Io.File = .{
                .handle = result.fd,
                .flags = .{ .nonblocking = e.op.flags.nonblocking },
            };

            _ = File.create(
                L,
                file,
                .File,
                .{
                    .read = e.op.flags.read,
                    .write = true,
                    .pollable = result.streaming_route == .pollable,
                },
            ) catch |err| {
                file.close(Zune.io());
                return Scheduler.resumeStateError(L, null, err) catch {};
            };
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .file_open,
        => |*e| {
            defer scheduler.allocator().free(e.op.path);

            if (L.status() != .Yield)
                return;

            const result = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            const file: std.Io.File = .{
                .handle = result.fd,
                .flags = .{ .nonblocking = e.op.flags.nonblocking },
            };

            _ = File.create(
                L,
                file,
                .File,
                .{
                    .read = e.op.flags.mode == .read_only or e.op.flags.mode == .read_write,
                    .write = e.op.flags.mode == .write_only or e.op.flags.mode == .read_write,
                    .pollable = result.streaming_route == .pollable,
                },
            ) catch |err| {
                file.close(Zune.io());
                return Scheduler.resumeStateError(L, null, err) catch {};
            };
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .file_stat,
        => |*e| {
            defer if (e.op.path) |path| scheduler.allocator().free(path);

            if (L.status() != .Yield)
                return;

            const stat = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            L.Zpushvalue(.{
                .kind = @tagName(stat.kind),
                .mode = stat.mode,
                .block_size = stat.block_size,
                .changed_at = @as(f64, @floatFromInt(stat.ctime)),
                .modified_at = @as(f64, @floatFromInt(stat.mtime)),
                .accessed_at = @as(f64, @floatFromInt(stat.atime)),
                .size = @as(f64, @floatFromInt(stat.size)),
            }) catch {};
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .dir_real_path,
        => |*e| {
            e.buffer_ref.deref(L);

            if (L.status() != .Yield)
                return;

            const bytes = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            L.pushunsigned(@truncate(bytes));
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        inline .dir_set_permissions,
        .dir_set_owner,
        => |*e| {
            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        inline .dir_set_file_permissions,
        .dir_set_file_owner,
        .dir_set_file_timestamps,
        => |*e| {
            const allocator = scheduler.allocator();
            defer allocator.free(e.op.path);

            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        inline .dir_read_link,
        .dir_real_path_file,
        => |*e| {
            const allocator = scheduler.allocator();
            defer allocator.free(e.op.path);

            e.buffer_ref.deref(L);

            if (L.status() != .Yield)
                return;

            const bytes = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            L.pushnumber(@floatFromInt(bytes));
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        inline .dir_rename,
        .dir_rename_preserve,
        => |*e| {
            const allocator = scheduler.allocator();
            defer allocator.free(e.op.new_path);
            defer allocator.free(e.op.old_path);

            e.dir_ref.deref(L);

            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        inline .dir_create_dir,
        .dir_delete_file,
        .dir_delete_dir,
        .dir_access,
        => |*e| {
            const allocator = scheduler.allocator();
            defer allocator.free(e.op.path);

            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        .dir_sym_link,
        => |*e| {
            const allocator = scheduler.allocator();
            defer allocator.free(e.op.target);
            defer allocator.free(e.op.link_path);

            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        .dir_open => |*e| {
            const allocator = scheduler.allocator();
            defer allocator.free(e.op.path);

            if (L.status() != .Yield)
                return;

            const handle = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = create(L, .{ .handle = handle }, .{
                .iterate = e.op.flags.iterate,
            }) catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .dir_close => |*e| {
            e.op.getResult() catch |err| switch (err) {
                error.Canceled => dir.dir.close(Zune.io()),
            };

            if (e.canceled)
                _ = scheduler.deferThread(.take(&async.ref), null, 0) catch {}
            else
                _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        else => unreachable,
    }
}

fn startAsync(self: *Dir, async: *Scheduler.Async, L: *VM.lua.State, scheduler: *Scheduler) void {
    self.ref.ref(L, 1);

    const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));

    common.op.c.userdata = @ptrCast(@alignCast(self));
    common.op.c.callback = asyncCallback;

    self.staged.append(async);
    scheduler.loop.add(&common.op.c);
}

/// Removes a temporary directory created with `cleanup`.
/// `deleteTree` goes through `std.Io` because it has no zio operation.
/// The open mode is cleared first so a second close or the destructor cannot free `sub_path` twice.
fn cleanupTemp(self: *Dir, allocator: std.mem.Allocator) !void {
    if (!self.mode.autocleanup)
        return;

    const parent = self.parent;
    const sub_path = self.sub_path;
    const close_dir = self.mode.isOpen() and self.mode.owned;
    self.mode = .closed;

    if (close_dir)
        self.dir.close(Zune.io());
    defer parent.close(Zune.io());
    defer allocator.free(sub_path);

    if (sub_path.len == 0)
        return;

    try parent.deleteTree(Zune.io(), sub_path);
}

pub fn lua_openDir(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const Options = struct {
        iterate: bool = false,
        follow_symlinks: bool = true,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 3, null) orelse .{};

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        const sub_dir = try self.dir.openDir(Zune.io(), path, .{
            .follow_symlinks = opts.follow_symlinks,
            .iterate = opts.iterate,
        });
        errdefer sub_dir.close(Zune.io());

        _ = try create(L, sub_dir, .{
            .iterate = opts.iterate,
        });

        return 1;
    }
    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_open = .{
                .op = .init(self.dir.handle, copy_path, .{
                    .follow_symlinks = opts.follow_symlinks,
                    .iterate = opts.iterate,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_openFile(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    var mode: zio.os.fs.FileOpenMode = .read_only;

    const Options = struct {
        mode: ?[:0]const u8 = null,
        follow_symlinks: bool = true,
        allow_directory: bool = true,
        nonblocking: bool = true,
        path_only: bool = false,
        allow_ctty: bool = false,
        resolve_beneath: bool = false,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 3, null) orelse .{};
    if (opts.mode) |m| {
        const has_read = std.mem.indexOfScalar(u8, m, 'r');
        const has_write = std.mem.indexOfScalar(u8, m, 'w');
        if (has_read != null and has_write != null) {
            mode = .read_write;
        } else if (has_read != null) {
            mode = .read_only;
        } else if (has_write != null) {
            mode = .write_only;
        } else return L.Zerror("invalid mode");
    }

    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    var op: zio.ev.FileOpen = .init(self.dir.handle, path, .{
        .mode = mode,
        .follow_symlinks = opts.follow_symlinks,
        .allow_directory = opts.allow_directory,
        .nonblocking = opts.nonblocking,
        .path_only = opts.path_only,
        .allow_ctty = opts.allow_ctty,
        .resolve_beneath = opts.resolve_beneath,
    });

    if (!L.isyieldable()) {
        // [SYNC]
        zio.ev.executeBlocking(&op.c, allocator);

        const result = try op.getResult();
        const file: std.Io.File = .{
            .handle = result.fd,
            .flags = .{ .nonblocking = op.flags.nonblocking },
        };
        errdefer file.close(Zune.io());

        _ = try File.create(L, file, .File, .{
            .read = op.flags.mode == .read_only or op.flags.mode == .read_write,
            .write = op.flags.mode == .write_only or op.flags.mode == .read_write,
            .pollable = result.streaming_route == .pollable,
        });

        return 1;
    }

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    op.path = copy_path;

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_open = .{
                .op = op,
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_copyFile(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);
    const new_dir = Dir.to(L, 3) orelse return L.Zerror("expected directory");
    const new_path = try L.Zcheckvalue([]const u8, 4, null);

    const opts = try L.Zcheckvalue(struct {
        permissions: ?u32 = null,
        make_path: bool = false,
        replace: bool = true,
    }, 5, null);

    try self.dir.copyFile(path, new_dir.dir, new_path, Zune.io(), .{
        .replace = opts.replace,
        .make_path = opts.make_path,
        .permissions = if (opts.permissions) |p| @fromBackingInt(@truncate(p)) else null,
    });

    return 0;
}

pub fn lua_setPermissions(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const mode = try L.Zcheckvalue(u32, 2, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.setPermissions(Zune.io(), @fromBackingInt(@truncate(mode)));
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_set_permissions = .{
                .op = .init(self.dir.handle, @truncate(mode)),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setOwner(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const owner = try L.Zcheckvalue(u32, 2, null);
    const group = try L.Zcheckvalue(u32, 3, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.setOwner(Zune.io(), owner, group);
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_set_owner = .{
                .op = .init(self.dir.handle, owner, group),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setFilePermissions(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);
    const mode = try L.Zcheckvalue(u32, 3, null);

    const scheduler = Scheduler.fromState(L);

    const Options = struct {
        follow_symlinks: bool = true,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 4, null) orelse .{};

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.setFilePermissions(Zune.io(), path, @fromBackingInt(@truncate(mode)), .{
            .follow_symlinks = opts.follow_symlinks,
        });
        return 0;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_set_file_permissions = .{
                .op = .init(self.dir.handle, copy_path, @truncate(mode), .{
                    .follow_symlinks = opts.follow_symlinks,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setFileOwner(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);
    const owner = try L.Zcheckvalue(?u32, 3, null);
    const group = try L.Zcheckvalue(?u32, 4, null);

    const scheduler = Scheduler.fromState(L);

    const Options = struct {
        follow_symlinks: bool = true,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 5, null) orelse .{};

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.setFileOwner(Zune.io(), path, owner, group, .{
            .follow_symlinks = opts.follow_symlinks,
        });
        return 0;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_set_file_owner = .{
                .op = .init(self.dir.handle, copy_path, owner, group, .{
                    .follow_symlinks = opts.follow_symlinks,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setFileTimestamps(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const atime = try L.Zcheckvalue(?i64, 3, null);
    const mtime = try L.Zcheckvalue(?i64, 4, null);

    const Options = struct {
        follow_symlinks: bool = true,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 5, null) orelse .{};

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.setTimestamps(Zune.io(), path, .{
            .access_timestamp = .init(if (atime) |v| .fromNanoseconds(@intCast(v)) else null),
            .modify_timestamp = .init(if (mtime) |v| .fromNanoseconds(@intCast(v)) else null),
        });
        return 0;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_set_file_timestamps = .{
                .op = .init(self.dir.handle, copy_path, .{
                    .atime = if (atime) |v| .{ .new = @intCast(v) } else .unchanged,
                    .mtime = if (mtime) |v| .{ .new = @intCast(v) } else .unchanged,
                }, .{
                    .follow_symlinks = opts.follow_symlinks,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_stat(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        const stat = try self.dir.stat(Zune.io());
        try L.Zpushvalue(.{
            .kind = @tagName(stat.kind),
            .mode = @backingInt(stat.permissions),
            .block_size = stat.block_size,
            .changed_at = @as(f64, @floatFromInt(@as(i64, @truncate(stat.ctime.nanoseconds)))),
            .modified_at = @as(f64, @floatFromInt(@as(i64, @truncate(stat.mtime.nanoseconds)))),
            .accessed_at = @as(f64, @floatFromInt(@as(i64, @truncate(if (stat.atime) |t| t.nanoseconds else 0)))),
            .size = @as(f64, @floatFromInt(stat.size)),
        });
        return 1;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_stat = .{
                .op = .init(self.dir.handle, null, .{}),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_statFile(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const scheduler = Scheduler.fromState(L);

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const Options = struct {
        follow_symlinks: bool = true,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 3, null) orelse .{};

    if (!L.isyieldable()) {
        // [SYNC]
        const stat = try self.dir.statFile(Zune.io(), path, .{
            .follow_symlinks = opts.follow_symlinks,
        });
        try L.Zpushvalue(.{
            .kind = @tagName(stat.kind),
            .mode = @backingInt(stat.permissions),
            .block_size = stat.block_size,
            .changed_at = @as(f64, @floatFromInt(@as(i64, @truncate(stat.ctime.nanoseconds)))),
            .modified_at = @as(f64, @floatFromInt(@as(i64, @truncate(stat.mtime.nanoseconds)))),
            .accessed_at = @as(f64, @floatFromInt(@as(i64, @truncate(if (stat.atime) |t| t.nanoseconds else 0)))),
            .size = @as(f64, @floatFromInt(stat.size)),
        });
        return 1;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_stat = .{
                .op = .init(self.dir.handle, copy_path, .{
                    .follow_symlinks = opts.follow_symlinks,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_symLink(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const target_path = try L.Zcheckvalue([]const u8, 2, null);
    const sym_link_path = try L.Zcheckvalue([]const u8, 3, null);

    const Options = struct {
        is_directory: bool = false,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 4, null) orelse .{};

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.symLink(Zune.io(), target_path, sym_link_path, .{
            .is_directory = opts.is_directory,
        });
        return 0;
    }

    const allocator = scheduler.allocator();

    const copy_target_path = try allocator.dupe(u8, target_path);
    errdefer allocator.free(copy_target_path);
    const copy_sym_link_path = try allocator.dupe(u8, sym_link_path);
    errdefer allocator.free(copy_sym_link_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_sym_link = .{
                .op = .init(self.dir.handle, copy_target_path, copy_sym_link_path, .{
                    .is_directory = opts.is_directory,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_readLink(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);
    const buf = Scripting.getControlledBuffer(L, []u8, 3) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        L.pushnumber(@floatFromInt(try self.dir.readLink(Zune.io(), path, buf)));
        return 1;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_read_link = .{
                .op = .init(self.dir.handle, copy_path, buf),
                .buffer_ref = .init(L, 3),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_access(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);
    const scheduler = Scheduler.fromState(L);

    const opts = try L.Zcheckvalue(struct {
        follow_symlinks: bool = true,
        read: bool = false,
        write: bool = false,
        execute: bool = false,
    }, 3, null);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.access(Zune.io(), path, .{
            .follow_symlinks = opts.follow_symlinks,
            .read = opts.read,
            .write = opts.write,
            .execute = opts.execute,
        });
        return 0;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_access = .{
                .op = .init(self.dir.handle, copy_path, .{
                    .follow_symlinks = opts.follow_symlinks,
                    .read = opts.read,
                    .write = opts.write,
                    .execute = opts.execute,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_realPath(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const buf = Scripting.getControlledBuffer(L, []u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        L.pushnumber(@floatFromInt(try self.dir.realPath(Zune.io(), buf)));
        return 1;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_real_path = .{
                .buffer_ref = .init(L, 2),
                .op = .init(self.dir.handle, buf),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_realPathFile(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);
    const buf = Scripting.getControlledBuffer(L, []u8, 3) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        L.pushnumber(@floatFromInt(try self.dir.realPathFile(Zune.io(), path, buf)));
        return 1;
    }

    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_real_path_file = .{
                .buffer_ref = .init(L, 3),
                .op = .init(self.dir.handle, copy_path, buf),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_createDir(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const mode = try L.Zcheckvalue(?u32, 3, null) orelse @backingInt(std.Io.Dir.Permissions.default_dir);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.createDir(Zune.io(), path, @fromBackingInt(@truncate(mode)));
        return 0;
    }
    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_create_dir = .{
                .op = .init(self.dir.handle, copy_path, @truncate(mode)),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_createFile(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const Options = struct {
        read: bool = false,
        truncate: bool = true,
        exclusive: bool = false,
        nonblocking: bool = false,
        resolve_beneath: bool = false,
        permissions: u32 = @backingInt(std.Io.Dir.Permissions.default_file),
    };
    const opts: Options = try L.Zcheckvalue(?Options, 3, null) orelse .{};

    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    var op: zio.ev.FileCreate = .init(self.dir.handle, path, .{
        .read = opts.read,
        .truncate = opts.truncate,
        .exclusive = opts.exclusive,
        .resolve_beneath = opts.resolve_beneath,
        .mode = @truncate(opts.permissions),
    });

    if (!L.isyieldable()) {
        // [SYNC]
        zio.ev.executeBlocking(&op.c, allocator);

        const result = try op.getResult();
        const file: std.Io.File = .{
            .handle = result.fd,
            .flags = .{ .nonblocking = op.flags.nonblocking },
        };
        errdefer file.close(Zune.io());

        _ = try File.create(L, file, .File, .{
            .owned = true,
            .write = true,
            .read = op.flags.read,
            .pollable = result.streaming_route == .pollable,
        });

        return 1;
    }

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    op.path = copy_path;

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_create = .{
                .op = op,
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_createDirPath(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    try self.dir.createDirPath(Zune.io(), path);

    return 0;
}

pub fn lua_rename(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const old_path = try L.Zcheckvalue([]const u8, 2, null);
    const new_dir = Dir.to(L, 3) orelse return L.Zerror("expected directory");
    const new_path = try L.Zcheckvalue([]const u8, 4, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.rename(old_path, new_dir.dir, new_path, Zune.io());
        return 0;
    }
    const allocator = scheduler.allocator();

    const copy_old_path = try allocator.dupe(u8, old_path);
    errdefer allocator.free(copy_old_path);
    const copy_new_path = try allocator.dupe(u8, new_path);
    errdefer allocator.free(copy_new_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_rename = .{
                .dir_ref = .init(L, 3),
                .op = .init(self.dir.handle, copy_old_path, new_dir.dir.handle, copy_new_path),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_renamePreserve(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const old_path = try L.Zcheckvalue([]const u8, 2, null);
    const new_dir = Dir.to(L, 3) orelse return L.Zerror("expected directory");
    const new_path = try L.Zcheckvalue([]const u8, 4, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.renamePreserve(old_path, new_dir.dir, new_path, Zune.io());
        return 0;
    }
    const allocator = scheduler.allocator();

    const copy_old_path = try allocator.dupe(u8, old_path);
    errdefer allocator.free(copy_old_path);
    const copy_new_path = try allocator.dupe(u8, new_path);
    errdefer allocator.free(copy_new_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_rename_preserve = .{
                .dir_ref = .init(L, 3),
                .op = .init(self.dir.handle, copy_old_path, new_dir.dir.handle, copy_new_path),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_deleteFile(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.deleteFile(Zune.io(), path);
        return 0;
    }
    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_delete_file = .{
                .op = .init(self.dir.handle, copy_path),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_deleteDir(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.dir.deleteDir(Zune.io(), path);
        return 0;
    }
    const allocator = scheduler.allocator();

    const copy_path = try allocator.dupe(u8, path);
    errdefer allocator.free(copy_path);

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .dir_delete_dir = .{
                .op = .init(self.dir.handle, copy_path),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_deleteTree(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");

    const path = try L.Zcheckvalue([]const u8, 2, null);

    try self.dir.deleteTree(Zune.io(), path);

    return 0;
}

pub fn lua_entries(self: *Dir, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("directory closed");
    if (!self.mode.iterate)
        return L.Zerror("directory not opened for iteration");

    var iter = self.dir.iterate();

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

pub fn lua_close(self: *Dir, L: *VM.lua.State) !i32 {
    if (self.mode.isOpen()) {
        if (!self.mode.owned)
            return L.Zerror("directory not owned");

        const scheduler = Scheduler.fromState(L);

        const canceled = blk: {
            var node = self.staged.list.first;
            const had = node != null;
            while (node) |n| {
                const async: *Scheduler.Async = @alignCast(@fieldParentPtr("node", n));
                const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));
                scheduler.loop.cancel(&common.op.c);
                node = n.next;
            }
            break :blk had;
        };

        if (self.mode.autocleanup) {
            // [SYNC] deleteTree has no zio operation.
            try self.cleanupTemp(scheduler.allocator());
            return 0;
        }

        if (!L.isyieldable()) {
            // [SYNC]
            self.mode = .closed;
            self.dir.close(Zune.io());
            return 0;
        }

        // [ASYNC]
        const async = try scheduler.createAsync();

        self.mode = .closed;

        async.* = .{
            .ref = .init(L),
            .op = .{
                .dir_close = .{
                    .op = .init(self.dir.handle),
                    .canceled = canceled,
                },
            },
        };

        self.startAsync(async, L, scheduler);

        return L.yield(0) catch unreachable;
    }
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *Dir) void {
    if (self.mode.autocleanup) {
        self.cleanupTemp(Scheduler.fromState(L).allocator()) catch {};
        return;
    }
    if (self.mode.isOpen() and self.mode.owned) {
        self.dir.close(Zune.io());
    }
}

pub fn to(L: *VM.lua.State, idx: i32) ?*Dir {
    return L.touserdatatagged(Dir, idx, OBJECT_TAG);
}

pub fn create(L: *VM.lua.State, dir: std.Io.Dir, mode: OpenMode) !*Dir {
    const self = try L.newuserdatataggedwithmetatable(Dir, OBJECT_TAG);
    self.* = .{
        .dir = dir,
        .mode = mode,
    };
    return self;
}
