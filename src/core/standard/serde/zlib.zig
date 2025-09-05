const std = @import("std");
const luau = @import("luau");
const lcompress = @import("lcompress");

const VM = luau.VM;

const OldWriter = @import("../../utils/old_writer.zig");

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer)
        L.Lcheckbuffer(1)
    else
        L.Lcheckstring(1);
    const options = L.typeOf(2);

    var level: u4 = 12;

    if (!options.isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const levelType = L.rawgetfield(2, "level");
        if (!levelType.isnoneornil()) {
            if (levelType != .Number)
                return L.Zerror("options 'level' field must be a number");
            const num = L.tointeger(-1) orelse unreachable;
            if (num < 4 or num > 13)
                return L.Zerror("options 'level' must not be over 13 or less than 4 or equal to 10");
            if (num == 10)
                return L.Zerrorf("options 'level' cannot be {d}, level does not exist", .{num});
            level = @intCast(num);
        }
        L.pop(1);
    }

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    var stream: std.Io.Reader = .fixed(string);

    try lcompress.zlib.compress(stream.adaptToOldInterface(), OldWriter.adaptToOldInterface(&allocating.writer), .{
        .level = @enumFromInt(level),
    });

    if (is_buffer)
        try L.Zpushbuffer(allocating.written())
    else
        try L.pushlstring(allocating.written());

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer)
        L.Lcheckbuffer(1)
    else
        L.Lcheckstring(1);

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    var stream: std.Io.Reader = .fixed(string);

    try lcompress.zlib.decompress(
        stream.adaptToOldInterface(),
        OldWriter.adaptToOldInterface(&allocating.writer),
    );

    if (is_buffer)
        try L.Zpushbuffer(allocating.written())
    else
        try L.pushlstring(allocating.written());

    return 1;
}
