// This code is based on https://github.com/oven-sh/bun/blob/1aa35089d64f32b43901e850e34bc18b96c02899/src/http/websocket.zig
const std = @import("std");

pub const Opcode = enum(u4) {
    Continue = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Res3 = 0x3,
    Res4 = 0x4,
    Res5 = 0x5,
    Res6 = 0x6,
    Res7 = 0x7,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    ResB = 0xB,
    ResC = 0xC,
    ResD = 0xD,
    ResE = 0xE,
    ResF = 0xF,

    pub fn isControl(opcode: Opcode) bool {
        return @intFromEnum(opcode) & 0x8 != 0;
    }
};

pub fn acceptHashKey(out: []u8, key: []const u8) void {
    std.debug.assert(out.len >= 28);
    std.debug.assert(key.len == 24);

    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"); // https://www.rfc-editor.org/rfc/rfc6455

    _ = std.base64.standard.Encoder.encode(out, &hash.finalResult());
}

pub const Header = packed struct(u16) {
    len: u7,
    mask: bool,
    opcode: Opcode,
    rsv: u2 = 0, //rsv2 and rsv3
    compressed: bool = false, // rsv1
    final: bool = true,

    pub fn packLength(length: usize) u7 {
        return switch (length) {
            0...125 => @as(u7, @truncate(length)),
            126...0xFFFF => 126,
            else => 127,
        };
    }
};

pub const DataFrame = struct {
    header: Header,
    data: []const u8,

    pub fn isValid(dataframe: DataFrame) bool {
        // Validate control frame
        if (dataframe.header.opcode.isControl()) {
            if (!dataframe.header.final) {
                return false; // Control frames cannot be fragmented
            }
            if (dataframe.data.len > 125) {
                return false; // Control frame payloads cannot exceed 125 bytes
            }
        }

        // Validate header len field
        const expected = switch (dataframe.data.len) {
            0...126 => dataframe.data.len,
            127...0xFFFF => 126,
            else => 127,
        };
        return dataframe.header.len == expected;
    }
};

pub fn calcWriteSize(len: usize, mask: bool) usize {
    var size: usize = @as(usize, @sizeOf(Header)) + @as(usize, switch (len) {
        0...126 => 0,
        127...0xFFFF => @sizeOf(u16),
        else => @sizeOf(u64),
    }) + len;

    if (mask)
        size += 4; // mask

    return size;
}

pub fn writeDataFrame(buf: []u8, dataframe: DataFrame) void {
    std.debug.assert(dataframe.isValid());
    std.debug.assert(buf.len >= calcWriteSize(dataframe.data.len, dataframe.header.mask));

    std.mem.writeInt(u16, buf[0..2], @as(u16, @bitCast(dataframe.header)), .big);
    var pos: usize = 2;

    // Write extended length if needed
    const n = dataframe.data.len;
    switch (n) {
        0...126 => {}, // Included in header
        127...0xFFFF => {
            std.mem.writeInt(u16, buf[2..4], @as(u16, @intCast(n)), .big);
            pos = 4;
        },
        else => {
            std.mem.writeInt(u64, buf[2..10], n, .big);
            pos = 10;
        },
    }

    // TODO: Handle compression
    std.debug.assert(!dataframe.header.compressed);

    if (dataframe.header.mask) {
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        @memcpy(buf[pos .. pos + 4], &mask);
        pos += 4;

        // Encode
        for (dataframe.data, 0..) |c, i| {
            buf[pos + i] = c ^ mask[i % 4];
        }
    } else {
        @memcpy(buf[pos .. pos + n], dataframe.data);
    }
}

const ReaderState = enum { header, size, data, complete };
pub fn Reader(comptime masked: bool, comptime staticSize: usize, comptime maxLength: ?union(enum) { fast: usize, safe: usize }) type {
    return struct {
        state: ReaderState = .header,
        header: Header = std.mem.zeroes(Header),
        written: usize = 0,
        size: u64 = 0,
        mask: if (masked) [4]u8 else void = if (masked) std.mem.zeroes([4]u8) else undefined,
        data: union(enum) {
            none: void,
            allocated: []u8,
            static: [staticSize]u8,
        } = .none,

        const StaticSize = staticSize;

        const Self = @This();

        comptime {
            if (maxLength) |max|
                switch (max) {
                    .fast, .safe => |m| std.debug.assert(m >= staticSize),
                };
        }

        pub fn next(self: *Self, allocator: std.mem.Allocator, buf: []const u8, consumed: *usize) !bool {
            consumed.* = 0;
            if (buf.len == 0)
                return false;
            errdefer self.state = .header;
            next: switch (self.state) {
                .complete => {
                    self.reset(allocator);
                    continue :next .header;
                },
                .header => {
                    var short: [2]u8 = @bitCast(self.header);
                    if (buf.len + self.written < 2) {
                        @memcpy(short[self.written .. self.written + buf.len], buf[self.written..buf.len]);
                        self.written += buf.len;
                        self.header = @bitCast(short); // partial
                        consumed.* += buf.len;
                        return false;
                    }
                    const consume = 2 - self.written;
                    @memcpy(short[self.written..2], buf[0..consume]); // full
                    consumed.* += consume;

                    self.header = @bitCast(std.mem.readVarInt(u16, short[0..2], .big));

                    self.written = 0;
                    if (masked != self.header.mask)
                        return if (comptime masked) error.UnmaskedMessage else error.MaskedMessage;

                    self.state = .size;
                    continue :next .size;
                },
                .size => {
                    var size_slice: [@sizeOf(u64)]u8 = @bitCast(self.size);
                    self.size = switch (self.header.len) {
                        126 => blk: {
                            const slice = buf[consumed.*..];
                            if (slice.len == 0)
                                return false;
                            if (slice.len + self.written < 2) {
                                @memcpy(size_slice[self.written .. self.written + slice.len], slice[0..]);
                                self.written += slice.len;
                                consumed.* += slice.len;
                                self.size = @bitCast(size_slice); // partial
                                return false;
                            }
                            const consume = 2 - self.written;
                            @memcpy(size_slice[self.written..2], slice[0..consume]); // full
                            consumed.* += consume;
                            var short: [2]u8 = undefined;
                            @memcpy(short[0..], size_slice[0..2]);
                            break :blk @as(usize, @byteSwap(@as(u16, @bitCast(short))));
                        },
                        127 => blk: {
                            const slice = buf[consumed.*..];
                            if (slice.len == 0)
                                return false;
                            if (slice.len + self.written < 8) {
                                @memcpy(size_slice[self.written .. self.written + slice.len], slice[0..]);
                                self.written += slice.len;
                                consumed.* += slice.len;
                                self.size = @bitCast(size_slice); // partial
                                return false;
                            }
                            const consume = 8 - self.written;
                            @memcpy(size_slice[self.written..8], slice[0..consume]); // full
                            consumed.* += consume;
                            break :blk @as(usize, @byteSwap(@as(u64, @bitCast(size_slice))));
                        },
                        else => self.header.len,
                    };
                    self.written = 0;
                    if (comptime maxLength) |max| {
                        switch (comptime max) {
                            .fast => |m| {
                                errdefer self.size = 0;
                                const size = self.size;
                                if (size > m)
                                    return error.MessageTooLarge;
                            },
                            else => {},
                        }
                    }
                    self.state = .data;
                    continue :next .data;
                },
                .data => {
                    var slice = buf[consumed.*..];
                    if (slice.len == 0)
                        return false;
                    if (comptime masked) {
                        if (self.data == .none and self.written < 4) {
                            if (slice.len + self.written < 4) {
                                @memcpy(self.mask[self.written .. self.written + slice.len], slice[0..]);
                                self.written += slice.len;
                                consumed.* += slice.len;
                                return false; // partial
                            }
                            const consume = 4 - self.written;
                            @memcpy(self.mask[self.written..4], slice[0..consume]); // full
                            consumed.* += consume;
                            slice = slice[consume..];
                            self.written = 0;
                        }
                    }
                    if (self.size <= StaticSize) {
                        if (self.size > 0) {
                            if (self.data != .static)
                                self.data = .{ .static = undefined };
                            if (slice.len + self.written < self.size) {
                                @memcpy(self.data.static[self.written .. self.written + slice.len], slice[0..]);
                                self.written += slice.len;
                                consumed.* += slice.len;
                                return false; // partial
                            }
                            const consume = self.size - self.written;
                            @memcpy(self.data.static[self.written..self.size], slice[0..consume]);
                            consumed.* += consume;
                        }
                    } else {
                        if (comptime maxLength) |max| {
                            switch (comptime max) {
                                .safe => |m| {
                                    const size = self.size;
                                    if (size > m) {
                                        const consume = @min(self.size - self.written, slice.len);
                                        self.written += consume;
                                        consumed.* += consume;
                                        if (self.written < size)
                                            return false; // partial
                                        self.reset(allocator);
                                        return error.MessageTooLarge;
                                    }
                                },
                                else => {},
                            }
                        }
                        if (self.data != .allocated)
                            self.data = .{ .allocated = try allocator.alloc(u8, self.size) };
                        if (slice.len + self.written < self.size) {
                            @memcpy(self.data.allocated[self.written .. self.written + slice.len], slice[0..]);
                            consumed.* += slice.len;
                            self.written += slice.len;
                            return false; // partial
                        }
                        const consume = self.size - self.written;
                        @memcpy(self.data.allocated[self.written..self.size], slice[0..consume]);
                        consumed.* += consume;
                    }
                    if (comptime masked) {
                        const mask = self.mask[0..];
                        const payload: []u8 = switch (self.data) {
                            .allocated => self.data.allocated[0..self.size],
                            .static => self.data.static[0..self.size],
                            .none => unreachable,
                        };
                        if (payload.len > 0)
                            for (payload, 0..) |_, i| {
                                payload[i] ^= mask[i % 4];
                            };
                    }
                    self.state = .complete;
                    return true;
                },
            }
        }

        pub fn getData(self: *Self) []const u8 {
            return switch (self.data) {
                .allocated => self.data.allocated[0..self.size],
                .static => self.data.static[0..self.size],
                .none => &[_]u8{},
            };
        }

        pub fn reset(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.data) {
                .allocated => |buf| allocator.free(buf),
                .none, .static => {},
            }
            self.* = .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.reset(allocator);
        }
    };
}

fn testReaderProcedural(reader: anytype, input: []const u8) !void {
    const allocator = std.testing.allocator;

    var tiny_buf: [1]u8 = undefined;
    for (input, 0..) |b, i| {
        tiny_buf[0] = b;
        var consumed: usize = 0;
        const finished = i == input.len - 1;
        try std.testing.expect(try reader.next(allocator, tiny_buf[0..], &consumed) == finished);
        try std.testing.expectEqual(1, consumed);
    }

    return;
}

fn testReaderProceduralIncomplete(reader: anytype, input: []const u8) !void {
    const allocator = std.testing.allocator;

    var tiny_buf: [1]u8 = undefined;
    for (input) |b| {
        tiny_buf[0] = b;
        var consumed: usize = 0;
        try std.testing.expect(try reader.next(allocator, tiny_buf[0..], &consumed) == false);
        try std.testing.expectEqual(1, consumed);
    }

    return;
}

test Reader {
    const allocator = std.testing.allocator;
    {
        const example_header: Header = .{
            .len = Header.packLength(5),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 128, null) = .{};

        var consumed: usize = 0;
        try std.testing.expectEqual(.header, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{}, &consumed) catch unreachable));
        try std.testing.expectEqual(0, consumed);
        try std.testing.expectEqual(.header, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[0]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.header, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[1]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);

        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expectEqual(5, reader.header.len);
        try std.testing.expectEqual(false, reader.header.mask);
        try std.testing.expectEqual(.Text, reader.header.opcode);
        try std.testing.expectEqual(0, reader.header.rsv);
        try std.testing.expectEqual(false, reader.header.compressed);
        try std.testing.expectEqual(true, reader.header.final);

        try std.testing.expect(!(reader.next(allocator, &[_]u8{}, &consumed) catch unreachable));
        try std.testing.expectEqual(0, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'H'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'e'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'l'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'l'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(reader.next(allocator, &[_]u8{'o'}, &consumed) catch unreachable);
        try std.testing.expectEqual(1, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .static);
        try std.testing.expectEqualStrings("Hello", reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(5),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 2, null) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[0]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[1]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'H'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'e'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'l'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'l'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(reader.next(allocator, &[_]u8{'o'}, &consumed) catch unreachable);
        try std.testing.expectEqual(1, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .allocated);
        try std.testing.expectEqualStrings("Hello", reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(5),
            .mask = true,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(true, 2, null) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[0]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[1]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{0}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{0}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{0}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{0}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'H'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'e'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'l'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{'l'}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(reader.next(allocator, &[_]u8{'o'}, &consumed) catch unreachable);
        try std.testing.expectEqual(1, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .allocated);
        try std.testing.expectEqualStrings(&[_]u8{ 0, 0, 0, 0 }, reader.mask[0..]);
        try std.testing.expectEqualStrings("Hello", reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(200),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 2, null) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[0]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{header_bytes[1]}, &consumed) catch unreachable));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.size, reader.state);
        try std.testing.expect(!(reader.next(allocator, &[_]u8{ 0x00, 0xC8 }, &consumed) catch unreachable));
        try std.testing.expectEqual(2, consumed);
        try std.testing.expectEqual(200, reader.size);
        try std.testing.expectEqual(.data, reader.state);
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(5),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 5, null) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expect((reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] } ++ "Hello and more bytes", &consumed) catch unreachable));
        try std.testing.expectEqual(7, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .static);
        try std.testing.expectEqualStrings("Hello", reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(5),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 2, null) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expect((reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] } ++ "Hello and more bytes", &consumed) catch unreachable));
        try std.testing.expectEqual(7, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .allocated);
        try std.testing.expectEqualStrings("Hello", reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(5),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 2, null) = .{};
        defer reader.deinit(allocator);

        try testReaderProcedural(&reader, &[_]u8{ header_bytes[0], header_bytes[1] } ++ "Hello");

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .allocated);
        try std.testing.expectEqualStrings("Hello", reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(200),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 200, null) = .{};
        defer reader.deinit(allocator);

        const short_size: u16 = 200;

        var consumed: usize = 0;
        try std.testing.expect((reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] } ++ @as([2]u8, @bitCast(@byteSwap(short_size))) ++ "Hello" ** 40, &consumed) catch unreachable));
        try std.testing.expectEqual(204, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .static);
        try std.testing.expectEqualStrings("Hello" ** 40, reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(200),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 200, null) = .{};
        defer reader.deinit(allocator);

        const short_size: u16 = 200;

        try testReaderProcedural(&reader, &[_]u8{ header_bytes[0], header_bytes[1] } ++ @as([2]u8, @bitCast(@byteSwap(short_size))) ++ "Hello" ** 40);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .static);
        try std.testing.expectEqualStrings("Hello" ** 40, reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(200),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, null) = .{};
        defer reader.deinit(allocator);

        const short_size: u16 = 200;

        var consumed: usize = 0;
        try std.testing.expect((reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] } ++ @as([2]u8, @bitCast(@byteSwap(short_size))) ++ "Hello" ** 40, &consumed) catch unreachable));
        try std.testing.expectEqual(204, consumed);

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .allocated);
        try std.testing.expectEqualStrings("Hello" ** 40, reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(200),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, null) = .{};
        defer reader.deinit(allocator);

        const short_size: u16 = 200;
        try testReaderProcedural(
            &reader,
            &[_]u8{ header_bytes[0], header_bytes[1] } ++ @as([2]u8, @bitCast(@byteSwap(short_size))) ++ "Hello" ** 40,
        );

        try std.testing.expectEqual(.complete, reader.state);
        try std.testing.expect(reader.data == .allocated);
        try std.testing.expectEqualStrings("Hello" ** 40, reader.getData());
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(0xFFFF + 1),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, null) = .{};
        defer reader.deinit(allocator);

        const short_size: u64 = 0xFFFF + 1;

        var consumed: usize = 0;
        try std.testing.expect(!(reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] } ++ @as([8]u8, @bitCast(@byteSwap(short_size))), &consumed) catch unreachable));
        try std.testing.expectEqual(10, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(reader.data == .none);
        try std.testing.expectEqual(0xFFFF + 1, reader.size);
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(0xFFFF + 1),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, null) = .{};
        defer reader.deinit(allocator);

        const short_size: u64 = 0xFFFF + 1;

        try testReaderProceduralIncomplete(&reader, &[_]u8{ header_bytes[0], header_bytes[1] } ++ @as([8]u8, @bitCast(@byteSwap(short_size))));

        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expect(reader.data == .none);
        try std.testing.expectEqual(0xFFFF + 1, reader.size);
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(6),
            .mask = true,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, null) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expectError(error.MaskedMessage, reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] }, &consumed));
        try std.testing.expectEqual(.header, reader.state);
        try std.testing.expectEqual(0, reader.written);
        try std.testing.expectEqual(.none, reader.data);
        try std.testing.expectEqual(0, reader.size);
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(1),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, .{ .fast = 0 }) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expectError(error.MessageTooLarge, reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] }, &consumed));
        try std.testing.expectEqual(2, consumed);
        try std.testing.expectEqual(.header, reader.state);
        try std.testing.expectEqual(0, reader.written);
        try std.testing.expectEqual(.none, reader.data);
        try std.testing.expectEqual(0, reader.size);
    }

    {
        const example_header: Header = .{
            .len = Header.packLength(1),
            .mask = false,
            .opcode = Opcode.Text,
            .rsv = 0,
            .compressed = false,
            .final = true,
        };
        const header_bytes: [2]u8 = @bitCast(@byteSwap(@as(u16, @bitCast(example_header))));
        var reader: Reader(false, 0, .{ .safe = 0 }) = .{};
        defer reader.deinit(allocator);

        var consumed: usize = 0;
        try std.testing.expect(!(reader.next(allocator, &[_]u8{ header_bytes[0], header_bytes[1] }, &consumed) catch unreachable));
        try std.testing.expectEqual(2, consumed);
        try std.testing.expectEqual(.data, reader.state);
        try std.testing.expectEqual(0, reader.written);
        try std.testing.expectEqual(.none, reader.data);
        try std.testing.expectEqual(1, reader.size);

        try std.testing.expectError(error.MessageTooLarge, reader.next(allocator, &[_]u8{1}, &consumed));
        try std.testing.expectEqual(1, consumed);
        try std.testing.expectEqual(.header, reader.state);
        try std.testing.expectEqual(0, reader.written);
        try std.testing.expectEqual(.none, reader.data);
        try std.testing.expectEqual(0, reader.size);
    }
}
