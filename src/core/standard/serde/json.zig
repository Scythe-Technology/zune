const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

pub const JsonIndent = json.JsonIndent;

var NULL_PTR: ?*const anyopaque = null;

const charset = "0123456789abcdef";
const escape_seq: []const u8 = blk: {
    var seq: []const u8 = "\"\\";
    for (0..32) |i|
        seq = seq ++ [_]u8{i};
    break :blk seq;
};
pub fn escapeString(writer: *std.Io.Writer, str: []const u8) !void {
    try writer.writeByte('"');

    var pos: usize = 0;
    while (pos < str.len) {
        const c = std.mem.indexOfAny(u8, str[pos..], escape_seq) orelse break;
        try writer.writeAll(str[pos .. pos + c]);
        pos += c;
        switch (str[pos]) {
            0...31, '"', '\\' => |char| {
                pos += 1;
                switch (char) {
                    8 => try writer.writeAll("\\b"),
                    '\t' => try writer.writeAll("\\t"),
                    '\n' => try writer.writeAll("\\n"),
                    12 => try writer.writeAll("\\f"),
                    '\r' => try writer.writeAll("\\r"),
                    '"', '\\' => {
                        try writer.writeByte('\\');
                        try writer.writeByte(char);
                    },
                    else => {
                        try writer.writeAll("\\u00");
                        try writer.writeByte(charset[char >> 4]);
                        try writer.writeByte(charset[char & 15]);
                    },
                }
            },
            else => unreachable,
        }
    }
    if (pos < str.len)
        try writer.writeAll(str[pos..]);
    try writer.writeByte('"');
}

pub fn prettyIndent(L: *VM.lua.State, default: JsonIndent) !JsonIndent {
    const field_type = L.rawgetfield(2, "pretty_indent");
    if (field_type.isnoneornil()) {
        L.pop(1);
        return default;
    }
    try L.Zchecktype(-1, .Number);
    const n = L.tointeger(-1).?;
    L.pop(1);
    return switch (n) {
        0 => .NO_LINE,
        1 => .SPACES_2,
        2 => .SPACES_4,
        3 => .TABS,
        else => L.Zerrorf("unsupported indent kind {d}", .{n}),
    };
}

pub fn baseIndent(L: *VM.lua.State) !u32 {
    const field_type = L.rawgetfield(2, "base_indent");
    if (field_type.isnoneornil()) {
        L.pop(1);
        return 0;
    }
    try L.Zchecktype(-1, .Number);
    const number = L.tointeger(-1).?;
    L.pop(1);
    if (number < 0 or number > 255)
        return L.Zerrorf("unsupported base indent {d}", .{number});
    return @intCast(number);
}

pub fn sortEntries(L: *VM.lua.State, default: bool) !bool {
    const field_type = L.rawgetfield(2, "sort");
    if (field_type.isnoneornil()) {
        L.pop(1);
        return default;
    }
    try L.Zchecktype(-1, .Boolean);
    const enabled = L.toboolean(-1);
    L.pop(1);
    return enabled;
}

pub fn writeIndent(writer: *std.Io.Writer, kind: json.JsonIndent, depth: u32) !void {
    const indent = switch (kind) {
        .NO_LINE => return,
        .SPACES_2 => "  ",
        .SPACES_4 => "    ",
        .TABS => "\t",
    };
    for (0..depth) |_| {
        try writer.writeAll(indent);
    }
}

const JsonKind = enum {
    JSON,
    JSON5,
};

fn encodeSortedObject(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
    comptime json_kind: JsonKind,
) !void {
    const Entry = struct {
        key: []u8,
        slot: i32,

        fn before(_: void, left: @This(), right: @This()) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    };

    const table_index = L.absindex(-1);
    const saved: i32 = @intCast(L.gettop());

    try L.rawcheckstack(4);
    try L.createtable(0, 0);
    const values_index = L.absindex(-1);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry|
            allocator.free(entry.key);
        entries.deinit(allocator);
    }

    var order: i32 = 0;
    var iter = L.rawiter(table_index, 0);
    while (iter >= 0) : (iter = L.rawiter(table_index, iter)) {
        if (order == std.math.maxInt(i32)) {
            L.settop(saved);
            return L.Zerror("table is too large");
        }
        order += 1;
        switch (L.typeOf(-2)) {
            .String => {},
            else => |tag| {
                const name = VM.lapi.typename(tag);
                L.settop(saved);
                return L.Zerrorf("invalid key type (expected string, got {s})", .{name});
            },
        }
        L.pushvalue(-1);
        try L.rawseti(values_index, order);
        const copy = try allocator.dupe(u8, L.tolstring(-2).?);
        entries.append(allocator, .{ .key = copy, .slot = order }) catch |err| {
            allocator.free(copy);
            return err;
        };
        L.pop(2);
    }

    std.mem.sort(Entry, entries.items, {}, Entry.before);
    const nested = std.math.add(u32, depth, 1) catch return L.Zerror("table is too deep");
    try writer.writeAll("{");
    for (entries.items, 0..) |entry, index| {
        if (index != 0)
            try writer.writeByte(',');
        if (kind != .NO_LINE)
            try writer.writeByte('\n');
        try writeIndent(writer, kind, nested);

        try L.pushlstring(entry.key);
        try encode(L, allocator, writer, tracked, kind, nested, sort, json_kind);
        L.pop(1);
        try writer.writeByte(':');
        if (kind != .NO_LINE)
            try writer.writeByte(' ');
        _ = L.rawgeti(values_index, entry.slot);
        try encode(L, allocator, writer, tracked, kind, nested, sort, json_kind);
        L.pop(1);
    }
    if (kind != .NO_LINE)
        try writer.writeByte('\n');
    try writeIndent(writer, kind, depth);
    try writer.writeByte('}');
    L.settop(saved);
}

fn encode(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tracked: *std.AutoHashMapUnmanaged(*const anyopaque, void),
    kind: json.JsonIndent,
    depth: u32,
    sort: bool,
    comptime json_kind: JsonKind,
) anyerror!void {
    switch (L.typeOf(-1)) {
        .Nil => try writer.writeAll("null"),
        .Table => {
            const tablePtr = L.topointer(-1).?;

            if (NULL_PTR) |ptr| if (tablePtr == ptr) {
                try writer.writeAll("null");
                return;
            };

            if (tracked.contains(tablePtr))
                return L.Zerror("table circular reference");
            try tracked.put(allocator, tablePtr, undefined);
            defer std.debug.assert(tracked.remove(tablePtr));

            try L.rawcheckstack(2);

            const nested = std.math.add(u32, depth, 1) catch return L.Zerror("table is too deep");

            const tableSize = L.objlen(-1);
            var i: i32 = L.rawiter(-1, 0);
            if (tableSize > 0 or i < 0) {
                try writer.writeByte('[');
                if (i >= 0) {
                    var n: i32 = 0;
                    var appended = false;
                    while (i >= 0) : (i = L.rawiter(-1, i)) {
                        defer appended = true;
                        if (appended) {
                            try writer.writeByte(',');
                        }

                        if (kind != .NO_LINE)
                            try writer.writeByte('\n');
                        try writeIndent(writer, kind, nested);

                        switch (L.typeOf(-2)) {
                            .Number => {},
                            else => |t| return L.Zerrorf("invalid key type (expected number, got {s})", .{(VM.lapi.typename(t))}),
                        }

                        try encode(L, allocator, writer, tracked, kind, nested, sort, json_kind);
                        L.pop(2); // drop: value, key
                        n += 1;
                    }
                    if (n != tableSize)
                        return L.Zerrorf("array size mismatch (expected {d}, got {d})", .{ tableSize, n });

                    if (kind != .NO_LINE)
                        try writer.writeByte('\n');
                    try writeIndent(writer, kind, depth);
                }

                try writer.writeByte(']');
            } else {
                if (sort) {
                    L.pop(2);
                    try encodeSortedObject(L, allocator, writer, tracked, kind, depth, sort, json_kind);
                } else {
                    try writer.writeAll("{");
                    var appended = false;
                    while (i >= 0) : (i = L.rawiter(-1, i)) {
                        defer appended = true;
                        if (appended)
                            try writer.writeByte(',');
                        switch (L.typeOf(-2)) {
                            .String => {},
                            else => |t| return L.Zerrorf("invalid key type (expected string, got {s})", .{(VM.lapi.typename(t))}),
                        }

                        if (kind != .NO_LINE)
                            try writer.writeByte('\n');
                        try writeIndent(writer, kind, nested);

                        L.pushvalue(-2); // push key [copy]
                        try encode(L, allocator, writer, tracked, kind, nested, sort, json_kind);
                        try writer.writeByte(':');
                        if (kind != .NO_LINE)
                            try writer.writeByte(' ');
                        L.pop(1); // drop: key [copy]
                        try encode(L, allocator, writer, tracked, kind, nested, sort, json_kind);
                        L.pop(2); // drop: value, key
                    }

                    if (kind != .NO_LINE)
                        try writer.writeByte('\n');
                    try writeIndent(writer, kind, depth);

                    try writer.writeByte('}');
                }
            }
        },
        .Number => {
            const num = L.Lchecknumber(-1);
            switch (json_kind) {
                .JSON => if (std.math.isNan(num) or std.math.isInf(num))
                    return L.Zerror("invalid number value (cannot be inf or nan)"),
                .JSON5 => if (std.math.isInf(num)) {
                    if (num > 0)
                        try writer.writeAll("Infinity")
                    else
                        try writer.writeAll("-Infinity");
                    return;
                } else if (std.math.isNan(num)) {
                    try writer.writeAll("NaN");
                    return;
                },
            }

            const str = L.tolstring(-1).?;
            try writer.writeAll(str);
        },
        .String => {
            const str = L.tolstring(-1).?;
            try escapeString(writer, str);
        },
        .Boolean => if (L.toboolean(-1))
            try writer.writeAll("true")
        else
            try writer.writeAll("false"),
        else => |t| return L.Zerrorf("unsupported value type (got {s})", .{(VM.lapi.typename(t))}),
    }
}

pub fn LuaEncoder(comptime json_kind: JsonKind) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(L: *VM.lua.State) anyerror!i32 {
            const allocator = Scheduler.fromState(L).allocator();

            var kind = json.JsonIndent.NO_LINE;
            var base: u32 = 0;
            var sort = false;

            const config_type = L.typeOf(2);
            if (!config_type.isnoneornil()) {
                try L.Zchecktype(2, .Table);
                kind = try prettyIndent(L, .NO_LINE);
                base = try baseIndent(L);
                sort = try sortEntries(L, false);
            }

            var allocating: std.Io.Writer.Allocating = .init(allocator);
            defer allocating.deinit();

            const writer = &allocating.writer;

            var tracked: std.AutoHashMapUnmanaged(*const anyopaque, void) = .empty;
            defer tracked.deinit(allocator);

            L.pushvalue(1);
            try encode(L, allocator, writer, &tracked, kind, base, sort, json_kind);
            try L.pushlstring(allocating.written());

            return 1;
        }
    }.inner;
}

fn decodeArray(L: *VM.lua.State, array: *std.ArrayList(json.Value), preserve_null: bool) !void {
    try L.rawcheckstack(2);
    try L.createtable(@intCast(array.items.len), 0);

    for (array.items, 1..) |item, i| {
        try decodeValue(L, item, preserve_null);
        try L.rawseti(-2, @intCast(i));
    }
}

fn decodeObject(L: *VM.lua.State, object: *std.array_hash_map.String(json.Value), preserve_null: bool) !void {
    try L.rawcheckstack(3);
    try L.createtable(0, @intCast(object.count()));

    var iter = object.iterator();
    while (iter.next()) |entry| {
        try L.pushlstring(entry.key_ptr.*);
        try decodeValue(L, entry.value_ptr.*, preserve_null);
        try L.rawset(-3);
    }
}

pub fn decodeValue(L: *VM.lua.State, jsonValue: json.Value, preserve_null: bool) anyerror!void {
    switch (jsonValue) {
        .nil => if (preserve_null) {
            _ = L.rawgetfield(VM.lua.REGISTRYINDEX, "_SERDE_JSON_NULL");
        } else L.pushnil(),
        .boolean => |boolean| L.pushboolean(boolean),
        .integer => |integer| L.pushnumber(@floatFromInt(integer)),
        .float => |float| L.pushnumber(float),
        .string, .static_string => |string| try L.pushlstring(string),
        .object => |object| try decodeObject(L, object, preserve_null),
        .array => |array| try decodeArray(L, array, preserve_null),
    }
}

pub fn LuaDecoder(comptime json_kind: JsonKind) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(L: *VM.lua.State) !i32 {
            const string = L.Lcheckstring(1);
            if (string.len == 0) {
                L.pushnil();
                return 1;
            }

            var preserve_null = false;

            const config_type = L.typeOf(2);
            if (!config_type.isnoneornil()) {
                try L.Zchecktype(2, .Table);
                const preserve_null_type = L.rawgetfield(2, "preserve_null");
                if (!preserve_null_type.isnoneornil()) {
                    try L.Zchecktype(-1, .Boolean);
                    preserve_null = L.toboolean(-1);
                }
                L.pop(1);
            }

            const allocator = Scheduler.fromState(L).allocator();

            var root = try switch (json_kind) {
                .JSON => json.parse(allocator, string),
                .JSON5 => json.parseJson5(allocator, string),
            };
            defer root.deinit(allocator);

            try decodeValue(L, root.value, preserve_null);

            return 1;
        }
    }.inner;
}

pub fn pushNullValue(L: *VM.lua.State) !void {
    if (!L.rawgetfield(VM.lua.REGISTRYINDEX, "_SERDE_JSON_NULL").isnoneornil())
        return;

    L.pop(1);

    try L.createtable(0, 0);

    { // JsonNull Metatable
        try L.Zpushvalue(.{
            .__tostring = Scripting.toCFn(struct {
                fn inner(l: *VM.lua.State) !i32 {
                    try l.pushstring("JsonValue.Null");
                    return 1;
                }
            }.inner),
        });
        try L.setreadonly(-1, true);
        _ = try L.setmetatable(-2);
    }

    try L.setreadonly(-1, true);

    L.pushvalue(-1);
    try L.rawsetfield(VM.lua.REGISTRYINDEX, "_SERDE_JSON_NULL");
    NULL_PTR = L.topointer(-1) orelse unreachable;
}

test "Escaped Strings" {
    for (0..256) |i| {
        const c: u8 = @intCast(i);

        var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer allocating.deinit();

        const writer = &allocating.writer;

        try escapeString(writer, &[1]u8{c});

        const res = allocating.written();

        switch (c) {
            8 => try std.testing.expectEqualSlices(u8, "\"\\b\"", res),
            9 => try std.testing.expectEqualSlices(u8, "\"\\t\"", res),
            10 => try std.testing.expectEqualSlices(u8, "\"\\n\"", res),
            12 => try std.testing.expectEqualSlices(u8, "\"\\f\"", res),
            13 => try std.testing.expectEqualSlices(u8, "\"\\r\"", res),
            '"' => try std.testing.expectEqualSlices(u8, "\"\\\"\"", res),
            '\\' => try std.testing.expectEqualSlices(u8, "\"\\\\\"", res),
            0...7, 11, 14...31 => try std.testing.expectEqualSlices(u8, &[_]u8{ '"', '\\', 'u', '0', '0', charset[c >> 4], charset[c & 15], '"' }, res),
            else => try std.testing.expectEqualSlices(u8, &[_]u8{ '"', c, '"' }, res),
        }
    }
}
