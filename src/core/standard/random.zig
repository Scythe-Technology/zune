const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const VM = luau.VM;

const tagged = @import("../../tagged.zig");

const TAG_RANDOM = tagged.Tags.get("RANDOM").?;

pub const LIB_NAME = "random";

const LuaRandom = struct {
    algorithm: Algorithm,

    pub const Algorithm = union(enum) {
        LuauPcg32: std.Random.Pcg,
        Isaac64: std.Random.Isaac64,
        Pcg32: std.Random.Pcg,
        Xoroshiro128: std.Random.Xoroshiro128,
        Xoshiro256: std.Random.Xoshiro256,
        Sfc64: std.Random.Sfc64,
        RomuTrio: std.Random.RomuTrio,

        pub fn random(self: *Algorithm) std.Random {
            return switch (self.*) {
                inline else => |*algo| algo.random(),
            };
        }
    };

    fn lua_nextInteger(self: *LuaRandom, L: *VM.lua.State) !i32 {
        const arg0 = try L.Zcheckvalue(i32, 2, null);
        const arg1 = try L.Zcheckvalue(i32, 3, null);
        const min = @min(arg0, arg1);
        const max = @max(arg0, arg1);

        L.pushinteger(self.algorithm.random().intRangeAtMost(i32, min, max));

        return 1;
    }

    fn lua_nextNumber(self: *LuaRandom, L: *VM.lua.State) !i32 {
        const min = try L.Zcheckvalue(?f64, 2, null);
        const max = try L.Zcheckvalue(?f64, 3, null);

        if (min == null or max == null) {
            if (min != null or max != null)
                return L.Zerror("both min and max must be provided");

            L.pushnumber(self.algorithm.random().float(f64));
        } else {
            const value = self.algorithm.random().float(f64);

            if (std.math.isNan(min.?) or std.math.isNan(max.?)) {
                L.pushnumber(std.math.nan(f64));
                return 1;
            }
            if (std.math.isInf(min.?) and std.math.isInf(max.?)) {
                if (min.? > 0 and max.? > 0) {
                    L.pushnumber(std.math.inf(f64));
                } else if (min.? < 0 and max.? < 0) {
                    L.pushnumber(std.math.inf(f64) * -1);
                } else {
                    L.pushnumber(std.math.nan(f64));
                }
                return 1;
            }
            if (std.math.isInf(min.?)) {
                L.pushnumber(min.?);
                return 1;
            }
            if (std.math.isInf(max.?)) {
                L.pushnumber(max.?);
                return 1;
            }

            const i_min = @min(min.?, max.?);
            const i_max = @max(min.?, max.?);

            L.pushnumber(value * (i_max - i_min) + i_min);
        }

        return 1;
    }

    fn lua_clone(self: *LuaRandom, L: *VM.lua.State) !i32 {
        const random = try L.newuserdatataggedwithmetatable(LuaRandom, TAG_RANDOM);
        random.* = .{
            .algorithm = self.algorithm,
        };
        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaRandom, TAG_RANDOM, .{
        .{ "nextInteger", lua_nextInteger },
        .{ "NextInteger", lua_nextInteger },
        .{ "nextNumber", lua_nextNumber },
        .{ "NextNumber", lua_nextInteger },
        .{ "clone", lua_clone },
        .{ "Clone", lua_clone },
    });
};

fn lua_newLuauPcg32(L: *VM.lua.State) !i32 {
    const seed = try L.Zcheckvalue(u32, 1, null);

    var pcg32: std.Random.Pcg = .{
        .s = 0,
        .i = 105,
    };

    var dummy: [4]u8 = undefined;
    pcg32.fill(&dummy);
    pcg32.s += seed;
    pcg32.fill(&dummy);

    const hasher = try L.newuserdatataggedwithmetatable(LuaRandom, TAG_RANDOM);
    hasher.* = .{ .algorithm = .{ .LuauPcg32 = pcg32 } };
    return 1;
}

fn NewGenerator(comptime name: []const u8) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(L: *VM.lua.State) !i32 {
            const seed = try L.Zcheckvalue(u32, 1, null);
            const hasher = try L.newuserdatataggedwithmetatable(LuaRandom, TAG_RANDOM);
            hasher.* = .{ .algorithm = @unionInit(LuaRandom.Algorithm, name, .init(@intCast(seed))) };
            return 1;
        }
    }.inner;
}

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaRandom), .{
            .__metatable = "Metatable is locked",
            .__type = "Random",
        });
        try LuaRandom.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_RANDOM);
    }

    try L.Zpushvalue(.{
        .new = lua_newLuauPcg32,
        .LuauPcg32 = .{ .new = lua_newLuauPcg32 },
        .Pcg32 = .{ .new = NewGenerator("Pcg32") },
        .Isaac64 = .{ .new = NewGenerator("Isaac64") },
        .Xoroshiro128 = .{ .new = NewGenerator("Xoroshiro128") },
        .Xoshiro256 = .{ .new = NewGenerator("Xoshiro256") },
        .Sfc64 = .{ .new = NewGenerator("Sfc64") },
        .RomuTrio = .{ .new = NewGenerator("RomuTrio") },
    });
    L.setreadonly(-1, true);
    try LuaHelper.registerModule(L, LIB_NAME);
}

test "random" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/random.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
