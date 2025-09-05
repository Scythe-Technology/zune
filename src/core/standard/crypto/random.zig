const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const VM = luau.VM;

pub fn lua_boolean(L: *VM.lua.State) i32 {
    L.pushboolean(std.crypto.random.boolean());
    return 1;
}

pub fn lua_nextinteger(L: *VM.lua.State) !i32 {
    const min = L.tointeger(1) orelse {
        L.pushinteger(std.crypto.random.int(i32));
        return 1;
    };
    const max = try L.Zcheckvalue(i32, 2, null);
    if (min > max)
        return L.Zerror("invalid range (min > max)");
    L.pushinteger(std.crypto.random.intRangeAtMost(i32, min, max));
    return 1;
}

pub fn lua_nextnumber(L: *VM.lua.State) !i32 {
    const min = L.tonumber(1) orelse {
        L.pushnumber(std.crypto.random.float(f64));
        return 1;
    };
    const max = try L.Zcheckvalue(f64, 2, null);
    if (min > max)
        return L.Zerror("invalid range (min > max)");
    const v = std.crypto.random.float(f64);
    L.pushnumber(min + (v * (max - min)));
    return 1;
}

pub fn lua_fill(L: *VM.lua.State) !i32 {
    const buffer = try L.Zcheckvalue([]u8, 1, null);
    const offset = try L.Zcheckvalue(i32, 2, null);
    const length = try L.Zcheckvalue(i32, 3, null);

    if (offset < 0)
        return L.Zerror("invalid offset (offset < 0)");
    if (length < 0)
        return L.Zerror("invalid length (length < 0)");
    if (offset + length > buffer.len)
        return L.Zerror("invalid length (offset + length > buffer size)");

    std.crypto.random.bytes(buffer[@intCast(offset)..][0..@intCast(length)]);

    return 0;
}
