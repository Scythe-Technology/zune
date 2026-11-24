const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

pub const Indent = enum(u2) { TwoSpaces, FourSpaces, Tabs };

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

pub fn isPlainText(slice: []const u8) bool {
    if (slice.len == 0)
        return false;
    switch (slice[0]) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => return false,
    }
    for (slice[1..]) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
            else => return false,
        }
    }
    return true;
}

const hex = "0123456789abcdef";
pub fn escapeString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            8 => try writer.writeAll("\\b"),
            11 => try writer.writeAll("\\v"),
            12 => try writer.writeAll("\\f"),
            0...7, 14...31, 127 => {
                try writer.writeAll("\\x");
                try writer.writeByte(hex[byte >> 4]);
                try writer.writeByte(hex[byte & 15]);
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn writeIndent(writer: *std.Io.Writer, levels: usize) !void {
    for (0..levels) |_|
        switch (Zune.State.options.format.indent) {
            .TwoSpaces => try writer.print("  ", .{}),
            .FourSpaces => try writer.print("    ", .{}),
            .Tabs => try writer.print("\t", .{}),
        };
}

fn writeField(
    L: *VM.lua.State,
    writer: *std.Io.Writer,
    depth: usize,
    map: ?*std.array_hash_map.Auto(usize, bool),
    max_depth: usize,
) anyerror!void {
    try writeIndent(writer, depth + 1);
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

fn writeSortedFields(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    idx: i32,
    depth: usize,
    map: ?*std.array_hash_map.Auto(usize, bool),
    max_depth: usize,
) anyerror!void {
    const KeyOrder = struct {
        L: *VM.lua.State,
        keys_index: i32,

        fn less(ctx: @This(), left_index: i32, right_index: i32) bool {
            const keys = ctx.L.Atoobject(ctx.keys_index).?.hvalue();
            const left = VM.ltable.Hgetnum(keys, left_index);
            const right = VM.ltable.Hgetnum(keys, right_index);
            const left_type = left.typeOf();
            const right_type = right.typeOf();
            const left_rank: i16 = switch (left_type) {
                .String => 0,
                .Number => 1,
                else => 100 + @as(i16, @backingInt(left_type)),
            };
            const right_rank: i16 = switch (right_type) {
                .String => 0,
                .Number => 1,
                else => 100 + @as(i16, @backingInt(right_type)),
            };
            if (left_rank != right_rank)
                return left_rank < right_rank;
            const order: std.math.Order = switch (left_type) {
                .String => std.mem.order(u8, left.tsvalue().toSlice(), right.tsvalue().toSlice()),
                .Number => blk: {
                    const left_number = left.nvalue();
                    const right_number = right.nvalue();
                    if (std.math.isNan(left_number) or std.math.isNan(right_number)) {
                        if (std.math.isNan(left_number) == std.math.isNan(right_number))
                            break :blk .eq;
                        break :blk if (std.math.isNan(left_number)) .gt else .lt;
                    }
                    if (left_number < right_number)
                        break :blk .lt;
                    if (right_number < left_number)
                        break :blk .gt;
                    break :blk .eq;
                },
                else => .eq,
            };
            if (order == .eq)
                return left_index < right_index;
            return order == .lt;
        }
    };

    const table_index = L.absindex(idx);
    if (!try L.checkstack(2))
        return error.StackOverflow;

    var count: i32 = 0;
    var iter = L.rawiter(table_index, 0);
    while (iter >= 0) : (iter = L.rawiter(table_index, iter)) {
        L.pop(2);
        if (count == std.math.maxInt(i32))
            return L.Zerror("table is too large");
        count += 1;
    }
    if (count == 0)
        return;

    const saved: i32 = @intCast(L.gettop());
    errdefer L.settop(saved);
    if (!try L.checkstack(5))
        return error.StackOverflow;

    try L.createtable(@intCast(count), 0);
    const keys = L.absindex(-1);
    try L.createtable(@intCast(count), 0);
    const values = L.absindex(-1);

    var slot_index: i32 = 0;
    iter = L.rawiter(table_index, 0);
    while (iter >= 0) : (iter = L.rawiter(table_index, iter)) {
        slot_index += 1;
        L.pushvalue(-2);
        try L.rawseti(keys, slot_index);
        L.pushvalue(-1);
        try L.rawseti(values, slot_index);
        L.pop(2);
    }

    const slots = try allocator.alloc(i32, @intCast(count));
    defer allocator.free(slots);
    for (slots, 1..) |*slot, index|
        slot.* = @intCast(index);

    std.mem.sort(i32, slots, KeyOrder{ .L = L, .keys_index = keys }, KeyOrder.less);

    for (slots) |slot| {
        if (!try L.checkstack(2))
            return error.StackOverflow;
        _ = L.rawgeti(keys, slot);
        _ = L.rawgeti(values, slot);
        try writeField(L, writer, depth, map, max_depth);
    }
    L.settop(saved);
}

pub fn printValue(
    L: *VM.lua.State,
    writer: *std.Io.Writer,
    idx: i32,
    depth: usize,
    asKey: bool,
    map: ?*std.array_hash_map.Auto(usize, bool),
    max_depth: usize,
) anyerror!void {
    const allocator = Scheduler.fromState(L).allocator();
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
                var buf: [VM.zapi.STR_BUF_SIZE]u8 = undefined;
                try Zune.debug.writerPrint(writer, "<bcyan>{s}<clear>", .{VM.zapi.Ztolstringkc(L, idx, &buf)});
            },
            .String => {
                const s = L.tostring(idx) orelse unreachable;
                if (asKey and isPlainText(s)) {
                    try writer.print("{s}", .{s});
                } else if (asKey) {
                    try Zune.debug.writerPrint(writer, "<dim>[<clear><green>", .{});
                    try escapeString(writer, s);
                    try Zune.debug.writerPrint(writer, "<clear><dim>]<clear>", .{});
                } else {
                    try Zune.debug.writerPrint(writer, "<green>", .{});
                    try escapeString(writer, s);
                    try Zune.debug.writerPrint(writer, "<clear>", .{});
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
                        if (Zune.State.options.format.table_address)
                            try Zune.debug.writerPrint(writer, "<dim><<recursive, table: 0x{x}>><clear>", .{ptr})
                        else
                            try Zune.debug.writerPrint(writer, "<dim><<recursive, table>><clear>", .{});
                        return;
                    }
                    try tracked.put(allocator, ptr, true);
                }
                defer _ = if (map) |tracked| tracked.orderedRemove(ptr);
                if (Zune.State.options.format.table_address) {
                    if (tostring(allocator, L, idx) catch try allocator.dupe(u8, "!ERR!")) |str| {
                        defer allocator.free(str);
                        try Zune.debug.writerPrint(writer, "<dim><<{s}>> {{<clear>\n", .{str});
                    } else try Zune.debug.writerPrint(writer, "<dim><<table>> {{<clear>\n", .{});
                } else try Zune.debug.writerPrint(writer, "<dim>{{<clear>\n", .{});
                if (Zune.State.options.format.sorted)
                    try writeSortedFields(L, allocator, writer, idx, depth, map, max_depth)
                else {
                    if (!try L.checkstack(3))
                        return error.StackOverflow;
                    var i: i32 = L.rawiter(idx, 0);
                    while (i >= 0) : (i = L.rawiter(idx, i))
                        try writeField(L, writer, depth, map, max_depth);
                }
                try writeIndent(writer, depth);
                try Zune.debug.writerPrint(writer, "<dim>}}<clear>", .{});
            },
            .Buffer => {
                const b = L.tobuffer(idx) orelse unreachable;
                const ptr: usize = blk: {
                    break :blk @intFromPtr(L.topointer(idx) orelse break :blk 0);
                };
                try Zune.debug.writerPrint(writer, "<bmagenta><<buffer ", .{});
                if (Zune.State.options.format.buffer_max_display > 0) {
                    if (b.len > Zune.State.options.format.buffer_max_display) {
                        try writer.print("0x{x} {X}", .{ ptr, b[0..Zune.State.options.format.buffer_max_display] });
                        try writer.print(" ...{d} truncated", .{(b.len - Zune.State.options.format.buffer_max_display)});
                    } else {
                        try writer.print("0x{x} {X}", .{ ptr, b });
                    }
                } else try writer.print("0x{x}", .{ptr});
                try Zune.debug.writerPrint(writer, ">><clear>", .{});
            },
            .Vector => {
                var buf: [VM.zapi.STR_BUF_SIZE]u8 = undefined;
                try Zune.debug.writerPrint(writer, "<bmagenta><<vector ({s})>><clear>", .{VM.zapi.Ztolstringkc(L, idx, &buf)});
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
            if (!Zune.State.options.format.recursive_table) {
                var map: std.array_hash_map.Auto(usize, bool) = .empty;
                defer map.deinit(allocator);
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
    const allocator = Scheduler.fromState(L).allocator();
    if (top == 0) {
        try L.pushlstring("");
        return 1;
    }
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    const writer = &allocating.writer;

    try writeBuffer(L, allocator, writer, @intCast(top), Zune.State.options.format.max_depth);

    try L.pushlstring(allocating.written());

    return 1;
}

pub fn print(L: *VM.lua.State) !i32 {
    const top = L.gettop();
    const allocator = Scheduler.fromState(L).allocator();
    if (top == 0) {
        std.debug.print("\n", .{});
        return 0;
    }
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    const writer = &allocating.writer;

    try writeBuffer(L, allocator, writer, @intCast(top), Zune.State.options.format.max_depth);

    std.debug.print("{s}\n", .{allocating.written()});

    return 0;
}
