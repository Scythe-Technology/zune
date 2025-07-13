const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;

const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const base64 = @import("base64.zig");

const gzip = @import("gzip.zig");
const zlib = @import("zlib.zig");
const flate = @import("flate.zig");
const lz4 = @import("lz4.zig");
const zstd = @import("zstd.zig");

const VM = luau.VM;

pub const LIB_NAME = "serde";

pub fn loadLib(L: *VM.lua.State) void {
    L.createtable(0, 10);

    { // Json
        L.createtable(0, 4);

        L.Zsetfieldfn(-1, "encode", json.LuaEncoder(.JSON));
        L.Zsetfieldfn(-1, "decode", json.LuaDecoder(.JSON));

        json.lua_setprops(L);

        L.setreadonly(-1, true);
        L.setfield(-2, "json");
    }

    { // Json5
        L.createtable(0, 4);

        L.Zsetfieldfn(-1, "encode", json.LuaEncoder(.JSON5));
        L.Zsetfieldfn(-1, "decode", json.LuaDecoder(.JSON5));

        _ = L.rawgetfield(-2, "json");

        _ = L.rawgetfield(-1, "indents");
        L.setfield(-3, "indents");

        _ = L.rawgetfield(-1, "values");
        L.setfield(-3, "values");

        L.pop(1);

        L.setreadonly(-1, true);
        L.setfield(-2, "json5");
    }

    { // Toml
        L.Zpushvalue(.{
            .encode = toml.lua_encode,
            .decode = toml.lua_decode,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "toml");
    }

    { // Yaml
        L.Zpushvalue(.{
            .encode = yaml.lua_encode,
            .decode = yaml.lua_decode,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "yaml");
    }

    { // Base64
        L.Zpushvalue(.{
            .encode = base64.lua_encode,
            .decode = base64.lua_decode,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "base64");
    }

    { // Gzip
        L.Zpushvalue(.{
            .compress = gzip.lua_compress,
            .decompress = gzip.lua_decompress,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "gzip");
    }

    { // Zlib
        L.Zpushvalue(.{
            .compress = zlib.lua_compress,
            .decompress = zlib.lua_decompress,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "zlib");
    }

    { // Flate
        L.Zpushvalue(.{
            .compress = flate.lua_compress,
            .decompress = flate.lua_decompress,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "flate");
    }

    { // Lz4
        L.Zpushvalue(.{
            .compress = lz4.lua_compress,
            .compressFrame = lz4.lua_frame_compress,
            .decompress = lz4.lua_decompress,
            .decompressFrame = lz4.lua_frame_decompress,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "lz4");
    }

    { // Zstd
        L.Zpushvalue(.{
            .compress = zstd.lua_compress,
            .decompress = zstd.lua_decompress,
        });
        L.setreadonly(-1, true);

        L.setfield(-2, "zstd");
    }

    L.setreadonly(-1, true);

    LuaHelper.registerModule(L, LIB_NAME);
}

test {
    std.testing.refAllDecls(@This());
}

test "serde" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/serde/init.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
