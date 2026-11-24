const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const Fmt = Zune.Resolvers.Fmt;

const json = @import("json.zig");

const VM = luau.VM;

fn writeNumber(L: *VM.lua.State, writer: *std.Io.Writer) !void {
    const number = L.Lchecknumber(-1);
    if (!std.math.isFinite(number))
        return L.Zerror("invalid number value (cannot be inf or nan)");
    try writer.writeAll(L.tolstring(-1).?);
}

fn writeVector(L: *VM.lua.State, writer: *std.Io.Writer) !void {
    const vec = L.tovector(-1) orelse unreachable;
    try writer.writeAll("vector.create(");
    for (vec, 0..) |component, index| {
        if (index != 0)
            try writer.writeAll(", ");
        if (!std.math.isFinite(component))
            return L.Zerror("invalid number value (cannot be inf or nan)");
        L.pushnumber(component);
        try writer.writeAll(L.tolstring(-1).?);
        L.pop(1);
    }
    try writer.writeByte(')');
}

fn writeBuffer(L: *VM.lua.State, writer: *std.Io.Writer) !void {
    const bytes = L.tobuffer(-1) orelse unreachable;
    try writer.writeAll("buffer.fromstring(");
    try Fmt.escapeString(writer, bytes);
    try writer.writeByte(')');
}

fn encode(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
) anyerror!void {
    switch (L.typeOf(-1)) {
        .Nil => try writer.writeAll("nil"),
        .Boolean => try writer.writeAll(if (L.toboolean(-1)) "true" else "false"),
        .Number => try writeNumber(L, writer),
        .String => try Fmt.escapeString(writer, L.tolstring(-1).?),
        .Vector => try writeVector(L, writer),
        .Buffer => try writeBuffer(L, writer),
        .Table => try encodeTable(L, allocator, writer, tracked, kind, depth, sort),
        else => |tag| return L.Zerrorf("unsupported value type (got {s})", .{VM.lapi.typename(tag)}),
    }
}

fn encodeTable(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
) !void {
    const idx = L.absindex(-1);
    const table_ptr = L.topointer(idx).?;
    if (tracked.contains(table_ptr))
        return L.Zerror("table circular reference");
    try tracked.put(allocator, table_ptr, {});
    defer std.debug.assert(tracked.remove(table_ptr));

    const len = L.objlen(idx);
    var count: usize = 0;
    var iter = L.rawiter(idx, 0);
    while (iter >= 0) : (iter = L.rawiter(idx, iter)) {
        count += 1;
        L.pop(2);
    }
    if (count == len) {
        try writeList(L, allocator, writer, tracked, kind, depth, sort, idx, len);
        return;
    }
    if (sort)
        try writeMapSorted(L, allocator, writer, tracked, kind, depth, sort, idx)
    else
        try writeMap(L, allocator, writer, tracked, kind, depth, sort, idx);
}

fn writeList(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
    idx: i32,
    len: usize,
) !void {
    if (len == 0) {
        try writer.writeAll("{}");
        return;
    }
    const nested = std.math.add(u32, depth, 1) catch return L.Zerror("table is too deep");
    try writer.writeByte('{');
    for (0..len) |offset| {
        if (kind == .NO_LINE) {
            if (offset != 0)
                try writer.writeAll(", ");
        } else {
            try writer.writeByte('\n');
            try json.writeIndent(writer, kind, nested);
        }
        _ = L.rawgeti(idx, std.math.cast(i32, offset + 1) orelse return L.Zerror("table is too large"));
        try encode(L, allocator, writer, tracked, kind, nested, sort);
        L.pop(1);
        if (kind != .NO_LINE)
            try writer.writeByte(',');
    }
    if (kind != .NO_LINE) {
        try writer.writeByte('\n');
        try json.writeIndent(writer, kind, depth);
    }
    try writer.writeByte('}');
}

fn writeKey(L: *VM.lua.State, writer: *std.Io.Writer, idx: i32) !void {
    switch (L.typeOf(idx)) {
        .String => {
            const text = L.tolstring(idx).?;
            if (Fmt.isPlainText(text))
                try writer.writeAll(text)
            else {
                try writer.writeByte('[');
                try Fmt.escapeString(writer, text);
                try writer.writeByte(']');
            }
        },
        .Number => {
            const number = L.tonumber(idx) orelse return L.Zerror("invalid number value (cannot be inf or nan)");
            if (std.math.isNan(number) or std.math.isInf(number))
                return L.Zerror("invalid number value (cannot be inf or nan)");
            try writer.writeByte('[');
            L.pushvalue(idx);
            try writeNumber(L, writer);
            L.pop(1);
            try writer.writeByte(']');
        },
        else => |tag| return L.Zerrorf("invalid key type (expected string or number, got {s})", .{VM.lapi.typename(tag)}),
    }
}

fn writeMap(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
    idx: i32,
) !void {
    const nested = std.math.add(u32, depth, 1) catch return L.Zerror("table is too deep");
    try writer.writeByte('{');
    var i: usize = 0;
    var iter = L.rawiter(idx, 0);
    while (iter >= 0) : (iter = L.rawiter(idx, iter)) {
        if (kind == .NO_LINE) {
            if (i != 0)
                try writer.writeAll(", ");
        } else {
            try writer.writeByte('\n');
            try json.writeIndent(writer, kind, nested);
        }
        i += 1;
        try writeKey(L, writer, L.absindex(-2));
        try writer.writeAll(" = ");
        try encode(L, allocator, writer, tracked, kind, nested, sort);
        L.pop(2);
        if (kind != .NO_LINE)
            try writer.writeByte(',');
    }
    if (kind != .NO_LINE) {
        try writer.writeByte('\n');
        try json.writeIndent(writer, kind, depth);
    }
    try writer.writeByte('}');
}

fn writeMapSorted(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
    idx: i32,
) !void {
    const Entry = struct {
        key: union(enum) {
            string: []u8,
            number: f64,
        },
        slot: i32,
        fn before(_: void, left: @This(), right: @This()) bool {
            return switch (left.key) {
                .string => |left_text| switch (right.key) {
                    .string => |right_text| std.mem.order(u8, left_text, right_text) == .lt,
                    .number => true,
                },
                .number => |left_number| switch (right.key) {
                    .string => false,
                    .number => |right_number| left_number < right_number,
                },
            };
        }
    };

    const saved: i32 = @intCast(L.gettop());

    try L.rawcheckstack(4);
    try L.createtable(0, 0);
    const values = L.absindex(-1);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| {
            switch (entry.key) {
                .string => |text| allocator.free(text),
                .number => {},
            }
        }
        entries.deinit(allocator);
    }

    var order: i32 = 0;
    var iter = L.rawiter(idx, 0);
    while (iter >= 0) : (iter = L.rawiter(idx, iter)) {
        if (order == std.math.maxInt(i32)) {
            L.settop(saved);
            return L.Zerror("table is too large");
        }
        order += 1;
        L.pushvalue(-1);
        try L.rawseti(values, order);
        switch (L.typeOf(-2)) {
            .String => {
                const copy = try allocator.dupe(u8, L.tolstring(-2).?);
                entries.append(allocator, .{ .key = .{ .string = copy }, .slot = order }) catch |err| {
                    allocator.free(copy);
                    return err;
                };
            },
            .Number => {
                const number = L.tonumber(-2) orelse return L.Zerror("invalid number value (cannot be inf or nan)");
                if (std.math.isNan(number) or std.math.isInf(number))
                    return L.Zerror("invalid number value (cannot be inf or nan)");
                try entries.append(allocator, .{ .key = .{ .number = number }, .slot = order });
            },
            else => |tag| {
                const name = VM.lapi.typename(tag);
                L.settop(saved);
                return L.Zerrorf("invalid key type (expected string or number, got {s})", .{name});
            },
        }
        L.pop(2);
    }

    std.mem.sort(Entry, entries.items, {}, Entry.before);

    const nested = std.math.add(u32, depth, 1) catch return L.Zerror("table is too deep");
    try writer.writeByte('{');
    for (entries.items, 0..) |entry, i| {
        if (kind == .NO_LINE) {
            if (i != 0)
                try writer.writeAll(", ");
        } else {
            try writer.writeByte('\n');
            try json.writeIndent(writer, kind, nested);
        }
        switch (entry.key) {
            .string => |text| try L.pushlstring(text),
            .number => |number| L.pushnumber(number),
        }
        try writeKey(L, writer, -1);
        L.pop(1);
        try writer.writeAll(" = ");
        _ = L.rawgeti(values, entry.slot);
        try encode(L, allocator, writer, tracked, kind, nested, sort);
        L.pop(1);
        if (kind != .NO_LINE)
            try writer.writeByte(',');
    }
    if (kind != .NO_LINE) {
        try writer.writeByte('\n');
        try json.writeIndent(writer, kind, depth);
    }
    try writer.writeByte('}');
    L.settop(saved);
}

pub fn lua_encode(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
    var kind: json.JsonIndent = .SPACES_4;
    var base: u32 = 0;

    var sort = false;
    if (!L.typeOf(2).isnoneornil()) {
        try L.Zchecktype(2, .Table);
        kind = try json.prettyIndent(L, .SPACES_4);
        base = try json.baseIndent(L);
        sort = try json.sortEntries(L, false);
    }

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    var tracked: std.AutoHashMapUnmanaged(*const anyopaque, void) = .empty;
    defer tracked.deinit(allocator);

    L.pushvalue(1);
    try encode(L, allocator, &allocating.writer, &tracked, kind, base, sort);
    try L.pushlstring(allocating.written());
    return 1;
}
