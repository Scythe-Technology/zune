const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub const LIB_NAME = "hash";

fn feedCrc(comptime Crc: type, L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 1, null);
    var crc = Crc.init();
    if (try L.Zcheckvalue(?u32, 2, "bad crc")) |sum| {
        if (comptime Crc.init().crc == 0)
            crc.crc = sum
        else
            crc.crc = sum ^ 0xFFFFFFFF;
    }
    crc.update(input);
    try L.Zpushvalue(crc.final());
    return 1;
}

pub fn lua_crc32(L: *VM.lua.State) !i32 {
    return feedCrc(std.hash.Crc32, L);
}

pub fn lua_crc32c(L: *VM.lua.State) !i32 {
    return feedCrc(std.hash.crc.@"CRC-32/ISCSI", L);
}

pub fn lua_adler32(L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 1, null);
    var state: std.hash.Adler32 = .{};
    if (try L.Zcheckvalue(?u32, 2, "bad sum")) |sum|
        state.adler = sum;
    state.update(input);
    try L.Zpushvalue(state.adler);
    return 1;
}

pub fn lua_fnv1a32(L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 1, null);
    var state = std.hash.Fnv1a_32.init();
    if (try L.Zcheckvalue(?u32, 2, "bad sum")) |sum|
        state.value = sum;
    state.update(input);
    try L.Zpushvalue(state.final());
    return 1;
}

pub fn lua_xxhash32(L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 1, null);
    const seed = try L.Zcheckvalue(?u32, 2, "bad seed") orelse 0;
    try L.Zpushvalue(std.hash.XxHash32.hash(seed, input));
    return 1;
}

pub fn lua_murmur32(L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 1, null);
    const seed = try L.Zcheckvalue(?u32, 2, "bad seed") orelse 0;
    try L.Zpushvalue(std.hash.murmur.Murmur3_32.hashWithSeed(input, seed));
    return 1;
}

pub fn lua_cityhash32(L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 1, null);
    try L.Zpushvalue(std.hash.CityHash32.hash(input));
    return 1;
}
