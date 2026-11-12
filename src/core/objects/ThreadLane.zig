const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const ThreadRegistry = @import("../standard/thread/registry.zig");

const ThreadLane = @This();

pub const OBJECT_TAG = Zune.Tags.get("THREAD_LANE").?;

pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (!builtin.single_threaded) .Full else null;
}

pub const Lane = struct {
    mutex: std.Io.Mutex = .init,
    messages: std.DoublyLinkedList = .{},
    waiters: std.DoublyLinkedList = .{},

    const Message = struct {
        node: std.DoublyLinkedList.Node = .{},
        allocator: std.mem.Allocator,
        value: union(enum) {
            none: void,
            small: Scripting.LuaValue,
            large: struct {
                values: [*]Scripting.LuaValue,
                len: u32,
            },
        },

        fn from(node: *std.DoublyLinkedList.Node) *Message {
            return @fieldParentPtr("node", node);
        }

        fn push(self: *Message, L: *VM.lua.State) !i32 {
            switch (self.value) {
                .none => return 0,
                .small => |v| {
                    try L.rawcheckstack(1);
                    try v.push(L);
                    return 1;
                },
                .large => |v| {
                    try L.rawcheckstack(v.len);
                    for (v.values[0..v.len]) |value|
                        try value.push(L);
                    return @intCast(v.len);
                },
            }
        }

        fn destroy(self: *Message) void {
            const allocator = self.allocator;
            switch (self.value) {
                .none => {},
                .small => |v| v.deinit(allocator),
                .large => |v| {
                    const slice = v.values[0..v.len];
                    for (slice) |value|
                        value.deinit(allocator);
                    allocator.free(slice);
                },
            }
            allocator.destroy(self);
        }
    };

    const Waiter = struct {
        node: std.DoublyLinkedList.Node = .{},
        sync: Scheduler.Synchronization.Context,
        scheduler: *Scheduler,
        thread: Scheduler.ThreadRef,
        thread_id: std.Thread.Id,
        message: *Message = undefined,

        fn complete(ctx: *Scheduler.Synchronization.Context, scheduler: *Scheduler) void {
            const self: *Waiter = @fieldParentPtr("sync", ctx);
            const message = self.message;
            const L = self.thread.value;
            defer {
                message.destroy();
                self.thread.deref();
                scheduler.allocator().destroy(self);
            }

            if (L.status() != .Yield)
                return;

            const amt = message.push(L) catch |err| std.debug.panic("{}", .{err});
            _ = Scheduler.resumeState(L, null, amt) catch {};
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

    pub fn send(self: *Lane, allocator: std.mem.Allocator, L: *VM.lua.State, start: usize) !void {
        const top = L.gettop();
        const send_count: usize = if (top < start) 0 else top - start + 1;

        var values: std.ArrayList(Scripting.LuaValue) = if (send_count > 0) try .initCapacity(allocator, 1) else .empty;
        defer values.deinit(allocator);
        errdefer for (values.items) |value| value.deinit(allocator);

        if (send_count > 0) {
            if (send_count > std.math.maxInt(i32))
                return error.TooManyValues;
            var err_type: VM.lua.Type = .None;
            var index: usize = start;
            while (index <= top) : (index += 1) {
                const value = Scripting.LuaValue.store(allocator, L, @intCast(index), &err_type) catch |err| switch (err) {
                    error.UnsupportedType => return L.Zerrorf("unsupported lua type for sending (got {s})", .{VM.lapi.typename(err_type)}),
                    else => return err,
                };
                values.append(allocator, value) catch |err| {
                    value.deinit(allocator);
                    return err;
                };
            }
        }

        const message = try allocator.create(Message);
        message.* = .{
            .allocator = allocator,
            .value = .none,
        };
        errdefer message.destroy();
        if (send_count == 1) {
            message.value = .{ .small = values.items[0] };
            values.clearRetainingCapacity();
        } else if (send_count > 1) {
            const slice = try values.toOwnedSlice(allocator);
            message.value = .{
                .large = .{
                    .values = slice.ptr,
                    .len = @intCast(slice.len),
                },
            };
        }

        self.mutex.lockUncancelable(Zune.io());
        if (self.waiters.popFirst()) |node| {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            waiter.message = message;
            const scheduler = waiter.scheduler;
            const sync = &waiter.sync;
            self.mutex.unlock(Zune.io());
            scheduler.synchronize(sync);
        } else {
            self.messages.append(&message.node);
            self.mutex.unlock(Zune.io());
        }
    }

    pub fn receive(self: *Lane, L: *VM.lua.State) !i32 {
        self.mutex.lockUncancelable(Zune.io());
        if (self.messages.popFirst()) |node| {
            self.mutex.unlock(Zune.io());
            const message = Message.from(node);
            defer message.destroy();
            return try message.push(L);
        }

        if (!L.isyieldable()) {
            self.mutex.unlock(Zune.io());
            return L.Zyielderror();
        }

        const scheduler = Scheduler.fromState(L);
        const waiter = scheduler.allocator().create(Waiter) catch |err| {
            self.mutex.unlock(Zune.io());
            return err;
        };
        waiter.* = .{
            .scheduler = scheduler,
            .thread = .init(L),
            .thread_id = std.Thread.getCurrentId(),
            .sync = .{
                .complete = Waiter.complete,
            },
        };

        scheduler.asyncWaitForSync(&waiter.sync);
        self.waiters.append(&waiter.node);
        self.mutex.unlock(Zune.io());
        return L.yield(0) catch unreachable;
    }

    pub fn abandon(self: *Lane, current: std.Thread.Id) void {
        self.mutex.lockUncancelable(Zune.io());
        var node = self.waiters.first;
        while (node) |current_node| {
            const next = current_node.next;
            const waiter: *Waiter = @fieldParentPtr("node", current_node);
            if (waiter.thread_id == current) {
                self.waiters.remove(current_node);
                waiter.unlink();
            }
            node = next;
        }
        self.mutex.unlock(Zune.io());
    }

    pub fn deinit(self: *Lane) void {
        while (self.messages.popFirst()) |node|
            Message.from(node).destroy();
    }
};

pub const Entry = struct {
    lane: Lane = .{},
    name: []const u8,
    ref_count: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    pub fn abandon(self: *Entry, current: std.Thread.Id) void {
        self.lane.abandon(current);
    }

    pub fn deinit(self: *Entry) void {
        std.debug.assert(self.lane.waiters.first == null);
        self.lane.deinit();
    }
};

pub const Registry = ThreadRegistry.Of(Entry);

target: *Entry,
armed: std.atomic.Value(bool) = .init(false),

pub fn lua_send(self: *ThreadLane, L: *VM.lua.State) !i32 {
    try self.target.lane.send(Zune.DEFAULT_ALLOCATOR, L, 2);
    return 0;
}

pub fn lua_receive(self: *ThreadLane, L: *VM.lua.State) !i32 {
    return self.target.lane.receive(L);
}

pub fn __dtor(L: *VM.lua.State, self: *ThreadLane) void {
    _ = L;
    if (!self.armed.swap(false, .acq_rel))
        return;
    Registry.release(self.target);
}

pub fn create(L: *VM.lua.State, target: *Entry) !*ThreadLane {
    const lane = try L.newuserdatataggedwithmetatable(ThreadLane, OBJECT_TAG);
    lane.* = .{
        .target = target,
    };
    return lane;
}
