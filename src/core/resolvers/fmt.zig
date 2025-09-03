const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const VM = luau.VM;

fn tostring(allocator: std.mem.Allocator, L: *VM.lua.State, idx: i32) !?[]const u8 {
    switch (L.typeOf(idx)) {
        else => |t| {
            const ptr: *const anyopaque = L.topointer(idx) orelse return null;
            return std.fmt.allocPrint(allocator, "{s}: 0x{x}", .{ VM.lapi.typename(t), @intFromPtr(ptr) }) catch null;
        },
    }
    return null;
}

fn writeMetamethod__tostring(L: *VM.lua.State, writer: *std.Io.Writer, idx: i32) !bool {
    if (!try L.checkstack(2))
        return error.StackOverflow;
    L.pushvalue(idx);
    defer L.pop(1); // drop: value
    if (L.getmetatable(-1)) {
        if (!try L.checkstack(2))
            return error.StackOverflow;
        const metaType = L.rawgetfield(-1, "__tostring");
        defer L.pop(2); // drop: field(or result of function), metatable
        if (!metaType.isnoneornil()) {
            if (metaType != .String) {
                L.pushvalue(-3);
                L.call(1, 1);
            }
            if (L.typeOf(-1) != .String)
                return L.Zerror("'__tostring' must return a string");
            const s = L.tostring(-1) orelse unreachable;
            try writer.print("{s}", .{s});
            return true;
        }
    }
    return false;
}

fn isPlainText(slice: []const u8) bool {
    for (0..slice.len) |i| {
        switch (slice[i]) {
            'A'...'Z', 'a'...'z', '_' => {},
            '0'...'9' => if (i == 0) return false,
            else => return false,
        }
    }
    return true;
}

pub fn printValue(
    L: *VM.lua.State,
    writer: *std.Io.Writer,
    idx: i32,
    depth: usize,
    asKey: bool,
    map: ?*std.AutoArrayHashMap(usize, bool),
    max_depth: usize,
) anyerror!void {
    const allocator = luau.getallocator(L);
    if (depth > max_depth) {
        try writer.print("{s}", .{"{...}"});
        return;
    } else {
        switch (L.typeOf(idx)) {
            .Nil => try writer.print("nil", .{}),
            .Boolean => {
                const b = L.toboolean(idx);
                try Zune.debug.writerPrint(writer, "<bold><yellow>{s}<clear>", .{if (b) "true" else "false"});
            },
            .Number => {
                const n = L.tonumber(idx) orelse unreachable;
                try Zune.debug.writerPrint(writer, "<bcyan>{d}<clear>", .{n});
            },
            .String => {
                const s = L.tostring(idx) orelse unreachable;
                if (asKey) {
                    if (isPlainText(s)) try writer.print("{s}", .{s}) else {
                        try Zune.debug.writerPrint(writer, "<dim>[<clear><green>\"{s}\"<clear><dim>]<clear>", .{s});
                        return;
                    }
                } else {
                    try Zune.debug.writerPrint(writer, "<green>\"{s}\"<clear>", .{s});
                }
            },
            .Table => {
                if (try writeMetamethod__tostring(L, writer, idx))
                    return;
                if (asKey) {
                    if (tostring(allocator, L, idx) catch try allocator.dupe(u8, "!ERR!")) |str| {
                        defer allocator.free(str);
                        try Zune.debug.writerPrint(writer, "<bmagenta><<{s}>><clear>", .{str});
                    } else try Zune.debug.writerPrint(writer, "<bmagenta><<table>><clear>", .{});
                    return;
                }
                const ptr = @intFromPtr(L.topointer(idx).?);
                if (map) |tracked| {
                    if (tracked.get(ptr)) |_| {
                        if (Zune.STATE.FORMAT.TABLE_ADDRESS)
                            try Zune.debug.writerPrint(writer, "<dim><<recursive, table: 0x{x}>><clear>", .{ptr})
                        else
                            try Zune.debug.writerPrint(writer, "<dim><<recursive, table>><clear>", .{});
                        return;
                    }
                    try tracked.put(ptr, true);
                }
                defer _ = if (map) |tracked| tracked.orderedRemove(ptr);
                if (Zune.STATE.FORMAT.TABLE_ADDRESS) {
                    if (tostring(allocator, L, idx) catch try allocator.dupe(u8, "!ERR!")) |str| {
                        defer allocator.free(str);
                        try Zune.debug.writerPrint(writer, "<dim><<{s}>> {{<clear>\n", .{str});
                    } else try Zune.debug.writerPrint(writer, "<dim><<table>> {{<clear>\n", .{});
                } else try Zune.debug.writerPrint(writer, "<dim>{{<clear>\n", .{});
                if (!try L.checkstack(3))
                    return error.StackOverflow;
                var i: i32 = L.rawiter(idx, 0);
                while (i >= 0) : (i = L.rawiter(idx, i)) {
                    for (0..depth + 1) |_|
                        try writer.print("    ", .{});
                    const n = L.gettop();
                    if (L.typeOf(@intCast(n - 1)) == .String) {
                        try printValue(L, writer, @intCast(n - 1), depth + 1, true, null, max_depth);
                        try Zune.debug.writerPrint(writer, "<dim> = <clear>", .{});
                    } else {
                        try Zune.debug.writerPrint(writer, "<dim>[<clear>", .{});
                        try printValue(L, writer, @intCast(n - 1), depth + 1, true, null, max_depth);
                        try Zune.debug.writerPrint(writer, "<dim>] = <clear>", .{});
                    }
                    try printValue(L, writer, @intCast(n), depth + 1, false, map, max_depth);
                    try Zune.debug.writerPrint(writer, "<dim>,<clear> \n", .{});
                    L.pop(2);
                }
                for (0..depth) |_|
                    try writer.print("    ", .{});
                try Zune.debug.writerPrint(writer, "<dim>}}<clear>", .{});
            },
            .Buffer => {
                const b = L.tobuffer(idx) orelse unreachable;
                const ptr: usize = blk: {
                    break :blk @intFromPtr(L.topointer(idx) orelse break :blk 0);
                };
                try Zune.debug.writerPrint(writer, "<bmagenta><<buffer ", .{});
                if (Zune.STATE.FORMAT.BUFFER_MAX_DISPLAY > 0) {
                    if (b.len > Zune.STATE.FORMAT.BUFFER_MAX_DISPLAY) {
                        try writer.print("0x{x} {X}", .{ ptr, b[0..Zune.STATE.FORMAT.BUFFER_MAX_DISPLAY] });
                        try writer.print(" ...{d} truncated", .{(b.len - Zune.STATE.FORMAT.BUFFER_MAX_DISPLAY)});
                    } else {
                        try writer.print("0x{x} {X}", .{ ptr, b });
                    }
                } else try writer.print("0x{x}", .{ptr});
                try Zune.debug.writerPrint(writer, ">><clear>", .{});
            },
            .Vector => {
                const v = L.tovector(idx) orelse unreachable;
                if (comptime luau.VM.lua.config.VECTOR_SIZE == 3)
                    try Zune.debug.writerPrint(writer, "<bmagenta><<vector ({d}, {d}, {d})>><clear>", .{ v[0], v[1], v[2] })
                else
                    try Zune.debug.writerPrint(writer, "<bmagenta><<vector ({d}, {d}, {d}, {d})>><clear>", .{ v[0], v[1], v[2], v[3] });
            },
            else => {
                if (try writeMetamethod__tostring(L, writer, -1))
                    return;
                if (tostring(allocator, L, idx) catch try allocator.dupe(u8, "!ERR!")) |str| {
                    defer allocator.free(str);
                    try Zune.debug.writerPrint(writer, "<bmagenta><<{s}>><clear>", .{str});
                }
            },
        }
    }
}

pub fn writeIdx(allocator: std.mem.Allocator, L: *VM.lua.State, writer: *std.Io.Writer, idx: i32, max_depth: usize) !void {
    switch (L.typeOf(idx)) {
        .Nil => try writer.print("nil", .{}),
        .String => try writer.print("{s}", .{L.tostring(idx) orelse @panic("Failed Conversion")}),
        .Function, .Userdata, .LightUserdata, .Thread => |t| blk: {
            if (try writeMetamethod__tostring(L, writer, idx))
                break :blk;
            if (tostring(allocator, L, idx) catch try allocator.dupe(u8, "!ERR!")) |str| {
                defer allocator.free(str);
                try Zune.debug.writerPrint(writer, "<bmagenta><<{s}>><clear>", .{str});
            } else try Zune.debug.writerPrint(writer, "<bmagenta><<{s}>><clear>", .{VM.lapi.typename(t)});
        },
        else => {
            if (!Zune.STATE.FORMAT.RECURSIVE_TABLE) {
                var map = std.AutoArrayHashMap(usize, bool).init(allocator);
                defer map.deinit();
                try printValue(L, writer, idx, 0, false, &map, max_depth);
            } else try printValue(L, writer, idx, 0, false, null, max_depth);
        },
    }
}

fn writeBuffer(L: *VM.lua.State, allocator: std.mem.Allocator, writer: *std.Io.Writer, top: usize, max_depth: usize) !void {
    for (1..top + 1) |i| {
        if (i > 1)
            try writer.print("\t", .{});
        const idx: i32 = @intCast(i);
        try writeIdx(allocator, L, writer, idx, max_depth);
    }
}

pub fn args(L: *VM.lua.State) !i32 {
    const top = L.gettop();
    const allocator = luau.getallocator(L);
    if (top == 0) {
        try L.pushlstring("");
        return 1;
    }
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    const writer = &allocating.writer;

    try writeBuffer(L, allocator, writer, @intCast(top), Zune.STATE.FORMAT.MAX_DEPTH);

    try L.pushlstring(allocating.written());

    return 1;
}

pub fn print(L: *VM.lua.State) !i32 {
    const top = L.gettop();
    const allocator = luau.getallocator(L);
    if (top == 0) {
        std.debug.print("\n", .{});
        return 0;
    }
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    const writer = &allocating.writer;

    try writeBuffer(L, allocator, writer, @intCast(top), Zune.STATE.FORMAT.MAX_DEPTH);

    std.debug.print("{s}\n", .{allocating.written()});

    return 0;
}
