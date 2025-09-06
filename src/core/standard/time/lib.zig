const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");
const builtin = @import("builtin");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const parse = @import("parse.zig");

const VM = luau.VM;

const TAG_DATETIME = Zune.Tags.get("DATETIME").?;

pub const LIB_NAME = "time";
pub fn PlatformSupported() bool {
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
        => return true,
        else => return false,
    }
}

pub const LuaDatetime = struct {
    datetime: time.Datetime,
    timezone: ?time.Timezone,

    fn lua_toIsoDate(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const datetime = self.datetime;
        const utc = if (datetime.isAware())
            try datetime.tzLocalize(null)
        else
            datetime;

        try L.pushfstring("{f}Z", .{utc});

        return 1;
    }

    fn lua_toLocalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const datetime = self.datetime;
        var tz = try time.Timezone.tzLocal(allocator);
        defer tz.deinit();
        const date = if (datetime.isNaive())
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC })
        else
            datetime;
        const local = try date.tzConvert(.{ .tz = &tz });

        try L.Zpushvalue(.{
            .year = local.year,
            .month = local.month,
            .day = local.day,
            .hour = local.hour,
            .minute = local.minute,
            .second = local.second,
            .millisecond = @divFloor(local.nanosecond, std.time.ns_per_ms),
        });

        return 1;
    }

    fn lua_toUniversalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const datetime = self.datetime;
        const utc = if (datetime.isAware())
            try datetime.tzConvert(.{ .tz = &time.Timezone.UTC })
        else
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC });

        try L.Zpushvalue(.{
            .year = utc.year,
            .month = utc.month,
            .day = utc.day,
            .hour = utc.hour,
            .minute = utc.minute,
            .second = utc.second,
            .millisecond = @divFloor(utc.nanosecond, std.time.ns_per_ms),
        });

        return 1;
    }

    fn lua_formatLocalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const datetime = self.datetime;
        const format_str = L.Lcheckstring(2);
        var tz = try time.Timezone.tzLocal(allocator);
        defer tz.deinit();
        const date = if (datetime.isNaive())
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC })
        else
            datetime;
        const local = try date.tzConvert(.{ .tz = &tz });

        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();

        try local.toString(format_str, &allocating.writer);

        try L.pushlstring(allocating.written());

        return 1;
    }

    fn lua_formatUniversalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const datetime = self.datetime;
        const format_str = L.Lcheckstring(2);
        const utc = if (datetime.isAware())
            try datetime.tzConvert(.{ .tz = &time.Timezone.UTC })
        else
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC });

        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();

        try utc.toString(format_str, &allocating.writer);

        try L.pushlstring(allocating.written());

        return 1;
    }

    pub const __namecall = MethodMap.CreateNamecallMap(LuaDatetime, TAG_DATETIME, .{
        .{ "toIsoDate", lua_toIsoDate },
        .{ "toLocalTime", lua_toLocalTime },
        .{ "toUniversalTime", lua_toUniversalTime },
        .{ "formatLocalTime", lua_formatLocalTime },
        .{ "formatUniversalTime", lua_formatUniversalTime },
    });

    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdatatagged(LuaDatetime, 1, TAG_DATETIME) orelse return L.Zerror("expected 'datetime'");

        const index = L.Lcheckstring(2);

        if (std.mem.eql(u8, index, "timestamp")) {
            L.pushnumber(@floatFromInt(ptr.datetime.toUnix(.second)));
            return 1;
        } else if (std.mem.eql(u8, index, "timestamp_millis")) {
            L.pushnumber(@floatFromInt(ptr.datetime.toUnix(.millisecond)));
            return 1;
        }
        return 0;
    }

    pub fn __dtor(_: *VM.lua.State, self: *LuaDatetime) void {
        if (self.timezone) |*tz| {
            tz.deinit();
            self.timezone = null;
        }
    }
};

fn lua_now(L: *VM.lua.State) !i32 {
    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.now(null),
        .timezone = null,
    };
    return 1;
}

fn lua_fromUnixTimestamp(L: *VM.lua.State) !i32 {
    const timestamp = L.Lchecknumber(1);

    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromUnix(@intFromFloat(timestamp), .second, null),
        .timezone = null,
    };
    return 1;
}

fn lua_fromUnixTimestampMillis(L: *VM.lua.State) !i32 {
    const timestamp = L.Lchecknumber(1);

    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromUnix(@intFromFloat(timestamp), .millisecond, null),
        .timezone = null,
    };
    return 1;
}

fn lua_fromUniversalTime(L: *VM.lua.State) !i32 {
    const year = L.Loptinteger(1, 1970);
    const month = L.Loptinteger(2, 1);
    const day = L.Loptinteger(3, 1);
    const hour = L.Loptinteger(4, 0);
    const minute = L.Loptinteger(5, 0);
    const second = L.Loptinteger(6, 0);
    const millisecond = L.Loptinteger(7, 0);

    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
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

fn lua_fromLocalTime(L: *VM.lua.State) !i32 {
    const year = L.Loptinteger(1, 1970);
    const month = L.Loptinteger(2, 1);
    const day = L.Loptinteger(3, 1);
    const hour = L.Loptinteger(4, 0);
    const minute = L.Loptinteger(5, 0);
    const second = L.Loptinteger(6, 0);
    const millisecond = L.Loptinteger(7, 0);

    const allocator = luau.getallocator(L);

    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.timezone = try time.Timezone.tzLocal(allocator);
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

fn lua_fromIsoDate(L: *VM.lua.State) !i32 {
    const iso_date = L.Lcheckstring(1);

    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromISO8601(iso_date),
        .timezone = null,
    };
    return 1;
}

fn lua_parse(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const date_string = L.Lcheckstring(1);

    const self = try L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    try parse.parse(self, allocator, date_string);

    return 1;
}

fn lua_instant_now(L: *VM.lua.State) !i32 {
    const now = try std.time.Instant.now();
    const bytes = try L.newbuffer(12);
    switch (comptime builtin.os.tag) {
        .windows => {
            const qpc = now.timestamp;
            const qpf = std.os.windows.QueryPerformanceFrequency();

            // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
            // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
            const common_qpf = 10_000_000;
            if (qpf == common_qpf) {
                const ns = qpc * (std.time.ns_per_s / common_qpf);
                const float_bytes: [8]u8 = @bitCast(@as(f64, @floatFromInt(ns / std.time.ns_per_s)));
                @memcpy(bytes[0..8], &float_bytes);
                const int_bytes: [4]u8 = @bitCast(@as(u32, @intCast(ns % std.time.ns_per_s)));
                @memcpy(bytes[8..12], &int_bytes);
            } else {
                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const since = @as(u96, qpc) * scale;
                const result = since >> 32;
                const float_bytes: [8]u8 = @bitCast(@as(f64, @floatFromInt(result / std.time.ns_per_s)));
                @memcpy(bytes[0..8], &float_bytes);
                const int_bytes: [4]u8 = @bitCast(@as(u32, @intCast(result % std.time.ns_per_s)));
                @memcpy(bytes[8..12], &int_bytes);
            }
        },
        else => {
            const float_bytes: [8]u8 = @bitCast(@as(f64, @floatFromInt(now.timestamp.sec)));
            @memcpy(bytes[0..8], &float_bytes);
            const int_bytes: [4]u8 = @bitCast(@as(u32, @intCast(now.timestamp.nsec)));
            @memcpy(bytes[8..12], &int_bytes);
        },
    }
    return 1;
}

fn lua_timestamp(L: *VM.lua.State) !i32 {
    L.pushnumber(@floatFromInt(std.time.timestamp()));
    return 1;
}

fn lua_timestampMillis(L: *VM.lua.State) !i32 {
    L.pushnumber(@floatFromInt(std.time.milliTimestamp()));
    return 1;
}

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaDatetime), .{
            .__index = LuaDatetime.__index,
            .__namecall = LuaDatetime.__namecall,
            .__metatable = "Metatable is locked",
            .__type = "Datetime",
        });
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_DATETIME);
        L.setuserdatadtor(LuaDatetime, TAG_DATETIME, LuaDatetime.__dtor);
    }

    try L.Zpushvalue(.{
        .date = .{
            .now = lua_now,
            .parse = lua_parse,
            .fromIsoDate = lua_fromIsoDate,
            .fromUniversalTime = lua_fromUniversalTime,
            .fromLocalTime = lua_fromLocalTime,
            .fromUnixTimestamp = lua_fromUnixTimestamp,
            .fromUnixTimestampMillis = lua_fromUnixTimestampMillis,
        },
        .instant = .{
            .now = lua_instant_now,
        },
        .timestamp = lua_timestamp,
        .timestampMillis = lua_timestampMillis,
    });
    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = parse;
}

test "time" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/time.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
