// This code is based on https://github.com/karlseguin/http.zig/blob/c3bf0fca2c224510d0496100178fa6e25bb97473/src/url.zig

const std = @import("std");

const Allocator = std.mem.Allocator;

const ENC_20 = @as(u16, @bitCast([2]u8{ '2', '0' }));
const ENC_21 = @as(u16, @bitCast([2]u8{ '2', '1' }));
const ENC_22 = @as(u16, @bitCast([2]u8{ '2', '2' }));
const ENC_23 = @as(u16, @bitCast([2]u8{ '2', '3' }));
const ENC_24 = @as(u16, @bitCast([2]u8{ '2', '4' }));
const ENC_25 = @as(u16, @bitCast([2]u8{ '2', '5' }));
const ENC_26 = @as(u16, @bitCast([2]u8{ '2', '6' }));
const ENC_27 = @as(u16, @bitCast([2]u8{ '2', '7' }));
const ENC_28 = @as(u16, @bitCast([2]u8{ '2', '8' }));
const ENC_29 = @as(u16, @bitCast([2]u8{ '2', '9' }));
const ENC_2A = @as(u16, @bitCast([2]u8{ '2', 'A' }));
const ENC_2B = @as(u16, @bitCast([2]u8{ '2', 'B' }));
const ENC_2C = @as(u16, @bitCast([2]u8{ '2', 'C' }));
const ENC_2F = @as(u16, @bitCast([2]u8{ '2', 'F' }));
const ENC_3A = @as(u16, @bitCast([2]u8{ '3', 'A' }));
const ENC_3B = @as(u16, @bitCast([2]u8{ '3', 'B' }));
const ENC_3D = @as(u16, @bitCast([2]u8{ '3', 'D' }));
const ENC_3F = @as(u16, @bitCast([2]u8{ '3', 'F' }));
const ENC_40 = @as(u16, @bitCast([2]u8{ '4', '0' }));
const ENC_5B = @as(u16, @bitCast([2]u8{ '5', 'B' }));
const ENC_5D = @as(u16, @bitCast([2]u8{ '5', 'D' }));

const Self = @This();

raw: []const u8 = "",
path: []const u8 = "",
query: []const u8 = "",

pub fn parse(raw: []const u8) Self {
    var path = raw;
    var query: []const u8 = "";

    if (std.mem.indexOfScalar(u8, raw, '?')) |index| {
        path = raw[0..index];
        query = raw[index + 1 ..];
    }

    return .{
        .raw = raw,
        .path = path,
        .query = query,
    };
}

// the special "*" url, which is valid in HTTP OPTIONS request.
pub fn star() Self {
    return .{
        .raw = "*",
        .path = "*",
        .query = "",
    };
}

// std.Url.unescapeString has 2 problems
//   First, it doesn't convert '+' -> ' '
//   Second, it _always_ allocates a new string even if nothing needs to
//   be unescaped
// When we _have_ to unescape a key or value,
// must free returned buffer
pub fn unescape(allocator: Allocator, input: []const u8) ![]const u8 {
    var has_plus = false;
    var unescaped_len = input.len;

    var in_i: usize = 0;
    while (in_i < input.len) {
        const b = input[in_i];
        if (b == '%') {
            if (in_i + 2 >= input.len or !HEX_CHAR[input[in_i + 1]] or !HEX_CHAR[input[in_i + 2]]) {
                return error.InvalidEscapeSequence;
            }
            in_i += 3;
            unescaped_len -= 2;
        } else if (b == '+') {
            has_plus = true;
            in_i += 1;
        } else {
            in_i += 1;
        }
    }

    // no encoding, and no plus. nothing to unescape
    if (unescaped_len == input.len and !has_plus) {
        return try allocator.dupe(u8, input);
    }

    var out = try allocator.alloc(u8, unescaped_len);

    in_i = 0;
    for (0..unescaped_len) |i| {
        const b = input[in_i];
        if (b == '%') {
            const enc = input[in_i + 1 .. in_i + 3];
            out[i] = switch (@as(u16, @bitCast(enc[0..2].*))) {
                ENC_20 => ' ',
                ENC_21 => '!',
                ENC_22 => '"',
                ENC_23 => '#',
                ENC_24 => '$',
                ENC_25 => '%',
                ENC_26 => '&',
                ENC_27 => '\'',
                ENC_28 => '(',
                ENC_29 => ')',
                ENC_2A => '*',
                ENC_2B => '+',
                ENC_2C => ',',
                ENC_2F => '/',
                ENC_3A => ':',
                ENC_3B => ';',
                ENC_3D => '=',
                ENC_3F => '?',
                ENC_40 => '@',
                ENC_5B => '[',
                ENC_5D => ']',
                else => HEX_DECODE[enc[0]] << 4 | HEX_DECODE[enc[1]],
            };
            in_i += 3;
        } else if (b == '+') {
            out[i] = ' ';
            in_i += 1;
        } else {
            out[i] = b;
            in_i += 1;
        }
    }

    return out;
}

pub fn isValid(url: []const u8) bool {
    var i: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |block_len| {
        const Block = @Vector(block_len, u8);

        // anything less than this should be encoded
        const min: Block = @splat(32);

        // anything more than this should be encoded
        const max: Block = @splat(126);

        while (i > block_len) {
            const block: Block = url[i..][0..block_len].*;
            if (@reduce(.Or, block < min) or @reduce(.Or, block > max)) {
                return false;
            }
            i += block_len;
        }
    }
    for (url[i..]) |c| {
        if (c < 32 or c > 126) {
            return false;
        }
    }

    return true;
}

const HEX_CHAR = blk: {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('f' + 1)) |b| all[b] = true;
    for ('A'..('F' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    break :blk all;
};

const HEX_DECODE = blk: {
    var all = std.mem.zeroes([255]u8);
    for ('a'..('z' + 1)) |b| all[b] = b - 'a' + 10;
    for ('A'..('Z' + 1)) |b| all[b] = b - 'A' + 10;
    for ('0'..('9' + 1)) |b| all[b] = b - '0';
    break :blk all;
};

test "url: parse" {
    {
        // absolute root
        const url = parse("/");
        try std.testing.expectEqualStrings("/", url.raw);
        try std.testing.expectEqualStrings("/", url.path);
        try std.testing.expectEqualStrings("", url.query);
    }

    {
        // absolute path
        const url = parse("/a/bc/def");
        try std.testing.expectEqualStrings("/a/bc/def", url.raw);
        try std.testing.expectEqualStrings("/a/bc/def", url.path);
        try std.testing.expectEqualStrings("", url.query);
    }

    {
        // absolute root with query
        const url = parse("/?over=9000");
        try std.testing.expectEqualStrings("/?over=9000", url.raw);
        try std.testing.expectEqualStrings("/", url.path);
        try std.testing.expectEqualStrings("over=9000", url.query);
    }

    {
        // absolute root with empty query
        const url = parse("/?");
        try std.testing.expectEqualStrings("/?", url.raw);
        try std.testing.expectEqualStrings("/", url.path);
        try std.testing.expectEqualStrings("", url.query);
    }

    {
        // absolute path with query
        const url = parse("/hello/teg?duncan=idaho&ghanima=atreides");
        try std.testing.expectEqualStrings("/hello/teg?duncan=idaho&ghanima=atreides", url.raw);
        try std.testing.expectEqualStrings("/hello/teg", url.path);
        try std.testing.expectEqualStrings("duncan=idaho&ghanima=atreides", url.query);
    }
}

test "url: unescape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    try std.testing.expectError(error.InvalidEscapeSequence, unescape(std.testing.allocator, "%"));
    try std.testing.expectError(error.InvalidEscapeSequence, unescape(std.testing.allocator, "%a"));
    try std.testing.expectError(error.InvalidEscapeSequence, unescape(std.testing.allocator, "%1"));
    try std.testing.expectError(error.InvalidEscapeSequence, unescape(std.testing.allocator, "123%45%6"));
    try std.testing.expectError(error.InvalidEscapeSequence, unescape(std.testing.allocator, "%zzzzz"));

    const res1 = try unescape(allocator, "a+b");
    defer allocator.free(res1);
    try std.testing.expectEqualStrings("a b", res1);

    const res2 = try unescape(allocator, "a%20b");
    defer allocator.free(res2);
    try std.testing.expectEqualStrings("a b", res2);

    const input = "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad";
    const expected = "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad";
    const res3 = try unescape(allocator, input);
    defer allocator.free(res3);
    try std.testing.expectEqualStrings(expected, res3);
}

fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    std.posix.getrandom(std.mem.asBytes(&seed)) catch std.debug.panic("getrandom failed\n", .{});
    return std.Random.DefaultPrng.init(seed);
}

test "url: isValid" {
    var input: [600]u8 = undefined;
    for ([_]u8{ ' ', 'a', 'Z', '~' }) |c| {
        @memset(&input, c);
        for (0..input.len) |i| {
            try std.testing.expectEqual(true, isValid(input[0..i]));
        }
    }

    var r = getRandom();
    const random = r.random();

    for ([_]u8{ 31, 128, 0, 255 }) |c| {
        for (1..input.len) |i| {
            var slice = input[0..i];
            const idx = random.uintAtMost(usize, slice.len - 1);
            slice[idx] = c;
            try std.testing.expectEqual(false, isValid(slice));
            slice[idx] = 'a'; // revert this index to a valid value
        }
    }
}
