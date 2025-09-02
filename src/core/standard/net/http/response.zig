const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const Self = @This();

const Url = @import("url.zig");

const Stream = std.net.Stream;
const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

/// converts ascii to unsigned int of appropriate size
pub fn asUint(comptime string: anytype) @Type(std.builtin.Type{
    .int = .{
        .bits = @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
        .signedness = .unsigned,
    },
}) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const QueryValue = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Parser = struct {
    arena: ArenaAllocator,
    buf: ?[]const u8 = null,
    left: ?[]const u8 = null,
    pos: usize = 0,

    stage: enum { protocol, headers, body } = .protocol,
    protocol: Protocol = .HTTP10,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: ?union(enum) {
        dynamic: []u8,
        static: []const u8,
    } = null,
    status_code: u16 = 200,
    status_message: ?[]const u8 = null,

    max_body_size: usize = 1_048_576,
    max_header_size: usize = 4096,
    max_header_count: usize = 100,

    pub fn init(allocator: Allocator, max_header_count: u32) Parser {
        var headers: std.StringHashMapUnmanaged([]const u8) = .empty;
        headers.ensureTotalCapacity(allocator, max_header_count) catch |err| std.debug.panic("{}\n", .{err});
        return .{
            .arena = .init(allocator),
            .headers = headers,
            .max_header_count = max_header_count,
        };
    }

    pub fn reset(self: *Parser) void {
        self.body = null;
        self.buf = null;
        self.url = null;
        self.protocol = .HTTP10;
        if (self.left) |_| {
            self.left = null;
        }
        if (!self.arena.reset(.retain_capacity)) {
            _ = self.arena.reset(.free_all);
        }
        self.pos = 0;
        self.stage = .protocol;
        self.headers.clearRetainingCapacity();
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
        self.headers.deinit(self.arena.child_allocator);
        if (self.left) |left|
            self.arena.child_allocator.free(left);
    }

    pub fn parse(self: *Parser, buf: []const u8) !bool {
        if (buf.len == 0)
            return false;

        const allocator = self.arena.child_allocator;
        const arena_allocator = self.arena.allocator();
        var input = buf;
        var allocated = false;
        if (self.left) |left| {
            input = try std.mem.concat(allocator, u8, &.{ left, buf });
            defer allocator.free(left);
            self.left = null;
            allocated = true;
        }
        defer if (allocated) allocator.free(input);

        const pos = self.pos;
        self.pos = 0;

        sw: switch (self.stage) {
            .protocol => if (try self.parseProtocol(arena_allocator, input[self.pos..]))
                continue :sw .headers,
            .headers => if (try self.parseHeaders(arena_allocator, input[self.pos..], allocated))
                return true,
            .body => {
                if (self.body) |b|
                    switch (b) {
                        .dynamic => |body| {
                            if (self.pos > 0) {
                                return false;
                            }
                            const remaining = body.len - pos;
                            if (buf.len >= remaining) {
                                @memcpy(body[pos..], buf[0..remaining]);
                                self.pos = pos + buf.len;
                                return true;
                            } else {
                                @memcpy(body[pos .. pos + buf.len], buf[0..]);
                                self.pos = pos + buf.len;
                                return false;
                            }
                        },
                        else => {},
                    };
                return true;
            },
        }

        const leftover = input[self.pos..];
        if (leftover.len > 0)
            self.left = try allocator.dupe(u8, leftover);

        return false;
    }

    // HTTP/#.# ###\r\n
    // HTTP/#.# ### MSG\r\n
    fn parseProtocol(self: *Parser, arena: std.mem.Allocator, buf: []const u8) !bool {
        self.stage = .protocol;
        if (buf.len < 12) return false;
        const end = std.mem.indexOf(u8, buf, "\r\n") orelse if (buf.len > 64) return error.TooLarge else return false;
        if (end < 12) return false;

        if (@as(u32, @bitCast(buf[0..4].*)) != asUint("HTTP")) {
            return error.UnknownProtocol;
        }

        self.protocol = switch (@as(u32, @bitCast(buf[4..8].*))) {
            asUint("/1.1") => .HTTP11,
            asUint("/1.0") => .HTTP10,
            else => return error.UnsupportedProtocol,
        };

        if (buf[8] != ' ')
            return error.InvalidStatusCode;

        const code = atoi(buf[9..12]) orelse return error.InvalidStatusCode;
        if (code < 100 or code > 599)
            return error.InvalidStatusCode;

        self.status_code = @intCast(code);
        if (buf[12] == ' ' and end > 13)
            self.status_message = try arena.dupe(u8, buf[13..end])
        else if (buf[12] != '\r' or buf[13] != '\n' or end != 12)
            return error.InvalidStatusCode;

        self.pos += end + 2;
        return true;
    }

    fn parseHeaders(self: *Parser, arena: Allocator, full: []const u8, allocated: bool) !bool {
        self.stage = .headers;
        var pos: usize = 0;
        var buf = full;
        const max_header_size = self.max_header_size;
        line: while (buf.len > 0) {
            for (buf, 0..) |bn, i| {
                switch (bn) {
                    'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                    ':' => {
                        const value_start = i + 1; // skip the colon
                        var value, const skip_len = trimLeadingSpaceCount(buf[value_start..]);
                        for (value, 0..) |bv, j| {
                            if (j + i > max_header_size)
                                return error.HeaderTooBig;
                            if (allowedHeaderValueByte[bv] == true) {
                                continue;
                            }

                            // To keep ALLOWED_HEADER_VALUE small, we said \r
                            // was illegal. I mean, it _is_ illegal in a header value
                            // but it isn't part of the header value, it's (probably) the end of line
                            if (bv != '\r') {
                                return error.InvalidHeaderLine;
                            }

                            const next = j + 1;
                            if (next == value.len) {
                                // we don't have any more data, we can't tell
                                self.pos += pos;
                                return false;
                            }

                            if (value[next] != '\n') {
                                // we have a \r followed by something that isn't
                                // a \n. Can't be valid
                                return error.InvalidHeaderLine;
                            }

                            // If we're here, it means our value had valid characters
                            // up until the point of a newline (\r\n), which means
                            // we have a valid value (and name)
                            value = value[0..j];
                            break;
                        } else {
                            // for loop reached the end without finding a \r
                            // we need more data
                            self.pos += pos;
                            return false;
                        }

                        const name = buf[0..i];
                        if (self.headers.size >= self.max_header_count)
                            return error.TooManyHeaders;
                        const name_copy = if (self.headers.getKey(name) == null) blk: {
                            const alloc = try arena.dupe(u8, name);
                            _ = std.ascii.lowerString(alloc, name);
                            break :blk alloc;
                        } else name;
                        const value_copy = try arena.dupe(u8, value);
                        errdefer arena.free(value_copy);
                        const res = self.headers.getOrPutAssumeCapacity(name_copy);
                        if (res.found_existing) {
                            if (res.value_ptr.*.len + value_copy.len > max_header_size)
                                return error.HeaderTooBig;
                            const new_value = try std.mem.join(arena, ",", &.{ res.value_ptr.*, value_copy });
                            arena.free(value_copy);
                            arena.free(res.value_ptr.*);
                            res.value_ptr.* = new_value;
                        } else res.value_ptr.* = value_copy;
                        // +2 to skip the \r\n
                        const next_line = value_start + skip_len + value.len + 2;
                        pos += next_line;
                        buf = buf[next_line..];
                        continue :line;
                    },
                    '\r' => {
                        if (i != 0) {
                            // We're still parsing the header name, so a
                            // \r should either be at the very start (to indicate the end of our headers)
                            // or not be there at all
                            return error.InvalidHeaderLine;
                        }

                        if (buf.len == 1) {
                            // we don't have any more data, we need more data
                            self.pos += pos;
                            return false;
                        }

                        if (buf[1] == '\n') {
                            // we have \r\n at the start of a line, we're done
                            pos += 2;
                            self.buf = full[pos..];
                            self.pos += pos;
                            return try self.prepareForBody(arena, allocated);
                        }
                        // we have a \r followed by something that isn't a \n, can't be right
                        return error.InvalidHeaderLine;
                    },
                    else => return error.InvalidHeaderLine,
                }
            } else {
                // didn't find a colon or blank line, we need more data
                self.pos += pos;
                return false;
            }
        }
        self.pos += pos;
        return false;
    }

    fn prepareForBody(self: *Parser, arena: Allocator, allocated: bool) !bool {
        self.stage = .body;
        const str = self.headers.get("content-length") orelse return true;
        const cl = atoi(str) orelse return error.InvalidContentLength;

        if (cl == 0)
            return true;

        if (cl > self.max_body_size) {
            return error.BodyTooBig;
        }

        self.pos = 0;
        const buf = self.buf.?;
        const len = buf.len;

        // how much (if any) of the body we've already read
        var read = len;

        if (read > cl)
            read = cl;

        // how much of the body are we missing
        const missing = cl - read;

        if (missing == 0) {
            // we've read the entire body into buf, point to that.
            self.pos += cl;
            if (allocated) {
                self.body = .{ .dynamic = try arena.dupe(u8, buf[0..cl]) };
            } else {
                self.body = .{ .static = buf[0..cl] };
            }
            return true;
        } else {
            // We don't have the [full] body, and our static buffer is too small
            const body_buf = try arena.alloc(u8, cl);
            if (read > 0)
                @memcpy(body_buf[0..read], buf[0..read]);
            self.pos = read;
            self.body = .{ .dynamic = body_buf };
        }
        return false;
    }

    pub fn push(self: *Parser, L: *VM.lua.State, buffer: bool) !void {
        try L.createtable(0, 3);

        try L.Zpushvalue(.{
            .ok = self.status_code >= 200 and self.status_code < 300,
            .status_code = self.status_code,
            .status_reason = if (self.status_message) |msg| msg else "",
        });

        try L.createtable(0, @intCast(self.headers.size));
        var iter = self.headers.iterator();
        while (iter.next()) |header| {
            try L.pushlstring(header.key_ptr.*);
            try L.pushlstring(header.value_ptr.*);
            try L.rawset(-3);
        }
        try L.rawsetfield(-2, "headers");

        if (self.body) |body|
            switch (body) {
                inline else => |bytes| {
                    if (buffer) {
                        try L.Zpushbuffer(bytes);
                    } else {
                        try L.pushlstring(bytes);
                    }
                    try L.rawsetfield(-2, "body");
                },
            };
    }
};

const allowedHeaderValueByte = blk: {
    var v = [_]bool{false} ** 256;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_ :;.,/\"'?!(){}[]@<>=-+*#$&`|~^%\t\\") |b| {
        v[b] = true;
    }
    break :blk v;
};

inline fn trimLeadingSpaceCount(in: []const u8) struct { []const u8, usize } {
    if (in.len > 1 and in[0] == ' ') {
        // very common case
        const n = in[1];
        if (n != ' ' and n != '\t') {
            return .{ in[1..], 1 };
        }
    }

    for (in, 0..) |b, i| {
        if (b != ' ' and b != '\t') return .{ in[i..], i };
    }
    return .{ "", in.len };
}

inline fn trimLeadingSpace(in: []const u8) []const u8 {
    const out, _ = trimLeadingSpaceCount(in);
    return out;
}

fn atoi(str: []const u8) ?usize {
    if (str.len == 0) {
        return null;
    }

    var n: usize = 0;
    for (str) |b| {
        if (b < '0' or b > '9') {
            return null;
        }
        n = std.math.mul(usize, n, 10) catch return null;
        n = std.math.add(usize, n, @intCast(b - '0')) catch return null;
    }
    return n;
}

const testing = std.testing;

test "atoi" {
    var buf: [5]u8 = undefined;
    for (0..99999) |i| {
        const b = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        try testing.expectEqual(i, atoi(b).?);
    }

    try testing.expectEqual(null, atoi(""));
    try testing.expectEqual(null, atoi("392a"));
    try testing.expectEqual(null, atoi("b392"));
    try testing.expectEqual(null, atoi("3c92"));
}

test "allowedHeaderValueByte" {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('z' + 1)) |b| all[b] = true;
    for ('A'..('Z' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    for ([_]u8{ '_', ' ', ',', ':', ';', '.', ',', '\\', '/', '"', '\'', '?', '!', '(', ')', '{', '}', '[', ']', '@', '<', '>', '=', '-', '+', '*', '#', '$', '&', '`', '|', '~', '^', '%', '\t' }) |b| {
        all[b] = true;
    }
    for (128..255) |b| all[b] = false;

    for (all, 0..) |allowed, b| {
        try testing.expectEqual(allowed, allowedHeaderValueByte[@intCast(b)]);
    }
}

fn testParseProcedural(input: []const u8, max: u32) !Parser {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, max);
    errdefer parser.deinit();

    var tiny_buf: [1]u8 = undefined;
    for (input) |b| {
        tiny_buf[0] = b;
        if (try parser.parse(tiny_buf[0..1]))
            return parser;
    }

    return error.Incomplete;
}

fn testParseFull(comptime input: []const u8, max: u32) !Parser {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, max);
    errdefer parser.deinit();

    if (try parser.parse(input)) {
        return parser;
    }

    return error.Incomplete;
}

test "parser: basic (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: basic 2 (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expect(parser.status_message == null);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: basic 3 (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\n\r\n", 2);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(2, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: basic 4 (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nContent-Length: 5\r\n\r\ntest\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(5, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("5", parser.headers.get("content-length").?);
    try testing.expectEqual(.body, parser.stage);
    try testing.expectEqualStrings("test\n", parser.body.?.dynamic);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: many headers (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUpgrade-Insecure-Requests: 1\r\nCache-Control: max-age=0\r\n\r\n", 100);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(8, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: errors (procedural)" {
    try testing.expectError(error.Incomplete, testParseProcedural("HTTP/1.1 200 OK\r\n", 0));
    try testing.expectError(error.InvalidStatusCode, testParseProcedural("HTTP/1.1 20O OK\r\n\r\n", 0));
    try testing.expectError(error.InvalidStatusCode, testParseProcedural("HTTP/1.1 2000 OK\r\n\r\n", 0));
    try testing.expectError(error.UnsupportedProtocol, testParseProcedural("HTTP/3.0 200\r\n\r\n", 0));
    try testing.expectError(error.UnknownProtocol, testParseProcedural("HTTZ/3.0 200\r\n\r\n", 0));
    try testing.expectEqual(error.TooManyHeaders, testParseProcedural("HTTP/1.1 200\r\nHost: foo.bar\r\nAccept: text/html\r\n\r\n", 1));
    try testing.expectEqual(error.HeaderTooBig, testParseProcedural("HTTP/1.1 200\r\nHost: " ++ ("foobar" ** 690), 100));
}

test "parser: basic (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(19, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: basic 2 (full)" {
    var parser = try testParseFull("HTTP/1.1 200\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expect(parser.status_message == null);
    try testing.expectEqual(16, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: basic 3 (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\n\r\n", 2);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(52, parser.pos);
    try testing.expectEqual(2, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: basic 4 (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nContent-Length: 5\r\n\r\ntest\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(5, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("5", parser.headers.get("content-length").?);
    try testing.expectEqual(.body, parser.stage);
    try testing.expectEqualStrings("test\n", parser.body.?.static);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: many headers (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUpgrade-Insecure-Requests: 1\r\nCache-Control: max-age=0\r\n\r\n", 100);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(223, parser.pos);
    try testing.expectEqual(8, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: errors (full)" {
    try testing.expectError(error.Incomplete, testParseFull("HTTP/1.1 200 OK\r\n", 0));
    try testing.expectError(error.InvalidStatusCode, testParseFull("HTTP/1.1 20O OK\r\n\r\n", 0));
    try testing.expectError(error.InvalidStatusCode, testParseFull("HTTP/1.1 2000 OK\r\n\r\n", 0));
    try testing.expectError(error.UnsupportedProtocol, testParseFull("HTTP/3.0 200\r\n\r\n", 0));
    try testing.expectError(error.UnknownProtocol, testParseFull("HTTZ/3.0 200\r\n\r\n", 0));
    try testing.expectEqual(error.TooManyHeaders, testParseFull("HTTP/1.1 200\r\nHost: foo.bar\r\nAccept: text/html\r\n\r\n", 1));
    try testing.expectEqual(error.HeaderTooBig, testParseFull("HTTP/1.1 200\r\nHost: " ++ ("foobar" ** 690), 100));
}
