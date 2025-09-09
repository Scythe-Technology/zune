const std = @import("std");
const luau = @import("luau");
const lz4 = @import("lz4");

const Zune = @import("zune");

const VM = luau.VM;

// Lune compatibility

pub fn lua_frame_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer)
        L.Lcheckbuffer(1)
    else
        L.Lcheckstring(1);

    var level: u32 = 4;

    if (!L.typeOf(2).isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const levelType = L.rawgetfield(2, "level");
        if (!levelType.isnoneornil()) {
            if (levelType != .Number)
                return L.Zerror("options 'level' field must be a number");
            const num = L.tointeger(-1) orelse unreachable;
            if (num < 0)
                return L.Zerror("options 'level' must not be less than 0");
            level = @intCast(num);
        }
        L.pop(1);
    }

    var encoder = try lz4.Encoder.init(allocator);
    _ = encoder.setLevel(level)
        .setContentChecksum(lz4.Frame.ContentChecksum.Enabled)
        .setBlockMode(lz4.Frame.BlockMode.Independent);
    defer encoder.deinit();

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    try encoder.compressStream(&allocating.writer, string);

    const written = allocating.written();

    const out = try allocator.alloc(u8, written.len + 4);
    defer allocator.free(out);

    const header: [4]u8 = @bitCast(@as(u32, @intCast(string.len)));
    @memcpy(out[0..4], header[0..4]);
    @memcpy(out[4..][0..written.len], written[0..]);

    if (is_buffer)
        try L.Zpushbuffer(out)
    else
        try L.pushlstring(out);

    return 1;
}

pub fn lua_frame_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    if (string.len < 4)
        return L.Zerror("invalid header");

    var decoder = try lz4.Decoder.init(allocator);
    defer decoder.deinit();

    const sizeHint = std.mem.bytesAsSlice(u32, string[0..4])[0];

    const decompressed = try decoder.decompress(string[4..], sizeHint);
    defer allocator.free(decompressed);

    if (decompressed.len > Zune.Utils.LuaHelper.MAX_LUAU_SIZE)
        return L.Zerror("decompressed data exceeds maximum string/buffer size");

    if (is_buffer) try L.Zpushbuffer(decompressed) else try L.pushlstring(decompressed);

    return 1;
}

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;
    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    const compressed = try lz4.Standard.compress(allocator, string);
    defer allocator.free(compressed);

    if (is_buffer) try L.Zpushbuffer(compressed) else try L.pushlstring(compressed);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);
    const sizeHint = try L.Zcheckvalue(i32, 2, null);

    const decompressed = try lz4.Standard.decompress(allocator, string, @intCast(sizeHint));
    defer allocator.free(decompressed);

    if (decompressed.len > Zune.Utils.LuaHelper.MAX_LUAU_SIZE)
        return L.Zerror("decompressed data exceeds maximum string/buffer size");

    if (is_buffer) try L.Zpushbuffer(decompressed) else try L.pushlstring(decompressed);

    return 1;
}
