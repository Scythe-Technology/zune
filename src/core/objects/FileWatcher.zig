const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const VM = luau.VM;

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Watcher = @import("../standard/fs/Watcher.zig");

const FileWatcher = @This();

pub const OBJECT_TAG = Zune.Tags.get("FS_WATCHER").?;
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => .Full,
        .freebsd => .Full,
        else => null,
    };
}

const Waiter = if (builtin.os.tag == .windows) zio.ev.Async else zio.ev.PipePoll;

watcher: Watcher = undefined,
closed: bool = false,
armed: bool = false,
waiter: Waiter = undefined,
staged: Scheduler.Async.Staged = .{},
ref: Scripting.CountedReference = .{},

fn asyncCallback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const async: *Scheduler.Async = Scheduler.Async.fromCompletion(completion);
    const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));
    const allocator = scheduler.allocator();
    defer async.deinit(scheduler);

    const L = async.ref.value;

    const watcher: *FileWatcher = @ptrCast(@alignCast(completion.userdata));

    watcher.ref.deref(L);
    watcher.staged.remove(async);

    switch (async.op) {
        inline .async,
        .pipe_poll,
        => |*e| {
            if (L.status() != .Yield)
                return;

            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};
            watcher.watcher.drain(allocator) catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            const ev = watcher.pushEvent(L, allocator) catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};
            if (!ev)
                return Scheduler.resumeStateError(L, null, error.NoEvent) catch {};
            _ = Scheduler.resumeState(L, null, 2) catch {};
        },
        else => unreachable,
    }
}

fn startAsync(self: *FileWatcher, async: *Scheduler.Async, L: *VM.lua.State, scheduler: *Scheduler) void {
    self.ref.ref(L, 1);

    const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));

    common.op.c.userdata = @ptrCast(@alignCast(self));
    common.op.c.callback = asyncCallback;

    self.staged.append(async);
    scheduler.loop.add(&common.op.c);
}

fn pushEvent(self: *FileWatcher, L: *VM.lua.State, allocator: std.mem.Allocator) !bool {
    const ev = self.watcher.pop() orelse return false;
    defer ev.deinit(allocator);
    try L.pushlstring(ev.path);
    try L.pushlstring(@tagName(ev.kind));
    return true;
}

pub fn lua_add(self: *FileWatcher, L: *VM.lua.State) !i32 {
    if (self.closed)
        return L.Zerror("stopped");
    const path = try L.Zcheckvalue([:0]const u8, 2, null);
    const recursive = try L.Zcheckvalue(?bool, 3, null);

    try self.watcher.add(Scheduler.fromState(L).allocator(), path, .{ .recursive = recursive orelse false });

    return 0;
}

pub fn lua_remove(self: *FileWatcher, L: *VM.lua.State) !i32 {
    if (self.closed)
        return L.Zerror("stopped");
    const path = try L.Zcheckvalue([:0]const u8, 2, null);
    try self.watcher.remove(Scheduler.fromState(L).allocator(), path);
    return 0;
}

pub fn lua_drain(self: *FileWatcher, L: *VM.lua.State) !i32 {
    if (self.closed)
        return L.Zerror("stopped");
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    try self.watcher.drain(allocator);

    return 0;
}

pub fn lua_next(self: *FileWatcher, L: *VM.lua.State) !i32 {
    if (self.closed) {
        L.pushnil();
        return 1;
    }
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    try self.watcher.drain(allocator);
    if (try self.pushEvent(L, allocator))
        return 2;

    if (!L.isyieldable())
        return L.Zyielderror();

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = if (comptime builtin.os.tag == .windows) .{
            .async = .{
                .op = .init(),
            },
        } else .{
            .pipe_poll = .{
                .op = .init(self.watcher.pollFd(), .read),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_stop(self: *FileWatcher, L: *VM.lua.State) !i32 {
    if (self.closed)
        return 0;
    self.closed = true;

    const scheduler = Scheduler.fromState(L);

    {
        var node = self.staged.list.first;
        while (node) |n| {
            const async: *Scheduler.Async = @alignCast(@fieldParentPtr("node", n));
            const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));
            scheduler.loop.cancel(&common.op.c);
            node = n.next;
        }
    }

    self.watcher.deinit(scheduler.allocator());

    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *FileWatcher) void {
    if (!self.closed)
        self.watcher.deinit(Scheduler.fromState(L).allocator());
}

fn windows_wakeNotify(ctx: *anyopaque) void {
    const self: *FileWatcher = @ptrCast(@alignCast(ctx));
    var node = self.staged.list.first;
    while (node) |n| {
        const async: *Scheduler.Async = @alignCast(@fieldParentPtr("node", n));
        switch (async.op) {
            .async => |*a| {
                a.op.notify();
            },
            else => {},
        }
        node = n.next;
    }
}

pub fn create(L: *VM.lua.State) !*FileWatcher {
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();
    const ptr = try L.newuserdatataggedwithmetatable(FileWatcher, OBJECT_TAG);
    ptr.* = .{
        .watcher = try Watcher.init(allocator),
    };
    if (comptime builtin.os.tag == .windows) {
        ptr.watcher.setWake(ptr, windows_wakeNotify);
    }
    return ptr;
}
