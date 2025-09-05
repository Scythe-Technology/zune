const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;

const VM = luau.VM;

const ffi = @import("ffi.zig");

pub const MAX_LUAU_SIZE = 1073741824; // 1 GB

pub const LIB_NAME = "mem";

inline fn isOutOfBounds(offset: u32, len: usize, access: usize) bool {
    return offset + access > len;
}

fn getWritableSlice(L: *VM.lua.State, idx: i32) ![]u8 {
    switch (L.typeOf(idx)) {
        .Buffer => return L.tobuffer(idx).?,
        .Userdata => {
            const ptr = ffi.LuaPointer.value(L, idx) orelse return L.Zerror("expected a buffer or userdata");
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
            return @as([*]u8, @ptrCast(@alignCast(ptr.ptr.?)))[0 .. ptr.size orelse return L.Zerror("unknown size")];
        },
        else => return L.Zerror("expected a buffer or userdata"),
    }
}

fn getReadableSlice(L: *VM.lua.State, idx: i32) ![]const u8 {
    switch (L.typeOf(idx)) {
        .Buffer => return L.tobuffer(idx).?,
        .String => return L.tolstring(idx).?,
        .Userdata => {
            const ptr = ffi.LuaPointer.value(L, idx) orelse return L.Zerror("expected a buffer or userdata");
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
            return @as([*]u8, @ptrCast(@alignCast(ptr.ptr.?)))[0 .. ptr.size orelse return L.Zerror("unknown size")];
        },
        else => return L.Zerror("expected a buffer, string, or userdata"),
    }
}

fn lua_len(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    L.pushnumber(@floatFromInt(slice.len));
    return 1;
}

fn lua_copy(L: *VM.lua.State) !i32 {
    const dst = try getWritableSlice(L, 1);
    const dst_offset = try L.Zcheckvalue(u32, 2, null);
    const src = try getReadableSlice(L, 3);
    const src_offset = try L.Zcheckvalue(u32, 4, null);
    const len = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(src_offset, src.len, len orelse 0) or
        isOutOfBounds(dst_offset, dst.len, len orelse 0))
        return L.Zerror("access out of bounds");

    const new_len = src.len - src_offset;
    const a = dst[dst_offset..][0..new_len];
    const b = src[src_offset..][0..new_len];

    std.mem.copyForwards(u8, a, b);

    return 0;
}

fn lua_slice(L: *VM.lua.State) !i32 {
    const a = try getReadableSlice(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const count = try L.Zcheckvalue(?u32, 3, null);

    if (isOutOfBounds(offset, a.len, count orelse 0))
        return L.Zerror("access out of bounds");

    try L.Zpushbuffer(if (count) |c| a[offset .. c + offset] else a[offset..]);

    return 1;
}

fn lua_eqlSlice(L: *VM.lua.State) !i32 {
    const a = try getReadableSlice(L, 1);
    const a_offset = try L.Zcheckvalue(u32, 2, null);
    const b = try getReadableSlice(L, 3);
    const b_offset = try L.Zcheckvalue(u32, 4, null);
    const count = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(a_offset, a.len, count orelse 0) or isOutOfBounds(b_offset, b.len, count orelse 0))
        return L.Zerror("access out of bounds");

    L.pushboolean(std.mem.eql(
        u8,
        if (count) |c| a[a_offset .. c + a_offset] else a[a_offset..],
        if (count) |c| b[b_offset .. c + b_offset] else b[b_offset..],
    ));

    return 1;
}

fn lua_eql(L: *VM.lua.State) !i32 {
    const a = try getReadableSlice(L, 1);
    const b = try getReadableSlice(L, 2);

    L.pushboolean(std.mem.eql(u8, a, b));

    return 1;
}

fn lua_startsWith(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const needle = try getReadableSlice(L, 2);
    L.pushboolean(std.mem.startsWith(u8, slice, needle));
    return 1;
}

fn lua_endsWith(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const needle = try getReadableSlice(L, 2);
    L.pushboolean(std.mem.endsWith(u8, slice, needle));
    return 1;
}

fn lua_trim(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values_to_strip = try getReadableSlice(L, 2);
    try L.Zpushbuffer(std.mem.trim(u8, slice, values_to_strip));
    return 1;
}

fn lua_trimLeft(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values_to_strip = try getReadableSlice(L, 2);
    try L.Zpushbuffer(std.mem.trimLeft(u8, slice, values_to_strip));
    return 1;
}

fn lua_trimRight(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values_to_strip = try getReadableSlice(L, 2);
    try L.Zpushbuffer(std.mem.trimRight(u8, slice, values_to_strip));
    return 1;
}

fn lua_indexOf(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const needle = try getReadableSlice(L, 2);
    if (std.mem.indexOf(u8, slice, needle)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfPos(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const needle = try getReadableSlice(L, 3);
    if (isOutOfBounds(offset, slice.len, offset))
        return L.Zerror("access out of bounds");
    if (std.mem.indexOfPos(u8, slice, offset, needle)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_lastIndexOf(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const needle = try getReadableSlice(L, 2);
    if (std.mem.lastIndexOf(u8, slice, needle)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfScalar(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    if (std.mem.indexOfScalar(u8, slice, scalar)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfScalarPos(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 3, null));
    if (isOutOfBounds(offset, slice.len, offset))
        return L.Zerror("access out of bounds");
    if (std.mem.indexOfScalarPos(u8, slice, offset, scalar)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_lastIndexOfScalar(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    if (std.mem.lastIndexOfScalar(u8, slice, scalar)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfAny(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values = try getReadableSlice(L, 2);
    if (std.mem.indexOfAny(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfAnyPos(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const values = try getReadableSlice(L, 3);
    if (isOutOfBounds(offset, slice.len, offset))
        return L.Zerror("access out of bounds");
    if (std.mem.indexOfAnyPos(u8, slice, offset, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_lastIndexOfAny(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values = try getReadableSlice(L, 2);
    if (std.mem.lastIndexOfAny(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfNone(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values = try getReadableSlice(L, 2);
    if (std.mem.indexOfNone(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfNonePos(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const values = try getReadableSlice(L, 3);
    if (isOutOfBounds(offset, slice.len, offset))
        return L.Zerror("access out of bounds");
    if (std.mem.indexOfNonePos(u8, slice, offset, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_lastIndexOfNone(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    const values = try getReadableSlice(L, 2);
    if (std.mem.lastIndexOfNone(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfDiff(L: *VM.lua.State) !i32 {
    const a = try getReadableSlice(L, 1);
    const b = try getReadableSlice(L, 2);
    if (std.mem.indexOfDiff(u8, a, b)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

fn lua_indexOfMax(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    if (slice.len == 0)
        return L.Zerror("cannot find max of empty slice");
    L.pushunsigned(@truncate(std.mem.indexOfMax(u8, slice)));
    return 1;
}

fn lua_indexOfMin(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    if (slice.len == 0)
        return L.Zerror("cannot find min of empty slice");
    L.pushunsigned(@truncate(std.mem.indexOfMin(u8, slice)));
    return 1;
}

fn lua_indexOfMinMax(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    if (slice.len == 0)
        return L.Zerror("cannot find min/max of empty slice");
    const min, const max = std.mem.indexOfMinMax(u8, slice);
    L.pushunsigned(@truncate(min));
    L.pushunsigned(@truncate(max));
    return 2;
}

fn lua_replaceScalar(L: *VM.lua.State) !i32 {
    const slice = try getWritableSlice(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    const replacement: u8 = @truncate(try L.Zcheckvalue(u32, 3, null));
    std.mem.replaceScalar(u8, slice, scalar, replacement);
    return 0;
}

fn lua_max(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    if (slice.len == 0)
        return L.Zerror("cannot find max of empty slice");
    L.pushunsigned(std.mem.max(u8, slice));
    return 1;
}

fn lua_min(L: *VM.lua.State) !i32 {
    const slice = try getReadableSlice(L, 1);
    if (slice.len == 0)
        return L.Zerror("cannot find min of empty slice");
    L.pushunsigned(std.mem.min(u8, slice));
    return 1;
}

fn lua_reverse(L: *VM.lua.State) !i32 {
    const slice = try getWritableSlice(L, 1);
    std.mem.reverse(u8, slice);
    return 0;
}

fn lua_rotate(L: *VM.lua.State) !i32 {
    const slice = try getWritableSlice(L, 1);
    const amount = try L.Zcheckvalue(u32, 2, null);
    std.mem.rotate(u8, slice, amount);
    return 0;
}

fn lua_set(L: *VM.lua.State) !i32 {
    const slice = try getWritableSlice(L, 1);
    const value: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    const start = try L.Zcheckvalue(?u32, 3, null);
    const count = try L.Zcheckvalue(?u32, 4, null);

    const offset = start orelse 0;

    if (isOutOfBounds(start orelse 0, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");

    @memset(if (count) |c| slice[offset .. offset + c] else slice[offset..], value);

    return 0;
}

pub fn loadLib(L: *VM.lua.State) !void {
    try L.Zpushvalue(.{
        .MAX_SIZE = MAX_LUAU_SIZE,
        .len = lua_len,
        .copy = lua_copy,
        .slice = lua_slice,
        .eqlSlice = lua_eqlSlice,
        .eql = lua_eql,
        .startsWith = lua_startsWith,
        .endsWith = lua_endsWith,
        .trim = lua_trim,
        .trimLeft = lua_trimLeft,
        .trimRight = lua_trimRight,
        .indexOf = lua_indexOf,
        .indexOfPos = lua_indexOfPos,
        .lastIndexOf = lua_lastIndexOf,
        .indexOfScalar = lua_indexOfScalar,
        .indexOfScalarPos = lua_indexOfScalarPos,
        .lastIndexOfScalar = lua_lastIndexOfScalar,
        .indexOfAny = lua_indexOfAny,
        .indexOfAnyPos = lua_indexOfAnyPos,
        .lastIndexOfAny = lua_lastIndexOfAny,
        .indexOfNone = lua_indexOfNone,
        .indexOfNonePos = lua_indexOfNonePos,
        .lastIndexOfNone = lua_lastIndexOfNone,
        .indexOfDiff = lua_indexOfDiff,
        .indexOfMax = lua_indexOfMax,
        .indexOfMin = lua_indexOfMin,
        .indexOfMinMax = lua_indexOfMinMax,
        .replaceScalar = lua_replaceScalar,
        .max = lua_max,
        .min = lua_min,
        .reverse = lua_reverse,
        .rotate = lua_rotate,
        .set = lua_set,
    });
    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test "mem" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/mem.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
