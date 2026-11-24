const luau = @import("luau");

const Codec = @import("codec.zig");

const VM = luau.VM;

pub fn lua_calcSize(L: *VM.lua.State) !i32 {
    return Codec.calcSize(L, .raw);
}

pub fn lua_compress(L: *VM.lua.State) !i32 {
    return Codec.compress(L, .raw);
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    return Codec.decompress(L, .raw);
}

pub fn lua_createDecompressor(L: *VM.lua.State) !i32 {
    return Codec.createDecompressor(L, .raw);
}

pub fn lua_createCompressor(L: *VM.lua.State) !i32 {
    return Codec.createCompressor(L, .raw);
}
