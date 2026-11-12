const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const ThreadRegistry = @import("../standard/thread/registry.zig");

const ThreadValue = @This();

pub const OBJECT_TAG = Zune.Tags.get("THREAD_VALUE").?;

pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (!builtin.single_threaded) .Full else null;
}

pub const Entry = struct {
    mutex: std.Io.Mutex = .init,
    value: Scripting.LuaValue = .nil,
    active: ?*Op = null,
    queue: std.DoublyLinkedList = .{},
    name: []const u8,
    ref_count: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    pub fn abandon(self: *Entry, current: std.Thread.Id) void {
        self.mutex.lockUncancelable(Zune.io());
        defer self.mutex.unlock(Zune.io());

        if (self.active) |op|
            std.debug.assert(op.thread_id != current);

        var node = self.queue.first;
        while (node) |current_node| {
            const next = current_node.next;
            const op: *Op = @fieldParentPtr("node", current_node);
            if (op.thread_id == current) {
                self.queue.remove(current_node);
                op.unlink();
            }
            node = next;
        }
    }

    pub fn deinit(self: *Entry) void {
        std.debug.assert(self.active == null);
        std.debug.assert(self.queue.first == null);
        self.value.deinit(Zune.DEFAULT_ALLOCATOR);
    }

    fn replace(self: *Entry, new_value: Scripting.LuaValue) void {
        self.mutex.lockUncancelable(Zune.io());

        const previous = self.value;
        self.value = new_value;

        self.mutex.unlock(Zune.io());

        previous.deinit(Zune.DEFAULT_ALLOCATOR);
    }

    fn advance(self: *Entry, finished: *Op) void {
        self.mutex.lockUncancelable(Zune.io());

        std.debug.assert(self.active == finished);

        const next: ?*Op = if (self.queue.popFirst()) |node|
            @fieldParentPtr("node", node)
        else
            null;

        self.active = next;
        self.mutex.unlock(Zune.io());

        if (next) |op|
            op.scheduler.synchronize(&op.sync);
    }
};

const Op = struct {
    node: std.DoublyLinkedList.Node = .{},
    sync: Scheduler.Synchronization.Context,
    scheduler: *Scheduler,
    thread: Scheduler.ThreadRef,
    thread_id: std.Thread.Id,
    entry: *Entry,
    kind: Kind,

    const Kind = union(enum) {
        set: Scripting.LuaValue,
        update: Scripting.Reference,

        fn deinit(self: *Kind, L: *VM.lua.State) void {
            switch (self.*) {
                .set => |value| value.deinit(Zune.DEFAULT_ALLOCATOR),
                .update => |*callback| callback.deref(L),
            }
        }
    };

    fn complete(ctx: *Scheduler.Synchronization.Context, scheduler: *Scheduler) void {
        const self: *Op = @fieldParentPtr("sync", ctx);
        const entry = self.entry;
        const L = self.thread.value;
        defer {
            self.kind.deinit(L);
            self.thread.deref();
            scheduler.allocator().destroy(self);
        }

        if (L.status() == .Yield) switch (self.kind) {
            .set => self.applySet(L),
            .update => self.applyUpdate(L),
        };

        entry.advance(self);
    }

    fn applySet(self: *Op, L: *VM.lua.State) void {
        const value = switch (self.kind) {
            .set => |*slot| blk: {
                const taken = slot.*;
                slot.* = .nil;
                break :blk taken;
            },
            .update => unreachable,
        };
        self.entry.replace(value);

        _ = Scheduler.resumeState(L, null, 0) catch {};
    }

    fn applyUpdate(self: *Op, L: *VM.lua.State) void {
        const callback = switch (self.kind) {
            .update => |ref| ref,
            .set => unreachable,
        };
        const entry = self.entry;

        if (L.status() != .Yield)
            return;

        const child = L.newthread() catch |err| {
            resumeError(L, err);
            return;
        };

        callback.push(child);

        entry.mutex.lockUncancelable(Zune.io());
        entry.value.push(child) catch |err| {
            entry.mutex.unlock(Zune.io());
            resumeError(L, err);
            return;
        };
        entry.mutex.unlock(Zune.io());

        if (child.pcall(1, 1, 0) != .Ok) {
            child.xmove(L, 1);
            L.remove(-2);
            _ = Scheduler.resumeStateErrorFast(L, null) catch {};
            return;
        }

        var err_type: VM.lua.Type = .None;
        const new_value = Scripting.LuaValue.store(Zune.DEFAULT_ALLOCATOR, child, -1, &err_type) catch |err| switch (err) {
            error.UnsupportedType => {
                resumeMessage(L, "unsupported lua type (got {s})", .{VM.lapi.typename(err_type)});
                return;
            },
            else => {
                resumeError(L, err);
                return;
            },
        };

        L.settop(0);
        entry.replace(new_value);
        _ = Scheduler.resumeState(L, null, 0) catch {};
    }

    fn unlink(self: *Op) void {
        const scheduler = self.scheduler;
        const L = self.thread.value;

        scheduler.sync.mutex.lockUncancelable(Zune.io());
        scheduler.sync.queue.remove(&self.sync.node);
        scheduler.sync.mutex.unlock(Zune.io());

        self.kind.deinit(L);
        self.thread.deref();

        scheduler.allocator().destroy(self);
    }
};

fn resumeError(L: *VM.lua.State, err: anyerror) void {
    L.settop(0);
    Scheduler.resumeStateError(L, null, err) catch {};
}

fn resumeMessage(L: *VM.lua.State, comptime fmt: []const u8, args: anytype) void {
    L.settop(0);
    _ = L.Zresumeferror(null, fmt, args) catch {};
}

fn copyValue(L: *VM.lua.State, index: i32) !Scripting.LuaValue {
    if (L.gettop() < @as(usize, @intCast(index)))
        return .nil;
    var err_type: VM.lua.Type = .None;
    return Scripting.LuaValue.store(Zune.DEFAULT_ALLOCATOR, L, index, &err_type) catch |err| switch (err) {
        error.UnsupportedType => return L.Zerrorf("unsupported lua type (got {s})", .{VM.lapi.typename(err_type)}),
        else => return err,
    };
}

fn enqueue(entry: *Entry, L: *VM.lua.State, kind: Op.Kind) !void {
    const scheduler = Scheduler.fromState(L);

    const op = try scheduler.allocator().create(Op);

    op.* = .{
        .scheduler = scheduler,
        .thread = .init(L),
        .thread_id = std.Thread.getCurrentId(),
        .entry = entry,
        .kind = kind,
        .sync = .{
            .complete = Op.complete,
        },
    };

    entry.mutex.lockUncancelable(Zune.io());

    scheduler.asyncWaitForSync(&op.sync);

    const start = entry.active == null;
    if (start) {
        std.debug.assert(entry.queue.first == null);
        entry.active = op;
    } else entry.queue.append(&op.node);

    entry.mutex.unlock(Zune.io());

    if (start)
        scheduler.synchronize(&op.sync);
}

pub const Registry = ThreadRegistry.Of(Entry);

target: *Entry,
armed: std.atomic.Value(bool) = .init(false),

pub fn lua_set(self: *ThreadValue, L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();

    const value = try copyValue(L, 2);
    errdefer value.deinit(Zune.DEFAULT_ALLOCATOR);

    try enqueue(self.target, L, .{ .set = value });

    return L.yield(0) catch unreachable;
}

pub fn lua_get(self: *ThreadValue, L: *VM.lua.State) !i32 {
    const entry = self.target;
    const top: i32 = @intCast(L.gettop());
    entry.mutex.lockUncancelable(Zune.io());
    entry.value.push(L) catch |err| {
        L.settop(top);
        entry.mutex.unlock(Zune.io());
        return err;
    };
    entry.mutex.unlock(Zune.io());
    return 1;
}

pub fn lua_update(self: *ThreadValue, L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    try L.Zchecktype(2, .Function);

    const top = L.gettop();
    L.pushvalue(2);
    var callback: Scripting.Reference = .init(L, -1);
    errdefer callback.deref(L);
    if (L.gettop() > top)
        L.pop(@intCast(L.gettop() - top));

    try enqueue(self.target, L, .{ .update = callback });

    return L.yield(0) catch unreachable;
}

pub fn __dtor(L: *VM.lua.State, self: *ThreadValue) void {
    _ = L;
    if (!self.armed.swap(false, .acq_rel))
        return;
    Registry.release(self.target);
}

pub fn create(L: *VM.lua.State, target: *Entry) !*ThreadValue {
    const value = try L.newuserdatataggedwithmetatable(ThreadValue, OBJECT_TAG);
    value.* = .{
        .target = target,
    };
    return value;
}
