const std = @import("std");
const luau = @import("luau");

const Parser = @import("../../utils/parser.zig");

const json = @import("json.zig");

const VM = luau.VM;

const Error = std.mem.Allocator.Error || error{
    InvalidString,
    InvalidIndexString,
    InvalidNumber,
    InvalidLiteral,
    InvalidArray,
    InvalidTable,
    InvalidCharacter,
    InvalidStringEof,
    InvalidArrayEof,
    InvalidTableEof,
    MissingString,
    MissingArray,
    MissingTable,

    NoSpaceLeft,
    InvalidLength,
};

const charset = "0123456789abcdef";
fn escape_string(bytes: *std.ArrayList(u8), str: []const u8) !void {
    errdefer bytes.deinit();
    const multi = std.mem.indexOfScalar(u8, str, '\n') != null;
    try bytes.append('"');

    if (str.len == 0) {
        try bytes.append('"');
        return;
    }

    if (multi)
        try bytes.appendSlice("\"\"");

    if (str[0] == '\n')
        try bytes.append(str[0])
    else if (str.len > 1 and str[0] == '\r' and str[1] == '\n')
        try bytes.appendSlice("\r\n");

    for (str) |c| switch (c) {
        0...9, 11...12, 14...31, '"', '\\' => {
            switch (c) {
                8 => try bytes.appendSlice("\\b"),
                '\t' => try bytes.appendSlice("\\t"),
                12 => try bytes.appendSlice("\\f"),
                '"', '\\' => {
                    try bytes.append('\\');
                    try bytes.append(c);
                },
                else => {
                    try bytes.appendSlice("\\u00");
                    try bytes.append(charset[c >> 4]);
                    try bytes.append(charset[c & 15]);
                },
            }
        },
        else => try bytes.append(c),
    };
    try bytes.append('"');
    if (multi) try bytes.appendSlice("\"\"");
}

const EncodeInfo = struct {
    root: bool = true,
    isName: bool = false,
    keyName: []const u8,
    tracked: *std.ArrayList(*const anyopaque),
    tagged: *std.StringArrayHashMap([]const u8),
};

fn createIndex(allocator: std.mem.Allocator, all: []const u8, key: []const u8) ![]const u8 {
    if (!Parser.isPlainText(key)) {
        var bytes = std.ArrayList(u8).init(allocator);
        defer bytes.deinit();
        try escape_string(&bytes, key);
        if (all.len == 0)
            return try allocator.dupe(u8, bytes.items);
        return try std.mem.join(allocator, ".", &[_][]const u8{
            all,
            bytes.items,
        });
    }
    if (all.len == 0)
        return try allocator.dupe(u8, key);
    return try std.mem.join(allocator, ".", &[_][]const u8{ all, key });
}

fn encodeArrayPartial(L: *VM.lua.State, allocator: std.mem.Allocator, arraySize: usize, buf: *std.ArrayList(u8), info: EncodeInfo) anyerror!void {
    var size: usize = 0;
    var i: i32 = L.rawiter(-1, 0);
    while (i >= 0) : (i = L.rawiter(-1, i)) {
        switch (L.typeOf(-2)) {
            .Number => {},
            else => |t| return L.Zerrorf("invalid key type (expected number, got {s})", .{(VM.lapi.typename(t))}),
        }
        switch (L.typeOf(-1)) {
            .String => {
                size += 1;
                const value = L.tostring(-1) orelse unreachable;
                try escape_string(buf, value);
                if (size != arraySize) try buf.appendSlice(", ");
            },
            .Number => {
                size += 1;
                const num = L.Lchecknumber(-1);
                if (std.math.isNan(num) or std.math.isInf(num))
                    return L.Zerror("invalid number value (cannot be inf or nan)");
                const value = L.tostring(-1) orelse std.debug.panic("Number failed to convert to string\n", .{});
                try buf.appendSlice(value);
                if (size != arraySize)
                    try buf.appendSlice(", ");
            },
            .Boolean => {
                size += 1;
                if (L.toboolean(-1))
                    try buf.appendSlice("true")
                else
                    try buf.appendSlice("false");
                if (size != arraySize)
                    try buf.appendSlice(", ");
            },
            .Table => {},
            else => |t| return L.Zerrorf("unsupported value type (got {s})", .{(VM.lapi.typename(t))}),
        }
        L.pop(2);
    }

    i = L.rawiter(1, 0);
    while (i >= 0) : (i = L.rawiter(1, i)) {
        switch (L.typeOf(-2)) {
            .Number => {},
            else => |t| return L.Zerrorf("invalid key type (expected number, got {s})", .{(VM.lapi.typename(t))}),
        }
        switch (L.typeOf(-1)) {
            .String, .Number, .Boolean => {},
            .Table => {
                size += 1;
                const tablePtr = L.topointer(-1) orelse return error.Failed;

                for (info.tracked.items) |t|
                    if (t == tablePtr)
                        return L.Zerror("table circular reference");
                try info.tracked.append(tablePtr);

                const tableSize = L.objlen(-1);
                const j: i32 = L.rawiter(-1, 0);
                if (tableSize > 0 or j < 0) {
                    if (j >= 0) {
                        switch (L.typeOf(-2)) {
                            .Number => {},
                            else => |t| return L.Zerrorf("invalid key type (expected number, got {s})", .{(VM.lapi.typename(t))}),
                        }
                        L.pop(2);
                        try buf.append('[');
                        try encodeArrayPartial(L, allocator, tableSize, buf, .{
                            .root = false,
                            .tracked = info.tracked,
                            .tagged = info.tagged,
                            .keyName = info.keyName,
                        });
                        try buf.append(']');
                        if (size != arraySize) try buf.appendSlice(", ");
                    } else {
                        try buf.appendSlice("[]");
                    }
                } else {
                    L.pop(2);
                    try buf.appendSlice("{");
                    try encodeTable(L, allocator, buf, .{
                        .root = false,
                        .tracked = info.tracked,
                        .tagged = info.tagged,
                        .keyName = info.keyName,
                    });
                    try buf.appendSlice("}");
                    if (size != arraySize) try buf.appendSlice(", ");
                }
            },
            else => unreachable, // checked first loop above
        }
        L.pop(2);
    }

    if (arraySize != size)
        return L.Zerrorf("array size mismatch (expected {d}, got {d})", .{ arraySize, size });
}

fn encodeTable(L: *VM.lua.State, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), info: EncodeInfo) anyerror!void {
    var i: i32 = L.rawiter(-1, 0);
    while (i >= 0) : (i = L.rawiter(-1, i)) {
        switch (L.typeOf(-2)) {
            .String => {},
            else => |t| return L.Zerrorf("invalid key type (expected string, got {s})", .{(VM.lapi.typename(t))}),
        }
        const key = L.tostring(-2) orelse unreachable;
        switch (L.typeOf(-1)) {
            .String => {
                const name = try createIndex(allocator, if (info.root) "" else info.keyName, key);
                defer allocator.free(name);
                try buf.appendSlice(name);
                try buf.appendSlice(" = ");
                const value = L.tostring(-1) orelse unreachable;
                try escape_string(buf, value);
                if (!info.root) try buf.appendSlice(",\n") else try buf.append('\n');
            },
            .Number => {
                const num = L.Lchecknumber(-1);
                if (std.math.isNan(num) or std.math.isInf(num))
                    return L.Zerror("invalid number value (cannot be inf or nan)");
                const name = try createIndex(allocator, if (info.root) "" else info.keyName, key);
                defer allocator.free(name);
                try buf.appendSlice(name);
                try buf.appendSlice(" = ");
                const value = L.tostring(-1) orelse std.debug.panic("Number failed to convert to string\n", .{});
                try buf.appendSlice(value);
                if (!info.root)
                    try buf.appendSlice(",\n")
                else
                    try buf.append('\n');
            },
            .Boolean => {
                const name = try createIndex(allocator, if (info.root) "" else info.keyName, key);
                defer allocator.free(name);
                try buf.appendSlice(name);
                try buf.appendSlice(" = ");
                if (L.toboolean(-1)) try buf.appendSlice("true") else try buf.appendSlice("false");
                if (!info.root) try buf.appendSlice(",\n") else try buf.append('\n');
            },
            .Table => {},
            else => |t| return L.Zerrorf("unsupported value type (got {s})", .{(VM.lapi.typename(t))}),
        }
        L.pop(2);
    }

    i = L.rawiter(-1, 0);
    while (i >= 0) : (i = L.rawiter(-1, i)) {
        switch (L.typeOf(-2)) {
            .String => {},
            else => |t| return L.Zerrorf("invalid key type (expected string, got {s})", .{(VM.lapi.typename(t))}),
        }
        switch (L.typeOf(-1)) {
            .String, .Number, .Boolean => {},
            .Table => {
                const key = L.tostring(-2).?;
                const name = try createIndex(allocator, info.keyName, key);
                defer allocator.free(name);

                const tablePtr = L.topointer(-1).?;

                for (info.tracked.items) |t|
                    if (t == tablePtr)
                        return L.Zerror("table circular reference");

                try info.tracked.append(tablePtr);

                const tableSize = L.objlen(-1);
                const j: i32 = L.rawiter(-1, 0);
                if (tableSize > 0 or j < 0) {
                    try buf.appendSlice(name);
                    try buf.appendSlice(" = ");
                    if (j >= 0) {
                        L.pop(2);
                        try buf.append('[');
                        try encodeArrayPartial(L, allocator, tableSize, buf, .{
                            .root = false,
                            .tracked = info.tracked,
                            .tagged = info.tagged,
                            .keyName = info.keyName,
                        });
                        try buf.append(']');
                        if (!info.root)
                            try buf.appendSlice(",\n")
                        else
                            try buf.append('\n');
                    } else {
                        try buf.appendSlice("[]");
                        if (!info.root)
                            try buf.appendSlice(",\n")
                        else
                            try buf.append('\n');
                    }
                } else {
                    L.pop(2);
                    if (!info.root) {
                        try buf.appendSlice(name);
                        try buf.appendSlice(" = {");
                        try encodeTable(L, allocator, buf, .{
                            .root = false,
                            .tracked = info.tracked,
                            .tagged = info.tagged,
                            .keyName = info.keyName,
                        });
                        try buf.append('}');
                        if (!info.root)
                            try buf.appendSlice(",\n")
                        else
                            try buf.append('\n');
                    } else {
                        var sub_buf = std.ArrayList(u8).init(allocator);
                        errdefer sub_buf.deinit();
                        try encodeTable(L, allocator, &sub_buf, .{
                            .tracked = info.tracked,
                            .tagged = info.tagged,
                            .keyName = name,
                        });
                        if (sub_buf.items.len > 0) {
                            const nameCopy = try allocator.dupe(u8, name);
                            try info.tagged.put(nameCopy, try sub_buf.toOwnedSlice());
                        } else sub_buf.deinit();
                    }
                }
            },
            else => unreachable, // checked first loop above
        }
        L.pop(2);
    }
}

fn encode(L: *VM.lua.State, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), info: EncodeInfo) !void {
    try encodeTable(L, allocator, buf, info);

    const tagged_count = info.tagged.count();
    if (buf.items.len > 0 and tagged_count > 0)
        try buf.append('\n');

    var iter = info.tagged.iterator();
    var pos: usize = 0;
    while (iter.next()) |k| {
        pos += 1;
        const key = k.key_ptr.*;
        const value = k.value_ptr.*;
        defer allocator.free(key);
        defer allocator.free(value);

        try buf.append('[');
        try buf.appendSlice(key);
        try buf.appendSlice("]\n");
        try buf.appendSlice(value);
        if (tagged_count != pos)
            try buf.append('\n');
    }
}
const WHITESPACE = [_]u8{ 32, '\t' };
const WHITESPACE_LINE = [_]u8{ 32, '\t', '\r', '\n' };
const DELIMITER = [_]u8{ 32, '\t', '\r', '\n', '}', ']', ',' };
const NEWLINE = [_]u8{ '\r', '\n' };

fn decodeGenerateName(L: *VM.lua.State, name: []const u8, comptime includeLast: bool) !void {
    var last_pos: usize = 0;
    var p: usize = 0;
    while (p < name.len) switch (name[p]) {
        '"', '\'' => {
            const slice = name[last_pos..];
            try L.newtable();
            var tempInfo = DecodeInfo{};
            const str_p = try decodeString(L, slice, false, &tempInfo);
            if (slice.len == str_p) {
                L.pop(2);
                break;
            }
            p += str_p;
            L.pushvalue(-1);
            const ttype = L.rawget(-4);
            if (ttype.isnoneornil()) {
                L.pop(1);
                L.pushvalue(-2);
                try L.rawset(-4);
            } else if (ttype != .Table) return Error.InvalidTable else {
                L.remove(-2);
                L.remove(-2);
            }
            last_pos = p;
        },
        '.' => {
            const slice = name[last_pos..p];
            p += 1;
            try L.newtable();
            try validateWord(slice);
            try L.pushlstring(slice);
            L.pushvalue(-1);
            const ttype = L.rawget(-4);
            if (ttype.isnoneornil()) {
                L.pop(1);
                L.pushvalue(-2);
                try L.rawset(-4);
            } else if (ttype != .Table) return Error.InvalidTable else {
                L.remove(-2);
                L.remove(-2);
            }
            last_pos = p;
        },
        else => p += 1,
    };

    if (last_pos >= name.len)
        return Error.InvalidTable;

    const slice = name[last_pos..];
    if (includeLast)
        try L.newtable();
    if (slice[0] == '\'' or slice[0] == '"') {
        var tempInfo = DecodeInfo{};
        _ = decodeString(L, slice, false, &tempInfo) catch return Error.InvalidIndexString;
    } else {
        try validateWord(slice);
        try L.pushlstring(slice);
    }
    if (includeLast) {
        L.pushvalue(-1);
        const ttype = L.rawget(-4);
        if (ttype.isnoneornil()) {
            L.pop(1);
            L.pushvalue(-2);
            try L.rawset(-4);
        } else if (ttype != .Table) return Error.InvalidTable else {
            L.remove(-2);
            L.remove(-2);
        }
    }
}

fn decodeString(L: *VM.lua.State, string: []const u8, comptime multi: bool, info: *DecodeInfo) !usize {
    if (string.len < if (multi) 6 else 2)
        return Error.InvalidString;
    if (multi) {
        if (std.mem.eql(u8, string[0..2], string[3..6])) {
            try L.pushstring("");
            return 6;
        }
    } else if (string[0] == string[1]) {
        try L.pushstring("");
        return 2;
    }

    const delim = string[0];
    const literal = delim == '\'';

    var buf = std.ArrayList(u8).init(luau.getallocator(L));
    defer buf.deinit();
    var end: usize = if (multi) 3 else 1;
    info.pos += end;
    try buf.ensureUnusedCapacity(string.len);
    const eof = comp: {
        while (end < string.len) {
            const c = string[end];
            if (c == '\\' and !literal) {
                end += 1;
                info.pos += 1;
                if (end >= string.len)
                    return Error.MissingString;
                if (string[end] == 'u') {
                    end += 1;
                    info.pos += 1;
                    if (end + 4 >= string.len)
                        return Error.MissingString;
                    var b: [4]u8 = undefined;
                    const bytes = try std.fmt.hexToBytes(&b, string[end .. end + 4]);
                    const trimmed = b: {
                        for (bytes, 0..) |byte, p| if (byte != 0) break :b bytes[p..];
                        break :b bytes;
                    };
                    try buf.appendSlice(trimmed);
                    end += 4;
                    info.pos += 4;
                } else if (string[end] == 'U') {
                    end += 1;
                    info.pos += 1;
                    if (end + 8 >= string.len)
                        return Error.MissingString;
                    var b: [8]u8 = undefined;
                    const bytes = try std.fmt.hexToBytes(&b, string[end .. end + 8]);
                    const trimmed = b: {
                        for (bytes, 0..) |byte, p| if (byte != 0) break :b bytes[p..];
                        break :b bytes[bytes.len - 1 ..];
                    };
                    try buf.appendSlice(trimmed);
                    end += 8;
                    info.pos += 8;
                } else {
                    switch (string[end]) {
                        'b' => try buf.append(8),
                        't' => try buf.append(9),
                        'n' => try buf.append(10),
                        'f' => try buf.append(12),
                        'r' => try buf.append(13),
                        '"' => try buf.append('"'),
                        '\\' => try buf.append('\\'),
                        else => return Error.InvalidString,
                    }
                    end += 1;
                    info.pos += 1;
                }
                continue;
            } else if (multi) {
                if (c == '\n' or c == '\r') {
                    if (end == 3) {
                        if (c == '\r') {
                            if (end + 2 >= string.len)
                                return Error.MissingString;
                            if (string[end + 1] == '\n')
                                end += 1;
                        }
                        end += 1;
                        info.pos += 1;
                        continue;
                    }
                } else if (c < 32)
                    return Error.InvalidString;
            } else if (c < 32)
                return Error.InvalidString;
            end += 1;
            info.pos += 1;
            if (multi and end + 2 >= string.len)
                return Error.MissingString;
            if (c == delim)
                if (multi) {
                    if (std.mem.eql(u8, string[end .. end + 2], &[_]u8{ c, c })) {
                        end += 2;
                        info.pos += 2;
                        break :comp true;
                    }
                } else break :comp true;
            try buf.append(c);
        }
        break :comp false;
    };
    if (!eof)
        return Error.InvalidStringEof;
    try L.pushlstring(buf.items);
    return end;
}

fn decodeArray(L: *VM.lua.State, string: []const u8, info: *DecodeInfo) !usize {
    if (string.len < 2)
        return Error.MissingArray;
    try L.newtable();

    if (string[0] == string[1])
        return 2;

    info.pos += 1;
    var end: usize = 1;
    var size: i32 = 0;
    const eof = comp: {
        while (end < string.len) {
            var adjustment = Parser.nextNonCharacter(string[end..], &WHITESPACE_LINE);
            end += adjustment;
            info.pos += adjustment;
            if (end >= string.len)
                return Error.MissingArray;
            if (string[end] == ']') {
                end += 1;
                break :comp true;
            }
            size += 1;

            end += try decodeValue(L, string[end..], info);

            try L.rawseti(-2, size);

            adjustment = Parser.nextNonCharacter(string[end..], &WHITESPACE_LINE);
            end += adjustment;
            info.pos += adjustment;

            if (end >= string.len)
                return Error.MissingArray;
            const c = string[end];
            end += 1;
            info.pos += 1;
            if (c == ']')
                break :comp true;
            if (c != ',')
                return Error.InvalidArray;
        }
        break :comp false;
    };
    if (!eof) return Error.InvalidArrayEof;
    return end;
}

fn decodeTable(L: *VM.lua.State, string: []const u8, info: *DecodeInfo) !usize {
    if (string.len < 2)
        return Error.MissingTable;

    try L.newtable();

    if (string[0] == string[1])
        return 2;

    const main = L.gettop();

    info.pos += 1;
    var end: usize = 1;
    const eof = comp: {
        while (end < string.len) {
            var adjustment = Parser.nextNonCharacter(string[end..], &WHITESPACE_LINE);
            end += adjustment;
            info.pos += adjustment;
            if (end >= string.len)
                return Error.MissingTable;
            if (string[end] == '}') {
                end += 1;
                break :comp true;
            }

            const pos = Parser.nextCharacter(string[end..], &[_]u8{'='});
            const variable_name = Parser.trimSpace(string[end .. end + pos]);
            end += pos + 1;
            info.pos += pos + 1;

            if (end >= string.len)
                return Error.InvalidCharacter;

            adjustment = Parser.nextNonCharacter(string[end..], &WHITESPACE_LINE);
            end += adjustment;
            info.pos += adjustment;

            try decodeGenerateName(L, variable_name, false);

            adjustment = Parser.nextNonCharacter(string[end..], &WHITESPACE_LINE);
            end += adjustment;
            info.pos += adjustment;

            end += try decodeValue(L, string[end..], info);

            try L.settable(-3);

            returnTop(L, @intCast(main));

            adjustment = Parser.nextNonCharacter(string[end..], &WHITESPACE_LINE);
            end += adjustment;
            info.pos += adjustment;

            if (end >= string.len)
                return Error.MissingTable;
            const c = string[end];
            end += 1;
            info.pos += 1;
            if (c == '}')
                break :comp true;
            if (c != ',')
                return Error.InvalidTable;
        }
        break :comp false;
    };
    if (!eof) return Error.InvalidTableEof;
    return end;
}

fn decodeValue(L: *VM.lua.State, string: []const u8, info: *DecodeInfo) anyerror!usize {
    switch (string[0]) {
        '"', '\'' => |c| {
            if (string.len > 2 and string[1] == c and string[2] == c)
                return decodeString(L, string, true, info) catch return Error.InvalidString;
            return decodeString(L, string, false, info) catch return Error.InvalidString;
        },
        '[' => return try decodeArray(L, string, info),
        '{' => return try decodeTable(L, string, info),
        '0'...'9', '-' => {
            const end = Parser.nextCharacter(string, &DELIMITER);
            if (std.mem.indexOfScalar(u8, string[0..end], ':') != null)
                try L.pushlstring(string[0..end])
            else {
                const num = std.fmt.parseFloat(f64, string[0..end]) catch return Error.InvalidNumber;
                L.pushnumber(num);
            }
            return end;
        },
        't' => {
            // TODO: static eql u32 == u32 [0..4] "true"
            if (string.len > 3 and std.mem.eql(u8, string[0..4], "true"))
                L.pushboolean(true)
            else
                return Error.InvalidLiteral;
            return 4;
        },
        'f' => {
            // TODO: static eql u32 == u32 [1..5] "alse"
            if (string.len > 4 and std.mem.eql(u8, string[0..5], "false"))
                L.pushboolean(false)
            else
                return Error.InvalidLiteral;
            return 5;
        },
        else => return Error.InvalidTable,
    }
}

fn validateWord(slice: []const u8) !void {
    for (slice) |b| switch (b) {
        '0'...'9', 'A'...'Z', 'a'...'z', '-', '_', '\'', '.' => {},
        else => return Error.InvalidCharacter,
    };
}

fn returnTop(L: *VM.lua.State, lastTop: i32) void {
    const diff = @as(i32, @intCast(L.gettop())) - lastTop;
    if (diff > 0)
        L.pop(diff);
}

const DecodeInfo = struct {
    pos: usize = 0,
};

fn decode(L: *VM.lua.State, string: []const u8, info: *DecodeInfo) !void {
    try L.newtable();
    errdefer L.pop(1);
    const main = L.gettop();
    var pos = Parser.nextNonCharacter(string, &WHITESPACE);
    var scan: usize = 0;
    while (pos < string.len) switch (string[pos]) {
        '\n' => {
            pos += 1;
            scan = pos;
        },
        '#' => pos += Parser.nextCharacter(string[pos..], &NEWLINE),
        '=' => {
            const variable_name = Parser.trimSpace(string[scan..pos]);
            info.pos = pos;
            pos += 1;

            if (pos >= string.len)
                return Error.InvalidCharacter;

            pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE);

            const last = L.gettop();
            info.pos = pos;
            try decodeGenerateName(L, variable_name, false);

            pos += try decodeValue(L, string[pos..], info);
            info.pos = pos;

            try L.settable(-3);

            returnTop(L, @intCast(last));

            pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE);
        },
        '[' => {
            if (pos + 2 >= string.len)
                return Error.InvalidTable;

            returnTop(L, @intCast(main));

            const slice = string[pos + 1 ..];
            const last = std.mem.indexOfScalar(u8, slice, ']') orelse slice.len;
            const table_name = Parser.trimSpace(slice[0..last]);

            info.pos = pos;
            try decodeGenerateName(L, table_name, true);

            pos += 1;
        },
        else => pos += 1,
    };
    returnTop(L, @intCast(main));
}

pub fn lua_encode(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);
    const allocator = luau.getallocator(L);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var tagged = std.StringArrayHashMap([]const u8).init(allocator);
    defer tagged.deinit();

    var tracked = std.ArrayList(*const anyopaque).init(allocator);
    defer tracked.deinit();

    const info = EncodeInfo{
        .keyName = "",
        .tagged = &tagged,
        .tracked = &tracked,
    };

    try encode(L, allocator, &buf, info);

    try L.pushlstring(buf.items);

    return 1;
}

pub fn lua_decode(L: *VM.lua.State) !i32 {
    const string = try L.Zcheckvalue([]const u8, 1, null);
    if (string.len == 0) {
        L.pushnil();
        return 1;
    }

    var info = DecodeInfo{};

    decode(L, string, &info) catch |err| {
        const lineInfo = Parser.getLineInfo(string, info.pos);
        switch (err) {
            else => return L.Zerrorf("{s} at line {d}, col {d}", .{ @errorName(err), lineInfo.line, lineInfo.col }),
        }
    };

    return 1;
}
