const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const parse = @import("parse.zig");

const VM = luau.VM;

const Datetime = Zune.objects.Datetime;

pub const LIB_NAME = "time";
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    switch (comptime builtin.cpu.arch) {
        .x86_64,
        .aarch64,
        .aarch64_be,
        .riscv64,
        .wasm64,
        .powerpc64,
        .powerpc64le,
        .loongarch64,
        .mips64,
        .mips64el,
        .spirv64,
        .sparc64,
        .nvptx64,
        => return .Full,
        else => return null,
    }
}

pub const lua_date = struct {
    pub fn lua_now(L: *VM.lua.State) !i32 {
        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        self.* = .{
            .datetime = try time.Datetime.now(Zune.io(), null),
            .timezone = null,
        };
        return 1;
    }

    pub fn lua_parse(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator();
        const date_string = L.Lcheckstring(1);

        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        try parse.parse(self, allocator, date_string);

        return 1;
    }

    pub fn lua_fromUnixTimestamp(L: *VM.lua.State) !i32 {
        const timestamp = L.Lchecknumber(1);

        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        self.* = .{
            .datetime = try time.Datetime.fromUnix(@intFromFloat(timestamp), .second, null),
            .timezone = null,
        };
        return 1;
    }

    pub fn lua_fromUnixTimestampMillis(L: *VM.lua.State) !i32 {
        const timestamp = L.Lchecknumber(1);

        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        self.* = .{
            .datetime = try time.Datetime.fromUnix(@intFromFloat(timestamp), .millisecond, null),
            .timezone = null,
        };
        return 1;
    }

    pub fn lua_fromUniversalTime(L: *VM.lua.State) !i32 {
        const year = L.Loptinteger(1, 1970);
        const month = L.Loptinteger(2, 1);
        const day = L.Loptinteger(3, 1);
        const hour = L.Loptinteger(4, 0);
        const minute = L.Loptinteger(5, 0);
        const second = L.Loptinteger(6, 0);
        const millisecond = L.Loptinteger(7, 0);

        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        self.* = .{
            .datetime = try time.Datetime.fromFields(.{
                .year = @intCast(year),
                .month = @intCast(month),
                .day = @intCast(day),
                .hour = @intCast(hour),
                .minute = @intCast(minute),
                .second = @intCast(second),
                .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
            }),
            .timezone = null,
        };
        return 1;
    }

    pub fn lua_fromLocalTime(L: *VM.lua.State) !i32 {
        const year = L.Loptinteger(1, 1970);
        const month = L.Loptinteger(2, 1);
        const day = L.Loptinteger(3, 1);
        const hour = L.Loptinteger(4, 0);
        const minute = L.Loptinteger(5, 0);
        const second = L.Loptinteger(6, 0);
        const millisecond = L.Loptinteger(7, 0);

        const allocator = Scheduler.fromState(L).allocator();

        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        self.timezone = try time.Timezone.tzLocal(Zune.io(), allocator);
        errdefer {
            self.timezone.?.deinit();
            self.timezone = null;
        }
        self.datetime = try time.Datetime.fromFields(.{
            .year = @intCast(year),
            .month = @intCast(month),
            .day = @intCast(day),
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
            .tz_options = if (self.timezone) |*tz| .{ .tz = tz } else null,
        });
        return 1;
    }

    pub fn lua_fromIsoDate(L: *VM.lua.State) !i32 {
        const iso_date = L.Lcheckstring(1);

        const self = try L.newuserdatataggedwithmetatable(Datetime, Datetime.OBJECT_TAG);
        self.* = .{
            .datetime = try time.Datetime.fromISO8601(iso_date),
            .timezone = null,
        };
        return 1;
    }
};

pub const lua_instant = struct {
    pub fn lua_now(L: *VM.lua.State) !i32 {
        const now_ts = std.Io.Clock.now(.awake, Zune.io());
        const bytes = try L.newbuffer(12);
        const ns = now_ts.nanoseconds;
        const sec: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
        const nsec: u32 = @intCast(@mod(ns, std.time.ns_per_s));
        const float_bytes: [8]u8 = @bitCast(@as(f64, @floatFromInt(sec)));
        @memcpy(bytes[0..8], &float_bytes);
        const int_bytes: [4]u8 = @bitCast(nsec);
        @memcpy(bytes[8..12], &int_bytes);
        return 1;
    }
};

pub const lua_process = struct {
    pub fn lua_now(L: *VM.lua.State) !i32 {
        const us = std.Io.Clock.now(.cpu_process, Zune.io()).nanoseconds;
        L.pushnumber(@as(f64, @floatFromInt(us)) / std.time.ns_per_s);
        return 1;
    }
};

pub const lua_thread = struct {
    pub fn lua_now(L: *VM.lua.State) !i32 {
        const ns = std.Io.Clock.now(.cpu_thread, Zune.io()).nanoseconds;
        L.pushnumber(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s);
        return 1;
    }
};

pub fn lua_timestamp(L: *VM.lua.State) !i32 {
    const ns = std.Io.Clock.now(.real, Zune.io()).nanoseconds;
    L.pushnumber(@floatFromInt(@divTrunc(ns, std.time.ns_per_s)));
    return 1;
}

pub fn lua_timestampMillis(L: *VM.lua.State) !i32 {
    const ns = std.Io.Clock.now(.real, Zune.io()).nanoseconds;
    L.pushnumber(@floatFromInt(@divTrunc(ns, std.time.ns_per_ms)));
    return 1;
}

test {
    if (comptime PlatformSupported() == null) return error.SkipZigTest;

    _ = parse;
}
