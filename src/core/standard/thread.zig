const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;
const Lists = Zune.Utils.Lists;

const VM = luau.VM;

const TAG_THREAD = Zune.Tags.get("THREAD").?;

pub const LIB_NAME = "thread";
pub fn PlatformSupported() bool {
    return !@import("builtin").single_threaded;
}

pub threadlocal var THREADS: Lists.DoublyLinkedList = .{};

pub const Sync = struct {
    node: Lists.DoublyLinkedList.Node = .{},
    scheduler: *Scheduler,
    runtime: *Runtime,
    thread: Scheduler.ThreadRef,
    message: *Transporter.MessageNode = undefined,

    pub fn from(node: *Lists.DoublyLinkedList.Node) *Sync {
        return @fieldParentPtr("node", node);
    }

    pub fn receiveComplete(self: *Sync, scheduler: *Scheduler) void {
        const runtime = self.runtime;
        defer scheduler.freeSync(self);
        defer self.thread.deref();
        defer runtime.transporter.freeMessage(self.message);

        const L = self.thread.value;
        if (L.status() != .Yield)
            return;

        const amt = self.message.push(L) catch |e| std.debug.panic("{}", .{e}); // OOM

        _ = Scheduler.resumeState(L, null, amt) catch {};
    }
    pub fn joinComplete(self: *Sync, scheduler: *Scheduler) void {
        defer scheduler.freeSync(self);
        defer self.thread.deref();

        _ = Scheduler.resumeState(self.thread.value, null, 0) catch {};
    }
};

pub const LuaValue = union(enum) {
    nil: void,
    boolean: bool,
    number: f64,
    string: []const u8,
    buffer: []const u8,
    table: struct {
        keys: [*]LuaValue,
        values: [*]LuaValue,
        len: usize,
    },
    vector: [VM.lua.config.VECTOR_SIZE]f32,

    pub fn push(self: LuaValue, L: *VM.lua.State) !void {
        switch (self) {
            .nil => L.pushnil(),
            .boolean => |v| L.pushboolean(v),
            .number => |v| L.pushnumber(v),
            .string => |v| try L.pushlstring(v),
            .buffer => |v| try L.Zpushbuffer(v),
            .table => |v| {
                var narray: u32 = 0;
                var nrec: u32 = 0;
                for (v.keys[0..v.len]) |key| switch (key) {
                    .number => |n| {
                        if (@as(i32, @intFromFloat(n)) == narray + 1)
                            narray += 1;
                    },
                    else => nrec += 1,
                };
                try L.createtable(narray, nrec);
                for (v.keys[0..v.len], v.values[0..v.len]) |key, value| {
                    try key.push(L);
                    try value.push(L);
                    try L.rawset(-3);
                }
            },
            .vector => |v| L.pushvector(v[0], v[1], v[2], if (VM.lua.config.VECTOR_SIZE > 3) v[3] else null),
        }
    }

    pub fn deinit(self: LuaValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string, .buffer => |v| allocator.free(v),
            .table => |v| {
                for (v.keys[0..v.len]) |key|
                    key.deinit(allocator);
                for (v.values[0..v.len]) |value|
                    value.deinit(allocator);
                allocator.free(v.keys[0..v.len]);
                allocator.free(v.values[0..v.len]);
            },
            else => {},
        }
    }
};

pub const Transporter = struct {
    allocator: std.mem.Allocator,
    incoming: Lists.DoublyLinkedList = .{},
    outgoing: Lists.DoublyLinkedList = .{},
    incoming_queue: Lists.DoublyLinkedList = .{},
    outgoing_queue: Lists.DoublyLinkedList = .{},
    incoming_mutex: std.Thread.Mutex = .{},
    outgoing_mutex: std.Thread.Mutex = .{},

    pub const MessageNode = struct {
        node: Lists.DoublyLinkedList.Node = .{},
        value: union(enum) {
            none: void,
            small: LuaValue,
            large: struct {
                values: [*]LuaValue,
                len: u32,
            },
        },

        pub fn push(self: *MessageNode, L: *VM.lua.State) !i32 {
            switch (self.value) {
                .none => return 0,
                .small => |v| {
                    try v.push(L);
                    return 1;
                },
                .large => |v| {
                    for (v.values[0..v.len]) |value|
                        try value.push(L);
                    return @intCast(v.len);
                },
            }
        }

        pub fn from(node: *Lists.DoublyLinkedList.Node) *MessageNode {
            return @fieldParentPtr("node", node);
        }

        pub fn deinit(self: *MessageNode, allocator: std.mem.Allocator, comptime own: bool) void {
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

            if (own)
                allocator.destroy(self);
        }
    };

    pub fn freeMessage(self: *Transporter, message: *MessageNode) void {
        message.deinit(self.allocator, true);
    }

    pub fn newMessage(self: *Transporter) !*MessageNode {
        const allocator = self.allocator;
        return try allocator.create(MessageNode);
    }

    pub fn pushAndConsumeMessage(self: *Transporter, L: *VM.lua.State, port: *Lists.DoublyLinkedList) !?i32 {
        const message = MessageNode.from(port.popFirst() orelse return null);
        defer self.freeMessage(message);
        return try message.push(L);
    }

    pub fn deinit(self: *Transporter) void {
        const allocator = self.allocator;
        inline for (&[_][]const u8{ "incoming", "outgoing" }) |port_name| {
            var node = @field(self, port_name).first;
            while (node) |n| {
                node = n.next;
                MessageNode.from(n).deinit(allocator, true);
            }
        }
    }
};

pub const Runtime = struct {
    node: Lists.DoublyLinkedList.Node = .{},
    L: *VM.lua.State,
    scheduler: Scheduler,
    transporter: Transporter,
    access_mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
    join_queue: Lists.DoublyLinkedList = .{},
    status: std.atomic.Value(enum(u8) { ready, running, dead }) align(std.atomic.cache_line) = .init(.ready),
    owner: enum { lua, thread } = .lua,

    pub fn from(node: *Lists.DoublyLinkedList.Node) *Runtime {
        return @alignCast(@fieldParentPtr("node", node));
    }

    fn entry(self: *Runtime) void {
        const ML = self.L.tothread(1).?;

        Scheduler.SCHEDULERS = .empty;

        jmp: {
            Scheduler.SCHEDULERS.append(Zune.DEFAULT_ALLOCATOR, &self.scheduler) catch break :jmp;

            Zune.initState(self.L) catch break :jmp;
            defer Zune.deinitState(self.L);

            Zune.Runtime.Engine.runAsync(ML, &self.scheduler, .{ .cleanUp = false }) catch {};
        }

        self.access_mutex.lock();
        defer self.access_mutex.unlock();

        var node = self.join_queue.first;
        while (node) |n| {
            node = n.next;
            const sync = Sync.from(n);
            sync.scheduler.synchronize(sync);
        }

        self.status.store(.dead, .release);
    }

    pub fn deinit(self: *Runtime) void {
        defer self.scheduler.allocator.destroy(self);
        defer self.L.deinit();
        self.scheduler.deinit();
        self.transporter.deinit();
    }
};

const LuaThread = struct {
    runtime: *Runtime,

    pub fn lua_start(self: *LuaThread, L: *VM.lua.State) !i32 {
        const runtime = self.runtime;
        if (runtime.status.cmpxchgStrong(.ready, .running, .acq_rel, .acquire) != null) {
            return L.Zerror("thread running or dead");
        }

        std.debug.assert(runtime.status.load(.acquire) == .running);
        runtime.thread = std.Thread.spawn(.{}, Runtime.entry, .{runtime}) catch |err| {
            runtime.status.store(.dead, .release);
            return L.Zerrorf("failed to start thread: {}", .{err});
        };

        return 0;
    }

    pub fn lua_send(self: *LuaThread, L: *VM.lua.State) !i32 {
        const runtime = self.runtime;

        const allocator = runtime.transporter.allocator;

        const send_count = L.gettop() - 1;

        var values: std.ArrayListUnmanaged(LuaValue) = if (send_count > 0) try .initCapacity(allocator, 1) else .empty;
        defer values.deinit(allocator);
        errdefer for (values.items) |value| value.deinit(allocator);
        if (send_count > 0) {
            if (send_count > std.math.maxInt(i32))
                return error.TooManyValues;
            var err_type: VM.lua.Type = .None;
            for (2..send_count + 2) |i| {
                var map = std.AutoArrayHashMap(usize, bool).init(allocator);
                defer map.deinit();
                const value = storevalue(L, allocator, @intCast(i), &err_type, &map) catch |err| switch (err) {
                    error.UnsupportedType => return L.Zerrorf("unsupported lua type for sending (got {s})", .{VM.lapi.typename(err_type)}),
                    else => return err,
                };
                errdefer value.deinit(allocator);
                try values.append(allocator, value);
            }
        }

        const node = try runtime.transporter.newMessage();
        errdefer runtime.transporter.freeMessage(node);
        if (send_count <= 1) {
            node.* = .{ .value = if (send_count == 0) .none else .{ .small = values.items[0] } };
        } else {
            const slice = try values.toOwnedSlice(allocator);
            node.* = .{ .value = .{ .large = .{ .values = slice.ptr, .len = @intCast(slice.len) } } };
        }

        {
            const port = &runtime.transporter.outgoing;
            const sync_port = &runtime.transporter.outgoing_queue;

            runtime.transporter.outgoing_mutex.lock();
            defer runtime.transporter.outgoing_mutex.unlock();

            if (sync_port.popFirst()) |n| {
                const s = Sync.from(n);
                s.message = node;
                s.scheduler.synchronize(s);
            } else {
                port.append(&node.node);
            }
        }

        return 0;
    }

    pub fn lua_receive(self: *LuaThread, L: *VM.lua.State) !i32 {
        const runtime = self.runtime;

        const port = &runtime.transporter.incoming;
        const sync_port = &runtime.transporter.incoming_queue;

        runtime.transporter.incoming_mutex.lock();
        defer runtime.transporter.incoming_mutex.unlock();
        if (try runtime.transporter.pushAndConsumeMessage(L, port)) |amt| {
            return amt;
        } else {
            if (!L.isyieldable())
                return L.Zyielderror();
            const scheduler = Scheduler.getScheduler(L);
            const sync = try scheduler.createSync(Sync, Sync.receiveComplete);
            sync.* = .{
                .scheduler = scheduler,
                .runtime = runtime,
                .thread = .init(L),
            };
            scheduler.asyncWaitForSync(sync);
            sync_port.append(&sync.node);
            return L.yield(0);
        }
    }

    pub fn lua_join(self: *LuaThread, L: *VM.lua.State) !i32 {
        const runtime = self.runtime;
        runtime.access_mutex.lock();
        defer runtime.access_mutex.unlock();
        switch (runtime.status.load(.acquire)) {
            .ready, .dead => return 0,
            .running => {},
        }
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);

        const state = try scheduler.createSync(Sync, Sync.joinComplete);
        state.* = .{
            .scheduler = scheduler,
            .runtime = runtime,
            .thread = .init(L),
        };
        scheduler.asyncWaitForSync(state);

        runtime.join_queue.append(&state.node);

        return L.yield(0);
    }

    pub fn lua_status(self: *LuaThread, L: *VM.lua.State) !i32 {
        const runtime = self.runtime;
        try L.pushlstring(@tagName(runtime.status.load(.acquire)));
        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaThread, TAG_THREAD, .{
        .{ "start", lua_start },
        .{ "join", lua_join },
        .{ "status", lua_status },
        .{ "send", lua_send },
        .{ "receive", lua_receive },
    });

    pub fn __dtor(L: *VM.lua.State, self: *LuaThread) void {
        _ = L;
        const runtime = self.runtime;
        runtime.access_mutex.lock();
        if (runtime.status.load(.acquire) == .running) {
            defer runtime.access_mutex.unlock();
            runtime.owner = .thread; // TODO: maybe atomic owner?
            return;
        }
        runtime.access_mutex.unlock();
        THREADS.remove(&runtime.node);
        if (runtime.thread) |t|
            t.join();
        runtime.deinit();
    }
};

fn storevalue(L: *VM.lua.State, allocator: std.mem.Allocator, idx: i32, out_type: ?*VM.lua.Type, map: *std.AutoArrayHashMap(usize, bool)) !LuaValue {
    switch (L.typeOf(idx)) {
        .Nil => return .nil,
        .Boolean => return .{ .boolean = L.toboolean(idx) },
        .Number => return .{ .number = L.tonumber(idx).? },
        .String => {
            const copy = try allocator.dupe(u8, L.tostring(idx).?);
            return .{ .string = copy };
        },
        .Buffer => {
            const copy = try allocator.dupe(u8, L.tobuffer(idx).?);
            return .{ .buffer = copy };
        },
        .Table => {
            const ptr = @intFromPtr(L.topointer(idx).?);
            if (map.get(ptr)) |_|
                return error.CyclicReference;
            try map.put(ptr, true);

            var keys: std.ArrayListUnmanaged(LuaValue) = .empty;
            errdefer keys.deinit(allocator);
            errdefer for (keys.items) |v| v.deinit(allocator);
            var values: std.ArrayListUnmanaged(LuaValue) = .empty;
            errdefer values.deinit(allocator);
            errdefer for (values.items) |v| v.deinit(allocator);

            var i = L.rawiter(idx, 0);
            while (i >= 0) : (i = L.rawiter(idx, i)) {
                defer L.pop(2);
                {
                    const key = try storevalue(L, allocator, -2, out_type, map);
                    errdefer key.deinit(allocator);
                    try keys.append(allocator, key);
                }
                {
                    const value = try storevalue(L, allocator, -1, out_type, map);
                    errdefer value.deinit(allocator);
                    try values.append(allocator, value);
                }
            }

            const keys_slice = try keys.toOwnedSlice(allocator);
            errdefer allocator.free(keys_slice);
            const values_slice = try values.toOwnedSlice(allocator);
            return .{
                .table = .{
                    .keys = keys_slice.ptr,
                    .values = values_slice.ptr,
                    .len = keys_slice.len,
                },
            };
        },
        .Vector => {
            const vec = L.tovector(idx).?;
            var value: LuaValue = .{ .vector = undefined };
            for (vec, 0..) |n, i|
                value.vector[i] = n;
            return value;
        },
        else => |@"type"| {
            if (out_type) |t|
                t.* = @"type";
            return error.UnsupportedType;
        },
    }
}

fn createThread(allocator: std.mem.Allocator, L: *VM.lua.State) !*VM.lua.State {
    const runtime = try allocator.create(Runtime);
    errdefer allocator.destroy(runtime);
    runtime.* = .{
        .L = undefined,
        .scheduler = .{
            .allocator = allocator,
            .thread_pool = undefined,
            .async = undefined,
            .global = undefined,
            .loop = undefined,
            .sleeping = undefined,
            .sync = undefined,
            .timer = undefined,
        },
        .transporter = .{ .allocator = allocator },
    };
    runtime.L = try luau.init(&runtime.scheduler.allocator);
    errdefer runtime.L.close();

    runtime.L.pushlightuserdata(@ptrCast(runtime));
    try runtime.L.rawsetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME");

    runtime.scheduler = try .init(allocator, runtime.L);

    const self = try L.newuserdatataggedwithmetatable(LuaThread, TAG_THREAD);
    self.* = .{ .runtime = runtime };

    try Zune.Runtime.Engine.prepAsync(runtime.L, &runtime.scheduler);
    try Zune.openZune(runtime.L, &.{}, .{});

    runtime.L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = try runtime.L.newthread();

    try ML.Lsandboxthread();

    THREADS.append(&runtime.node);

    return ML;
}

fn lua_fromModule(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const moduleName = try L.Zcheckvalue([:0]const u8, 1, null);

    const cwd = std.fs.cwd();

    const script_path = try Zune.Resolvers.Require.resolveScriptPath(allocator, L, moduleName, cwd);
    defer allocator.free(script_path);

    const module_src_buf: [:0]u8 = try allocator.allocSentinel(u8, 1 + script_path.len + Zune.Resolvers.File.LARGEST_EXTENSION.len, 0);
    defer allocator.free(module_src_buf);

    std.debug.assert(script_path.len <= std.fs.max_path_bytes);

    module_src_buf[0] = '@';
    @memcpy(module_src_buf[1..][0..script_path.len], script_path);

    const input_buf = module_src_buf[1..][0 .. script_path.len + Zune.Resolvers.File.LARGEST_EXTENSION.len];
    const search_result = (if (Zune.STATE.BUNDLE) |*b|
        Zune.Resolvers.File.searchLuauFileBundle(input_buf, b, script_path)
    else
        Zune.Resolvers.File.searchLuauFile(input_buf, cwd, script_path)) catch |err| switch (err) {
        error.RedundantFileExtension => return L.Zerrorf("redundant file extension, remove '{s}'", .{std.fs.path.extension(script_path)}),
        else => return err,
    };
    defer search_result.deinit();

    try Zune.Resolvers.Require.checkSearchResult(allocator, L, script_path, search_result);

    const file = search_result.first();

    const extended = module_src_buf[1 + script_path.len ..];
    @memcpy(extended[0..file.ext.len], file.ext);
    extended[file.ext.len] = 0;

    const module_src: [:0]u8 = module_src_buf[0 .. 1 + script_path.len + file.ext.len :0];

    const file_content: []const u8 = switch (file.val) {
        .contents => |c| c,
        .handle => |h| h.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| {
            return L.Zerrorf("could not read module file '{s}': {}", .{ module_src, err });
        },
    };
    defer if (file.val == .handle) allocator.free(file_content);

    const ML = try createThread(allocator, L);

    try Zune.Runtime.Engine.setLuaFileContext(ML, .{
        .main = false,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    if (Zune.STATE.BUNDLE == null or Zune.STATE.BUNDLE.?.mode.compiled == .debug) {
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

fn lua_fromBytecode(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

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

    if (luau.CodeGen.Supported() and Zune.STATE.LUAU_OPTIONS.CODEGEN and Zune.STATE.LUAU_OPTIONS.JIT_ENABLED and opts.native_code_gen)
        luau.CodeGen.Compile(ML, -1);

    return 1;
}

fn lua_selfReceive(L: *VM.lua.State) !i32 {
    switch (L.rawgetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME")) {
        .LightUserdata => {},
        else => return L.Zerror("current context is not a thread"),
    }
    const runtime = L.tolightuserdata(Runtime, -1).?;
    L.pop(1);

    const port = &runtime.transporter.outgoing;
    const sync_port = &runtime.transporter.outgoing_queue;

    runtime.transporter.outgoing_mutex.lock();
    defer runtime.transporter.outgoing_mutex.unlock();
    if (try runtime.transporter.pushAndConsumeMessage(L, port)) |amt| {
        return amt;
    } else {
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);
        const sync = try scheduler.createSync(Sync, Sync.receiveComplete);
        sync.* = .{
            .scheduler = scheduler,
            .runtime = runtime,
            .thread = .init(L),
        };
        scheduler.asyncWaitForSync(sync);
        sync_port.append(&sync.node);
        return L.yield(0);
    }
}

fn lua_selfSend(L: *VM.lua.State) !i32 {
    switch (L.rawgetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME")) {
        .LightUserdata => {},
        else => return L.Zerror("current context is not a thread"),
    }
    const runtime = L.tolightuserdata(Runtime, -1).?;
    L.pop(1);

    const allocator = runtime.transporter.allocator;

    const send_count = L.gettop();

    var values: std.ArrayListUnmanaged(LuaValue) = if (send_count > 0) try .initCapacity(allocator, 1) else .empty;
    defer values.deinit(allocator);
    errdefer for (values.items) |value| value.deinit(allocator);
    if (send_count > 0) {
        if (send_count > std.math.maxInt(i32))
            return error.TooManyValues;
        var err_type: VM.lua.Type = .None;
        for (1..send_count + 1) |i| {
            var map = std.AutoArrayHashMap(usize, bool).init(allocator);
            defer map.deinit();
            const value = storevalue(L, allocator, @intCast(i), &err_type, &map) catch |err| switch (err) {
                error.UnsupportedType => return L.Zerrorf("unsupported lua type for sending (got {s})", .{VM.lapi.typename(err_type)}),
                else => return err,
            };
            errdefer value.deinit(allocator);
            try values.append(allocator, value);
        }
    }

    const node = try runtime.transporter.newMessage();
    errdefer runtime.transporter.freeMessage(node);
    if (send_count <= 1) {
        node.* = .{ .value = if (send_count == 0) .none else .{ .small = values.items[0] } };
    } else {
        const slice = try values.toOwnedSlice(allocator);
        node.* = .{ .value = .{ .large = .{ .values = slice.ptr, .len = @intCast(slice.len) } } };
    }

    {
        const port = &runtime.transporter.incoming;
        const sync_port = &runtime.transporter.incoming_queue;

        runtime.transporter.incoming_mutex.lock();
        defer runtime.transporter.incoming_mutex.unlock();

        if (sync_port.popFirst()) |n| {
            const s = Sync.from(n);
            s.message = node;
            s.scheduler.synchronize(s);
        } else port.append(&node.node);
    }

    return 0;
}

fn lua_getCpuCount(L: *VM.lua.State) i32 {
    L.pushunsigned(@intCast(std.Thread.getCpuCount() catch 1));
    return 1;
}

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaThread), .{
            .__metatable = "Metatable is locked",
            .__type = "Thread",
        });
        try LuaThread.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_THREAD);
        L.setuserdatadtor(LuaThread, TAG_THREAD, LuaThread.__dtor);
    }

    const is_thread = L.rawgetfield(VM.lua.REGISTRYINDEX, "_THREAD_RUNTIME") == .LightUserdata;
    L.pop(1);

    try L.Zpushvalue(.{
        .fromModule = lua_fromModule,
        .fromBytecode = lua_fromBytecode,
        .receive = lua_selfReceive,
        .send = lua_selfSend,
        .getCpuCount = lua_getCpuCount,
        .isThread = is_thread,
    });
    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test "thread" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/thread/init.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
