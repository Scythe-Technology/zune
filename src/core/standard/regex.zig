const std = @import("std");
const luau = @import("luau");
const pcre2 = @import("regex");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const VM = luau.VM;

const TAG_REGEX_COMPILED = Zune.Tags.get("REGEX_COMPILED").?;

pub const LIB_NAME = "regex";

const LuaRegex = struct {
    code: *pcre2.Code,

    pub fn match(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        if (try self.code.match(allocator, input)) |m| {
            defer m.free(allocator);
            try L.createtable(@intCast(m.captures.len), 0);
            for (m.captures, 1..) |capture, i| {
                if (capture) |c| {
                    try L.Zpushvalue(.{
                        .index = 1 + c.index,
                        .string = c.slice,
                        .name = c.name,
                    });
                } else {
                    L.pushnil();
                }
                try L.rawseti(-2, @intCast(i));
            }
            return 1;
        }
        L.pushnil();
        return 1;
    }

    pub fn search(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        if (try self.code.search(allocator, input)) |m| {
            defer m.free(allocator);
            try L.createtable(@intCast(m.captures.len), 0);
            for (m.captures, 1..) |capture, i| {
                if (capture) |c| {
                    try L.Zpushvalue(.{
                        .index = 1 + c.index,
                        .string = c.slice,
                        .name = c.name,
                    });
                } else {
                    L.pushnil();
                }
                try L.rawseti(-2, @intCast(i));
            }
            return 1;
        }
        L.pushnil();
        return 1;
    }

    pub fn captures(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        const global = L.Loptboolean(3, false);

        try L.newtable();

        var iter = try self.code.searchIterator(input);
        defer iter.free();
        var captures_count: i32 = 1;
        while (try iter.next(allocator)) |m| {
            defer m.free(allocator);
            try L.createtable(@intCast(m.captures.len), 0);
            for (m.captures, 1..) |capture, i| {
                if (capture) |c| {
                    try L.Zpushvalue(.{
                        .index = 1 + c.index,
                        .string = c.slice,
                        .name = c.name,
                    });
                } else {
                    L.pushnil();
                }
                try L.rawseti(-2, @intCast(i));
            }
            try L.rawseti(-2, captures_count);
            captures_count += 1;
            if (!global)
                break;
        }

        return 1;
    }

    pub fn split(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        const global = L.Loptboolean(3, false);

        try L.newtable();

        var iter = try self.code.searchIterator(input);
        defer iter.free();
        var current_index: usize = 0;
        var split_count: i32 = 1;
        while (try iter.next(allocator)) |m| {
            defer m.free(allocator);
            if (m.captures.len == 0)
                continue;

            const capture = m.captures[0].?;
            const start_index = capture.index;

            const slice = input[current_index..start_index];

            current_index = capture.index + capture.slice.len;
            try L.pushlstring(slice);
            try L.rawseti(-2, split_count);

            split_count += 1;

            if (!global)
                break;
        }
        if (current_index < input.len) {
            const slice = input[current_index..];
            try L.pushlstring(slice);
            try L.rawseti(-2, split_count);
        }

        return 1;
    }

    pub fn isMatch(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const input = try L.Zcheckvalue([]const u8, 2, null);
        L.pushboolean(try self.code.isMatch(input));
        return 1;
    }

    pub fn format(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([:0]const u8, 2, null);
        const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
        const formatted = try self.code.allocFormat(allocator, input, fmt);
        defer allocator.free(formatted);
        try L.pushlstring(formatted);
        return 1;
    }

    pub fn replace(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([:0]const u8, 2, null);
        const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
        const formatted = try self.code.allocReplace(allocator, input, fmt);
        defer allocator.free(formatted);
        try L.pushlstring(formatted);
        return 1;
    }

    pub fn replaceAll(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([:0]const u8, 2, null);
        const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
        const formatted = try self.code.allocReplaceAll(allocator, input, fmt);
        defer allocator.free(formatted);
        try L.pushlstring(formatted);
        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaRegex, TAG_REGEX_COMPILED, .{
        .{ "match", match },
        .{ "search", search },
        .{ "captures", captures },
        .{ "split", split },
        .{ "isMatch", isMatch },
        .{ "format", format },
        .{ "replace", replace },
        .{ "replaceAll", replaceAll },
    });

    pub fn __dtor(L: *VM.lua.State, reg: **pcre2.Code) void {
        _ = L;
        reg.*.deinit();
    }
};

fn regex_create(L: *VM.lua.State) !i32 {
    const flags = L.tolstring(2) orelse "";

    if (flags.len > 2)
        return L.Zerror("too many flags provided");

    var flag: u32 = 0;
    for (flags) |f| switch (f) {
        'i' => flag |= pcre2.Options.CASELESS,
        'm' => flag |= pcre2.Options.MULTILINE,
        'u' => flag |= pcre2.Options.UTF,
        else => return L.Zerrorf("unknown flag: {c}", .{f}),
    };

    var pos: usize = 0;
    const r = try pcre2.compile(try L.Zcheckvalue([]const u8, 1, null), flag, &pos);
    const ptr = try L.newuserdatataggedwithmetatable(*pcre2.Code, TAG_REGEX_COMPILED);
    ptr.* = r;
    return 1;
}

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaRegex), .{
            .__metatable = "Metatable is locked",
            .__type = "Regex",
        });
        try LuaRegex.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_REGEX_COMPILED);
        L.setuserdatadtor(*pcre2.Code, TAG_REGEX_COMPILED, LuaRegex.__dtor);
    }

    try L.Zpushvalue(.{
        .create = regex_create,
    });
    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test "regex" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/regex.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
