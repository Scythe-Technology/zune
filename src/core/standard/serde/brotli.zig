const std = @import("std");
const luau = @import("luau");
const brotli = @import("brotli");

const Zune = @import("zune");

const VM = luau.VM;

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;
    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    var level: u4 = 11;

    if (!L.typeOf(2).isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const levelType = L.rawgetfield(2, "level");
        if (!levelType.isnoneornil()) {
            if (levelType != .Number)
                return L.Zerror("options 'level' field must be a number");
            const num = L.tointeger(-1) orelse unreachable;
            if (num < 0 or num > 11)
                return L.Zerror("options 'level' must not be less than 0 or greater than 11");
            level = @intCast(num);
        }
        L.pop(1);
    }

    const encoder = try brotli.Encoder.init(.{
        .quality = level,
        .window = 22,
    });
    defer encoder.deinit();

    const compressed = try encoder.encode(allocator, string);
    defer allocator.free(compressed);

    if (is_buffer) try L.Zpushbuffer(compressed) else try L.pushlstring(compressed);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    const decoder = try brotli.Decoder.init(.{});
    defer decoder.deinit();

    const decompressed = try decoder.decode(allocator, string);
    defer allocator.free(decompressed);

    if (decompressed.len > Zune.Utils.LuaHelper.MAX_LUAU_SIZE)
        return L.Zerror("decompressed data exceeds maximum string/buffer size");

    if (is_buffer) try L.Zpushbuffer(decompressed) else try L.pushlstring(decompressed);

    return 1;
}
