const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

pub const OBJECT_TAG = Zune.Tags.get("THREAD").?;

const Thread = @This();

pub const LIB_NAME = "thread";
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (!@import("builtin").single_threaded) .Full else null;
}

pub const threadlib = Zune.standard.libraries.thread;

runtime: *threadlib.Runtime,

pub fn lua_start(self: *Thread, L: *VM.lua.State) !i32 {
    const runtime = self.runtime;
    if (runtime.status.cmpxchgStrong(.ready, .running, .acq_rel, .acquire) != null) {
        return L.Zerror("thread running or dead");
    }

    std.debug.assert(runtime.status.load(.acquire) == .running);
    runtime.thread = std.Thread.spawn(.{}, threadlib.Runtime.entry, .{runtime}) catch |err| {
        runtime.status.store(.dead, .release);
        return L.Zerrorf("failed to start thread: {}", .{err});
    };

    return 0;
}

pub fn lua_send(self: *Thread, L: *VM.lua.State) !i32 {
    const runtime = self.runtime;
    try runtime.to_worker.send(runtime.allocator, L, 2);
    return 0;
}

pub fn lua_receive(self: *Thread, L: *VM.lua.State) !i32 {
    return self.runtime.to_owner.receive(L);
}

pub fn lua_join(self: *Thread, L: *VM.lua.State) !i32 {
    const runtime = self.runtime;
    runtime.access_mutex.lockUncancelable(Zune.io());
    defer runtime.access_mutex.unlock(Zune.io());
    switch (runtime.status.load(.acquire)) {
        .ready, .dead => return 0,
        .running => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    const state = try allocator.create(threadlib.Sync);
    state.* = .{
        .scheduler = scheduler,
        .runtime = runtime,
        .thread = .init(L),
        .sync = .{
            .complete = threadlib.Sync.joinComplete,
        },
    };
    scheduler.asyncWaitForSync(&state.sync);

    runtime.join_queue.append(&state.node);

    return L.yield(0);
}

pub fn lua_status(self: *Thread, L: *VM.lua.State) !i32 {
    const runtime = self.runtime;
    try L.pushlstring(@tagName(runtime.status.load(.acquire)));
    return 1;
}

pub fn __dtor(L: *VM.lua.State, self: *Thread) void {
    _ = L;
    const runtime = self.runtime;
    runtime.access_mutex.lockUncancelable(Zune.io());
    if (runtime.status.load(.acquire) == .running) {
        defer runtime.access_mutex.unlock(Zune.io());
        runtime.owner = .thread; // TODO: maybe atomic owner?
        return;
    }
    runtime.access_mutex.unlock(Zune.io());
    threadlib.THREADS.remove(&runtime.node);
    if (runtime.thread) |t|
        t.join();
    runtime.deinit();
}
