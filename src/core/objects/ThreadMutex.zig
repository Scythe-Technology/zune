const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

const ThreadRegistry = @import("../standard/thread/registry.zig");

const Mutex = @This();

pub const OBJECT_TAG = Zune.Tags.get("THREAD_MUTEX").?;

pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (!builtin.single_threaded) .Full else null;
}

pub const Entry = struct {
    mutex: std.Io.Mutex = .init,
    owner: ?*VM.lua.State = null,
    owner_thread: std.Thread.Id = 0,
    queue: std.DoublyLinkedList = .{},
    name: []const u8,
    ref_count: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    pub fn abandon(self: *Entry, current: std.Thread.Id) void {
        self.mutex.lockUncancelable(Zune.io());
        if (self.owner_thread != current) {
            self.mutex.unlock(Zune.io());
            return;
        }

        var wake: ?*Waiter = null;
        while (self.queue.popFirst()) |node| {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            if (waiter.thread_id == current) {
                waiter.unlink();
                continue;
            }
            self.owner = waiter.thread.value;
            self.owner_thread = waiter.thread_id;
            wake = waiter;
            break;
        } else {
            self.owner = null;
            self.owner_thread = 0;
        }
        self.mutex.unlock(Zune.io());

        if (wake) |waiter|
            waiter.scheduler.synchronize(&waiter.sync);
    }

    pub fn deinit(self: *Entry) void {
        std.debug.assert(self.owner == null);
        std.debug.assert(self.queue.first == null);
    }

    fn takeWaiter(self: *Entry) ?*Waiter {
        const node = self.queue.popFirst() orelse {
            self.owner = null;
            self.owner_thread = 0;
            return null;
        };
        const waiter: *Waiter = @fieldParentPtr("node", node);
        self.owner = waiter.thread.value;
        self.owner_thread = waiter.thread_id;
        return waiter;
    }

    fn handOff(self: *Entry) void {
        self.mutex.lockUncancelable(Zune.io());
        const waiter = self.takeWaiter();
        self.mutex.unlock(Zune.io());
        if (waiter) |parked|
            parked.scheduler.synchronize(&parked.sync);
    }
};

const Waiter = struct {
    node: std.DoublyLinkedList.Node = .{},
    sync: Scheduler.Synchronization.Context,
    scheduler: *Scheduler,
    thread: Scheduler.ThreadRef,
    thread_id: std.Thread.Id,
    entry: *Entry,

    fn complete(ctx: *Scheduler.Synchronization.Context, scheduler: *Scheduler) void {
        const self: *Waiter = @fieldParentPtr("sync", ctx);
        const entry = self.entry;
        const L = self.thread.value;
        defer {
            self.thread.deref();
            scheduler.allocator().destroy(self);
        }

        if (L.status() != .Yield) {
            entry.handOff();
            return;
        }
        _ = Scheduler.resumeState(L, null, 0) catch {};
    }

    fn unlink(self: *Waiter) void {
        const scheduler = self.scheduler;
        scheduler.sync.mutex.lockUncancelable(Zune.io());
        scheduler.sync.queue.remove(&self.sync.node);
        scheduler.sync.mutex.unlock(Zune.io());
        self.thread.deref();
        scheduler.allocator().destroy(self);
    }
};

pub const Registry = ThreadRegistry.Of(Entry);

target: *Entry,
armed: std.atomic.Value(bool) = .init(false),

pub fn lua_lock(self: *Mutex, L: *VM.lua.State) !i32 {
    const entry = self.target;
    const id = std.Thread.getCurrentId();

    entry.mutex.lockUncancelable(Zune.io());
    if (entry.owner == null) {
        entry.owner = L;
        entry.owner_thread = id;
        entry.mutex.unlock(Zune.io());
        return 0;
    }

    if (!L.isyieldable()) {
        entry.mutex.unlock(Zune.io());
        return L.Zyielderror();
    }

    const scheduler = Scheduler.fromState(L);
    const waiter = scheduler.allocator().create(Waiter) catch |err| {
        entry.mutex.unlock(Zune.io());
        return err;
    };
    waiter.* = .{
        .scheduler = scheduler,
        .thread = .init(L),
        .thread_id = id,
        .entry = entry,
        .sync = .{
            .complete = Waiter.complete,
        },
    };

    scheduler.asyncWaitForSync(&waiter.sync);

    entry.queue.append(&waiter.node);
    entry.mutex.unlock(Zune.io());

    return L.yield(0) catch unreachable;
}

pub fn lua_unlock(self: *Mutex, L: *VM.lua.State) !i32 {
    const entry = self.target;
    entry.mutex.lockUncancelable(Zune.io());
    if (entry.owner != L) {
        entry.mutex.unlock(Zune.io());
        return L.Zerror("not locked");
    }

    const waiter = entry.takeWaiter();
    entry.mutex.unlock(Zune.io());
    if (waiter) |parked|
        parked.scheduler.synchronize(&parked.sync);
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *Mutex) void {
    _ = L;
    if (!self.armed.swap(false, .acq_rel))
        return;
    Registry.release(self.target);
}

pub fn create(L: *VM.lua.State, target: *Entry) !*Mutex {
    const mutex = try L.newuserdatataggedwithmetatable(Mutex, OBJECT_TAG);
    mutex.* = .{
        .target = target,
    };
    return mutex;
}
