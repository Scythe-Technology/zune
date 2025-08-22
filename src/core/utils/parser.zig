const std = @import("std");

const LineInfo = struct {
    line: usize,
    col: usize,
};

pub fn getLineInfo(string: []const u8, pos: usize) LineInfo {
    var line: usize = 1;
    var col: usize = 0;
    for (0..pos) |p| {
        if (p >= string.len)
            break;
        switch (string[p]) {
            '\n' => {
                line += 1;
                col = 0;
            },
            else => col += 1,
        }
    }
    return .{ .line = line, .col = col };
}

pub fn nextNonCharacter(slice: []const u8, comptime characters: []const u8) usize {
    loop: for (slice, 0..) |c, p| {
        for (characters) |b|
            if (b == c)
                continue :loop;
        return p;
    }
    return slice.len;
}

pub fn nextCharacter(slice: []const u8, comptime characters: []const u8) usize {
    for (slice, 0..) |c, p|
        for (characters) |b|
            if (b == c)
                return p;
    return slice.len;
}

pub fn trimSpace(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, " \t\r");
}

pub fn isPlainText(slice: []const u8) bool {
    for (0..slice.len) |i| {
        switch (slice[i]) {
            'A'...'Z', 'a'...'z', '_' => {},
            '0'...'9' => if (i == 0) return false,
            else => return false,
        }
    }
    return true;
}
