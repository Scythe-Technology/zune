const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

const Codec = @import("codec.zig");

const VM = luau.VM;

fn destWindow(L: *VM.lua.State, need: usize) ![]u8 {
    const dest = try Scripting.getWritable(L, 1);
    const dest_offset = try L.Zcheckvalue(u32, 2, null);
    if (dest_offset > dest.len)
        return L.Zerror("access out of bounds");
    if (dest.len - dest_offset < need)
        return L.Zerror("no space");

    return dest[dest_offset..][0..need];
}

pub fn lua_calcSize(L: *VM.lua.State) !i32 {
    const len = try L.Zcheckvalue(u32, 1, null);
    L.pushunsigned(@intCast(std.base64.standard.Encoder.calcSize(len)));
    return 1;
}

pub fn lua_encode(L: *VM.lua.State) !i32 {
    const src = try Codec.sourceWindow(L);
    const need = std.base64.standard.Encoder.calcSize(src.len);
    const dest = try destWindow(L, need);
    const encoded = std.base64.standard.Encoder.encode(dest, src);
    L.pushunsigned(@intCast(encoded.len));
    return 1;
}

pub fn lua_decode(L: *VM.lua.State) !i32 {
    const src = try Codec.sourceWindow(L);
    const need = try std.base64.standard.Decoder.calcSizeForSlice(src);
    const dest = try destWindow(L, need);
    try std.base64.standard.Decoder.decode(dest, src);
    L.pushunsigned(@intCast(need));
    return 1;
}
