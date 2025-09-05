const std = @import("std");
const luau = @import("luau");
const zstd = @import("zstd");

const VM = luau.VM;

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer)
        L.Lcheckbuffer(1)
    else
        L.Lcheckstring(1);
    const options = L.typeOf(2);

    var level: i32 = zstd.DEFAULT_COMPRESSION_LEVEL;

    if (!options.isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const levelType = L.rawgetfield(2, "level");
        if (!levelType.isnoneornil()) {
            if (levelType != .Number)
                return L.Zerror("options 'level' field must be a number");
            const num = L.tointeger(-1) orelse unreachable;
            if (num < zstd.MIN_COMPRESSION_LEVEL or num > zstd.MAX_COMPRESSION_LEVEL)
                return L.Zerrorf("options 'level' must not be over {} or less than {}", .{ zstd.MAX_COMPRESSION_LEVEL, zstd.MIN_COMPRESSION_LEVEL });
            level = num;
        }
        L.pop(1);
    }

    const compressed = try zstd.compressAlloc(allocator, string, level);
    defer allocator.free(compressed);

    if (is_buffer)
        try L.Zpushbuffer(compressed)
    else
        try L.pushlstring(compressed);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer)
        L.Lcheckbuffer(1)
    else
        L.Lcheckstring(1);

    const decompressed = try zstd.decompressAlloc(allocator, string);
    defer allocator.free(decompressed);

    if (is_buffer)
        try L.Zpushbuffer(decompressed)
    else
        try L.pushlstring(decompressed);

    return 1;
}
