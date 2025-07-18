const std = @import("std");
const xev = @import("xev");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;

const Lists = Zune.Utils.Lists;

const VM = luau.VM;

pub threadlocal var SCHEDULERS = std.ArrayList(*Scheduler).init(Zune.DEFAULT_ALLOCATOR);

pub fn KillScheduler(scheduler: *Scheduler, cleanUp: bool) void {
    {
        var i = scheduler.awaits.items.len;
        while (i > 0) {
            i -= 1;
            const awaiting = scheduler.awaits.items[i];
            awaiting.virtualDtor(awaiting.data, awaiting.state.value, scheduler);
            _ = scheduler.awaits.orderedRemove(i);
        }
    }
    if (cleanUp)
        for (SCHEDULERS.items, 0..) |o, p|
            if (scheduler == o) {
                _ = SCHEDULERS.orderedRemove(p);
                break;
            };
}

pub fn KillSchedulers() void {
    for (SCHEDULERS.items) |scheduler|
        KillScheduler(scheduler, false);
    SCHEDULERS.clearAndFree();
}

pub const ThreadRef = struct {
    value: *VM.lua.State,
    ref: ?i32,

    pub fn init(L: *VM.lua.State) ThreadRef {
        const GL = L.mainthread();
        if (GL == L)
            return .{ .value = L, .ref = null };
        if (L.pushthread()) {
            L.pop(1);
            return .{ .value = L, .ref = null };
        }
        const ref = (L.ref(-1) catch |err| std.debug.panic("{}", .{err})) orelse std.debug.panic("Task Scheduler failed to create thread ref\n", .{});
        L.pop(1);
        return .{ .value = L, .ref = ref };
    }

    pub fn deref(self: *ThreadRef) void {
        if (self.ref) |r| {
            if (r <= 0)
                return;
            self.value.mainthread().unref(r);
            self.ref = null;
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

pub const DeferredThread = struct {
    from: ?*VM.lua.State,
    thread: ThreadRef,
    args: i32,
    node: LinkedList.Node,

    pub const LinkedList = Lists.DoublyLinkedList;

    pub inline fn fromNode(node: *LinkedList.Node) *DeferredThread {
        return @fieldParentPtr("node", node);
    }
};

const Scheduler = @This();

pub const TaskResult = enum {
    Continue,
    ContinueFast,
    Stop,
};

pub const AwaitTaskPriority = enum { Internal, User };

const AwaitedFn = fn (ctx: *anyopaque, L: *VM.lua.State, scheduler: *Scheduler) void;

const AwaitingObject = struct {
    data: *anyopaque,
    state: ThreadRef,
    resumeFn: *const AwaitedFn,
    virtualDtor: *const AwaitedFn,
    priority: AwaitTaskPriority,
};

const Synchronization = struct {
    completion: xev.Dynamic.Completion,
    completed: LinkedList = .{},
    queue: LinkedList = .{},
    mutex: std.Thread.Mutex = .{},
    queue_count: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    notified: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
    waiting: bool = false,

    pub const LinkedList = Lists.DoublyLinkedList;

    pub fn Node(comptime T: type) type {
        return struct {
            node: LinkedList.Node,
            callback: *const fn (ud: *anyopaque, scheduler: *Scheduler) void,
            free: *const fn (ud: *anyopaque, allocator: std.mem.Allocator) void,
            data: T,

            const ThisNode = @This();
        };
    }

    pub fn init() Synchronization {
        return .{
            .completion = .init(),
        };
    }

    pub inline fn hasPending(self: *Synchronization) bool {
        return self.waiting or // awaiting instances
            self.notified.load(.acquire); // completed instances
    }

    pub fn notify(self: *Synchronization, scheduler: *Scheduler) void {
        if (self.notified.load(.acquire))
            return;
        self.notified.store(true, .release);
        scheduler.@"async".notify() catch |err| std.debug.print("[Async Notify Error: {}]\n", .{err});
    }

    fn async_completion(
        _: ?*void,
        _: *xev.Dynamic.Loop,
        completion: *xev.Dynamic.Completion,
        _: xev.Dynamic.Async.WaitError!void,
    ) xev.Dynamic.CallbackAction {
        const self: *Synchronization = @alignCast(@fieldParentPtr("completion", completion));
        if (self.queue_count.load(.acquire) > 0)
            return .rearm;
        self.waiting = false;
        return .disarm;
    }

    pub fn wait(self: *Synchronization, scheduler: *Scheduler) void {
        if (self.waiting)
            return;
        self.waiting = true;
        scheduler.@"async".wait(
            &scheduler.loop,
            &self.completion,
            void,
            null,
            async_completion,
        );
    }
};

const Pool = struct {
    io: *xev.ThreadPool,
    general: *xev.ThreadPool,

    pub fn free(self: *Pool, allocator: std.mem.Allocator) void {
        defer allocator.destroy(self.general);
        defer allocator.destroy(self.io);
        self.io.deinit();
        self.general.deinit();
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
pub const CompletionLinkedList = std.DoublyLinkedList(xev.Dynamic.Completion);

global: *VM.lua.State,
allocator: std.mem.Allocator,
sleeping: SleepingQueue,
deferred: DeferredThread.LinkedList = .{},
awaits: std.ArrayListUnmanaged(AwaitingObject) = .empty,
timer: xev.Dynamic.Timer,
loop: xev.Dynamic.Loop,
@"async": xev.Dynamic.Async,
pools: Pool,
async_tasks: usize = 0,
now_clock: f64 = 0,

running: bool = false,
threadId: std.Thread.Id = 0,

sync: Synchronization,

frame: FrameKind = .None,

pub fn init(allocator: std.mem.Allocator, L: *VM.lua.State) !Scheduler {
    const max_threads = std.Thread.getCpuCount() catch 1;
    const io_pool = try allocator.create(xev.ThreadPool);
    errdefer allocator.destroy(io_pool);
    const general_pool = try allocator.create(xev.ThreadPool);
    errdefer allocator.destroy(general_pool);

    io_pool.* = .init(max_threads);
    general_pool.* = .init(max_threads);

    return .{
        .loop = try xev.Dynamic.Loop.init(.{
            .entries = 4096,
            .thread_pool = io_pool,
        }),
        .timer = try xev.Dynamic.Timer.init(),
        .@"async" = try xev.Dynamic.Async.init(),
        .pools = .{
            .io = io_pool,
            .general = general_pool,
        },
        .global = L,
        .allocator = allocator,
        .sleeping = SleepingQueue.init(allocator, {}),
        .sync = .init(),
    };
}

pub fn deferThread(self: *Scheduler, thread: *VM.lua.State, from: ?*VM.lua.State, args: i32) void {
    const ptr = self.allocator.create(DeferredThread) catch |err| std.debug.panic("Error: {}\n", .{err});
    ptr.* = .{
        .from = from,
        .thread = ThreadRef.init(thread),
        .args = args,
        .node = .{},
    };
    self.deferred.append(&ptr.node);
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

    self.sleeping.add(.{
        .thread = ThreadRef.init(thread),
        .from = from,
        .start = start,
        .wake = wake,
        .args = args,
        .waited = waited,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});
}

pub fn awaitResult(
    self: *Scheduler,
    comptime T: type,
    data: *T,
    L: *VM.lua.State,
    comptime handlerFn: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Scheduler) void,
    comptime dtorFn: ?*const fn (ctx: *T, L: *VM.lua.State, scheduler: *Scheduler) void,
    priority: ?AwaitTaskPriority,
) void {
    std.debug.assert(L.status() == .Yield); // Thread must be yielded

    const resumeFn = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Scheduler) void {
            @call(.always_inline, handlerFn, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;

    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Scheduler) void {
            if (dtorFn) |dtor| {
                @call(.always_inline, dtor, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
            }
        }
    }.inner;

    self.awaits.append(self.allocator, .{
        .data = @ptrCast(data),
        .state = ThreadRef.init(L),
        .resumeFn = resumeFn,
        .virtualDtor = virtualDtor,
        .priority = priority orelse .User,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});
}

pub fn awaitCall(
    self: *Scheduler,
    comptime T: type,
    data: *T,
    L: *VM.lua.State,
    from: ?*VM.lua.State,
    args: i32,
    comptime handlerFn: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Scheduler) void,
    comptime dtorFn: ?*const fn (ctx: *T, L: *VM.lua.State, scheduler: *Scheduler) void,
) void {
    switch (resumeState(L, from, args) catch .ErrErr) {
        .Yield => awaitResult(self, T, data, L, handlerFn, dtorFn, .User),
        else => {
            handlerFn(data, L, self);
            if (dtorFn) |dtor| {
                dtor(data, L, self);
            }
        },
    }
}

pub fn completeAsync(
    self: *Scheduler,
    data: anytype,
) void {
    defer self.async_tasks -= 1;
    self.allocator.destroy(data);
}

pub fn createAsyncCtx(
    self: *Scheduler,
    comptime T: type,
) std.mem.Allocator.Error!*T {
    const ptr = try self.allocator.create(T);
    defer self.async_tasks += 1;
    return ptr;
}

pub fn cancelAsyncTask(
    self: *Scheduler,
    completion: *xev.Dynamic.Completion,
) void {
    const cancel_completion = self.allocator.create(xev.Dynamic.Completion) catch |err| std.debug.panic("{}\n", .{err});
    self.loop.cancel(
        completion,
        cancel_completion,
        Scheduler,
        self,
        (struct {
            fn callback(
                ud: ?*Scheduler,
                _: *xev.Dynamic.Loop,
                c: *xev.Dynamic.Completion,
                r: xev.Dynamic.CancelError!void,
            ) xev.Dynamic.CallbackAction {
                const sch = ud.?;
                defer sch.allocator.destroy(c);
                r catch |err| switch (err) {
                    inline error.Inactive => {},
                    inline else => std.debug.print("Cancel Error: {}\n", .{err}),
                };
                return .disarm;
            }
        }.callback),
    );
}

/// Can be called from any thread
pub fn synchronize(self: *Scheduler, data: anytype) void {
    self.sync.mutex.lock();
    defer self.sync.mutex.unlock();
    const Node = Synchronization.Node(@typeInfo(@TypeOf(data)).pointer.child);
    const ptr: *Node = @fieldParentPtr("data", data);
    self.sync.queue.remove(&ptr.node);
    self.sync.completed.append(&ptr.node);
    self.sync.notify(self);
    _ = self.sync.queue_count.fetchSub(1, .acq_rel);
}

pub fn asyncWaitForSync(self: *Scheduler, data: anytype) void {
    _ = self.sync.queue_count.fetchAdd(1, .acq_rel);
    const Node = Synchronization.Node(@typeInfo(@TypeOf(data)).pointer.child);
    const ptr: *Node = @fieldParentPtr("data", data);
    self.sync.queue.append(&ptr.node);
    self.sync.wait(self);
}

pub fn createSync(self: *Scheduler, comptime T: type, callback: fn (*T, *Scheduler) void) !*T {
    if (T == void)
        @compileError("Void type not allowed");
    const Node = Synchronization.Node(T);
    const ptr = try self.allocator.create(Node);
    ptr.* = .{
        .node = .{},
        .callback = struct {
            fn inner(ud: *anyopaque, sched: *Scheduler) void {
                const node: *Node = @alignCast(@ptrCast(ud));
                @call(.always_inline, callback, .{ &node.data, sched });
            }
        }.inner,
        .free = struct {
            fn inner(ud: *anyopaque, allocator: std.mem.Allocator) void {
                const node: *Node = @alignCast(@ptrCast(ud));
                allocator.destroy(node);
            }
        }.inner,
        .data = undefined,
    };
    return &ptr.data;
}

pub fn freeSync(self: *Scheduler, data: anytype) void {
    const Node = Synchronization.Node(@typeInfo(@TypeOf(data)).pointer.child);
    const ptr: *Node = @fieldParentPtr("data", data);
    ptr.free(ptr, self.allocator);
}

pub fn resumeState(state: *VM.lua.State, from: ?*VM.lua.State, args: i32) !VM.lua.Status {
    return switch (state.status()) {
        .Yield, .Ok => state.resumethread(from, args).check() catch |err| {
            Engine.logError(state, err, false);
            if (Zune.Runtime.Debugger.ACTIVE) {
                @branchHint(.unpredictable);
                switch (err) {
                    error.Runtime => Zune.Runtime.Debugger.luau_panic(state, -2),
                    else => {},
                }
            }
            return err;
        },
        inline else => |e| e.check(),
    };
}

pub fn resumeStateError(state: *VM.lua.State, from: ?*VM.lua.State) !VM.lua.Status {
    return switch (state.status()) {
        .Yield, .Ok => state.resumeerror(from).check() catch |err| {
            Engine.logError(state, err, false);
            if (Zune.Runtime.Debugger.ACTIVE) {
                @branchHint(.unpredictable);
                switch (err) {
                    error.Runtime => Zune.Runtime.Debugger.luau_panic(state, -2),
                    else => {},
                }
            }
            return err;
        },
        inline else => |e| e.check(),
    };
}

pub fn cancelThread(self: *Scheduler, thread: *VM.lua.State) void {
    const sleeping_items = self.sleeping.items;
    for (sleeping_items, 0..) |item, i| {
        if (item.thread.value == thread) {
            var slept = self.sleeping.removeIndex(i);
            slept.thread.deref();
            return;
        }
    }
    var next_node = self.deferred.first;
    while (next_node) |node| {
        const deferred = DeferredThread.fromNode(node);
        if (deferred.thread.value == thread) {
            defer self.allocator.destroy(deferred);
            deferred.thread.deref();
            self.deferred.remove(node);
            break;
        }
        next_node = node.next;
    }
}

inline fn hasPendingWork(self: *Scheduler) bool {
    return self.sleeping.items.len > 0 or
        self.deferred.len > 0 or
        self.awaits.items.len > 0 or
        self.async_tasks > 0 or
        self.sync.hasPending();
}

pub fn XevNoopCallback(err: type, action: xev.CallbackAction) fn (
    _: ?*void,
    _: *xev.Dynamic.Loop,
    _: *xev.Dynamic.Completion,
    _: err,
) xev.CallbackAction {
    return struct {
        fn inner(
            _: ?*void,
            _: *xev.Dynamic.Loop,
            _: *xev.Dynamic.Completion,
            _: err,
        ) xev.CallbackAction {
            return action;
        }
    }.inner;
}

pub fn XevNoopWatcherCallback(watcher: type, err: type, action: xev.CallbackAction) fn (
    _: ?*void,
    _: *xev.Dynamic.Loop,
    _: *xev.Dynamic.Completion,
    _: watcher,
    _: err,
) xev.CallbackAction {
    return struct {
        fn inner(
            _: ?*void,
            _: *xev.Dynamic.Loop,
            _: *xev.Dynamic.Completion,
            _: watcher,
            _: err,
        ) xev.CallbackAction {
            return action;
        }
    }.inner;
}

inline fn processFrame(self: *Scheduler, comptime frame: FrameKind) void {
    self.frame = frame;
    switch (frame) {
        .EventLoop => self.loop.run(.once) catch |err| {
            std.debug.print("EventLoop Error: {}\n", .{err});
        },
        .Synchronize => {
            self.sync.mutex.lock();
            defer self.sync.mutex.unlock();

            self.sync.notified.store(false, .release);

            const SyncNode = Synchronization.Node(void);

            while (self.sync.completed.popFirst()) |node| {
                const sync: *SyncNode = @fieldParentPtr("node", node);
                sync.callback(sync, self);
            }
        },
        .Sleeping => {
            const now = self.now_clock;
            while (self.sleeping.peek()) |current| {
                if (current.wake <= now) {
                    var slept = self.sleeping.remove();
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
        .Deferred => while (self.deferred.popFirst()) |node| {
            const deferred = DeferredThread.fromNode(node);
            defer self.allocator.destroy(deferred);
            const thread = deferred.thread.value;
            const status = thread.status();
            defer deferred.thread.deref();
            if (status != .Ok and status != .Yield)
                continue;
            _ = resumeState(
                thread,
                deferred.from,
                deferred.args,
            ) catch {};
        },
        .Awaiting => {
            var i = self.awaits.items.len;
            while (i > 0) {
                i -= 1;
                const awaiting = self.awaits.items[i];
                if (awaiting.state.value.status() != .Yield) {
                    var ref = awaiting.state;
                    defer ref.deref();
                    _ = self.awaits.orderedRemove(i);
                    const state = awaiting.state.value;
                    const data = awaiting.data;
                    awaiting.resumeFn(data, state, self);
                    awaiting.virtualDtor(data, state, self);
                }
            }
        },
        else => unreachable,
    }
}

pub fn run(self: *Scheduler, comptime mode: Zune.RunMode) void {
    if (self.running) {
        std.debug.print("Warning: Scheduler is already running, this may lead to unexpected behavior.\n", .{});
        return;
    }
    self.threadId = std.Thread.getCurrentId();
    self.running = true;
    var timer_completion: xev.Dynamic.Completion = .init();
    var timer_cancel_completion: xev.Dynamic.Completion = .init();
    while (true) {
        if (!self.hasPendingWork())
            break;
        const now = VM.lperf.clock();
        self.now_clock = now;
        const sleep_time: ?u64 = if (self.sleeping.peek()) |lowest|
            @intFromFloat(@max(lowest.wake - now, 0) * std.time.ms_per_s)
        else
            null;
        if (sleep_time) |time|
            self.timer.reset(
                &self.loop,
                &timer_completion,
                &timer_cancel_completion,
                time,
                void,
                null,
                XevNoopCallback(xev.Dynamic.Timer.RunError!void, .disarm),
            );
        self.processFrame(.EventLoop);
        if (self.sync.completed.len > 0)
            self.processFrame(.Synchronize);
        if (self.sleeping.items.len > 0)
            self.processFrame(.Sleeping);
        if (self.awaits.items.len > 0)
            self.processFrame(.Awaiting);
        while (self.deferred.len > 0) {
            self.processFrame(.Deferred);
            if (self.awaits.items.len > 0)
                self.processFrame(.Awaiting);
        }
        self.frame = .None;
        if (comptime mode == .Test)
            _ = self.global.gc(.Collect, 0);
    }
    self.running = false;
}

pub fn deinit(self: *Scheduler) void {
    KillScheduler(self, true);
    self.sleeping.deinit();
    {
        while (self.deferred.pop()) |node|
            self.allocator.destroy(node);
    }
    self.awaits.deinit(self.allocator);
    self.timer.deinit();
    self.loop.deinit();
    self.@"async".deinit();
    self.pools.free(self.allocator);
}

pub fn getScheduler(L: anytype) *Scheduler {
    if (@TypeOf(L) == *VM.lua.State) {
        const GL = L.mainthread();
        const scheduler = GL.getthreaddata(*Scheduler);
        return scheduler;
    } else if (@TypeOf(L) == ThreadRef) {
        const state, _ = L;
        const GL = state.mainthread();
        const scheduler = GL.getthreaddata(*Scheduler);
        return scheduler;
    } else @compileError("Invalid type for getScheduler");
}
