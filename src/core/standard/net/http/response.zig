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

    stage: Stage = .protocol,
    protocol: Protocol = .HTTP10,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: ?union(enum) {
        dynamic: std.Io.Writer,
        chunked: struct {
            size: ?usize = null,
            buffer: std.ArrayListUnmanaged(u8) = .empty,
        },
        static: []const u8,
    } = null,
    status_code: u16 = 200,
    status_message: ?[]const u8 = null,

    max_body_size: usize = 1_048_576,
    max_header_size: usize = 4096,
    max_header_count: usize = 100,

    const Stage = enum { protocol, headers, body, done };

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

        self.pos = 0;

        sw: switch (self.stage) {
            .protocol => continue :sw try self.parseProtocol(arena_allocator, input[self.pos..]) orelse break :sw,
            .headers => continue :sw try self.parseHeaders(arena_allocator, input[self.pos..], allocated) orelse break :sw,
            .body => continue :sw try self.parseBody(arena_allocator, input[self.pos..]) orelse break :sw,
            .done => {
                self.stage = .done;
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
    fn parseProtocol(self: *Parser, arena: std.mem.Allocator, buf: []const u8) !?Stage {
        self.stage = .protocol;
        if (buf.len < 12) return null;
        const end = std.mem.indexOf(u8, buf, "\r\n") orelse if (buf.len > 64) return error.TooLarge else return null;
        if (end < 12) return null;

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
        return .headers;
    }

    fn parseHeaders(self: *Parser, arena: Allocator, full: []const u8, allocated: bool) !?Stage {
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
                                return null;
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
                            return null;
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
                            return null;
                        }

                        if (buf[1] == '\n') {
                            // we have \r\n at the start of a line, we're done
                            pos += 2;
                            self.pos += pos;
                            return try self.prepareForBody(arena, full[pos..], allocated);
                        }
                        // we have a \r followed by something that isn't a \n, can't be right
                        return error.InvalidHeaderLine;
                    },
                    else => return error.InvalidHeaderLine,
                }
            } else {
                // didn't find a colon or blank line, we need more data
                self.pos += pos;
                return null;
            }
        }
        self.pos += pos;
        return null;
    }

    fn prepareForBody(self: *Parser, arena: Allocator, buf: []const u8, allocated: bool) !?Stage {
        self.stage = .body;
        const str = self.headers.get("content-length") orelse {
            const encoding = self.headers.get("transfer-encoding") orelse return .done;
            var iter = std.mem.splitScalar(u8, encoding, ',');
            var chunked_found = false;
            while (iter.next()) |enc| {
                if (std.mem.eql(u8, enc, "chunked")) {
                    chunked_found = true;
                } else return error.UnsupportedTransferEncoding;
            }
            if (chunked_found) {
                self.body = .{ .chunked = .{} };
                return .body;
            }
            return .done;
        };
        const cl = atoi(str) orelse return error.InvalidContentLength;

        if (cl == 0)
            return .done;

        if (cl > self.max_body_size) {
            return error.BodyTooBig;
        }

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
                self.body = .{ .dynamic = .fixed(try arena.dupe(u8, buf[0..cl])) };
            } else {
                self.body = .{ .static = buf[0..cl] };
            }
            return .done;
        } else {
            // We don't have the [full] body, and our static buffer is too small
            const body_buf = try arena.alloc(u8, cl);
            if (read > 0)
                @memcpy(body_buf[0..read], buf[0..read]);
            self.pos += read;
            self.body = .{ .dynamic = .fixed(body_buf) };
            self.body.?.dynamic.end = read;
        }
        return null;
    }

    fn parseBody(self: *Parser, arena: Allocator, buffer: []const u8) !?Stage {
        self.stage = .body;
        if (buffer.len == 0) return null;
        if (self.body) |*b|
            switch (b.*) {
                .dynamic => |*writer| {
                    const remaining = writer.buffer.len - writer.end;
                    const consume = buffer[0..@min(remaining, buffer.len)];
                    self.pos += consume.len;
                    std.debug.assert(writer.write(consume) catch unreachable == consume.len);
                    if (writer.buffer.len - writer.end == 0)
                        return .done;
                    return null;
                },
                .chunked => |*chunked| {
                    if (chunked.size) |sz| {
                        if (sz <= 2) {
                            const consume = buffer[0..@min(sz, buffer.len)];
                            chunked.size = sz - consume.len;
                            switch (sz) {
                                2 => switch (consume.len) {
                                    2 => if (!std.mem.eql(u8, consume, "\r\n"))
                                        return error.InvalidChunkedEncoding,
                                    1 => if (consume[0] != '\r')
                                        return error.InvalidChunkedEncoding,
                                    else => unreachable,
                                },
                                1 => if (consume[0] != '\n') return error.InvalidChunkedEncoding,
                                else => unreachable,
                            }
                            if (chunked.size == 0)
                                chunked.size = null;
                            self.pos += consume.len;
                            return .body;
                        }
                        const consume = buffer[0..@min(sz - 2, buffer.len)];
                        chunked.size = sz - consume.len;
                        chunked.buffer.appendSliceAssumeCapacity(consume);
                        self.pos += consume.len;
                        return .body;
                    }
                    const end_index = std.mem.indexOfScalar(u8, buffer, '\n') orelse return null;
                    if (buffer.len < 2 or end_index < 1 or buffer[end_index - 1] != '\r')
                        return error.InvalidChunkedEncoding;
                    const number = buffer[0 .. end_index - 1];
                    if (number.len == 0)
                        return error.InvalidChunkedEncoding;
                    const size = atoi(number) orelse return error.InvalidChunkedEncoding;
                    if (size == 0) {
                        if (buffer.len < end_index + 3)
                            return null;
                        if (!std.mem.eql(u8, buffer[end_index + 1 .. end_index + 3], "\r\n"))
                            return error.InvalidChunkedEncoding;
                        return .done;
                    }
                    if (chunked.buffer.items.len + size > self.max_body_size)
                        return error.BodyTooBig;
                    try chunked.buffer.ensureUnusedCapacity(arena, size);
                    chunked.size = size + 2;
                    self.pos += end_index + 1;
                    return .body;
                },
                else => {},
            };
        return .done;
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
                .static => |bytes| {
                    if (buffer) try L.Zpushbuffer(bytes) else try L.pushlstring(bytes);
                    try L.rawsetfield(-2, "body");
                },
                .dynamic => |writer| {
                    if (buffer) try L.Zpushbuffer(writer.buffer) else try L.pushlstring(writer.buffer);
                    try L.rawsetfield(-2, "body");
                },
                .chunked => |chunked| {
                    if (buffer) try L.Zpushbuffer(chunked.buffer.items) else try L.pushlstring(chunked.buffer.items);
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

fn testParseProceduralIncomplete(input: []const u8, max: u32) !void {
    for (0..input.len) |i| {
        const slice = input[0..i];
        try std.testing.expectError(error.Incomplete, testParseProcedural(slice, max));
    }
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
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
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
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
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
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.left == null);
}

test "parser: basic 4 (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nContent-Length: 5\r\n\r\ntest\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(1, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("5", parser.headers.get("content-length").?);
    try testing.expectEqual(.done, parser.stage);
    try testing.expectEqualStrings("test\n", parser.body.?.dynamic.buffer);
    try testing.expect(parser.left == null);
}

test "parser: chunk transfer encoding (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\ntest\n\r\n0\r\n\r\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(0, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("chunked", parser.headers.get("transfer-encoding").?);
    try testing.expectEqual(.done, parser.stage);
    try testing.expectEqualStrings("test\n", parser.body.?.chunked.buffer.items);
    try testing.expect(parser.left == null);
}

test "parser: chunk transfer encoding 2 (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\ntest\n\r\n1\r\nt\r\n1\r\ne\r\n1\r\ns\r\n1\r\nt\r\n0\r\n\r\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(0, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("chunked", parser.headers.get("transfer-encoding").?);
    try testing.expectEqual(.done, parser.stage);
    try testing.expectEqualStrings("test\ntest", parser.body.?.chunked.buffer.items);
    try testing.expect(parser.left == null);
}

test "parser: bad chunked transfer encoding (procedural)" {
    try testParseProceduralIncomplete("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n", 1);
    try testing.expectError(error.Incomplete, testParseProcedural("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n", 1));
    try testing.expectError(error.InvalidChunkedEncoding, testParseProcedural("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\r\r\n", 1));
    try testing.expectError(error.InvalidChunkedEncoding, testParseProcedural("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n  \r\n", 1));
    try testing.expectError(error.InvalidChunkedEncoding, testParseProcedural("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nhello\r\n", 1));
}

test "parser: many headers (procedural)" {
    var parser = try testParseProcedural("HTTP/1.1 200 OK\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUpgrade-Insecure-Requests: 1\r\nCache-Control: max-age=0\r\n\r\n", 100);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(8, parser.headers.size);
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
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
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
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
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
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
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.left == null);
}

test "parser: basic 4 (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nContent-Length: 5\r\n\r\ntest\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(76, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("5", parser.headers.get("content-length").?);
    try testing.expectEqual(.done, parser.stage);
    try testing.expectEqualStrings("test\n", parser.body.?.static);
    try testing.expect(parser.left == null);
}

test "parser: chunk transfer encoding (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\ntest\n\r\n0\r\n\r\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(90, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("chunked", parser.headers.get("transfer-encoding").?);
    try testing.expectEqual(.done, parser.stage);
    try testing.expectEqualStrings("test\n", parser.body.?.chunked.buffer.items);
    try testing.expect(parser.left == null);
}

test "parser: chunk transfer encoding 2 (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\ntest\n\r\n1\r\nt\r\n1\r\ne\r\n1\r\ns\r\n1\r\nt\r\n0\r\n\r\n", 3);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(114, parser.pos);
    try testing.expectEqual(3, parser.headers.size);
    try testing.expectEqualStrings("false", parser.headers.get("test").?);
    try testing.expectEqualStrings("somehost.com", parser.headers.get("host").?);
    try testing.expectEqualStrings("chunked", parser.headers.get("transfer-encoding").?);
    try testing.expectEqual(.done, parser.stage);
    try testing.expectEqualStrings("test\ntest", parser.body.?.chunked.buffer.items);
    try testing.expect(parser.left == null);
}

test "parser: bad chunked transfer encoding (full)" {
    try testing.expectError(error.Incomplete, testParseFull("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n", 1));
    try testing.expectError(error.InvalidChunkedEncoding, testParseFull("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\r\r\n", 1));
    try testing.expectError(error.InvalidChunkedEncoding, testParseFull("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n  \r\n", 1));
    try testing.expectError(error.InvalidChunkedEncoding, testParseFull("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nhello\r\n", 1));
}

test "parser: many headers (full)" {
    var parser = try testParseFull("HTTP/1.1 200 OK\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUpgrade-Insecure-Requests: 1\r\nCache-Control: max-age=0\r\n\r\n", 100);
    defer parser.deinit();

    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(200, parser.status_code);
    try testing.expectEqualStrings("OK", parser.status_message.?);
    try testing.expectEqual(223, parser.pos);
    try testing.expectEqual(8, parser.headers.size);
    try testing.expectEqual(.done, parser.stage);
    try testing.expect(parser.body == null);
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
