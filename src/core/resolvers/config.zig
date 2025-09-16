const std = @import("std");

const log = std.log.scoped(.Config);

pub fn isValidAlias(alias: []const u8) bool {
    if (alias.len == 0)
        return false;
    if (std.mem.eql(u8, alias, ".") or std.mem.eql(u8, alias, "..") or std.mem.indexOfAny(u8, alias, "/\\") != null)
        return false;
    for (alias) |b| switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9' => continue,
        '-', '_', '.' => continue,
        else => return false,
    };
    return true;
}

const Config = @This();

mode: Mode = .Nonstrict,
lintErrors: bool = false,
typeErrors: bool = true,
aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
globals: std.ArrayListUnmanaged([]const u8) = .empty,

const Mode = enum {
    NoCheck,
    Strict,
    Nonstrict,
};

pub const Parser = struct {
    offset: usize = 0,
    line: usize = 1,
    lineOffset: usize = 0,
    err_message: ?*?[]const u8 = null,
    allocator: std.mem.Allocator,
    buffer: []const u8,
    current: Token = .Eof,

    inline fn isSpace(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\r', '\n' => true,
            11, 12 => true, // \v, \f
            else => false,
        };
    }
    inline fn isQuote(c: u8) bool {
        return c == '"' or c == '\'';
    }
    inline fn isNewline(c: u8) bool {
        return c == '\n';
    }
    inline fn isAlpha(c: u8) bool {
        return switch (c) {
            'A'...'Z', 'a'...'z' => true,
            else => false,
        };
    }
    inline fn isDigit(c: u8) bool {
        return switch (c) {
            '0'...'9' => true,
            else => false,
        };
    }

    inline fn peek(self: *Parser) u8 {
        if (self.offset >= self.buffer.len)
            return 0; // EOF
        return self.buffer[self.offset];
    }
    inline fn peekahead(self: *Parser, lookahead: usize) u8 {
        if (self.offset + lookahead >= self.buffer.len)
            return 0; // EOF
        return self.buffer[self.offset + lookahead];
    }

    fn readName(self: *Parser) []const u8 {
        std.debug.assert(isAlpha(self.peek()) or self.peek() == '_' or self.peek() == '@');
        const startOffset = self.offset;
        self.consume();
        while (isAlpha(self.peek()) or isDigit(self.peek()) or self.peek() == '_')
            self.consume();
        return self.buffer[startOffset..self.offset];
    }

    fn readQuotedString(self: *Parser) ?[]const u8 {
        const delimiter = self.peek();
        std.debug.assert(delimiter == '"' or delimiter == '\'');
        self.consume();

        const startOffset = self.offset;
        while (self.peek() != delimiter) {
            switch (self.peek()) {
                0, '\r', '\n' => return null,
                '\\' => {
                    self.consume();
                    switch (self.peek()) {
                        0 => {},
                        '\r' => {
                            self.consume();
                            if (self.peek() == '\n') {
                                self.consumeAny();
                            }
                        },
                        'z' => {
                            self.consume();
                            while (isSpace(self.peek()))
                                self.consumeAny();
                        },
                        else => self.consumeAny(),
                    }
                    continue;
                },
                else => {},
            }
            self.consume();
        }

        self.consume();

        return self.buffer[startOffset .. self.offset - 1];
    }

    inline fn consume(self: *Parser) void {
        std.debug.assert(!isNewline(self.buffer[self.offset]));
        self.offset += 1;
    }

    inline fn consumeAny(self: *Parser) void {
        if (isNewline(self.buffer[self.offset])) {
            self.line += 1;
            self.lineOffset = self.offset + 1;
        }
        self.offset += 1;
    }

    const Token = union(enum) {
        Character: u8,
        String: []const u8,
        Name: []const u8,
        BrokenString: void,
        ReservedTrue: void,
        ReservedFalse: void,
        FloorDiv: void,
        Eof: void,

        pub fn char(self: Token) u8 {
            return switch (self) {
                .Character => |c| c,
                .String => |s| s[0],
                else => 0,
            };
        }
    };

    fn nextline(self: *Parser) void {
        while (self.peek() != 0 and self.peek() != '\r' and !isNewline(self.peek()))
            self.consume();

        self.next();
    }

    fn next(self: *Parser) void {
        while (isSpace(self.peek()))
            self.consumeAny();
        self.current = switch (self.peek()) {
            0 => .Eof,
            '"', '\'' => blk: {
                if (self.readQuotedString()) |s|
                    break :blk .{ .String = s }
                else
                    break :blk .{ .BrokenString = {} };
            },
            '/' => blk: {
                self.consume();
                if (self.peek() == '/')
                    break :blk .FloorDiv
                else
                    break :blk .{ .Character = '/' };
            },
            '_', 'A'...'Z', 'a'...'z' => blk: {
                const name = self.readName();
                if (std.mem.eql(u8, name, "true")) {
                    break :blk .{ .ReservedTrue = {} };
                } else if (std.mem.eql(u8, name, "false")) {
                    break :blk .{ .ReservedFalse = {} };
                } else {
                    break :blk .{ .Name = name };
                }
            },
            else => |c| blk: {
                self.consume();
                break :blk .{ .Character = c };
            },
        };

        if (self.current == .FloorDiv)
            self.nextline();
    }

    fn fail(self: *Parser, comptime message: []const u8) !void {
        if (self.err_message) |msg|
            msg.* = try std.fmt.allocPrint(self.allocator, ".luaurc: Expected " ++ message ++ " at line {d}", .{self.line});
        return error.SyntaxError;
    }
    fn failFmt(self: *Parser, comptime fmt: []const u8, args: anytype) !void {
        if (self.err_message) |msg|
            msg.* = try std.fmt.allocPrint(self.allocator, ".luaurc: " ++ fmt ++ " at line {d}", args ++ .{self.line});
        return error.SyntaxError;
    }

    fn parseModeString(value: []const u8, compat: bool) ?Mode {
        if (std.mem.eql(u8, value, "nocheck")) {
            return .NoCheck;
        } else if (std.mem.eql(u8, value, "strict")) {
            return .Strict;
        } else if (std.mem.eql(u8, value, "nonstrict")) {
            return .Nonstrict;
        } else if (std.mem.eql(u8, value, "noinfer") and compat) {
            return .NoCheck;
        } else return null;
    }

    pub const ParseOptions = struct {
        overwriteAliases: bool = false,
    };

    pub fn process(self: *Parser, allocator: std.mem.Allocator, config: *Config, opts: ParseOptions) !void {
        var keys: [2][]const u8 = undefined;
        var key_count: u8 = 0;

        self.next();
        if (self.current.char() != '{')
            return self.fail("'{{'");

        var arrayTop: bool = false;

        self.next();

        while (true) {
            if (arrayTop) {
                if (self.current.char() == ']') {
                    self.next();
                    arrayTop = false;

                    std.debug.assert(key_count > 0);
                    key_count -= 1;

                    if (self.current.char() == ',') {
                        self.next();
                    } else if (self.current.char() != '}') {
                        return self.fail("',' or '}}'");
                    }
                } else if (self.current == .String) {
                    const value = self.current.String;
                    self.next();

                    switch (key_count) {
                        1 => {
                            if (std.mem.eql(u8, keys[0], "globals")) {
                                const copy = try allocator.dupe(u8, value);
                                errdefer allocator.free(copy);
                                try config.globals.append(allocator, copy);
                            } else {
                                const path = try std.mem.join(allocator, "/", keys[0..key_count]);
                                defer allocator.free(path);
                                return self.failFmt("Unknown key {s}", .{path});
                            }
                        },
                        else => {
                            const path = try std.mem.join(allocator, "/", keys[0..key_count]);
                            defer allocator.free(path);
                            return self.failFmt("Unknown key {s}", .{path});
                        },
                    }

                    if (self.current.char() == ',')
                        self.next()
                    else if (self.current.char() != ']')
                        return self.fail("',' or ']'");
                } else return self.fail("array element or ']'");
            } else {
                if (self.current.char() == '}') {
                    self.next();
                    if (key_count == 0) {
                        if (self.current != .Eof)
                            return self.fail("end of file");
                        return;
                    } else {
                        key_count -= 1;
                    }
                    if (self.current.char() == ',') {
                        self.next();
                    } else if (self.current.char() != '}') {
                        return self.fail("',' or '}}'");
                    }
                } else if (self.current == .String) {
                    if (key_count >= keys.len)
                        return self.fail("short keys");
                    keys[key_count] = self.current.String;
                    key_count += 1;

                    self.next();

                    if (self.current.char() != ':')
                        return self.fail("':'");
                    self.next();

                    if (self.current.char() == '{' or self.current.char() == '[') {
                        arrayTop = self.current.char() == '[';
                        self.next();
                    } else if (self.current == .String or self.current == .ReservedTrue or self.current == .ReservedFalse) {
                        switch (key_count) {
                            1 => {
                                if (std.mem.eql(u8, keys[0], "languageMode")) {
                                    const value = switch (self.current) {
                                        .String => |s| s,
                                        .ReservedTrue => "true",
                                        .ReservedFalse => "false",
                                        else => unreachable, // assert
                                    };
                                    if (parseModeString(value, false)) |mode|
                                        config.mode = mode
                                    else
                                        return self.failFmt("Bad mode \"{s}\".  Valid options are nocheck, nonstrict, and strict", .{value});
                                } else if (std.mem.eql(u8, keys[0], "lintErrors")) {
                                    config.lintErrors = switch (self.current) {
                                        .ReservedTrue => true,
                                        .ReservedFalse => false,
                                        .String => |s| return self.failFmt("Bad mode \"{s}\".  Valid options are true and false", .{s}),
                                        else => unreachable, // assert
                                    };
                                } else if (std.mem.eql(u8, keys[0], "typeErrors")) {
                                    config.typeErrors = switch (self.current) {
                                        .ReservedTrue => true,
                                        .ReservedFalse => false,
                                        .String => |s| return self.failFmt("Bad mode \"{s}\".  Valid options are true and false", .{s}),
                                        else => unreachable, // assert
                                    };
                                } else {
                                    const path = try std.mem.join(allocator, "/", keys[0..key_count]);
                                    defer allocator.free(path);
                                    return self.failFmt("Unknown key {s}", .{path});
                                }
                            },
                            2 => {
                                if (std.mem.eql(u8, keys[0], "aliases")) {
                                    const alias = keys[1];
                                    if (!isValidAlias(alias))
                                        return self.failFmt("Invalid alias {s}", .{alias});
                                    if (opts.overwriteAliases or !config.aliases.contains(alias)) {
                                        const value = switch (self.current) {
                                            .String => |s| s,
                                            .ReservedTrue => "true",
                                            .ReservedFalse => "false",
                                            else => unreachable, // assert
                                        };
                                        const key = try std.ascii.allocLowerString(allocator, alias);
                                        errdefer allocator.free(key);
                                        const copy = try allocator.dupe(u8, value);
                                        errdefer allocator.free(copy);
                                        const result = try config.aliases.getOrPut(allocator, key);
                                        if (result.found_existing) {
                                            defer allocator.free(key);
                                            allocator.free(result.value_ptr.*);
                                        }
                                        result.value_ptr.* = copy;
                                    }
                                } else if (std.mem.eql(u8, keys[0], "lint")) {
                                    // do nothing
                                } else {
                                    const path = try std.mem.join(allocator, "/", keys[0..key_count]);
                                    defer allocator.free(path);
                                    return self.failFmt("Unknown key {s}", .{path});
                                }
                            },
                            else => {},
                        }
                        self.next();
                        key_count -= 1;

                        if (self.current.char() == ',') {
                            self.next();
                        } else if (self.current.char() != '}') {
                            return self.fail("',' or '}}'");
                        }
                    } else return self.fail("field value");
                } else return self.fail("field key");
            }
        }
    }

    pub fn deinit(self: *Parser) void {
        if (self.message) |msg|
            self.allocator.free(msg);
    }
};

pub fn parse(allocator: std.mem.Allocator, contents: []const u8, err_msg: ?*?[]const u8) !Config {
    var config: Config = .{};
    errdefer config.deinit(allocator);

    var parser: Parser = .{
        .allocator = allocator,
        .buffer = contents,
        .err_message = err_msg,
    };

    try parser.process(allocator, &config, .{ .overwriteAliases = false });

    return config;
}

pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    var iter = self.aliases.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    self.aliases.deinit(allocator);
    for (self.globals.items) |item|
        allocator.free(item);
    self.globals.deinit(allocator);
}

test Config {
    const allocator = std.testing.allocator;
    {
        var config = try Config.parse(allocator,
            \\{
            \\  "aliases": {
            \\    "home": "./home/user",
            \\    "docs": "./home/user/docs"
            \\  }
            \\}
        , null);
        defer config.deinit(allocator);

        try std.testing.expectEqual(2, config.aliases.count());
        try std.testing.expectEqualStrings("./home/user", config.aliases.get("home") orelse @panic("no home"));
        try std.testing.expectEqualStrings("./home/user/docs", config.aliases.get("docs") orelse @panic("no docs"));
    }
    {
        var err_msg: ?[]const u8 = null;
        defer if (err_msg) |e| allocator.free(e);
        try std.testing.expectError(error.SyntaxError, Config.parse(allocator,
            \\{
            \\  "aliases": {
            \\    "home": "./home/user",
            \\    "docs": "./home/user/docs",
            \\    "invalid-alias!": "./home/user/invalid"
            \\  }
            \\}
        , &err_msg));
        try std.testing.expectEqualStrings(".luaurc: Invalid alias invalid-alias! at line 5", err_msg.?);
    }
    {
        var err_msg: ?[]const u8 = null;
        defer if (err_msg) |e| allocator.free(e);
        try std.testing.expectError(error.SyntaxError, Config.parse(allocator,
            \\{
            \\  "aliases": {
            \\    "home": "./home/user",
            \\    "docs": "./home/user/docs",
            \\    "invalid-alias!": 1,
            \\  }
            \\}
        , &err_msg));
        try std.testing.expectEqualStrings(".luaurc: Expected field value at line 5", err_msg.?);
    }
    {
        var err_msg: ?[]const u8 = null;
        defer if (err_msg) |e| allocator.free(e);
        try std.testing.expectError(error.SyntaxError, Config.parse(allocator,
            \\{
            \\  "aliases": {
            \\    "home": "./home/user",
            \\    "docs": "./home/user/docs",
            \\}
        , &err_msg));
        try std.testing.expectEqualStrings(".luaurc: Expected ',' or '}' at line 5", err_msg.?);
    }
}
