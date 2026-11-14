const std = @import("std");
const luau = @import("luau");
const pcre2 = @import("regex");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Regex = @This();

pub const OBJECT_TAG = Zune.Tags.get("REGEX_COMPILED").?;

code: *pcre2.Code,

pub fn lua_match(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

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

pub fn lua_search(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

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

pub fn lua_captures(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

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

pub fn lua_split(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

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

pub fn lua_isMatch(self: *Regex, L: *VM.lua.State) !i32 {
    const input = try L.Zcheckvalue([]const u8, 2, null);
    L.pushboolean(try self.code.isMatch(input));
    return 1;
}

pub fn lua_format(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const input = try L.Zcheckvalue([:0]const u8, 2, null);
    const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
    const formatted = try self.code.allocFormat(allocator, input, fmt);
    defer allocator.free(formatted);
    try L.pushlstring(formatted);
    return 1;
}

pub fn lua_replace(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const input = try L.Zcheckvalue([:0]const u8, 2, null);
    const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
    const formatted = try self.code.allocReplace(allocator, input, fmt);
    defer allocator.free(formatted);
    try L.pushlstring(formatted);
    return 1;
}

pub fn lua_replaceAll(self: *Regex, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const input = try L.Zcheckvalue([:0]const u8, 2, null);
    const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
    const formatted = try self.code.allocReplaceAll(allocator, input, fmt);
    defer allocator.free(formatted);
    try L.pushlstring(formatted);
    return 1;
}

pub fn __dtor(L: *VM.lua.State, regex: *Regex) void {
    _ = L;
    regex.code.deinit();
}

pub fn create(L: *VM.lua.State, code: *pcre2.Code) !*Regex {
    const regex = try L.newuserdatataggedwithmetatable(Regex, OBJECT_TAG);
    regex.code = code;
    return regex;
}
