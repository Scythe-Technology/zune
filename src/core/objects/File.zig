const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const File = @This();

pub const OBJECT_TAG = Zune.Tags.get("FS_FILE").?;
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows, .wasi => .Full,
        .freebsd => .Full,
        else => null,
    };
}

pub const Kind = enum {
    File,
    Pipe,
};

pub const OpenMode = packed struct {
    read: bool = false,
    write: bool = false,
    pollable: bool = false,
    owned: bool = true,

    pub const closed: OpenMode = .{ .owned = false };

    pub inline fn isOpen(self: OpenMode) bool {
        return self.read or self.write;
    }
    pub inline fn canRead(self: OpenMode) bool {
        return self.read;
    }
    pub inline fn canWrite(self: OpenMode) bool {
        return self.write;
    }
};

file: std.Io.File,
mode: OpenMode = .{},
kind: Kind = .File,
staged: Scheduler.Async.Staged = .{},
ref: Scripting.CountedReference = .{},

fn asyncCallback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const async: *Scheduler.Async = Scheduler.Async.fromCompletion(completion);
    const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));
    defer async.deinit(scheduler);

    const L = async.ref.value;

    const file: *File = @ptrCast(@alignCast(completion.userdata));

    file.ref.deref(L);
    file.staged.remove(async);

    switch (async.op) {
        inline .file_read,
        .file_read_streaming,
        .file_write,
        .file_write_streaming,
        .file_real_path,
        => |*e| {
            e.buffer_ref.deref(L);

            if (L.status() != .Yield)
                return;

            const bytes = e.op.getResult() catch |err| {
                L.pushunsigned(0);
                L.pushlstring(@errorName(err)) catch |oom|
                    return Scheduler.resumeStateError(L, null, oom) catch {};
                _ = Scheduler.resumeState(L, null, 2) catch {};
                return;
            };

            L.pushunsigned(@truncate(bytes));
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .file_size,
        => |*e| {
            if (L.status() != .Yield)
                return;

            const bytes = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            L.Zpushvalue(bytes) catch |err| switch (err) {
                error.IntegerOverflow => {
                    L.pushstring("integer overflow") catch |oom|
                        return Scheduler.resumeStateError(L, null, oom) catch {};
                    _ = Scheduler.resumeStateErrorFast(L, null) catch {};
                    return;
                },
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
        inline .file_set_size,
        .file_set_permissions,
        .file_set_owner,
        .file_set_timestamps,
        .file_sync,
        => |*e| {
            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        inline .file_close, .pipe_close => |*e| {
            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            file.mode = .closed;
            if (e.canceled)
                _ = scheduler.deferThread(.take(&async.ref), null, 0) catch {}
            else
                _ = Scheduler.resumeState(L, null, 0) catch {};
        },

        else => unreachable,
    }
}

fn startAsync(self: *File, async: *Scheduler.Async, L: *VM.lua.State, scheduler: *Scheduler) void {
    self.ref.ref(L, 1);

    const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));

    common.op.c.userdata = @ptrCast(@alignCast(self));
    common.op.c.callback = asyncCallback;

    self.staged.append(async);
    scheduler.loop.add(&common.op.c);
}

pub fn lua_size(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        L.Zpushvalue(try self.file.length(Zune.io())) catch |err| switch (err) {
            error.IntegerOverflow => return L.Zerror("integer overflow"),
        };
        return 1;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_size = .{
                .op = .init(self.file.handle),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setSize(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }

    const size: u64 = @truncate(try L.Zcheckvalue(u53, 2, null));

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.file.setLength(Zune.io(), size);
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_set_size = .{
                .op = .init(self.file.handle, size),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setPermissions(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }

    const mode = try L.Zcheckvalue(u32, 2, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.file.setPermissions(Zune.io(), @fromBackingInt(mode));
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_set_permissions = .{
                .op = .init(self.file.handle, mode),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setOwner(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }

    const owner = try L.Zcheckvalue(u32, 2, null);
    const group = try L.Zcheckvalue(u32, 3, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.file.setOwner(Zune.io(), owner, group);
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_set_owner = .{
                .op = .init(self.file.handle, owner, group),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setTimestamps(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }

    const atime = try L.Zcheckvalue(?i64, 2, null);
    const mtime = try L.Zcheckvalue(?i64, 3, null);

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.file.setTimestamps(Zune.io(), .{
            .access_timestamp = .init(if (atime) |v| .fromNanoseconds(@intCast(v)) else null),
            .modify_timestamp = .init(if (mtime) |v| .fromNanoseconds(@intCast(v)) else null),
        });
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_set_timestamps = .{
                .op = .init(self.file.handle, .{
                    .atime = if (atime) |v| .{ .new = @intCast(v) } else .unchanged,
                    .mtime = if (mtime) |v| .{ .new = @intCast(v) } else .unchanged,
                }),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_stat(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        const stat = try self.file.stat(Zune.io());
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
                .op = .init(self.file.handle, null, .{}),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_realPath(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");

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
        L.pushnumber(@floatFromInt(try self.file.realPath(Zune.io(), buf)));
        return 1;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_real_path = .{
                .buffer_ref = .init(L, 2),
                .op = .init(self.file.handle, buf),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_read(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    if (!self.mode.canRead())
        return L.Zerror("file not open for reading");
    if (self.kind == .File)
        return L.Zerror("file does not support streaming (use positional)");

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
        const n = self.file.readStreaming(Zune.io(), &.{buf}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => {
                L.pushunsigned(0);
                try L.pushlstring(@errorName(err));
                return 2;
            },
        };
        L.pushunsigned(@intCast(n));
        return 1;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_read_streaming = .{
                .buffer_ref = .init(L, 2),
            },
        },
    };

    const read = &async.op.file_read_streaming;

    read.op = .init(self.file.handle, .fromSlice(buf, &read.iovec));

    if (comptime builtin.os.tag == .windows) {
        if (!self.file.flags.nonblocking)
            read.op.streaming_route = .thread_pool;
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_readPositional(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    if (!self.mode.canRead())
        return L.Zerror("file not open for reading");
    if (self.mode.pollable)
        return L.Zerror("file does not support offsets (use streaming)");

    const offset = try L.Zcheckvalue(u53, 2, null);
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
        const amt = self.file.readPositional(Zune.io(), &.{buf}, offset) catch |err| {
            L.pushunsigned(0);
            try L.pushlstring(@errorName(err));
            return 2;
        };
        L.pushunsigned(@intCast(amt));
        return 1;
    }

    if (comptime builtin.os.tag == .windows) {
        if (!self.file.flags.nonblocking)
            return L.Zerror("file not open for overlapped I/O");
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_read = .{
                .buffer_ref = .init(L, 3),
            },
        },
    };

    const read = &async.op.file_read;

    read.op = .init(self.file.handle, .fromSlice(buf, &read.iovec), offset);

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_write(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    if (!self.mode.canWrite())
        return L.Zerror("file not open for writing");
    if (self.kind == .File)
        return L.Zerror("file does not support streaming (use positional)");

    const buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };

    if (!L.isyieldable()) {
        // [SYNC]
        const amt = self.file.writeStreaming(Zune.io(), &.{}, &.{buf}, 1) catch |err| {
            L.pushunsigned(0);
            try L.pushlstring(@errorName(err));
            return 2;
        };
        L.pushunsigned(@intCast(amt));
        return 1;
    }

    // [ASYNC]
    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_write_streaming = .{
                .buffer_ref = .init(L, 2),
            },
        },
    };

    const write = &async.op.file_write_streaming;

    write.op = .init(self.file.handle, .fromSlice(buf, &write.iovec));

    if (comptime builtin.os.tag == .windows) {
        if (!self.file.flags.nonblocking)
            write.op.streaming_route = .thread_pool;
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_writePositional(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    if (!self.mode.canWrite())
        return L.Zerror("file not open for writing");
    if (self.mode.pollable)
        return L.Zerror("file does not support offsets (use streaming)");

    const offset = try L.Zcheckvalue(u53, 2, null);
    const buf = Scripting.getControlledBuffer(L, []const u8, 3) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };

    if (!L.isyieldable()) {
        const amt = self.file.writePositional(Zune.io(), &.{buf}, offset) catch |err| {
            L.pushunsigned(0);
            try L.pushlstring(@errorName(err));
            return 2;
        };
        L.pushunsigned(@intCast(amt));
        return 1;
    }

    if (comptime builtin.os.tag == .windows) {
        if (!self.file.flags.nonblocking)
            return L.Zerror("file not open for overlapped I/O");
    }

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_write = .{
                .buffer_ref = .init(L, 3),
            },
        },
    };

    const write = &async.op.file_write;

    write.op = .init(self.file.handle, .fromSlice(buf, &write.iovec), offset);

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_lock(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    var lockOpt: std.Io.File.Lock = .exclusive;
    if (L.typeOf(2) == .String) {
        const lockType = L.tostring(2) orelse unreachable;
        if (std.mem.eql(u8, lockType, "shared")) {
            lockOpt = .shared;
        } else if (!std.mem.eql(u8, lockType, "exclusive")) {
            lockOpt = .exclusive;
        } else if (!std.mem.eql(u8, lockType, "none")) {
            lockOpt = .none;
        }
    }
    L.pushboolean(try self.file.tryLock(Zune.io(), lockOpt));
    return 1;
}

pub fn lua_unlock(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    self.file.unlock(Zune.io());
    return 0;
}

pub fn lua_isTty(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .Pipe => {},
        .File => return L.Zerror("not a pipe"),
    }

    L.pushboolean(self.file.isTty(Zune.io()) catch false);
    return 1;
}

pub fn lua_sync(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.isOpen())
        return L.Zerror("file closed");
    switch (self.kind) {
        .File => {},
        .Pipe => return L.Zerror("not a regular file"),
    }

    const scheduler = Scheduler.fromState(L);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.file.sync(Zune.io());
        return 0;
    }

    // [ASYNC]
    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .file_sync = .{
                .op = .init(self.file.handle, .{}),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_close(self: *File, L: *VM.lua.State) !i32 {
    if (self.mode.isOpen()) {
        if (!self.mode.owned)
            return L.Zerror("file not owned");

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

        if (!L.isyieldable()) {
            // [SYNC]
            self.mode = .closed;
            self.file.close(Zune.io());
            return 0;
        }

        // [ASYNC]
        const async = try scheduler.createAsync();

        async.* = .{
            .ref = .init(L),
            .op = switch (self.kind) {
                .File => .{
                    .file_close = .{
                        .op = .init(self.file.handle),
                        .canceled = canceled,
                    },
                },
                .Pipe => .{
                    .pipe_close = .{
                        .op = .init(self.file.handle),
                        .canceled = canceled,
                    },
                },
            },
        };

        self.startAsync(async, L, scheduler);

        return L.yield(0) catch unreachable;
    }
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *File) void {
    _ = L;
    if (self.mode.isOpen() and self.mode.owned) {
        self.file.close(Zune.io());
    }
}

pub fn create(L: *VM.lua.State, file: std.Io.File, kind: Kind, mode: OpenMode) !*File {
    const self = try L.newuserdatataggedwithmetatable(File, OBJECT_TAG);
    self.* = .{
        .file = file,
        .kind = kind,
        .mode = mode,
    };
    return self;
}
