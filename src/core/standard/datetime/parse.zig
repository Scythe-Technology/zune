const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");

const LuaDatetime = @import("lib.zig").LuaDatetime;

const Month = enum {
    Jan,
    Feb,
    Mar,
    Apr,
    May,
    Jun,
    Jul,
    Aug,
    Sep,
    Oct,
    Nov,
    Dec,
};

const MonthMap = std.StaticStringMap(Month).initComptime(.{
    .{ "jan", Month.Jan },
    .{ "feb", Month.Feb },
    .{ "mar", Month.Mar },
    .{ "apr", Month.Apr },
    .{ "may", Month.May },
    .{ "jun", Month.Jun },
    .{ "jul", Month.Jul },
    .{ "aug", Month.Aug },
    .{ "sep", Month.Sep },
    .{ "oct", Month.Oct },
    .{ "nov", Month.Nov },
    .{ "dec", Month.Dec },
});

// in the format "<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT"
// eg, "Wed, 21 Oct 2015 07:28:00 GMT"
pub fn parseModified(self: *LuaDatetime, allocator: std.mem.Allocator, timestring: []const u8) !void {
    const value = std.mem.trim(u8, timestring, " ");
    if (value.len < 29)
        return error.InvalidFormat;

    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidFormat;

    const lower_month = try std.ascii.allocLowerString(allocator, value[8..11]);
    defer allocator.free(lower_month);

    const month = @intFromEnum(MonthMap.get(lower_month) orelse return error.InvalidFormat) + 1;
    const year = std.fmt.parseInt(u16, value[12..16], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return error.InvalidFormat;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return error.InvalidFormat;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return error.InvalidFormat;

    const tz = std.mem.trim(u8, value[26..], " ");
    if (tz.len != 3)
        return error.InvalidFormat;

    self.timezone = try time.Timezone.fromTzdata(tz, allocator);
    errdefer {
        self.timezone.?.deinit();
        self.timezone = null;
    }
    self.datetime = try time.Datetime.fromFields(.{
        .day = day,
        .month = month,
        .year = @intCast(year),
        .hour = hour,
        .minute = minute,
        .second = second,
        .tz_options = if (self.timezone) |*t| .{ .tz = t } else null,
    });
}

// in the format "<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT"
// eg, "21 Oct 2015 07:28:00 GMT"
pub fn parseModifiedShort(self: *LuaDatetime, allocator: std.mem.Allocator, timestring: []const u8) !void {
    const value = std.mem.trim(u8, timestring, " ");
    if (value.len < 24)
        return error.InvalidFormat;

    const day = std.fmt.parseInt(u8, value[0..2], 10) catch return error.InvalidFormat;

    const lower_month = try std.ascii.allocLowerString(allocator, value[3..6]);
    defer allocator.free(lower_month);

    const month = @intFromEnum(MonthMap.get(lower_month) orelse return error.InvalidFormat) + 1;
    const year = std.fmt.parseInt(u16, value[7..11], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, value[12..14], 10) catch return error.InvalidFormat;
    const minute = std.fmt.parseInt(u8, value[15..17], 10) catch return error.InvalidFormat;
    const second = std.fmt.parseInt(u8, value[18..20], 10) catch return error.InvalidFormat;

    const tz = std.mem.trim(u8, value[21..], " ");
    if (tz.len != 3)
        return error.InvalidFormat;

    self.timezone = try time.Timezone.fromTzdata(tz, allocator);
    errdefer {
        self.timezone.?.deinit();
        self.timezone = null;
    }
    self.datetime = try time.Datetime.fromFields(.{
        .day = day,
        .month = month,
        .year = @intCast(year),
        .hour = hour,
        .minute = minute,
        .second = second,
        .tz_options = if (self.timezone) |*t| .{ .tz = t } else null,
    });
}

pub fn parse(self: *LuaDatetime, allocator: std.mem.Allocator, str: []const u8) !void {
    const trimmed = std.mem.trimLeft(u8, std.mem.trimRight(u8, str, " "), " ");
    if (std.mem.indexOfScalar(u8, trimmed, '-') == null) {
        if (str.len < 29)
            return parseModifiedShort(self, allocator, trimmed);
        return parseModified(self, allocator, trimmed);
    } else {
        self.* = .{
            .datetime = try time.Datetime.fromISO8601(trimmed),
            .timezone = null,
        };
    }
}

const testing = std.testing;
test "Timeparse" {
    {
        var result: LuaDatetime = undefined;
        try parse(&result, testing.allocator, "Wed, 21 Oct 2015 07:28:00 GMT");
        defer LuaDatetime.__dtor(undefined, &result);
        const datetime = result.datetime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("GMT", result.timezone.?.name());
    }
    {
        var result: LuaDatetime = undefined;
        try parse(&result, testing.allocator, "Wed, 21 Oct 2015 07:28:00 UTC");
        defer LuaDatetime.__dtor(undefined, &result);
        const datetime = result.datetime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("UTC", result.timezone.?.name());
    }
    {
        var result: LuaDatetime = undefined;
        try testing.expectError(error.DayOutOfRange, parse(&result, testing.allocator, "Wed, 33 Oct 2015 07:28:00 GMT"));
        try testing.expectError(error.InvalidFormat, parse(&result, testing.allocator, "Wed, 21 Abc 2015 07:28:00 GMT"));
    }

    {
        var result: LuaDatetime = undefined;
        try parse(&result, testing.allocator, "21 Oct 2015 07:28:00 GMT");
        defer LuaDatetime.__dtor(undefined, &result);
        const datetime = result.datetime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("GMT", result.timezone.?.name());
    }
    {
        var result: LuaDatetime = undefined;
        try parse(&result, testing.allocator, "21 Oct 2015 07:28:00 UTC");
        defer LuaDatetime.__dtor(undefined, &result);
        const datetime = result.datetime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("UTC", result.timezone.?.name());
    }

    {
        var result: LuaDatetime = undefined;
        try testing.expectError(error.DayOutOfRange, parse(&result, testing.allocator, "33 Oct 2015 07:28:00 GMT"));
        try testing.expectError(error.InvalidFormat, parse(&result, testing.allocator, "21 Abc 2015 07:28:00 GMT"));
    }

    {
        var result: LuaDatetime = undefined;
        try parse(&result, testing.allocator, "2015-10-21T07:28:00Z");
        defer LuaDatetime.__dtor(undefined, &result);
        const datetime = result.datetime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone == null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("UTC", datetime.tz.?.name());
    }
    {
        var result: LuaDatetime = undefined;
        try parse(&result, testing.allocator, "2015-10-21T07:28:00");
        defer LuaDatetime.__dtor(undefined, &result);
        const datetime = result.datetime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone == null);
        try testing.expect(datetime.tz == null);
    }
    {
        var result: LuaDatetime = undefined;
        try testing.expectError(error.InvalidFormat, parse(&result, testing.allocator, "2015-10-21T07:28:00B"));
        try testing.expectError(error.InvalidFormat, parse(&result, testing.allocator, "2015-10-21T"));
    }
}
