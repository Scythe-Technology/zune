const std = @import("std");
const toml = @import("toml");

pub const parse = toml.parse;

pub fn checkTable(table: toml.Table, comptime key: []const u8) ?toml.Table {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .table)
        std.debug.panic("[zune.toml] '{s}' must be a table\n", .{key});
    return item.table;
}

pub fn checkArray(table: toml.Table, comptime key: []const u8) ?toml.Array {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .array)
        std.debug.panic("[zune.toml] '{s}' must be a table\n", .{key});
    return item.array;
}

pub fn checkInteger(table: toml.Table, comptime key: []const u8) ?i64 {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .integer)
        std.debug.panic("[zune.toml] '{s}' must be a integer\n", .{key});
    return item.integer;
}

pub fn checkBool(table: toml.Table, comptime key: []const u8) ?bool {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .boolean)
        std.debug.panic("[zune.toml] '{s}' must be a boolean\n", .{key});
    return item.boolean;
}

pub fn checkString(table: toml.Table, comptime key: []const u8) ?[]const u8 {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .string)
        std.debug.panic("[zune.toml] '{s}' must be a string\n", .{key});
    return item.string;
}
