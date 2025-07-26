const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const Fmt = Zune.Resolvers.Fmt;

const LuaHelper = Zune.Utils.LuaHelper;

const test_lib_gz = @embedFile("../lua/testing_lib.luac.gz");
const test_lib_size = @embedFile("../lua/testing_lib.luac").len;

const VM = luau.VM;

pub const LIB_NAME = "testing";

pub var REF_LEAK_CHECK = false;

fn testing_debug(L: *VM.lua.State) i32 {
    const str = L.Lcheckstring(1);
    Zune.debug.print("{s}\n", .{str});
    return 0;
}

var REF_LEAKED_SOURCE = std.AutoHashMap(usize, struct {
    scope: []const u8,
    value: []const u8,
}).init(Zune.DEFAULT_ALLOCATOR);

fn freeRefTrace(allocator: std.mem.Allocator, index: usize) void {
    if (REF_LEAKED_SOURCE.get(index)) |source| {
        allocator.free(source.scope);
        allocator.free(source.value);
        _ = REF_LEAKED_SOURCE.remove(index);
    }
}

fn stepCheckLeakedReferences(L: *VM.lua.State) void {
    const allocator = luau.getallocator(L);

    L.pushvalue(VM.lua.REGISTRYINDEX);

    const references: usize = @intCast(L.objlen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        defer L.pop(1);
        if (L.rawgeti(-1, @intCast(index)) == .Number) {
            freeRefTrace(allocator, store_index);
            continue;
        }
    }
}

fn testing_checkLeakedReferences(L: *VM.lua.State) !i32 {
    if (!REF_LEAK_CHECK)
        return 0;
    const scope = L.Lcheckstring(1);
    const allocator = luau.getallocator(L);

    L.pushvalue(VM.lua.REGISTRYINDEX);

    const references: usize = @intCast(L.objlen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        defer L.pop(1);
        if (L.rawgeti(-1, @intCast(index)) == .Number) {
            freeRefTrace(allocator, store_index);
            continue;
        }

        if (REF_LEAKED_SOURCE.get(store_index) != null)
            continue;

        const scope_copy = try allocator.dupe(u8, scope);

        var buf = std.ArrayList(u8).init(allocator);
        try Fmt.writeIdx(allocator, L, buf.writer(), @intCast(L.gettop()), Zune.STATE.FORMAT.MAX_DEPTH);

        try REF_LEAKED_SOURCE.put(store_index, .{ .scope = scope_copy, .value = try buf.toOwnedSlice() });
    }
    return 0;
}

fn testing_droptasks(L: *VM.lua.State) i32 {
    const scheduler = Scheduler.getScheduler(L);

    var awaitsSize = scheduler.awaits.items.len;
    while (awaitsSize > 0) {
        awaitsSize -= 1;
        const awaiting = scheduler.awaits.items[awaitsSize];
        if (awaiting.priority == .Internal)
            continue;
        _ = scheduler.awaits.orderedRemove(awaitsSize);
        awaiting.virtualDtor(awaiting.data, awaiting.state.value, scheduler);
    }

    var sleepingSize = scheduler.sleeping.items.len;
    while (sleepingSize > 0) {
        sleepingSize -= 1;
        var slept = scheduler.sleeping.remove();
        slept.thread.deref();
    }

    while (scheduler.deferred.pop()) |node| {
        const deferred = Scheduler.DeferredThread.fromNode(node);
        defer scheduler.allocator.destroy(deferred);
        deferred.thread.deref();
    }

    return 0;
}

fn testing_declareSafeEnv(L: *VM.lua.State) i32 {
    L.setsafeenv(VM.lua.GLOBALSINDEX, true);
    return 0;
}

fn empty(L: *VM.lua.State) i32 {
    _ = L;
    return 0;
}

pub const TestResult = struct {
    failed: i32,
    total: i32,
};

pub fn finish_testing(L: *VM.lua.State, rawstart: f64) !TestResult {
    const allocator = luau.getallocator(L);
    const end = VM.lperf.clock();

    _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    if (L.rawgetfield(-1, LIB_NAME) != .Table)
        std.debug.panic("No test framework loaded", .{});

    const stdOut = if (L.rawgetfield(VM.lua.GLOBALSINDEX, "_testing_stdOut") == .Boolean)
        L.toboolean(-1)
    else
        true;
    L.pop(1);

    const start = if (L.rawgetfield(-1, "_start") == .Number)
        L.tonumber(-1) orelse rawstart
    else
        rawstart;
    L.pop(1);

    const time = end - start;
    const mainTestCount = if (L.rawgetfield(-1, "_count") == .Number)
        L.tointeger(-1) orelse unreachable
    else
        0;
    L.pop(1);
    const mainFailedCount = if (L.rawgetfield(-1, "_failed") == .Number)
        L.tointeger(-1) orelse unreachable
    else
        0;
    L.pop(1);

    _ = L.gc(.Collect, 0);

    stepCheckLeakedReferences(L);

    var header = false;
    if (REF_LEAKED_SOURCE.count() > 0) {
        var iter = REF_LEAKED_SOURCE.iterator();
        while (iter.next()) |entry| {
            const idx = entry.key_ptr.*;
            const source = entry.value_ptr.*;
            const refIdx = idx + 1;
            if (!header) {
                header = true;
                Zune.debug.print("\n", .{});
                Zune.debug.print("<bold><blue>LEAK<clear> Runtime leaked references (Information may not be accurate)<clear>", .{});
            }
            Zune.debug.print("\n {s}<clear>", .{source.scope});
            Zune.debug.print("\n  <bcyan>{}<clear> <dim>-<clear> {s}", .{ refIdx, source.value });

            freeRefTrace(allocator, idx);
        }
    }
    if (header)
        Zune.debug.print("\n", .{});

    if (stdOut) {
        Zune.debug.print("\n", .{});
        if (mainFailedCount > 0) {
            Zune.debug.print(" <bold>Tests<clear>: <bold><red>{} failed<clear>, {} total\n", .{ mainFailedCount, mainTestCount });
        } else {
            Zune.debug.print(" <bold>Tests<clear>: {} total\n", .{mainTestCount});
        }
        Zune.debug.print(" <bold>Time<clear>:  {d} s\n", .{std.math.ceil(time * 1000) / 1000});
    }
    return .{
        .failed = mainFailedCount,
        .total = mainTestCount,
    };
}

pub fn runTestAsync(L: *VM.lua.State, sched: *Scheduler) !TestResult {
    const start = VM.lperf.clock();

    Engine.runAsync(L, sched, .{ .cleanUp = true, .mode = .Test }) catch {};

    return try finish_testing(L, start);
}

pub fn loadLib(L: *VM.lua.State, enabled: bool) !void {
    const allocator = luau.getallocator(L);
    if (enabled) {
        const GL = L.mainthread();
        const ML = try GL.newthread();
        GL.xmove(L, 1);
        try ML.Lsandboxthread();

        if (L.rawgetfield(VM.lua.GLOBALSINDEX, "_testing_stdOut") == .Boolean and !L.toboolean(-1)) {
            try ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "print", empty);
        } else try ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "print", testing_debug);
        L.pop(1);
        try ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "declare_safeEnv", testing_declareSafeEnv);
        try ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "stepcheck_references", testing_checkLeakedReferences);
        try ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "scheduler_droptasks", testing_droptasks);
        try ML.Zsetfield(VM.lua.GLOBALSINDEX, "_FILE", false);

        const bytecode_buf = allocator.alloc(u8, test_lib_size) catch |err| std.debug.panic("Unable to allocate space for testing framework: {}", .{err});
        defer allocator.free(bytecode_buf);
        var bytecode_buf_stream = std.io.fixedBufferStream(bytecode_buf);
        var bytecode_gz_buf_stream = std.io.fixedBufferStream(test_lib_gz);

        std.compress.gzip.decompress(bytecode_gz_buf_stream.reader(), bytecode_buf_stream.writer()) catch |err| std.debug.panic("Failed to decompress testing framework: {}", .{err});

        ML.load("test_framework", bytecode_buf, 0) catch |err|
            std.debug.panic("Error loading test framework: {}\n", .{err});
        _ = ML.pcall(0, 1, 0).check() catch |err| {
            Zune.debug.print("Error loading test framework (2): {}\n", .{err});
            Engine.logError(ML, err, false);
            std.debug.panic("Test Framework (2)\n", .{});
        };
        ML.xmove(L, 1);

        L.remove(-2);
    } else {
        try L.createtable(0, 4);
        try L.Zsetfield(-1, "running", false);
        try L.Zsetfieldfn(-1, "describe", empty);
        try L.Zsetfieldfn(-1, "test", empty);
        try L.Zsetfieldfn(-1, "expect", empty);
        L.setreadonly(-1, true);
    }

    try LuaHelper.registerModule(L, LIB_NAME);
}

test "Test" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/testing.test.luau"),
        &.{},
        .{ .std_out = false },
    );

    try std.testing.expect(testResult.failed == 3);
    try std.testing.expect(testResult.total == 11);
}
