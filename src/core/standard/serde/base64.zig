const std = @import("std");
const yaml = @import("yaml");
const luau = @import("luau");

const VM = luau.VM;

pub fn lua_encode(L: *VM.lua.State) !i32 {
    const string = try L.Zcheckvalue([]const u8, 1, null);

    const allocator = luau.getallocator(L);

    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(string.len));
    defer allocator.free(out);

    const encoded = std.base64.standard.Encoder.encode(out, string);

    if (L.typeOf(1) == .Buffer)
        try L.Zpushbuffer(encoded)
    else
        try L.pushlstring(encoded);

    return 1;
}

pub fn lua_decode(L: *VM.lua.State) !i32 {
    const string = try L.Zcheckvalue([]const u8, 1, null);

    const allocator = luau.getallocator(L);

    const out = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(string));
    defer allocator.free(out);

    try std.base64.standard.Decoder.decode(out, string);

    if (L.typeOf(1) == .Buffer)
        try L.Zpushbuffer(out)
    else
        try L.pushlstring(out);

    return 1;
}
