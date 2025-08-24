const std = @import("std");
const yaml = @import("yaml");
const luau = @import("luau");

const VM = luau.VM;

const charset = "0123456789abcdef";
const escape_seq = blk: {
    var seq: []const u8 = "\"\\";
    for (0..32) |i|
        seq = seq ++ [_]u8{i};
    break :blk seq;
};
fn escapeString(bytes: *std.ArrayList(u8), str: []const u8) !void {
    try bytes.append('"');

    var pos: usize = 0;
    while (pos < str.len) {
        const c = std.mem.indexOfAny(u8, str[pos..], escape_seq) orelse break;
        try bytes.appendSlice(str[pos .. pos + c]);
        pos += c;
        switch (str[pos]) {
            0...31, '"', '\\' => |char| {
                pos += 1;
                switch (char) {
                    8 => try bytes.appendSlice("\\b"),
                    '\t' => try bytes.appendSlice("\\t"),
                    '\n' => try bytes.appendSlice("\\n"),
                    12 => try bytes.appendSlice("\\f"),
                    '\r' => try bytes.appendSlice("\\r"),
                    '"', '\\' => {
                        try bytes.append('\\');
                        try bytes.append(char);
                    },
                    else => {
                        try bytes.appendSlice("\\u00");
                        try bytes.append(charset[char >> 4]);
                        try bytes.append(charset[char & 15]);
                    },
                }
            },
            else => unreachable,
        }
    }
    if (pos < str.len)
        try bytes.appendSlice(str[pos..]);
    try bytes.append('"');
}

fn encodeValue(L: *VM.lua.State, allocator: std.mem.Allocator, tracked: *std.AutoHashMap(*const anyopaque, void)) !yaml.Yaml.Value {
    switch (L.typeOf(-1)) {
        .String => {
            var buf = std.ArrayList(u8).init(allocator);
            errdefer buf.deinit();
            const string = L.Lcheckstring(-1);
            try escapeString(&buf, string);
            return yaml.Yaml.Value{ .scalar = try buf.toOwnedSlice() };
        },
        .Number => {
            const num = L.Lchecknumber(-1);
            if (std.math.isNan(num) or std.math.isInf(num))
                return L.Zerror("invalid number value (cannot be inf or nan)");
            return yaml.Yaml.Value{ .scalar = try std.fmt.allocPrint(allocator, "{d}", .{num}) };
        },
        .Boolean => {
            const boolean = L.Lcheckboolean(-1);
            return yaml.Yaml.Value{ .scalar = if (boolean) "true" else "false" };
        },
        .Table => {
            const tablePtr = L.topointer(-1).?;

            if (tracked.contains(tablePtr))
                return L.Zerror("table circular reference");
            try tracked.put(tablePtr, undefined);
            defer std.debug.assert(tracked.remove(tablePtr));

            const tableSize = L.objlen(-1);

            var i: i32 = L.rawiter(-1, 0);
            if (tableSize > 0 or i < 0) {
                const list = try allocator.alloc(yaml.Yaml.Value, @intCast(tableSize));
                errdefer allocator.free(list);
                if (i >= 0) {
                    var order: usize = 0;
                    while (i >= 0) : (i = L.rawiter(-1, i)) {
                        switch (L.typeOf(-2)) {
                            .Number => {},
                            else => |t| return L.Zerrorf("invalid key type (expected number, got {s})", .{(VM.lapi.typename(t))}),
                        }

                        list[order] = try encodeValue(L, allocator, tracked);
                        order += 1;
                        L.pop(2); // drop: value, key
                    }

                    if (@as(i32, @intCast(order)) != tableSize)
                        return L.Zerrorf("array size mismatch (expected {d}, got {d})", .{ tableSize, order });
                }
                return yaml.Yaml.Value{ .list = list };
            } else {
                var map = std.StringArrayHashMapUnmanaged(yaml.Yaml.Value){};
                errdefer map.deinit(allocator);
                while (i >= 0) : (i = L.rawiter(-1, i)) {
                    switch (L.typeOf(-2)) {
                        .String => {},
                        else => |t| return L.Zerrorf("invalid key type (expected string, got {s})", .{(VM.lapi.typename(t))}),
                    }

                    const str = L.tolstring(-2).?;
                    var buf = try std.ArrayList(u8).initCapacity(allocator, str.len);
                    errdefer buf.deinit();
                    if (std.mem.indexOfNone(u8, str, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")) |_|
                        try escapeString(&buf, str)
                    else
                        try buf.appendSlice(str);

                    try map.put(allocator, try buf.toOwnedSlice(), try encodeValue(L, allocator, tracked));
                    L.pop(2); // drop: value
                }
                return yaml.Yaml.Value{ .map = map };
            }
        },
        else => |e| return L.Zerrorf("unsupported type '{s}'", .{VM.lapi.typename(e)}),
    }
}

pub fn lua_encode(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tracked: std.AutoHashMap(*const anyopaque, void) = .init(allocator);
    defer tracked.deinit();

    const value = try encodeValue(L, arena.allocator(), &tracked);

    var buf = std.ArrayList(u8).init(arena.allocator());
    try value.stringify(buf.writer(), .{});

    try L.pushlstring(buf.items);

    return 1;
}

fn decodeList(L: *VM.lua.State, list: yaml.Yaml.List) anyerror!void {
    try L.createtable(@intCast(list.len), 0);

    if (list.len == 0)
        return;

    for (list, 1..) |val, key| {
        switch (val) {
            .scalar => |str| try L.pushlstring(str),
            .map => |m| try decodeMap(L, m),
            .list => |ls| try decodeList(L, ls),
            .empty => continue,
        }
        try L.rawseti(-2, @intCast(key));
    }
}

fn decodeMap(L: *VM.lua.State, map: yaml.Yaml.Map) anyerror!void {
    const count = map.count();
    try L.createtable(0, @intCast(count));
    if (count == 0)
        return;

    var iter = map.iterator();
    while (iter.next()) |k| {
        const key = k.key_ptr.*;
        const value = k.value_ptr.*;
        try L.pushlstring(key);
        switch (value) {
            .scalar => |str| try L.pushlstring(str),
            .map => |m| try decodeMap(L, m),
            .list => |ls| try decodeList(L, ls),
            .empty => continue,
        }
        try L.rawset(-3);
    }
}

pub fn lua_decode(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const string = try L.Zcheckvalue([]const u8, 1, null);
    if (string.len == 0) {
        L.pushnil();
        return 1;
    }

    var raw: yaml.Yaml = .{ .source = string };
    defer raw.deinit(allocator);
    raw.load(allocator) catch |err| {
        switch (err) {
            error.ParseFailure => return L.Zerrorf("decode error: {s}", .{raw.parse_errors.string_bytes}),
            else => return err,
        }
    };

    if (raw.docs.items.len == 0) {
        try L.createtable(0, 0);
        return 1;
    }

    switch (raw.docs.items[0]) {
        .scalar => |str| try L.pushlstring(str),
        .map => |m| try decodeMap(L, m),
        .list => |ls| try decodeList(L, ls),
        .empty => return 0,
    }

    return 1;
}
