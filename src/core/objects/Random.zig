const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const VM = luau.VM;

const Random = @This();

pub const OBJECT_TAG = Zune.Tags.get("RANDOM").?;

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

pub fn lua_nextInteger(self: *Random, L: *VM.lua.State) !i32 {
    const arg0 = try L.Zcheckvalue(i32, 2, null);
    const arg1 = try L.Zcheckvalue(i32, 3, null);
    const min = @min(arg0, arg1);
    const max = @max(arg0, arg1);

    L.pushinteger(self.algorithm.random().intRangeAtMost(i32, min, max));

    return 1;
}

pub fn lua_nextNumber(self: *Random, L: *VM.lua.State) !i32 {
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

pub fn lua_nextBoolean(self: *Random, L: *VM.lua.State) !i32 {
    L.pushboolean(self.algorithm.random().boolean());
    return 1;
}

pub fn lua_clone(self: *Random, L: *VM.lua.State) !i32 {
    _ = try create(L, self.algorithm);
    return 1;
}

pub fn create(L: *VM.lua.State, algo: Algorithm) !*Random {
    const random = try L.newuserdatataggedwithmetatable(Random, OBJECT_TAG);
    random.* = .{ .algorithm = algo };
    return random;
}
