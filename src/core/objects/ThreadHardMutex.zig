const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const VM = luau.VM;

const ThreadRegistry = @import("../standard/thread/registry.zig");

const HardMutex = @This();

pub const OBJECT_TAG = Zune.Tags.get("THREAD_HARD_MUTEX").?;

pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (!builtin.single_threaded) .Full else null;
}

pub const Entry = struct {
    mutex: std.Io.Mutex = .init,
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    name: []const u8,
    ref_count: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    pub fn abandon(self: *Entry, current: std.Thread.Id) void {
        if (self.owner.cmpxchgStrong(current, 0, .acq_rel, .acquire) == null)
            self.mutex.unlock(Zune.io());
    }
};

pub const Registry = ThreadRegistry.Of(Entry);

target: *Entry,
armed: std.atomic.Value(bool) = .init(false),

pub fn lua_lock(self: *HardMutex, L: *VM.lua.State) !i32 {
    const id = std.Thread.getCurrentId();
    if (self.target.owner.load(.acquire) == id)
        return L.Zerror("already locked");

    self.target.mutex.lockUncancelable(Zune.io());
    self.target.owner.store(id, .release);
    return 0;
}

pub fn lua_unlock(self: *HardMutex, L: *VM.lua.State) !i32 {
    const id = std.Thread.getCurrentId();
    if (self.target.owner.cmpxchgStrong(id, 0, .acq_rel, .acquire) != null)
        return L.Zerror("not locked");

    self.target.mutex.unlock(Zune.io());
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *HardMutex) void {
    _ = L;
    if (!self.armed.swap(false, .acq_rel))
        return;
    Registry.release(self.target);
}

pub fn create(L: *VM.lua.State, target: *Entry) !*HardMutex {
    const mutex = try L.newuserdatataggedwithmetatable(HardMutex, OBJECT_TAG);
    mutex.* = .{
        .target = target,
    };
    return mutex;
}
