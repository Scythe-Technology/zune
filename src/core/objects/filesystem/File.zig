const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const tagged = Zune.tagged;
const sysfd = @import("../../utils/sysfd.zig");

const VM = luau.VM;

const File = @This();

const TAG_FS_FILE = tagged.Tags.get("FS_FILE").?;
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows, .wasi => true,
        else => false,
    };
}

pub const FileKind = enum {
    File,
    Tty,
};

pub const OpenMode = packed struct {
    read: bool = false,
    write: bool = false,
    seek: bool = false,
    close: bool = false,

    pub const closed: OpenMode = .{};

    const ExtraOptions = enum { none, seek, close, seek_close };
    pub fn writable(extra: ExtraOptions) OpenMode {
        return .{
            .read = false,
            .write = true,
            .seek = extra == .seek or extra == .seek_close,
            .close = extra == .close or extra == .seek_close,
        };
    }
    pub fn readable(extra: ExtraOptions) OpenMode {
        return .{
            .read = true,
            .write = false,
            .seek = extra == .seek or extra == .seek_close,
            .close = extra == .close or extra == .seek_close,
        };
    }
    pub fn readwrite(extra: ExtraOptions) OpenMode {
        return .{
            .read = true,
            .write = true,
            .seek = extra == .seek or extra == .seek_close,
            .close = extra == .close or extra == .seek_close,
        };
    }

    pub inline fn isOpen(self: OpenMode) bool {
        return self.read or self.write;
    }
    pub inline fn canRead(self: OpenMode) bool {
        return self.read;
    }
    pub inline fn canWrite(self: OpenMode) bool {
        return self.write;
    }
    pub inline fn canSeek(self: OpenMode) bool {
        return self.seek;
    }
};

file: std.fs.File,
mode: OpenMode = .{},
kind: FileKind = .File,
list: *Scheduler.CompletionLinkedList,

pub const AsyncReadContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    ref: Scheduler.ThreadRef,
    limit: usize = LuaHelper.MAX_LUAU_SIZE,
    array: std.ArrayList(u8) = undefined,
    lua_type: VM.lua.Type = .String,
    buffer_len: usize = 0,
    err: ?anyerror = null,
    auto_close: bool = true,
    file_kind: FileKind = .File,
    list: ?*Scheduler.CompletionLinkedList = null,

    const This = @This();

    fn cleanup(
        self: *This,
        L: *VM.lua.State,
        scheduler: *Scheduler,
        completion: *xev.Completion,
        file: xev.File,
    ) xev.CallbackAction {
        if (self.auto_close) {
            self.auto_close = false;
            file.close(&scheduler.loop, completion, This, self, close_complete);
            return .disarm;
        }
        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.array.deinit();

        if (self.list) |l|
            l.remove(&self.completion);

        if (self.err) |e| {
            L.pushstring(@errorName(e)) catch |err| std.debug.panic("{}", .{err});
            _ = Scheduler.resumeStateError(L, null) catch {};
        } else {
            self.array.shrinkAndFree(@min(self.buffer_len, self.limit));
            switch (self.lua_type) {
                .Buffer => L.Zpushbuffer(self.array.items) catch |e| std.debug.panic("{}", .{e}),
                .String => L.pushlstring(self.array.items) catch |e| std.debug.panic("{}", .{e}),
                else => unreachable,
            }
            _ = Scheduler.resumeState(L, null, 1) catch {};
        }
        return .disarm;
    }

    pub fn close_complete(
        ud: ?*This,
        _: *xev.Loop,
        completion: *xev.Completion,
        file: xev.File,
        c: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        c catch |err| {
            if (self.err == null)
                self.err = err;
        };

        return self.cleanup(L, scheduler, completion, file);
    }

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        completion: *xev.Completion,
        file: xev.File,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);
        if (L.status() != .Yield)
            return self.cleanup(L, scheduler, completion, file);

        const read_len = r catch |err| switch (err) {
            xev.ReadError.EOF => 0,
            else => {
                self.err = err;
                return self.cleanup(L, scheduler, completion, file);
            },
        };

        self.buffer_len += read_len;

        if (read_len == 0 or self.buffer_len > self.limit)
            return self.cleanup(L, scheduler, completion, file);

        switch (self.file_kind) {
            .File => {
                self.array.ensureTotalCapacity(self.buffer_len + 1) catch |err| {
                    self.err = err;
                    return self.cleanup(L, scheduler, completion, file);
                };
                if (self.array.capacity > self.limit)
                    self.array.shrinkAndFree(self.limit);
                self.array.expandToCapacity();

                file.pread(
                    &scheduler.loop,
                    completion,
                    .{ .slice = self.array.items[self.buffer_len..] },
                    self.buffer_len,
                    This,
                    self,
                    This.complete,
                );

                return .disarm;
            },
            .Tty => return self.cleanup(L, scheduler, completion, file),
        }
    }

    pub fn queue(
        L: *VM.lua.State,
        f: std.fs.File,
        useBuffer: bool,
        pre_alloc_size: usize,
        max_size: usize,
        auto_close: bool,
        file_kind: FileKind,
        list: ?*Scheduler.CompletionLinkedList,
    ) !i32 {
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);
        const allocator = luau.getallocator(L);

        const file = xev.File.init(f) catch unreachable;

        const array = try std.ArrayList(u8).initCapacity(allocator, @min(pre_alloc_size, max_size));
        errdefer array.deinit();

        const ctx = try scheduler.createAsyncCtx(This);

        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
            .lua_type = if (useBuffer) .Buffer else .String,
            .array = array,
            .limit = max_size,
            .auto_close = auto_close,
            .file_kind = file_kind,
            .list = list,
        };

        ctx.array.expandToCapacity();

        switch (file_kind) {
            .File => file.pread(
                &scheduler.loop,
                &ctx.completion.completion,
                .{ .slice = ctx.array.items },
                0,
                This,
                ctx,
                This.complete,
            ),
            .Tty => file.read(
                &scheduler.loop,
                &ctx.completion.completion,
                .{ .slice = ctx.array.items },
                This,
                ctx,
                This.complete,
            ),
        }
        if (list) |l|
            l.append(&ctx.completion);

        return L.yield(0);
    }
};

pub const AsyncWriteContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    ref: Scheduler.ThreadRef,
    data: []u8,
    err: ?anyerror = null,
    auto_close: bool = true,
    pos: u64 = 0,
    file_kind: FileKind = .File,
    list: ?*Scheduler.CompletionLinkedList = null,

    const This = @This();

    pub fn cleanup(
        self: *This,
        L: *VM.lua.State,
        scheduler: *Scheduler,
        completion: *xev.Completion,
        file: xev.File,
    ) xev.CallbackAction {
        if (self.auto_close) {
            self.auto_close = false;
            file.close(&scheduler.loop, completion, This, self, close_complete);
            return .disarm;
        }
        defer scheduler.completeAsync(self);
        const allocator = luau.getallocator(L);

        defer allocator.free(self.data);
        defer self.ref.deref();

        if (self.list) |l|
            l.remove(&self.completion);

        if (self.err) |e| {
            L.pushstring(@errorName(e)) catch |err| std.debug.panic("{}", .{err});
            _ = Scheduler.resumeStateError(L, null) catch {};
        } else _ = Scheduler.resumeState(L, null, 0) catch {};
        return .disarm;
    }

    pub fn close_complete(
        ud: ?*This,
        _: *xev.Loop,
        completion: *xev.Completion,
        file: xev.File,
        c: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        c catch |err| {
            if (self.err == null)
                self.err = err;
        };

        return self.cleanup(L, scheduler, completion, file);
    }

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        completion: *xev.Completion,
        file: xev.File,
        b: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;

        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        if (L.status() != .Yield)
            return self.cleanup(L, scheduler, completion, file);

        const written = w catch |err| {
            self.err = err;
            return self.cleanup(L, scheduler, completion, file);
        };

        if (written == 0 or written == b.slice.len)
            return self.cleanup(L, scheduler, completion, file);

        switch (self.file_kind) {
            .File => {
                self.pos += written;
                file.pwrite(
                    &scheduler.loop,
                    completion,
                    .{ .slice = self.data[written..] },
                    self.pos,
                    This,
                    self,
                    This.complete,
                );
            },
            .Tty => file.write(
                &scheduler.loop,
                completion,
                .{ .slice = b.slice[written..] },
                This,
                self,
                This.complete,
            ),
        }

        return .disarm;
    }

    pub fn queue(
        L: *VM.lua.State,
        f: std.fs.File,
        data: []const u8,
        auto_close: bool,
        pos: u64,
        file_kind: FileKind,
        list: ?*Scheduler.CompletionLinkedList,
    ) !i32 {
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);
        const allocator = luau.getallocator(L);

        const copy = try allocator.dupe(u8, data);
        errdefer allocator.free(copy);

        const file = try xev.File.init(f);
        const ctx = try scheduler.createAsyncCtx(This);

        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
            .data = copy,
            .auto_close = auto_close,
            .pos = pos,
            .file_kind = file_kind,
            .list = list,
        };

        switch (file_kind) {
            .File => file.pwrite(
                &scheduler.loop,
                &ctx.completion.completion,
                .{ .slice = data },
                pos,
                This,
                ctx,
                This.complete,
            ),
            .Tty => file.write(
                &scheduler.loop,
                &ctx.completion.completion,
                .{ .slice = data },
                This,
                ctx,
                This.complete,
            ),
        }

        if (list) |l|
            l.append(&ctx.completion);

        return L.yield(0);
    }
};

fn lua_write(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const data = try L.Zcheckvalue([]const u8, 2, null);

    const pos = switch (self.kind) {
        .File => if (self.mode.canSeek()) try self.file.getPos() else 0,
        .Tty => 0,
    };

    return File.AsyncWriteContext.queue(L, self.file, data, false, pos, self.kind, self.list);
}

fn lua_writeSync(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const data = try L.Zcheckvalue([]const u8, 2, null);

    try self.file.writeAll(data);

    return 0;
}

fn lua_append(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotAppendable,
    }
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const string = try L.Zcheckvalue([]const u8, 2, null);

    const pos = pos: {
        if (self.mode.canSeek()) {
            try self.file.seekFromEnd(0);
            break :pos try self.file.getPos();
        }
        break :pos 0;
    };

    return File.AsyncWriteContext.queue(L, self.file, string, false, pos, self.kind, self.list);
}

fn lua_appendSync(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotAppendable,
    }
    if (!self.mode.canWrite())
        return error.NotOpenForWriting;
    const string = try L.Zcheckvalue([]const u8, 2, null);

    try self.file.seekFromEnd(0);
    try self.file.writeAll(string);

    return 0;
}

fn lua_getSeekPosition(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    L.pushnumber(@floatFromInt(try self.file.getPos()));
    return 1;
}

fn lua_getSize(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    L.pushnumber(@floatFromInt(try self.file.getEndPos()));
    return 1;
}

fn lua_seekFromEnd(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.file.seekFromEnd(@intFromFloat(@max(0, L.Loptnumber(2, 0))));
    return 0;
}

fn lua_seekTo(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.file.seekTo(@intFromFloat(@max(0, L.Loptnumber(2, 0))));
    return 0;
}

fn lua_seekBy(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotSeekable,
    }
    try self.file.seekBy(@intFromFloat(L.Loptnumber(2, 1)));
    return 0;
}

fn lua_read(self: *File, L: *VM.lua.State) !i32 {
    const size = L.Loptunsigned(2, LuaHelper.MAX_LUAU_SIZE);
    if (!self.mode.canRead())
        return error.NotOpenForReading;
    return AsyncReadContext.queue(
        L,
        self.file,
        L.Loptboolean(3, false),
        1024,
        @intCast(size),
        false,
        self.kind,
        self.list,
    );
}

fn lua_readSync(self: *File, L: *VM.lua.State) !i32 {
    if (!self.mode.canRead())
        return error.NotOpenForReading;
    const allocator = luau.getallocator(L);
    const size = L.Loptunsigned(2, LuaHelper.MAX_LUAU_SIZE);
    const useBuffer = L.Loptboolean(3, false);
    switch (self.kind) {
        .File => {
            const data = try self.file.readToEndAlloc(allocator, @intCast(size));
            defer allocator.free(data);

            if (useBuffer)
                try L.Zpushbuffer(data)
            else
                try L.pushlstring(data);
        },
        .Tty => blk: {
            var fds = [1]sysfd.context.pollfd{.{
                .events = sysfd.context.POLLIN,
                .fd = self.file.handle,
                .revents = 0,
            }};

            const poll = try sysfd.context.poll(&fds, 0);
            if (poll < 0)
                std.debug.panic("InternalError (Bad Poll)", .{});
            if (poll == 0) {
                try L.pushlstring("");
                break :blk;
            }

            var buffer = try allocator.alloc(u8, @intCast(size));
            defer allocator.free(buffer);

            const amount = try self.file.read(buffer);

            const data = buffer[0..amount];
            if (useBuffer)
                try L.Zpushbuffer(data)
            else
                try L.pushlstring(data);
        },
    }
    return 1;
}

fn lua_lock(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    var lockOpt: std.fs.File.Lock = .exclusive;
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
    if (builtin.os.tag == .windows) {
        switch (lockOpt) {
            .none => {},
            .shared, .exclusive => {
                var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
                const range_off: std.os.windows.LARGE_INTEGER = 0;
                const range_len: std.os.windows.LARGE_INTEGER = 1;
                std.os.windows.LockFile(
                    self.file.handle,
                    null,
                    null,
                    null,
                    &io_status_block,
                    &range_off,
                    &range_len,
                    null,
                    std.os.windows.FALSE, // non-blocking=false
                    @intFromBool(lockOpt == .exclusive),
                ) catch |err| switch (err) {
                    error.WouldBlock => unreachable, // non-blocking=false
                    else => |e| return e,
                };
            },
        }
        L.pushboolean(true);
    } else {
        L.pushboolean(try self.file.tryLock(lockOpt));
    }
    return 1;
}

fn lua_unlock(self: *File, L: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    _ = L;
    self.file.unlock();
    return 0;
}

fn lua_sync(self: *File, _: *VM.lua.State) !i32 {
    switch (self.kind) {
        .File => {},
        .Tty => return error.NotFile,
    }
    try self.file.sync();

    return 0;
}

fn lua_readonly(self: *File, L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const meta = try self.file.metadata();
    var permissions = meta.permissions();
    const enabled = if (L.typeOf(2) != .Boolean) {
        L.pushboolean(permissions.readOnly());
        return 1;
    } else L.toboolean(2);
    permissions.setReadOnly(enabled);
    try self.file.setPermissions(permissions);
    return 0;
}

pub const AsyncCloseContext = struct {
    completion: xev.Completion = .{},
    ref: Scheduler.ThreadRef,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        _: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();

        if (L.status() != .Yield)
            return .disarm;

        _ = Scheduler.resumeState(L, null, 0) catch {};
        return .disarm;
    }
};

fn lua_close(self: *File, L: *VM.lua.State) !i32 {
    if (self.mode.isOpen()) {
        if (!self.mode.close)
            return error.NotCloseable;
        if (!L.isyieldable())
            return L.Zyielderror();
        self.mode = .closed;
        const scheduler = Scheduler.getScheduler(L);
        const file = xev.File.init(self.file) catch unreachable;

        const ctx = try scheduler.createAsyncCtx(AsyncCloseContext);
        ctx.* = .{
            .ref = Scheduler.ThreadRef.init(L),
        };

        switch (comptime builtin.os.tag) {
            .windows => _ = std.os.windows.kernel32.CancelIoEx(self.file.handle, null),
            else => {
                var node = self.list.list.first;
                while (node) |n| {
                    scheduler.cancelAsyncTask(&Scheduler.CompletionLinkedList.Node.from(n).completion);
                    node = n.next;
                }
            },
        }

        file.close(
            &scheduler.loop,
            &ctx.completion,
            AsyncCloseContext,
            ctx,
            AsyncCloseContext.complete,
        );

        return L.yield(0);
    }
    return 0;
}

fn before_method(self: *File, L: *VM.lua.State) !void {
    if (!self.mode.isOpen())
        return L.Zerror("File is closed");
}

const __index = MethodMap.CreateStaticIndexMap(File, TAG_FS_FILE, .{
    .{ "write", MethodMap.WithFn(File, lua_write, before_method) },
    .{ "writeSync", MethodMap.WithFn(File, lua_writeSync, before_method) },
    .{ "append", MethodMap.WithFn(File, lua_append, before_method) },
    .{ "appendSync", MethodMap.WithFn(File, lua_appendSync, before_method) },
    .{ "getSeekPosition", MethodMap.WithFn(File, lua_getSeekPosition, before_method) },
    .{ "getSize", MethodMap.WithFn(File, lua_getSize, before_method) },
    .{ "seekFromEnd", MethodMap.WithFn(File, lua_seekFromEnd, before_method) },
    .{ "seekTo", MethodMap.WithFn(File, lua_seekTo, before_method) },
    .{ "seekBy", MethodMap.WithFn(File, lua_seekBy, before_method) },
    .{ "read", MethodMap.WithFn(File, lua_read, before_method) },
    .{ "readSync", MethodMap.WithFn(File, lua_readSync, before_method) },
    .{ "lock", MethodMap.WithFn(File, lua_lock, before_method) },
    .{ "unlock", MethodMap.WithFn(File, lua_unlock, before_method) },
    .{ "sync", MethodMap.WithFn(File, lua_sync, before_method) },
    .{ "readonly", MethodMap.WithFn(File, lua_readonly, before_method) },
    .{ "close", lua_close },
});

pub fn __dtor(_: *VM.lua.State, self: *File) void {
    if (self.mode.isOpen() and self.mode.close)
        self.file.close();
    self.list.deinit();
}

pub inline fn load(L: *VM.lua.State) !void {
    _ = try L.Znewmetatable(@typeName(@This()), .{
        .__metatable = "Metatable is locked",
        .__type = "FileHandle",
    });
    try __index(L, -1);
    L.setreadonly(-1, true);
    L.setuserdatametatable(TAG_FS_FILE);
    L.setuserdatadtor(File, TAG_FS_FILE, __dtor);
}

pub fn push(L: *VM.lua.State, file: std.fs.File, kind: FileKind, mode: OpenMode) !void {
    const allocator = luau.getallocator(L);
    const self = try L.newuserdatataggedwithmetatable(File, TAG_FS_FILE);
    const list = try allocator.create(Scheduler.CompletionLinkedList);
    list.* = .{ .allocator = allocator };
    self.* = .{
        .file = file,
        .kind = kind,
        .mode = mode,
        .list = list,
    };
}
