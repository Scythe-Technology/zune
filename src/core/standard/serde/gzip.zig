const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);
    const options = L.typeOf(2);

    var level: u4 = 12;

    if (!options.isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const levelType = L.rawgetfield(2, "level");
        if (!levelType.isnoneornil()) {
            if (levelType != .Number)
                return L.Zerror("Options 'level' field must be a number");
            const num = L.tointeger(-1) orelse unreachable;
            if (num < 4 or num > 13)
                return L.Zerror("Options 'level' must not be over 13 or less than 4 or equal to 10");
            if (num == 10)
                return L.Zerrorf("Options 'level' cannot be {d}, level does not exist", .{num});
            level = @intCast(num);
        }
        L.pop(1);
    }

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var stream = std.io.fixedBufferStream(string);

    try std.compress.gzip.compress(stream.reader(), buf.writer(), .{
        .level = @enumFromInt(level),
    });

    if (is_buffer) try L.Zpushbuffer(buf.items) else try L.pushlstring(buf.items);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;
    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var stream = std.io.fixedBufferStream(string);

    try std.compress.gzip.decompress(stream.reader(), buf.writer());

    if (is_buffer) try L.Zpushbuffer(buf.items) else try L.pushlstring(buf.items);

    return 1;
}
