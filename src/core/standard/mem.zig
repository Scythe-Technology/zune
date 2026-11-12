const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const CPointer = Zune.objects.CPointer;

pub const lua_MAX_SIZE = Scripting.MAX_LUAU_SIZE; // 1 GB

pub const LIB_NAME = "mem";

inline fn isOutOfBounds(offset: u32, len: usize, access: usize) bool {
    return access + offset > len;
}

pub fn lua_len(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    L.pushnumber(@floatFromInt(slice.len));
    return 1;
}

pub fn lua_copy(L: *VM.lua.State) !i32 {
    const dest = try Scripting.getWritable(L, 1);
    const dest_offset = try L.Zcheckvalue(u32, 2, null);
    const src = try Scripting.getReadable(L, 3);
    const src_offset = try L.Zcheckvalue(u32, 4, null);
    const len = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(src_offset, src.len, len orelse 0) or
        isOutOfBounds(dest_offset, dest.len, len orelse 0))
        return L.Zerror("access out of bounds");

    const new_len = len orelse @min(src.len - src_offset, dest.len - dest_offset);
    const a = dest[dest_offset..][0..new_len];
    const b = src[src_offset..][0..new_len];

    std.mem.copyForwards(u8, a, b);

    return 0;
}

pub fn lua_slice(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const count = try L.Zcheckvalue(?u32, 3, null);

    if (isOutOfBounds(offset, a.len, count orelse 0))
        return L.Zerror("access out of bounds");

    try L.Zpushbuffer(if (count) |n| a[offset .. n + offset] else a[offset..]);

    return 1;
}

pub fn lua_eqlSlice(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const a_offset = try L.Zcheckvalue(u32, 2, null);
    const b = try Scripting.getReadable(L, 3);
    const b_offset = try L.Zcheckvalue(u32, 4, null);
    const count = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(a_offset, a.len, count orelse 0) or isOutOfBounds(b_offset, b.len, count orelse 0))
        return L.Zerror("access out of bounds");

    L.pushboolean(std.mem.eql(
        u8,
        if (count) |n| a[a_offset .. n + a_offset] else a[a_offset..],
        if (count) |n| b[b_offset .. n + b_offset] else b[b_offset..],
    ));

    return 1;
}

pub fn lua_eql(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const b = try Scripting.getReadable(L, 2);

    L.pushboolean(std.mem.eql(u8, a, b));

    return 1;
}

pub fn lua_startsWith(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    L.pushboolean(std.mem.startsWith(u8, slice, needle));
    return 1;
}

pub fn lua_endsWith(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    L.pushboolean(std.mem.endsWith(u8, slice, needle));
    return 1;
}

pub fn lua_trim(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values_to_strip = try Scripting.getReadable(L, 2);
    try L.Zpushbuffer(std.mem.trim(u8, slice, values_to_strip));
    return 1;
}

pub fn lua_trimStart(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values_to_strip = try Scripting.getReadable(L, 2);
    try L.Zpushbuffer(std.mem.trimStart(u8, slice, values_to_strip));
    return 1;
}

pub fn lua_trimEnd(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values_to_strip = try Scripting.getReadable(L, 2);
    try L.Zpushbuffer(std.mem.trimEnd(u8, slice, values_to_strip));
    return 1;
}

pub fn lua_find(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    if (std.mem.indexOf(u8, slice, needle)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findPos(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const needle = try Scripting.getReadable(L, 3);
    const count = try L.Zcheckvalue(?u32, 4, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (std.mem.indexOf(u8, buf, needle)) |pos|
        L.pushunsigned(@as(u32, @truncate(pos)) + offset)
    else
        L.pushnil();
    return 1;
}

pub fn lua_findLast(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    if (std.mem.lastIndexOf(u8, slice, needle)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findScalar(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    if (std.mem.indexOfScalar(u8, slice, scalar)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findScalarPos(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 3, null));
    const count = try L.Zcheckvalue(?u32, 4, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (std.mem.indexOfScalar(u8, buf, scalar)) |pos|
        L.pushunsigned(@as(u32, @truncate(pos)) + offset)
    else
        L.pushnil();
    return 1;
}

pub fn lua_findScalarLast(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    if (std.mem.lastIndexOfScalar(u8, slice, scalar)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findAny(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values = try Scripting.getReadable(L, 2);
    if (std.mem.indexOfAny(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findAnyPos(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const values = try Scripting.getReadable(L, 3);
    const count = try L.Zcheckvalue(?u32, 4, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (std.mem.indexOfAny(u8, buf, values)) |pos|
        L.pushunsigned(@as(u32, @truncate(pos)) + offset)
    else
        L.pushnil();
    return 1;
}

pub fn lua_findAnyLast(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values = try Scripting.getReadable(L, 2);
    if (std.mem.lastIndexOfAny(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findNone(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values = try Scripting.getReadable(L, 2);
    if (std.mem.indexOfNone(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findNonePos(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const values = try Scripting.getReadable(L, 3);
    const count = try L.Zcheckvalue(?u32, 4, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (std.mem.indexOfNone(u8, buf, values)) |pos|
        L.pushunsigned(@as(u32, @truncate(pos)) + offset)
    else
        L.pushnil();
    return 1;
}

pub fn lua_findNoneLast(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const values = try Scripting.getReadable(L, 2);
    if (std.mem.lastIndexOfNone(u8, slice, values)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findDiff(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const b = try Scripting.getReadable(L, 2);
    if (std.mem.indexOfDiff(u8, a, b)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findDiffPos(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const a_offset = try L.Zcheckvalue(u32, 2, null);
    const b = try Scripting.getReadable(L, 3);
    const b_offset = try L.Zcheckvalue(u32, 4, null);
    const count = try L.Zcheckvalue(?u32, 5, null);
    if (isOutOfBounds(a_offset, a.len, count orelse 0))
        return L.Zerror("access out of bounds");
    if (isOutOfBounds(b_offset, b.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const search_a = if (count) |n| a[a_offset .. a_offset + n] else a[a_offset..];
    const search_b = if (count) |n| b[b_offset .. b_offset + n] else b[b_offset..];
    if (std.mem.indexOfDiff(u8, search_a, search_b)) |pos|
        L.pushunsigned(@as(u32, @truncate(pos)) + a_offset)
    else
        L.pushnil();
    return 1;
}

pub fn lua_findMax(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 3, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (buf.len == 0)
        return L.Zerror("cannot find max of empty slice");
    L.pushunsigned(@as(u32, @truncate(std.mem.indexOfMax(u8, buf))) + offset);
    return 1;
}

pub fn lua_findMin(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 3, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (buf.len == 0)
        return L.Zerror("cannot find min of empty slice");
    L.pushunsigned(@as(u32, @truncate(std.mem.indexOfMin(u8, buf))) + offset);
    return 1;
}

pub fn lua_findMinMax(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 3, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (buf.len == 0)
        return L.Zerror("cannot find min/max of empty slice");
    const min, const max = std.mem.indexOfMinMax(u8, buf);
    L.pushunsigned(@as(u32, @truncate(min)) + offset);
    L.pushunsigned(@as(u32, @truncate(max)) + offset);
    return 2;
}

pub fn lua_cutPrefix(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const prefix = try Scripting.getReadable(L, 2);
    if (std.mem.startsWith(u8, slice, prefix))
        try L.Zpushbuffer(slice[prefix.len..])
    else
        L.pushnil();
    return 1;
}

pub fn lua_cutSuffix(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const suffix = try Scripting.getReadable(L, 2);
    if (std.mem.endsWith(u8, slice, suffix))
        try L.Zpushbuffer(slice[0 .. slice.len - suffix.len])
    else
        L.pushnil();
    return 1;
}

pub fn lua_cut(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    if (std.mem.indexOf(u8, slice, needle)) |index| {
        try L.Zpushbuffer(slice[0..index]);
        try L.Zpushbuffer(slice[index + needle.len ..]);
    } else {
        L.pushnil();
        L.pushnil();
    }
    return 2;
}

pub fn lua_cutLast(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    if (std.mem.lastIndexOf(u8, slice, needle)) |index| {
        try L.Zpushbuffer(slice[0..index]);
        try L.Zpushbuffer(slice[index + needle.len ..]);
    } else {
        L.pushnil();
        L.pushnil();
    }
    return 2;
}

pub fn lua_cutScalar(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    if (std.mem.indexOfScalar(u8, slice, scalar)) |index| {
        try L.Zpushbuffer(slice[0..index]);
        try L.Zpushbuffer(slice[index + 1 ..]);
    } else {
        L.pushnil();
        L.pushnil();
    }
    return 2;
}

pub fn lua_cutScalarLast(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    if (std.mem.lastIndexOfScalar(u8, slice, scalar)) |index| {
        try L.Zpushbuffer(slice[0..index]);
        try L.Zpushbuffer(slice[index + 1 ..]);
    } else {
        L.pushnil();
        L.pushnil();
    }
    return 2;
}

pub fn lua_replaceScalar(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const scalar: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    const replacement: u8 = @truncate(try L.Zcheckvalue(u32, 3, null));
    const offset = try L.Zcheckvalue(?u32, 4, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 5, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    std.mem.replaceScalar(u8, buf, scalar, replacement);
    return 0;
}

pub fn lua_max(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 3, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (buf.len == 0)
        return L.Zerror("cannot find max of empty slice");
    L.pushunsigned(std.mem.max(u8, buf));
    return 1;
}

pub fn lua_min(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 3, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (buf.len == 0)
        return L.Zerror("cannot find min of empty slice");
    L.pushunsigned(std.mem.min(u8, buf));
    return 1;
}

pub fn lua_reverse(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 3, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    std.mem.reverse(u8, buf);
    return 0;
}

pub fn lua_rotate(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const amount = try L.Zcheckvalue(u32, 2, null);
    const offset = try L.Zcheckvalue(?u32, 3, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 4, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    std.mem.rotate(u8, buf, amount);
    return 0;
}

pub fn lua_set(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const value: u8 = @truncate(try L.Zcheckvalue(u32, 2, null));
    const offset = try L.Zcheckvalue(?u32, 3, null) orelse 0;
    const count = try L.Zcheckvalue(?u32, 4, null);

    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");

    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];

    @memset(buf, value);

    return 0;
}

comptime {
    std.debug.assert(@sizeOf(f32) == @sizeOf(u32));
}

pub fn lua_readvectorf32x2(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const F32_SIZE = @sizeOf(f32);

    if (isOutOfBounds(offset, slice.len, 2 * F32_SIZE))
        return L.Zerror("access out of bounds");

    const x = std.mem.readVarInt(u32, slice[offset..][0..F32_SIZE], comptime builtin.cpu.arch.endian());
    const y = std.mem.readVarInt(u32, slice[offset + F32_SIZE ..][0..F32_SIZE], comptime builtin.cpu.arch.endian());

    L.pushvector(
        @as(f32, @bitCast(x)),
        @as(f32, @bitCast(y)),
        0,
    );

    return 1;
}

pub fn lua_readvectorf32x3(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const F32_SIZE = @sizeOf(f32);

    if (isOutOfBounds(offset, slice.len, 3 * F32_SIZE))
        return L.Zerror("access out of bounds");

    const x = std.mem.readVarInt(u32, slice[offset..][0..F32_SIZE], comptime builtin.cpu.arch.endian());
    const y = std.mem.readVarInt(u32, slice[offset + F32_SIZE ..][0..F32_SIZE], comptime builtin.cpu.arch.endian());
    const z = std.mem.readVarInt(u32, slice[offset + 2 * F32_SIZE ..][0..F32_SIZE], comptime builtin.cpu.arch.endian());

    L.pushvector(
        @as(f32, @bitCast(x)),
        @as(f32, @bitCast(y)),
        @as(f32, @bitCast(z)),
    );

    return 1;
}

pub fn lua_writevectorf32x2(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const F32_SIZE = @sizeOf(f32);

    if (isOutOfBounds(offset, slice.len, 2 * F32_SIZE))
        return L.Zerror("access out of bounds");

    const vec = L.tovector(3) orelse return L.Zerror("expected a vector");

    const x: [F32_SIZE]u8 = @bitCast(vec[0]);
    const y: [F32_SIZE]u8 = @bitCast(vec[1]);

    @memcpy(slice[offset..][0..F32_SIZE], x[0..]);
    @memcpy(slice[offset + F32_SIZE ..][0..F32_SIZE], y[0..]);

    return 1;
}

pub fn lua_writevectorf32x3(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const F32_SIZE = @sizeOf(f32);

    if (isOutOfBounds(offset, slice.len, 3 * F32_SIZE))
        return L.Zerror("access out of bounds");

    const vec = L.tovector(3) orelse return L.Zerror("expected a vector");

    const x: [F32_SIZE]u8 = @bitCast(vec[0]);
    const y: [F32_SIZE]u8 = @bitCast(vec[1]);
    const z: [F32_SIZE]u8 = @bitCast(vec[2]);

    @memcpy(slice[offset..][0..F32_SIZE], x[0..]);
    @memcpy(slice[offset + F32_SIZE ..][0..F32_SIZE], y[0..]);
    @memcpy(slice[offset + 2 * F32_SIZE ..][0..F32_SIZE], z[0..]);

    return 1;
}

pub fn lua_readu64(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const U64_SIZE = @sizeOf(u64);

    if (isOutOfBounds(offset, slice.len, U64_SIZE))
        return L.Zerror("access out of bounds");

    var bytes: [U64_SIZE]u8 = undefined;
    @memcpy(bytes[0..], slice[offset..][0..U64_SIZE]);
    const value = std.mem.readInt(u64, &bytes, .little);

    L.Zpushvalue(value) catch |err| switch (err) {
        error.IntegerOverflow => return L.Zerror("integer overflow"),
    };

    return 1;
}

pub fn lua_writeu64(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const U64_SIZE = @sizeOf(u64);

    if (isOutOfBounds(offset, slice.len, U64_SIZE))
        return L.Zerror("access out of bounds");

    const value = try L.Zcheckvalue(u53, 3, null);

    const bytes: [U64_SIZE]u8 = @bitCast(@as(u64, @intCast(value)));
    @memcpy(slice[offset..][0..U64_SIZE], bytes[0..]);

    return 1;
}

pub fn lua_readi64(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const I64_SIZE = @sizeOf(i64);

    if (isOutOfBounds(offset, slice.len, I64_SIZE))
        return L.Zerror("access out of bounds");

    var bytes: [I64_SIZE]u8 = undefined;
    @memcpy(bytes[0..], slice[offset..][0..I64_SIZE]);
    const value = std.mem.readInt(i64, &bytes, .little);

    L.Zpushvalue(value) catch |err| switch (err) {
        error.IntegerOverflow => return L.Zerror("integer overflow"),
    };

    return 1;
}

pub fn lua_writei64(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getWritable(L, 1);
    const offset = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const I64_SIZE = @sizeOf(i64);

    if (isOutOfBounds(offset, slice.len, I64_SIZE))
        return L.Zerror("access out of bounds");

    const value = try L.Zcheckvalue(i54, 3, null);

    const bytes: [I64_SIZE]u8 = @bitCast(@as(i64, @intCast(value)));
    @memcpy(slice[offset..][0..I64_SIZE], bytes[0..]);

    return 1;
}
