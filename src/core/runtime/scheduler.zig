const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Runtime = Zune.Runtime;
const Scripting = Runtime.Scripting;

const VM = luau.VM;

pub const ThreadRef = struct {
    value: *VM.lua.State,
    ref: i32 = 0,

    pub fn init(L: *VM.lua.State) ThreadRef {
        const GL = L.mainthread();
        if (GL == L)
            return .{ .value = L, .ref = 0 };
        L.rawcheckstack(1) catch |err| std.debug.panic("{}", .{err});
        _ = L.pushthread();
        std.debug.assert(L.isthread(-1));
        const ref = (L.ref(-1) catch |err| std.debug.panic("{}", .{err})) orelse unreachable;
        L.pop(1);
        return .{ .value = L, .ref = ref };
    }

    pub fn take(self: *ThreadRef) ThreadRef {
        const ret: ThreadRef = .{
            .value = self.value,
            .ref = self.ref,
        };
        self.ref = 0;
        return ret;
    }

    pub fn derefUnretained(self: ThreadRef) void {
        if (self.ref > 0)
            self.value.mainthread().unref(self.ref);
    }

    pub fn deref(self: *ThreadRef) void {
        if (self.ref > 0) {
            self.value.mainthread().unref(self.ref);
            self.ref = 0;
        }
    }
};

pub const SleepingThread = struct {
    from: ?*VM.lua.State,
    thread: ThreadRef,
    wake: f64,
    start: f64,
    args: i32,
    waited: bool,
};

pub const Deferred = struct {
    from: ?*VM.lua.State,
    thread: ThreadRef,
    args: i32,
};

pub fn Queue(comptime T: type) type {
    return struct {
        list: std.ArrayListUnmanaged(T) = .empty,
        head: usize = 0,

        pub const empty: Self = .{};

        const Self = @This();

        pub fn initCapacity(gpa: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .list = try .initCapacity(gpa, capacity),
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.list.deinit(gpa);
            self.head = 0;
        }

        pub fn enqueue(self: *Self, gpa: std.mem.Allocator, value: T) !void {
            try self.list.append(gpa, value);
        }

        pub fn dequeue(self: *Self) ?T {
            std.debug.assert(self.head < self.list.items.len);
            const value = self.list.items[self.head];
            self.head += 1;
            return value;
        }

        pub fn consume(self: *Self, amt: usize) void {
            std.debug.assert(amt <= self.count());
            self.head += amt;
        }

        pub fn rebase(self: *Self) void {
            if (self.head == 0)
                return;

            const remaining = self.list.items.len - self.head;
            if (remaining > 0)
                std.mem.copyForwards(T, self.list.items[0..remaining], self.list.items[self.head..]);

            self.list.items.len = remaining;
            self.head = 0;
        }

        pub fn shrink(self: *Self, gpa: std.mem.Allocator, amount: usize) void {
            if (self.list.capacity <= amount or self.list.items.len > amount)
                return;
            std.debug.assert(self.head == 0); // needs to be rebased
            self.list.shrinkAndFree(gpa, self.list.items.len);
        }

        pub fn count(self: Self) usize {
            return self.list.items.len - self.head;
        }

        pub fn array(self: Self) []T {
            return self.list.items[self.head..];
        }

        pub fn orderedRemove(self: *Self, i: usize) ?T {
            std.debug.assert(i < self.count());
            return self.list.orderedRemove(self.head + i);
        }
    };
}

const Scheduler = @This();

pub const Awaiting = struct {
    data: *anyopaque,
    state: ThreadRef,
    resumeFn: *const Fn,
    kind: Kind,

    pub const Kind = enum { Internal, User };

    pub const Fn = fn (ctx: *anyopaque, L: *VM.lua.State, scheduler: *Scheduler) void;
};

pub const Synchronization = struct {
    async: zio.ev.Async = .{
        .c = .{
            .op = .async,
            .callback = Synchronization.asyncCallback,
        },
    },
    completed: LinkedList = .{},
    queue: LinkedList = .{},
    mutex: std.Io.Mutex = .init,
    notified: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
    waiting: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),

    pub const LinkedList = std.DoublyLinkedList;

    pub const Context = struct {
        node: LinkedList.Node = .{},
        complete: *const fn (*Context, *Scheduler) void,
    };

    pub inline fn hasPending(self: *Synchronization) bool {
        return self.waiting.load(.acquire) or // awaiting instances
            self.notified.load(.acquire); // completed instances
    }

    pub fn notify(self: *Synchronization) void {
        if (self.notified.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return;
        std.debug.assert(self.notified.load(.acquire) == true);
        self.async.notify();
    }

    fn asyncCallback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
        const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));
        const sync: *Synchronization = &scheduler.sync;
        sync.mutex.lockUncancelable(Zune.io());
        defer sync.mutex.unlock(Zune.io());
        if (sync.queue.first != null) {
            loop.add(completion);
            return;
        }
        sync.waiting.store(false, .release);
    }

    pub fn wait(self: *Synchronization, scheduler: *Scheduler) void {
        if (self.waiting.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return;
        std.debug.assert(self.waiting.load(.acquire) == true);
        scheduler.loop.add(&self.async.c);
    }
};

pub const Policy = struct {
    list: std.DoublyLinkedList = .{},
    running_count: std.atomic.Value(u32) = .init(0),

    const Limit = struct {
        node: std.DoublyLinkedList.Node = .{},
        thread: *VM.lua.State,
        seconds: f64 = 0,
        start: f64 = 0,
        running: bool = false,

        fn from(node: *std.DoublyLinkedList.Node) *Limit {
            return @fieldParentPtr("node", node);
        }
    };

    threadlocal var enabled: bool = false;
    threadlocal var resumed: ?*Limit = null;

    pub var sample_fn: ?*const fn (*VM.lua.State, c_int) void = null;
    pub var sample_due: std.atomic.Value(bool) = .init(false);

    const Resume = struct {
        previous: ?*Limit,
        current: ?*Limit,

        fn begin(state: *VM.lua.State) Resume {
            const previous = resumed;
            if (!enabled)
                return .{ .previous = previous, .current = null };

            const scheduler = Scheduler.fromState(state);
            const entry = scheduler.policy.find(state) orelse return .{
                .previous = previous,
                .current = null,
            };

            scheduler.policy.start(scheduler, entry);
            resumed = entry;
            return .{ .previous = previous, .current = entry };
        }

        fn end(self: Resume, state: *VM.lua.State, status: VM.lua.Status) void {
            if (self.current) |entry| {
                const scheduler = Scheduler.fromState(state);
                switch (status) {
                    .Yield, .Break => {
                        if (entry.running)
                            scheduler.policy.stop(scheduler, entry);
                    },
                    else => scheduler.policy.remove(state),
                }
            }

            if (self.previous == self.current) {
                resumed = null;
            } else {
                resumed = self.previous;
            }
        }
    };

    pub fn interruptCallback(L: *VM.lua.State, gc: c_int) callconv(.c) void {
        checkLimit(L);
        if (sample_due.swap(false, .acq_rel)) {
            if (sample_fn) |sample|
                sample(L, gc);
        }
    }

    pub fn checkLimit(L: *VM.lua.State) void {
        const entry = findResumed(L) orelse return;
        if (entry.seconds <= 0)
            return;

        const scheduler = Scheduler.fromState(L);
        if (resumed) |current| {
            if (current != entry and current.running)
                scheduler.policy.stop(scheduler, current);
        }

        const now = VM.lperf.clock();
        if (!entry.running) {
            scheduler.policy.start(scheduler, entry);
            return;
        }

        if (now - entry.start < entry.seconds)
            return;

        Scheduler.fromState(L).policy.remove(L);
        if (!(L.checkstack(1) catch false))
            @panic("OOM");

        L.pushlstring("execution timeout") catch @panic("OOM");
        L.raiseerror();
    }

    fn findResumed(L: *VM.lua.State) ?*Limit {
        if (resumed) |entry| {
            if (entry.thread == L)
                return entry;
        }

        if (!enabled)
            return null;

        return Scheduler.fromState(L).policy.find(L);
    }

    fn userthreadCallback(parent: ?*VM.lua.State, thread: *VM.lua.State) callconv(.c) void {
        const scheduler = Scheduler.fromState(thread);
        if (parent) |from| {
            const entry = scheduler.policy.find(from) orelse return;
            if (entry.seconds <= 0)
                return;

            scheduler.policy.inherit(scheduler, thread, entry);
            return;
        }

        scheduler.policy.remove(thread);
    }

    fn find(self: *Policy, thread: *VM.lua.State) ?*Limit {
        var node = self.list.first;
        while (node) |current| {
            const entry = Limit.from(current);
            if (entry.thread == thread)
                return entry;
            node = current.next;
        }
        return null;
    }

    fn create(self: *Policy, scheduler: *Scheduler, thread: *VM.lua.State) *Limit {
        const entry = scheduler.allocator().create(Limit) catch |err| std.debug.panic("{}", .{err});
        entry.* = .{ .thread = thread };
        self.list.append(&entry.node);

        if (!enabled) {
            enabled = true;
            scheduler.global.callbacks().userthread = userthreadCallback;
        }

        return entry;
    }

    fn release(self: *Policy, scheduler: *Scheduler) void {
        if (self.list.first != null)
            return;

        enabled = false;
        const callbacks = scheduler.global.callbacks();
        if (callbacks.userthread == userthreadCallback)
            callbacks.userthread = null;
    }

    fn inherit(self: *Policy, scheduler: *Scheduler, thread: *VM.lua.State, parent: *Limit) void {
        if (self.find(thread) != null)
            return;

        const entry = self.create(scheduler, thread);
        entry.seconds = parent.seconds;
    }

    pub fn limit(self: *Policy, thread: *VM.lua.State, seconds: f64) void {
        const scheduler = Scheduler.fromState(thread);
        const entry = self.find(thread) orelse self.create(scheduler, thread);
        if (entry.running)
            self.stop(scheduler, entry);

        entry.seconds = seconds;
    }

    pub fn remove(self: *Policy, thread: *VM.lua.State) void {
        if (!enabled)
            return;

        const scheduler = Scheduler.fromState(thread);
        const entry = self.find(thread) orelse return;
        if (entry.running)
            self.stop(scheduler, entry);

        self.list.remove(&entry.node);
        scheduler.allocator().destroy(entry);
        self.release(scheduler);
    }

    fn start(self: *Policy, scheduler: *Scheduler, entry: *Limit) void {
        if (entry.seconds <= 0 or entry.running)
            return;

        entry.running = true;
        entry.start = VM.lperf.clock();

        const previous = self.running_count.fetchAdd(1, .monotonic);
        if (previous == 0)
            scheduler.global.callbacks().interrupt = interruptCallback;
    }

    fn stop(self: *Policy, scheduler: *Scheduler, entry: *Limit) void {
        if (!entry.running)
            return;

        entry.running = false;

        const previous = self.running_count.fetchSub(1, .monotonic);
        if (previous != 1)
            return;

        const callbacks = scheduler.global.callbacks();
        if (callbacks.interrupt == interruptCallback)
            callbacks.interrupt = null;
    }

    pub fn deinit(self: *Policy, scheduler: *Scheduler) void {
        const callbacks = scheduler.global.callbacks();
        if (callbacks.userthread == userthreadCallback)
            callbacks.userthread = null;
        if (callbacks.interrupt == interruptCallback)
            callbacks.interrupt = null;

        self.running_count.store(0, .monotonic);
        enabled = false;
        resumed = null;

        const gpa = scheduler.allocator();
        while (self.list.popFirst()) |node|
            gpa.destroy(Limit.from(node));
    }
};

const FrameKind = enum {
    None,
    EventLoop,
    Synchronize,
    Task,
    Sleeping,
    Deferred,
    Awaiting,
};

fn SleepOrder(_: void, a: SleepingThread, b: SleepingThread) std.math.Order {
    const wakeA = a.wake;
    const wakeB = b.wake;
    if (wakeA == wakeB) {
        return .eq;
    } else if (wakeA < wakeB) {
        return .lt;
    } else if (wakeA > wakeB) {
        return .gt;
    } else {
        unreachable;
    }
}

const SleepingQueue = std.PriorityQueue(SleepingThread, void, SleepOrder);

pub const Async = struct {
    node: std.DoublyLinkedList.Node = .{},
    ref: ThreadRef,
    op: Operation,
    tracker: if (builtin.mode == .debug) ?*u8 else void = if (builtin.mode == .debug) null else undefined,

    // comptime {
    //     @compileLog(@sizeOf(Async));
    // }

    pub const Operation = union(enum) {
        pub const Common = struct {
            op: Op = undefined,
            pub const Op = struct {
                c: zio.ev.Completion = undefined,
            };
        };

        file_open: FileOpen,
        file_create: FileCreate,
        file_close: FileClose,
        file_read: FileRead,
        file_read_streaming: FileReadStreaming,
        file_write: FileWrite,
        file_write_streaming: FileWriteStreaming,
        file_set_size: FileSetSize,
        file_set_permissions: FileSetPermissions,
        file_set_owner: FileSetOwner,
        file_set_timestamps: FileSetTimestamps,
        file_real_path: FileRealPath,
        file_sync: FileSync,
        file_size: FileSize,
        file_stat: FileStat,
        dir_open: DirOpen,
        dir_set_permissions: DirSetPermissions,
        dir_set_owner: DirSetOwner,
        dir_set_file_permissions: DirSetFilePermissions,
        dir_set_file_owner: DirSetFileOwner,
        dir_set_file_timestamps: DirSetFileTimestamps,
        dir_sym_link: DirSymLink,
        dir_read_link: DirReadLink,
        dir_access: DirAccess,
        dir_real_path: DirRealPath,
        dir_real_path_file: DirRealPathFile,
        dir_create_dir: DirCreateDir,
        dir_rename: DirRename,
        dir_rename_preserve: DirRenamePreserve,
        dir_delete_file: DirDeleteFile,
        dir_delete_dir: DirDeleteDir,
        dir_close: DirClose,
        net_send: NetSend,
        net_send_to: NetSendTo,
        net_recv: NetRecv,
        net_recv_from: NetRecvFrom,
        net_connect: NetConnect,
        net_listen: NetListen,
        net_accept: NetAccept,
        net_bind: NetBind,
        net_shutdown: NetShutdown,
        net_close: NetClose,
        pipe_create: PipeCreate,
        pipe_poll: PipePoll,
        pipe_close: PipeClose,
        process_wait: ProcessWait,
        async: @This().Async,

        pub const FileOpen = struct {
            op: zio.ev.FileOpen = undefined,
        };

        pub const FileCreate = struct {
            op: zio.ev.FileCreate = undefined,
        };

        pub const FileClose = struct {
            op: zio.ev.FileClose = undefined,
            canceled: bool = false,
        };

        pub const FileRead = struct {
            op: zio.ev.FileRead = undefined,
            iovec: [1]zio.os.iovec = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const FileReadStreaming = struct {
            op: zio.ev.FileReadStreaming = undefined,
            iovec: [1]zio.os.iovec = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const FileWrite = struct {
            op: zio.ev.FileWrite = undefined,
            iovec: [1]zio.os.iovec_const = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const FileWriteStreaming = struct {
            op: zio.ev.FileWriteStreaming = undefined,
            iovec: [1]zio.os.iovec_const = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const FileSync = struct {
            op: zio.ev.FileSync = undefined,
        };

        pub const FileSize = struct {
            op: zio.ev.FileSize = undefined,
        };

        pub const FileSetSize = struct {
            op: zio.ev.FileSetSize = undefined,
        };

        pub const FileSetPermissions = struct {
            op: zio.ev.FileSetPermissions = undefined,
        };

        pub const FileSetOwner = struct {
            op: zio.ev.FileSetOwner = undefined,
        };

        pub const FileSetTimestamps = struct {
            op: zio.ev.FileSetTimestamps = undefined,
        };

        pub const FileStat = struct {
            op: zio.ev.FileStat = undefined,
        };

        pub const FileRealPath = struct {
            op: zio.ev.FileRealPath = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const DirOpen = struct {
            op: zio.ev.DirOpen = undefined,
        };

        pub const DirSetPermissions = struct {
            op: zio.ev.DirSetPermissions = undefined,
        };

        pub const DirSetOwner = struct {
            op: zio.ev.DirSetOwner = undefined,
        };

        pub const DirSetFilePermissions = struct {
            op: zio.ev.DirSetFilePermissions = undefined,
        };

        pub const DirSetFileOwner = struct {
            op: zio.ev.DirSetFileOwner = undefined,
        };

        pub const DirSetFileTimestamps = struct {
            op: zio.ev.DirSetFileTimestamps = undefined,
        };

        pub const DirSymLink = struct {
            op: zio.ev.DirSymLink = undefined,
        };

        pub const DirReadLink = struct {
            op: zio.ev.DirReadLink = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const DirAccess = struct {
            op: zio.ev.DirAccess = undefined,
        };

        pub const DirRealPath = struct {
            op: zio.ev.DirRealPath = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const DirRealPathFile = struct {
            op: zio.ev.DirRealPathFile = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const DirCreateDir = struct {
            op: zio.ev.DirCreateDir = undefined,
        };

        pub const DirRename = struct {
            op: zio.ev.DirRename = undefined,
            dir_ref: Scripting.Reference,
        };

        pub const DirRenamePreserve = struct {
            op: zio.ev.DirRenamePreserve = undefined,
            dir_ref: Scripting.Reference,
        };

        pub const DirDeleteFile = struct {
            op: zio.ev.DirDeleteFile = undefined,
        };

        pub const DirDeleteDir = struct {
            op: zio.ev.DirDeleteDir = undefined,
        };

        pub const DirClose = struct {
            op: zio.ev.DirClose = undefined,
            canceled: bool = false,
        };

        pub const NetSend = struct {
            op: zio.ev.Group,
            op_work: zio.ev.NetSend = undefined,
            op_timeout: ?zio.ev.Timer = null,
            iovec: [4]zio.os.iovec_const = undefined,
            buffer: [4]Scripting.Reference = @splat(.empty),
        };

        pub const NetSendTo = struct {
            op: zio.ev.Group,
            op_work: zio.ev.NetSendTo = undefined,
            op_timeout: ?zio.ev.Timer = null,
            iovec: [4]zio.os.iovec_const = undefined,
            buffer: [4]Scripting.Reference = @splat(.empty),
            addr: zio.net.Address,
        };

        pub const NetRecv = struct {
            op: zio.ev.Group,
            op_work: zio.ev.NetRecv = undefined,
            op_timeout: ?zio.ev.Timer = null,
            iovec: [1]zio.os.iovec = undefined,
            buffer_ref: Scripting.Reference,
        };

        pub const NetRecvFrom = struct {
            op: zio.ev.Group,
            op_work: zio.ev.NetRecvFrom = undefined,
            op_timeout: ?zio.ev.Timer = null,
            iovec: [1]zio.os.iovec = undefined,
            buffer_ref: Scripting.Reference,
            addr: zio.net.Address = undefined,
            addr_len: zio.os.net.socklen_t,
        };

        pub const NetConnect = struct {
            op: zio.ev.NetConnect = undefined,
            addr: zio.net.Address,
        };

        pub const NetListen = struct {
            op: zio.ev.NetListen = undefined,
        };

        pub const NetAccept = struct {
            op: zio.ev.NetAccept = undefined,
            addr: zio.net.Address = undefined,
            addr_len: zio.os.net.socklen_t,
        };

        pub const NetBind = struct {
            op: zio.ev.NetBind = undefined,
            addr: zio.net.Address,
            addr_len: zio.os.net.socklen_t,
        };

        pub const NetShutdown = struct {
            op: zio.ev.NetShutdown = undefined,
        };

        pub const NetClose = struct {
            op: zio.ev.NetClose = undefined,
            canceled: bool = false,
        };

        pub const PipeCreate = struct {
            op: zio.ev.PipeCreate = undefined,
        };

        pub const PipePoll = struct {
            op: zio.ev.PipePoll = undefined,
        };

        pub const PipeClose = struct {
            op: zio.ev.PipeClose = undefined,
            canceled: bool = false,
        };

        pub const ProcessWait = struct {
            op: zio.ev.ProcessWait,
        };

        pub const Async = struct {
            op: zio.ev.Async = undefined,
        };
    };

    pub const FreeList = struct {
        pub const MAX = 1024;

        list: std.DoublyLinkedList = .{},
        len: usize = 0,

        pub fn deinit(self: *FreeList, gpa: std.mem.Allocator) void {
            var node = self.list.first;
            while (node) |n| {
                node = n.next;
                const async: *Async = @alignCast(@fieldParentPtr("node", n));
                gpa.destroy(async);
            }
            self.* = .{};
        }

        pub fn add(self: *FreeList, async: *Async) bool {
            if (self.len >= MAX)
                return false;
            self.list.append(&async.node);
            self.len += 1;
            return true;
        }

        pub fn popFirst(self: *FreeList) ?*Async {
            const node = self.list.popFirst() orelse return null;
            self.len -= 1;
            return @alignCast(@fieldParentPtr("node", node));
        }
    };

    pub const Staged = struct {
        list: std.DoublyLinkedList = .{},

        pub fn remove(self: *Staged, async: *Async) void {
            self.list.remove(&async.node);
            if (comptime builtin.mode == .debug) {
                Zune.DEFAULT_ALLOCATOR.destroy(async.tracker.?);
            }
        }

        pub fn append(self: *Staged, async: *Async) void {
            if (comptime builtin.mode == .debug) {
                if (async.tracker != null)
                    std.debug.panic("double append detected", .{});
                async.tracker = Zune.DEFAULT_ALLOCATOR.create(u8) catch |err| std.debug.panic("{}", .{err});
            }
            self.list.append(&async.node);
        }
    };

    pub fn fromCompletion(completion: *zio.ev.Completion) *Async {
        const op: *Async.Operation.Common.Op = @alignCast(@fieldParentPtr("c", completion));
        const self: *Async.Operation.Common = @alignCast(@fieldParentPtr("op", op));
        return @alignCast(@fieldParentPtr("op", @as(*Scheduler.Async.Operation, @ptrCast(@alignCast(self)))));
    }

    pub fn deinit(self: *Async, scheduler: *Scheduler) void {
        self.ref.derefUnretained();
        scheduler.destroyAsync(self);
    }
};

global: *VM.lua.State = undefined,
sleeping: SleepingQueue = .empty,
deferred: Queue(Deferred) = .empty,
timer: zio.ev.Timer,
loop: zio.ev.Loop = undefined,
thread_pool: *zio.ev.ThreadPool,
awaiting: usize = 0,
now_clock: f64 = 0,
async_freelist: Async.FreeList = .{},

running: bool = false,
thread_id: std.Thread.Id = 0,

sync: Synchronization = .{},
policy: Policy = .{},

frame: FrameKind = .None,

pub fn allocator(self: *Scheduler) std.mem.Allocator {
    return self.loop.allocator;
}

pub fn init(gpa: std.mem.Allocator) !Scheduler {
    const pool = try gpa.create(zio.ev.ThreadPool);
    errdefer gpa.destroy(pool);

    try pool.init(.{ .min_threads = 0 });
    errdefer pool.deinit();

    return .{
        .thread_pool = pool,
        .loop = .{
            .allocator = gpa,
            .state = undefined,
            .backend = undefined,
            .loop_group = undefined,
        },
        .deferred = try .initCapacity(gpa, 16),
        .timer = .init(.fromMilliseconds(0)),
    };
}

fn scheduler_postresume(L: *VM.lua.State) callconv(.c) void {
    const awaiting = L.getthreaddata(?*Awaiting) orelse return;
    switch (L.status()) {
        .Yield, .Break => {},
        else => {
            const scheduler = Scheduler.fromState(L);
            defer scheduler.allocator().destroy(awaiting);
            if (awaiting.kind == .User) scheduler.awaiting -= 1;
            L.setthreaddata(?*Awaiting, null);
            var ref = awaiting.state;
            defer ref.deref();
            const state = awaiting.state.value;
            const data = awaiting.data;
            awaiting.resumeFn(data, state, scheduler);
        },
    }
}

fn blankCallback(_: *zio.ev.Loop, _: *zio.ev.Completion) void {}

pub fn setup(self: *Scheduler, L: *VM.lua.State) void {
    RUNNING_STATE = null;

    L.global.mainthread.userdata = @ptrCast(@alignCast(self));
    self.global = L;

    L.global.mainthread.callbacks().postresume = scheduler_postresume;

    self.timer.c.callback = blankCallback;

    const gpa = self.loop.allocator;

    if (comptime builtin.os.tag == .windows) {
        if (Zune.State.env_map.get("SystemRoot") == null) {
            Zune.quitMsg("<red>error<clear>: 'SystemRoot' environment variable is not set, this is required on Windows (event loop will not start)", .{});
        }
    }
    self.loop.init(.{
        .allocator = gpa,
        .thread_pool = self.thread_pool,
        .queue_size = 4096,
    }) catch |err| std.debug.panic("failed to initialize event loop: {}", .{err});
}

pub fn deferThread(self: *Scheduler, thread: ThreadRef, from: ?*VM.lua.State, args: i32) !void {
    try self.deferred.enqueue(self.allocator(), .{
        .from = from,
        .thread = thread,
        .args = args,
    });
}

pub fn sleepThread(
    self: *Scheduler,
    thread: *VM.lua.State,
    from: ?*VM.lua.State,
    time: f64,
    args: i32,
    waited: bool,
) void {
    const start = VM.lperf.clock();
    const wake = start + time + if (time == 0 and self.frame == .Sleeping) @as(f64, 0.0001) else @as(f64, 0);

    self.sleeping.push(self.allocator(), .{
        .thread = .init(thread),
        .from = from,
        .start = start,
        .wake = wake,
        .args = args,
        .waited = waited,
    }) catch |err| std.debug.panic("{}\n", .{err});
}

pub fn awaitResult(
    self: *Scheduler,
    comptime T: type,
    data: *T,
    L: *VM.lua.State,
    comptime callback: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Scheduler) void,
    kind: Awaiting.Kind,
) void {
    std.debug.assert(L != L.mainthread());
    std.debug.assert(L.status() == .Yield); // Thread must be yielded
    std.debug.assert(L.getthreaddata(*allowzero anyopaque) == @as(*allowzero anyopaque, @ptrFromInt(0)));

    if (kind == .User)
        self.awaiting += 1;

    const resumeFn = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Scheduler) void {
            @call(.always_inline, callback, .{ @as(*T, @ptrCast(@alignCast(ctx))), l, scheduler });
        }
    }.inner;

    const awaiting = self.allocator().create(Awaiting) catch |err| std.debug.panic("{}", .{err});

    awaiting.* = .{
        .data = @ptrCast(data),
        .state = .init(L),
        .resumeFn = resumeFn,
        .kind = kind,
    };

    L.setthreaddata(?*Awaiting, awaiting);
}

pub fn awaitCall(
    self: *Scheduler,
    comptime T: type,
    data: *T,
    L: *VM.lua.State,
    from: ?*VM.lua.State,
    args: i32,
    comptime callback: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Scheduler) void,
    kind: Awaiting.Kind,
) void {
    switch (resumeState(L, from, args) catch .ErrErr) {
        .Yield => awaitResult(self, T, data, L, callback, kind),
        else => callback(data, L, self),
    }
}

pub fn createAsync(self: *Scheduler) !*Async {
    return self.async_freelist.popFirst() orelse return try self.allocator().create(Async);
}

pub fn destroyAsync(self: *Scheduler, async: *Async) void {
    if (!self.async_freelist.add(async))
        self.allocator().destroy(async);
}

/// Can be called from any thread
pub fn synchronize(self: *Scheduler, ctx: *Synchronization.Context) void {
    self.sync.mutex.lockUncancelable(Zune.io());
    defer self.sync.mutex.unlock(Zune.io());
    self.sync.queue.remove(&ctx.node);
    self.sync.completed.append(&ctx.node);
    self.sync.notify();
}

pub fn asyncWaitForSync(self: *Scheduler, ctx: *Synchronization.Context) void {
    self.sync.mutex.lockUncancelable(Zune.io());
    defer self.sync.mutex.unlock(Zune.io());
    self.sync.queue.append(&ctx.node);
    self.sync.wait(self);
}

pub threadlocal var RUNNING_STATE: ?*VM.lua.State = null;

pub fn resumeThread(state: *VM.lua.State, from: ?*VM.lua.State, args: i32) VM.lua.Status {
    const last_running_state = RUNNING_STATE;
    RUNNING_STATE = state;
    defer RUNNING_STATE = last_running_state;
    const frame = Policy.Resume.begin(state);
    const status = state.resumethread(from, args);
    frame.end(state, status);
    return status;
}

pub inline fn resumeStateFast(state: *VM.lua.State, from: ?*VM.lua.State, args: i32) !VM.lua.Status {
    return resumeThread(state, from, args).check() catch |err| Runtime.Engine.handleError(state, err);
}

pub fn resumeState(state: *VM.lua.State, from: ?*VM.lua.State, args: i32) !VM.lua.Status {
    return switch (state.status()) {
        .Yield, .Ok, .Break => resumeStateFast(state, from, args),
        inline else => |e| e.check(),
    };
}

pub fn resumeThreadError(state: *VM.lua.State, from: ?*VM.lua.State) VM.lua.Status {
    const last_running_state = RUNNING_STATE;
    RUNNING_STATE = state;
    defer RUNNING_STATE = last_running_state;
    const frame = Policy.Resume.begin(state);
    const status = state.resumeerror(from);
    frame.end(state, status);
    return status;
}

pub inline fn resumeStateErrorFast(state: *VM.lua.State, from: ?*VM.lua.State) !VM.lua.Status {
    return resumeThreadError(state, from).check() catch |err| Runtime.Engine.handleError(state, err);
}

pub fn resumeStateError(state: *VM.lua.State, from: ?*VM.lua.State, err: anyerror) !void {
    switch (state.status()) {
        .Yield, .Ok, .Break => {
            state.pushstring(@errorName(err)) catch {
                // should be fixed error message, thus impossible to fail
                state.pushstring(VM.ldebug.MEMERRMSG) catch @panic("OOM");
            };
            _ = try resumeStateErrorFast(state, from);
        },
        else => |e| _ = try e.check(),
    }
}

pub fn cancelThread(self: *Scheduler, thread: *VM.lua.State) void {
    const sleeping_items = self.sleeping.items;
    for (sleeping_items, 0..) |item, i| {
        if (item.thread.value == thread) {
            var slept = self.sleeping.popIndex(i);
            slept.thread.deref();
            return;
        }
    }
    for (self.deferred.array(), 0..) |deferred, i| {
        if (deferred.thread.value == thread) {
            deferred.thread.derefUnretained();
            _ = self.deferred.orderedRemove(i);
            break;
        }
    }
}

// from zio done API
pub fn loopDone(self: *zio.ev.Loop) bool {
    if (self.state.stopped) return true;
    if (self.backend.hasInflight()) return false;
    for (&self.state.timers) |*heap| {
        if (!heap.isEmpty()) return false;
    }
    return self.state.async_handles.empty() and
        self.state.pool_inflight == 0 and
        self.state.completions.empty();
}

inline fn hasPendingWork(self: *Scheduler) bool {
    return self.sleeping.items.len > 0 or
        self.deferred.count() > 0 or
        self.awaiting > 0 or
        !loopDone(&self.loop) or
        self.sync.hasPending();
}

inline fn processFrame(self: *Scheduler, comptime frame: FrameKind) void {
    self.frame = frame;
    switch (frame) {
        .EventLoop => {
            self.loop.poll(.max) catch |err| {
                std.debug.print("EventLoop Error: {}\n", .{err});
            };
            self.loop.processCompletions();
        },
        .Synchronize => {
            self.sync.mutex.lockUncancelable(Zune.io());

            var list: Synchronization.LinkedList = self.sync.completed;
            self.sync.completed = .{};

            self.sync.notified.store(false, .release);

            self.sync.mutex.unlock(Zune.io());

            while (list.popFirst()) |node| {
                const sync: *Synchronization.Context = @fieldParentPtr("node", node);
                sync.complete(sync, self);
            }
        },
        .Sleeping => {
            const now = self.now_clock;
            while (self.sleeping.peek()) |current| {
                if (current.wake <= now) {
                    var slept = self.sleeping.pop().?;
                    var args = slept.args;
                    const thread = slept.thread.value;
                    const status = thread.status();
                    defer slept.thread.deref();
                    if (status != .Ok and status != .Yield) {
                        std.debug.print("Cannot resume thread error status: {}\n", .{status});
                        continue;
                    }
                    if (thread.isthreadreset())
                        continue;
                    if (slept.waited) {
                        thread.pushnumber(now - slept.start);
                        args += 1;
                    }
                    _ = resumeState(
                        thread,
                        slept.from,
                        args,
                    ) catch {};
                } else break;
            }
        },
        .Deferred => {
            const list = self.deferred.array();
            for (list) |deferred| {
                self.deferred.consume(1);
                const thread = deferred.thread.value;
                const status = thread.status();
                defer deferred.thread.derefUnretained();
                if (status != .Ok and status != .Yield)
                    continue;
                _ = resumeState(
                    thread,
                    deferred.from,
                    deferred.args,
                ) catch {};
            }
            self.deferred.rebase();
            self.deferred.shrink(self.allocator(), 128);
        },
        else => unreachable,
    }
}

fn resetTimer(self: *Scheduler, now: f64) void {
    const phase = self.timer.c.loadState().phase;
    const lowest = self.sleeping.peek() orelse {
        switch (phase) {
            .running => self.loop.cancel(&self.timer.c),
            .completed => unreachable, // should've already been processed
            else => {},
        }
        return;
    };

    const ms: u64 = @intFromFloat(@max(lowest.wake - now, 0) * std.time.ms_per_s);
    switch (phase) {
        .new, .dead => {
            self.timer.timeout = .fromMilliseconds(ms);
            self.loop.add(&self.timer.c);
        },
        .running => {
            const left = self.loop.now().durationTo(self.timer.deadline);
            if (zio.time.Duration.fromMilliseconds(ms).value < left.value)
                self.loop.setTimer(&self.timer, .fromMilliseconds(ms));
        },
        .completed => unreachable, // should've already been processed
    }
}

pub fn run(self: *Scheduler) void {
    std.debug.assert(!self.running);
    self.thread_id = std.Thread.getCurrentId();
    self.running = true;
    while (true) {
        if (!self.hasPendingWork())
            break;
        const now = VM.lperf.clock();
        self.now_clock = now;
        self.resetTimer(now);
        self.processFrame(.EventLoop);
        if (self.sync.completed.first != null)
            self.processFrame(.Synchronize);
        if (self.sleeping.items.len > 0)
            self.processFrame(.Sleeping);
        while (self.deferred.count() > 0)
            self.processFrame(.Deferred);
        self.frame = .None;
        if (comptime builtin.mode == .debug)
            _ = self.global.gc(.Collect, 0);
    }
    self.running = false;
}

pub fn deinit(self: *Scheduler) void {
    self.policy.deinit(self);

    const gpa = self.allocator();
    self.thread_pool.stop();
    self.sleeping.deinit(gpa);
    self.deferred.deinit(gpa);
    self.async_freelist.deinit(gpa);
    self.loop.deinit();
    self.thread_pool.deinit();
    gpa.destroy(self.thread_pool);
}

pub fn fromState(L: *VM.lua.State) *Scheduler {
    return @ptrCast(@alignCast(L.global.mainthread.userdata));
}
