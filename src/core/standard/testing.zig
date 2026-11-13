const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Runtime = Zune.Runtime;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Fmt = Zune.Resolvers.Fmt;

const VM = luau.VM;

pub const LIB_NAME = "testing";

pub var REF_LEAK_CHECK = false;

pub var COMPLETE_LUA: ?LuaCompleteHandler = null;

pub const TestResult = struct {
    start: ?f64 = null,
    finish: ?f64 = null,
    failed: u32 = 0,
    skipped: u32 = 0,
    total: u32 = 0,
};

const LuaCompleteHandler = struct {
    state: *VM.lua.State,
    ref: Scripting.Reference,
};

pub threadlocal var results: TestResult = .{};

pub fn init() void {
    results = .{};
}

pub fn running() bool {
    return results.start != null;
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

fn isCachedCwdRef(index: usize) bool {
    const cached = Zune.standard.libraries.io.cachedCwdRegistryId() orelse return false;
    return index == @as(usize, @intCast(cached));
}

fn stepCheckLeakedReferences(L: *VM.lua.State) void {
    const allocator = Scheduler.fromState(L).allocator();

    L.pushvalue(VM.lua.REGISTRYINDEX);

    const references: usize = @intCast(L.objlen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        if (isCachedCwdRef(index)) {
            freeRefTrace(allocator, store_index);
            continue;
        }
        defer L.pop(1);
        if (L.rawgeti(-1, @intCast(index)) == .Number) {
            freeRefTrace(allocator, store_index);
            continue;
        }
    }
}

pub fn lua_stepCheckReferences(L: *VM.lua.State) !i32 {
    if (!REF_LEAK_CHECK)
        return 0;
    const scope = L.Lcheckstring(1);
    const allocator = Scheduler.fromState(L).allocator();

    L.pushvalue(VM.lua.REGISTRYINDEX);

    const references: usize = @intCast(L.objlen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        if (isCachedCwdRef(index)) {
            freeRefTrace(allocator, store_index);
            continue;
        }
        defer L.pop(1);
        if (L.rawgeti(-1, @intCast(index)) == .Number) {
            freeRefTrace(allocator, store_index);
            continue;
        }

        if (REF_LEAKED_SOURCE.get(store_index) != null)
            continue;

        const scope_copy = try allocator.dupe(u8, scope);
        errdefer allocator.free(scope_copy);

        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();

        try Fmt.writeIdx(allocator, L, &allocating.writer, @intCast(L.gettop()), Zune.State.options.format.max_depth);

        const slice = try allocating.toOwnedSlice();
        errdefer allocator.free(slice);

        try REF_LEAKED_SOURCE.put(store_index, .{
            .scope = scope_copy,
            .value = slice,
        });
    }
    return 0;
}

pub fn consumeTestingResults(L: *VM.lua.State) !TestResult {
    defer results = .{};
    if (results.start == null)
        return results;
    results.finish = VM.lperf.clock();
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    var total: usize = 0;
    total += scheduler.sleeping.items.len;
    total += scheduler.deferred.count();
    total += scheduler.awaiting;
    total += if (!Scheduler.loopDone(&scheduler.loop)) @as(usize, 1) else @as(usize, 0);

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

    if (COMPLETE_LUA) |handler| {
        if (try Scripting.callSyncGlobalFunction(handler.state, handler.ref, results)) |res| switch (res) {
            .boolean => |v| if (v) return .{ .failed = 0 },
            else => {},
        };
    }

    return results;
}

pub fn lua_consumeResults(L: *VM.lua.State) !i32 {
    const res = try consumeTestingResults(L);
    try L.Zpushvalue(res);
    return 1;
}

pub fn lua_addFailed(L: *VM.lua.State) !i32 {
    const amt = L.tounsigned(2) orelse 1;
    results.failed += amt;
    return 0;
}

pub fn lua_addSkipped(L: *VM.lua.State) !i32 {
    const amt = L.tounsigned(2) orelse 1;
    results.skipped += amt;
    return 0;
}

pub fn lua_addCount(L: *VM.lua.State) !i32 {
    const amt = L.tounsigned(2) orelse 1;
    results.total += amt;
    return 0;
}

pub fn lua_start(_: *VM.lua.State) !i32 {
    if (running())
        return 0;
    results.start = VM.lperf.clock();
    return 0;
}

pub fn lua_onComplete(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Function);

    if (Zune.State.main_thread_id) |id|
        if (id != std.Thread.getCurrentId())
            return L.Zerror("function can only be called in the main thread");
    COMPLETE_LUA = .{ .state = L.mainthread(), .ref = .init(L, 1) };
    return 0;
}
