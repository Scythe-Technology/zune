const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Random = Zune.objects.Random;

pub const LIB_NAME = "random";

fn defaultSeed(L: *VM.lua.State) u64 {
    var default_seed: u64 = @intFromPtr(L);
    const ns = std.Io.Clock.now(.real, Zune.io()).nanoseconds;
    default_seed ^= @as(u64, @truncate(@as(u96, @bitCast(ns))));
    default_seed ^= @intFromFloat(VM.lperf.clock());
    return default_seed;
}

pub const lua_LuauPcg32 = struct {
    pub fn lua_new(L: *VM.lua.State) !i32 {
        const seed = try L.Zcheckvalue(?u32, 1, null) orelse defaultSeed(L);

        var pcg32: std.Random.Pcg = .{
            .s = 0,
            .i = 105,
        };

        var dummy: [4]u8 = undefined;
        pcg32.fill(&dummy);
        pcg32.s += seed;
        pcg32.fill(&dummy);

        _ = try Random.create(L, .{ .LuauPcg32 = pcg32 });
        return 1;
    }
};

pub const lua_Pcg32 = struct {
    pub const lua_new = NewGenerator("Pcg32");
};

pub const lua_Isaac64 = struct {
    pub const lua_new = NewGenerator("Isaac64");
};

pub const lua_Xoroshiro128 = struct {
    pub const lua_new = NewGenerator("Xoroshiro128");
};

pub const lua_Xoshiro256 = struct {
    pub const lua_new = NewGenerator("Xoshiro256");
};

pub const lua_Sfc64 = struct {
    pub const lua_new = NewGenerator("Sfc64");
};

pub const lua_RomuTrio = struct {
    pub const lua_new = NewGenerator("RomuTrio");
};

pub const lua_new = lua_LuauPcg32.lua_new;

fn NewGenerator(comptime name: []const u8) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(L: *VM.lua.State) !i32 {
            const seed: u64 = try L.Zcheckvalue(?u32, 1, null) orelse defaultSeed(L);
            _ = try Random.create(L, @unionInit(Random.Algorithm, name, .init(@intCast(seed))));
            return 1;
        }
    }.inner;
}
