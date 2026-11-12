const std = @import("std");
const luau = @import("luau");
const zstd = @import("zstd");

const Zune = @import("zune");

const Codec = @import("codec.zig");

const VM = luau.VM;

fn level(L: *VM.lua.State) !i32 {
    if (L.typeOf(6).isnoneornil())
        return zstd.DEFAULT_COMPRESSION_LEVEL;
    const num = try L.Zcheckvalue(i32, 6, null);
    if (num < zstd.MIN_COMPRESSION_LEVEL or num > zstd.MAX_COMPRESSION_LEVEL)
        return L.Zerrorf("options 'level' must not be over {} or less than {}", .{ zstd.MAX_COMPRESSION_LEVEL, zstd.MIN_COMPRESSION_LEVEL });
    return num;
}

pub fn lua_calcSize(L: *VM.lua.State) !i32 {
    const len = try L.Zcheckvalue(u32, 1, null);
    const bound = zstd.compressBound(len);
    if (bound > std.math.maxInt(u32))
        return L.Zerror("no space");

    try L.Zpushvalue(bound);

    return 1;
}

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const src = try Codec.sourceWindow(L);
    const dest = try Codec.destTail(L);

    const compressed = zstd.compress(dest, src, try level(L)) catch |err| switch (err) {
        error.TooSmallDestSize, error.NoForwardProgressDestFull => return L.Zerror("no space"),
        else => return err,
    };

    try L.Zpushvalue(compressed.len);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = Zune.Runtime.Scheduler.fromState(L).allocator();
    const src = try Codec.sourceWindow(L);
    const dest = try Codec.destTail(L);

    const plain = zstd.decompressAlloc(allocator, src) catch |err| switch (err) {
        error.TooSmallDestSize, error.NoForwardProgressDestFull => return L.Zerror("no space"),
        else => return err,
    };
    defer allocator.free(plain);

    if (plain.len > dest.len)
        return L.Zerror("no space");

    @memcpy(dest[0..plain.len], plain);

    try L.Zpushvalue(plain.len);

    return 1;
}
