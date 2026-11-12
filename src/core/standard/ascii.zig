const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

pub const LIB_NAME = "ascii";

inline fn isOutOfBounds(offset: u32, len: usize, access: usize) bool {
    return access + offset > len;
}

pub fn lua_eqlIgnoreCaseSlice(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const a_offset = try L.Zcheckvalue(u32, 2, null);
    const b = try Scripting.getReadable(L, 3);
    const b_offset = try L.Zcheckvalue(u32, 4, null);
    const count = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(a_offset, a.len, count orelse 0) or isOutOfBounds(b_offset, b.len, count orelse 0))
        return L.Zerror("access out of bounds");

    L.pushboolean(std.ascii.eqlIgnoreCase(
        if (count) |n| a[a_offset .. n + a_offset] else a[a_offset..],
        if (count) |n| b[b_offset .. n + b_offset] else b[b_offset..],
    ));

    return 1;
}

pub fn lua_eqlIgnoreCase(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const b = try Scripting.getReadable(L, 2);

    L.pushboolean(std.ascii.eqlIgnoreCase(a, b));

    return 1;
}

pub fn lua_startsWithIgnoreCase(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    L.pushboolean(std.ascii.startsWithIgnoreCase(slice, needle));
    return 1;
}

pub fn lua_endsWithIgnoreCase(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    L.pushboolean(std.ascii.endsWithIgnoreCase(slice, needle));
    return 1;
}

pub fn lua_findIgnoreCase(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const needle = try Scripting.getReadable(L, 2);
    if (std.ascii.findIgnoreCase(slice, needle)) |pos|
        L.pushunsigned(@truncate(pos))
    else
        L.pushnil();
    return 1;
}

pub fn lua_findIgnoreCasePos(L: *VM.lua.State) !i32 {
    const slice = try Scripting.getReadable(L, 1);
    const offset = try L.Zcheckvalue(u32, 2, null);
    const needle = try Scripting.getReadable(L, 3);
    const count = try L.Zcheckvalue(?u32, 4, null);
    if (isOutOfBounds(offset, slice.len, count orelse 0))
        return L.Zerror("access out of bounds");
    const buf = if (count) |n| slice[offset .. offset + n] else slice[offset..];
    if (std.ascii.findIgnoreCase(buf, needle)) |pos|
        L.pushunsigned(@as(u32, @truncate(pos)) + offset)
    else
        L.pushnil();
    return 1;
}

pub fn lua_lessThanIgnoreCaseSlice(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const a_offset = try L.Zcheckvalue(u32, 2, null);
    const b = try Scripting.getReadable(L, 3);
    const b_offset = try L.Zcheckvalue(u32, 4, null);
    const count = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(a_offset, a.len, count orelse 0) or isOutOfBounds(b_offset, b.len, count orelse 0))
        return L.Zerror("access out of bounds");

    L.pushboolean(std.ascii.lessThanIgnoreCase(
        if (count) |n| a[a_offset .. n + a_offset] else a[a_offset..],
        if (count) |n| b[b_offset .. n + b_offset] else b[b_offset..],
    ));

    return 1;
}

pub fn lua_lessThanIgnoreCase(L: *VM.lua.State) !i32 {
    const a = try Scripting.getReadable(L, 1);
    const b = try Scripting.getReadable(L, 2);

    L.pushboolean(std.ascii.lessThanIgnoreCase(a, b));

    return 1;
}
