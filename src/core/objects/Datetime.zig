const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Datetime = @This();

pub const OBJECT_TAG = Zune.Tags.get("DATETIME").?;

datetime: time.Datetime,
timezone: ?time.Timezone,

pub fn lua_toIsoDate(self: *Datetime, L: *VM.lua.State) !i32 {
    const datetime = self.datetime;
    const utc = if (datetime.isAware())
        try datetime.tzLocalize(null)
    else
        datetime;

    try L.pushfstring("{f}Z", .{utc});

    return 1;
}

pub fn lua_toLocalTime(self: *Datetime, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const datetime = self.datetime;
    var tz = try time.Timezone.tzLocal(Zune.io(), allocator);
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

pub fn lua_toUniversalTime(self: *Datetime, L: *VM.lua.State) !i32 {
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

pub fn lua_formatLocalTime(self: *Datetime, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const datetime = self.datetime;
    const format_str = L.Lcheckstring(2);
    var tz = try time.Timezone.tzLocal(Zune.io(), allocator);
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

pub fn lua_formatUniversalTime(self: *Datetime, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

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

pub fn lua_direct_timestamp(self: *Datetime, res: *VM.lobject.TValue) void {
    res.setnvalue(@floatFromInt(self.datetime.toUnix(.second)));
}

pub fn lua_direct_timestamp_millis(self: *Datetime, res: *VM.lobject.TValue) void {
    res.setnvalue(@floatFromInt(self.datetime.toUnix(.millisecond)));
}

pub fn __dtor(_: *VM.lua.State, self: *Datetime) void {
    if (self.timezone) |*tz| {
        tz.deinit();
        self.timezone = null;
    }
}
