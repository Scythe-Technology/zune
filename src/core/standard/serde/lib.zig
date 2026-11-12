const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

pub const lua_toml = @import("toml.zig");
pub const lua_yaml = @import("yaml.zig");
pub const lua_base64 = @import("base64.zig");

pub const lua_gzip = @import("gzip.zig");
pub const lua_zlib = @import("zlib.zig");
pub const lua_flate = @import("flate.zig");
pub const lua_lz4 = @import("lz4.zig");
pub const lua_zstd = @import("zstd.zig");

const VM = luau.VM;

pub const LIB_NAME = "serde";

const json = @import("json.zig");
pub const lua_json = struct {
    pub const lua_custom_null = json.pushNullValue;

    pub const lua_encode = json.LuaEncoder(.JSON);
    pub const lua_decode = json.LuaDecoder(.JSON);
};

pub const lua_json5 = struct {
    pub const lua_custom_null = json.pushNullValue;

    pub const lua_encode = json.LuaEncoder(.JSON5);
    pub const lua_decode = json.LuaDecoder(.JSON5);
};

test {
    _ = json;
    _ = lua_toml;
    _ = lua_yaml;
    _ = lua_base64;
    _ = lua_gzip;
    _ = lua_zlib;
    _ = lua_flate;
    _ = lua_lz4;
    _ = lua_zstd;
}
