const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Thread = Zune.objects.Thread;
const ThreadLane = Zune.objects.ThreadLane;
const ThreadValue = Zune.objects.ThreadValue;

pub const LIB_NAME = "thread";
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (!@import("builtin").single_threaded) .Full else null;
}

pub threadlocal var THREADS: std.DoublyLinkedList = .{};

pub const MUTEX_REGISTRY = Zune.objects.ThreadMutex.Registry;
pub const HARD_MUTEX_REGISTRY = Zune.objects.ThreadHardMutex.Registry;
pub const LANE_REGISTRY = ThreadLane.Registry;
pub const VALUE_REGISTRY = ThreadValue.Registry;

pub const Sync = struct {
    node: std.DoublyLinkedList.Node = .{},
    scheduler: *Scheduler,
    runtime: *Runtime,
    thread: Scheduler.ThreadRef,
    sync: Scheduler.Synchronization.Context,

    pub fn from(node: *std.DoublyLinkedList.Node) *Sync {
        return @fieldParentPtr("node", node);
    }

    pub fn joinComplete(ctx: *Scheduler.Synchronization.Context, scheduler: *Scheduler) void {
        const self: *Sync = @fieldParentPtr("sync", ctx);
        const allocator = scheduler.allocator();
        defer allocator.destroy(self);
        defer self.thread.deref();

        const L = self.thread.value;
        if (L.status() != .Yield)
            return;

        _ = Scheduler.resumeState(L, null, 0) catch {};
    }
};

pub const Runtime = struct {
    node: std.DoublyLinkedList.Node = .{},
    L: *VM.lua.State,
    /// Messages are copied with this allocator. It stays valid after `scheduler` is replaced.
    allocator: std.mem.Allocator,
    scheduler: Scheduler,
    /// Owner `Thread:send` writes here. The worker `thread.receive` reads it.
    to_worker: ThreadLane.Lane = .{},
    /// Worker `thread.send` writes here. The owner `Thread:receive` reads it.
    to_owner: ThreadLane.Lane = .{},
    access_mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    join_queue: std.DoublyLinkedList = .{},
    status: std.atomic.Value(enum(u8) { ready, running, dead }) align(std.atomic.cache_line) = .init(.ready),
    owner: enum { lua, thread } = .lua,

    pub fn from(node: *std.DoublyLinkedList.Node) *Runtime {
        return @alignCast(@fieldParentPtr("node", node));
    }

    pub fn entry(self: *Runtime) void {
        const ML = self.L.tothread(1).?;

        jmp: {
            const allocator = self.allocator;

            self.scheduler = Scheduler.init(allocator) catch break :jmp;
            defer self.scheduler.deinit();

            self.scheduler.setup(self.L);

            Zune.openZune(self.L, .{}) catch break :jmp;
            Zune.initState(self.L, allocator) catch break :jmp;

            defer Zune.deinitState(self.L, allocator);

            Zune.Runtime.Engine.runAsync(ML, &self.scheduler, .{ .clean_up = false }) catch {};
        }

        self.access_mutex.lockUncancelable(Zune.io());
        defer self.access_mutex.unlock(Zune.io());

        var node = self.join_queue.first;
        while (node) |n| {
            node = n.next;
            const sync = Sync.from(n);
            sync.scheduler.synchronize(&sync.sync);
        }

        self.status.store(.dead, .release);
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.allocator;
        self.to_worker.deinit();
        self.to_owner.deinit();
        self.L.deinit();
        allocator.destroy(self);
    }
};

fn createThread(allocator: std.mem.Allocator, L: *VM.lua.State) !*VM.lua.State {
    if (Zune.State.main_thread_id == null) {
        Zune.State.main_thread_id = std.Thread.getCurrentId();
    }

    const runtime = try allocator.create(Runtime);
    errdefer allocator.destroy(runtime);
    runtime.* = .{
        .L = try luau.VM.lstate.Lnewstate(),
        .allocator = allocator,
        .scheduler = .{
            .thread_pool = undefined,
            .global = undefined,
            .loop = undefined,
            .sleeping = undefined,
            .sync = undefined,
            .timer = undefined,
        },
    };
    errdefer runtime.L.close();

    runtime.L.pushlightuserdata(@ptrCast(runtime));
    try runtime.L.rawsetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME");

    runtime.scheduler.loop.allocator = allocator;

    const self = try L.newuserdatataggedwithmetatable(Thread, Thread.OBJECT_TAG);
    self.* = .{ .runtime = runtime };

    try Zune.Runtime.Engine.prep(runtime.L);

    runtime.L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = try runtime.L.newthread();

    try ML.Lsandboxthread();

    THREADS.append(&runtime.node);

    return ML;
}

pub fn lua_fromModule(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const moduleName = try L.Zcheckvalue([:0]const u8, 1, null);

    const cwd = std.Io.Dir.cwd();

    const script_path = try Zune.Resolvers.Require.resolveScriptPath(allocator, L, moduleName, cwd);
    defer allocator.free(script_path);

    const module_src_buf: [:0]u8 = try allocator.allocSentinel(u8, 1 + script_path.len + Zune.Resolvers.File.LARGEST_EXTENSION.len, 0);
    defer allocator.free(module_src_buf);

    std.debug.assert(script_path.len <= std.Io.Dir.max_path_bytes);

    module_src_buf[0] = '@';
    @memcpy(module_src_buf[1..][0..script_path.len], script_path);

    const input_buf = module_src_buf[1..][0 .. script_path.len + Zune.Resolvers.File.LARGEST_EXTENSION.len];
    const search_result = (if (Zune.State.bundle) |*b|
        Zune.Resolvers.File.searchLuauFileBundle(input_buf, b, script_path)
    else
        Zune.Resolvers.File.searchLuauFile(input_buf, cwd, script_path)) catch |err| switch (err) {
        error.RedundantFileExtension => return L.Zerrorf("redundant file extension, remove '{s}'", .{std.fs.path.extension(script_path)}),
        else => return err,
    };
    defer search_result.deinit();

    try Zune.Resolvers.Require.checkSearchResult(allocator, L, script_path, search_result);

    const file = search_result.first();

    if (file.ext.type == .Luau and std.mem.eql(u8, std.fs.path.basename(script_path), ".config")) {
        return L.Zerror("cannot require configuration file");
    }

    const extended = module_src_buf[1 + script_path.len ..];
    @memcpy(extended[0..file.ext.ext.len], file.ext.ext);
    extended[file.ext.ext.len] = 0;

    const module_src: [:0]u8 = module_src_buf[0 .. 1 + script_path.len + file.ext.ext.len :0];

    const file_content: []const u8 = switch (file.val) {
        .contents => |c| c,
        .handle => |h| blk: {
            var reader = h.reader(Zune.io(), &.{});
            break :blk reader.interface.allocRemaining(allocator, .unlimited) catch |err| {
                return L.Zerrorf("could not read module file '{s}': {}", .{ module_src, err });
            };
        },
    };
    defer if (file.val == .handle) allocator.free(file_content);

    const ML = try createThread(allocator, L);

    try Zune.Runtime.Engine.setLuaFileContext(ML, .{
        .main = false,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    if (Zune.State.bundle == null or Zune.State.bundle.?.mode.compiled == .debug) {
        @branchHint(.likely);
        Zune.Runtime.Engine.loadModule(ML, module_src, file_content, null) catch |err| switch (err) {
            error.Syntax => return L.Zerror(ML.tostring(-1) orelse "UnknownError"),
        };
    } else {
        ML.load(module_src, file_content, 0) catch unreachable; // should not error
        Zune.Runtime.Engine.loadNative(ML);
    }
    return 1;
}

pub fn lua_fromBytecode(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const bytecode = try L.Zcheckvalue([]const u8, 1, null);

    const Options = struct {
        native_code_gen: bool = true,
        chunk_name: [:0]const u8 = "(thread)",
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};

    const ML = try createThread(allocator, L);

    try Zune.Runtime.Engine.setLuaFileContext(ML, .{
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    ML.load(opts.chunk_name, bytecode, 0) catch {
        return L.Zerrorf("load error: {s}", .{ML.tostring(-1) orelse "unknown error"});
    };

    if (luau.CodeGen.Supported() and Zune.State.options.runtime.luau.default_ncg and Zune.State.options.runtime.luau.jit_enabled and opts.native_code_gen)
        luau.CodeGen.Compile(ML, -1);

    return 1;
}

pub fn lua_receive(L: *VM.lua.State) !i32 {
    switch (L.rawgetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME")) {
        .LightUserdata => {},
        else => return L.Zerror("current context is not a thread"),
    }
    const runtime = L.tolightuserdata(Runtime, -1).?;
    L.pop(1);
    return runtime.to_worker.receive(L);
}

pub fn lua_send(L: *VM.lua.State) !i32 {
    switch (L.rawgetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME")) {
        .LightUserdata => {},
        else => return L.Zerror("current context is not a thread"),
    }
    const runtime = L.tolightuserdata(Runtime, -1).?;
    L.pop(1);
    try runtime.to_owner.send(runtime.allocator, L, 1);
    return 0;
}

pub fn lua_getCpuCount(L: *VM.lua.State) i32 {
    L.pushunsigned(@intCast(std.Thread.getCpuCount() catch 1));
    return 1;
}

fn lua_createNamed(L: *VM.lua.State, comptime Registry: type, comptime Object: type) !i32 {
    const name = try L.Zcheckvalue([]const u8, 1, null);
    const allocator = Zune.DEFAULT_ALLOCATOR;

    Registry.mutex.lockUncancelable(Zune.io());
    if (Registry.refs.get(name)) |existing| {
        Registry.mutex.unlock(Zune.io());
        existing.push(L);
        return 1;
    }

    const entry = Registry.reserve(allocator, name) catch |err| {
        Registry.mutex.unlock(Zune.io());
        return err;
    };
    Registry.mutex.unlock(Zune.io());

    // The userdata is not armed until the thread-local ref is stored. On failure
    // the dtor must not drop the reservation this function still owns.
    const obj = Object.create(L, entry) catch |err| {
        Registry.release(entry);
        return err;
    };
    const top = L.gettop();
    const lua_ref = Scripting.Reference.init(L, -1);
    // The C backend pops. The zig backend leaves the value on the stack.
    if (L.gettop() < top)
        lua_ref.push(L);

    Registry.mutex.lockUncancelable(Zune.io());
    Registry.refs.put(allocator, entry.name, lua_ref) catch |err| {
        Registry.mutex.unlock(Zune.io());
        var dropped = lua_ref;
        dropped.deref(L);
        Registry.release(entry);
        return err;
    };
    Registry.mutex.unlock(Zune.io());

    obj.armed.store(true, .release);
    return 1;
}

pub fn lua_createMutex(L: *VM.lua.State) !i32 {
    return lua_createNamed(L, MUTEX_REGISTRY, Zune.objects.ThreadMutex);
}

pub fn lua_createHardMutex(L: *VM.lua.State) !i32 {
    return lua_createNamed(L, HARD_MUTEX_REGISTRY, Zune.objects.ThreadHardMutex);
}

pub fn lua_createLane(L: *VM.lua.State) !i32 {
    return lua_createNamed(L, LANE_REGISTRY, ThreadLane);
}

pub fn lua_createValue(L: *VM.lua.State) !i32 {
    return lua_createNamed(L, VALUE_REGISTRY, ThreadValue);
}

pub fn lua_custom_isThread(L: *VM.lua.State) !void {
    const is_thread = L.rawgetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME") == .LightUserdata;
    L.pop(1);
    L.pushboolean(is_thread);
}
