const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const VM = luau.VM;

const ColorMap = std.StaticStringMap([]const u8).initComptime(.{
    .{ "red", "31" },
    .{ "green", "32" },
    .{ "yellow", "33" },
    .{ "blue", "34" },
    .{ "magenta", "35" },
    .{ "cyan", "36" },
    .{ "white", "37" },
    .{ "black", "30" },

    .{ "bblack", "90" },
    .{ "bred", "91" },
    .{ "bgreen", "92" },
    .{ "byellow", "93" },
    .{ "bblue", "94" },
    .{ "bmagenta", "95" },
    .{ "bcyan", "96" },
    .{ "bwhite", "97" },

    .{ "bold", "1" },
    .{ "dim", "2" },
    .{ "italic", "3" },
    .{ "underline", "4" },
    .{ "blink", "5" },
    .{ "reverse", "7" },
    .{ "clear", "0" },
});

fn ColorFormat(comptime fmt: []const u8, comptime use_colors: bool) []const u8 {
    comptime var new_fmt: []const u8 = "";

    comptime var start = -1;
    comptime var ignore_next = false;
    comptime var closed = true;
    @setEvalBranchQuota(200_000);
    comptime for (fmt, 0..) |c, i| switch (c) {
        '<' => {
            if (ignore_next) {
                if (!closed) {
                    if (use_colors)
                        new_fmt = new_fmt ++ &[_]u8{'m'};
                    closed = true;
                }
                new_fmt = new_fmt ++ &[_]u8{c};
                ignore_next = false;
                continue;
            }
            if (i + 1 < fmt.len and fmt[i + 1] == '<') {
                ignore_next = true;
                continue;
            }
            if (use_colors) {
                if (!closed)
                    new_fmt = new_fmt ++ &[_]u8{';'}
                else
                    new_fmt = new_fmt ++ "\x1b[";
            }
            if (start >= 0)
                @compileError("Nested color tags in format string: " ++ fmt);
            closed = false;
            start = i;
        },
        '>' => {
            if (ignore_next) {
                if (!closed) {
                    if (use_colors)
                        new_fmt = new_fmt ++ &[_]u8{'m'};
                    closed = true;
                }
                new_fmt = new_fmt ++ &[_]u8{c};
                ignore_next = false;
                continue;
            }
            if (i + 1 < fmt.len and fmt[i + 1] == '>') {
                ignore_next = true;
                continue;
            }
            if (start >= 0) {
                const color_name = fmt[start + 1 .. i];
                const code = ColorMap.get(color_name) orelse @compileError("unknown color: " ++ color_name);
                if (use_colors)
                    new_fmt = new_fmt ++ code;
                start = -1;
            } else @compileError("Unmatched closing color tag in format string: " ++ fmt);
        },
        else => if (start < 0) {
            if (!closed) {
                if (use_colors)
                    new_fmt = new_fmt ++ &[_]u8{'m'};
                closed = true;
            }
            new_fmt = new_fmt ++ &[_]u8{c};
        },
    };
    if (!closed) {
        if (use_colors)
            new_fmt = new_fmt ++ &[_]u8{'m'};
    }
    if (start >= 0)
        @compileError("Unclosed color tag in format string: " ++ fmt);
    return new_fmt;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buffer: [64]u8 = undefined;
    const bw = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    if (Zune.STATE.FORMAT.USE_COLOR == true and std.mem.eql(u8, Zune.STATE.ENV_MAP.get("NO_COLOR") orelse "0", "0")) {
        const color_format = comptime ColorFormat(fmt, true);
        nosuspend bw.print(color_format, args) catch return;
    } else {
        const color_format = comptime ColorFormat(fmt, false);
        nosuspend bw.print(color_format, args) catch return;
    }
}

pub fn writerPrint(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    if (Zune.STATE.FORMAT.USE_COLOR == true and std.mem.eql(u8, Zune.STATE.ENV_MAP.get("NO_COLOR") orelse "0", "0")) {
        const color_format = comptime ColorFormat(fmt, true);
        try writer.print(color_format, args);
    } else {
        const color_format = comptime ColorFormat(fmt, false);
        try writer.print(color_format, args);
    }
}

pub fn writeFullPreviewError(writer: *std.Io.Writer, padding: []u8, line: u32, comptime fmt: []const u8, args: anytype) !void {
    try writerPrint(writer, "{s}|\n", .{padding});
    _ = std.fmt.bufPrint(padding, "{d}", .{line}) catch |e| std.debug.panic("{}", .{e});
    try writerPrint(writer, "{s}~ ", .{padding});
    try writePreviewError(writer, fmt, args);
    @memset(padding, ' ');
    try writerPrint(writer, "{s}|\n", .{padding});
}

pub fn writePreviewError(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writerPrint(writer, " <dim>PreviewError: " ++ fmt ++ "<clear>\n", args);
}

const StackInfo = struct {
    what: VM.lua.Debug.Context,
    name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_line: ?u32 = null,
    current_line: ?u32 = null,
};

pub fn dumpStackInfo(writer: *std.Io.Writer, padded_string: []u8, info: StackInfo, point: ?enum { Red, Yellow }) !void {
    const src = info.source orelse return;
    const current_line = info.current_line orelse info.source_line orelse return;

    try writerPrint(writer, "<bold><underline>{s}:{d}<clear>\n", .{
        if (src.len > 1 and src[0] == '@') src[1..] else src,
        current_line,
    });

    var buffer: [4096]u8 = undefined;
    var file: std.fs.File = undefined;
    var file_reader: std.fs.File.Reader = undefined;

    if (Zune.STATE.BUNDLE) |b| {
        const script = b.loadScript(src[1..]) catch |e| {
            return writeFullPreviewError(writer, padded_string, current_line, "Failed to open source file: {t}", .{e});
        };
        file_reader.interface = .fixed(script);
    } else {
        file = std.fs.cwd().openFile(src[1..], .{ .mode = .read_only }) catch |e| {
            return writeFullPreviewError(writer, padded_string, current_line, "Failed to open source file: {t}", .{e});
        };
        file_reader = file.reader(&buffer);
    }
    defer if (Zune.STATE.BUNDLE == null) file.close();

    var reader = &file_reader.interface;

    if (current_line > 1) for (0..@intCast(current_line - 1)) |_| {
        while (true) {
            const slice = reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return writeFullPreviewError(writer, padded_string, current_line, "Line EOF", .{}),
                else => return writeFullPreviewError(writer, padded_string, current_line, "Failed to read line: {t}", .{e}),
            };
            if (slice[slice.len - 1] == '\n') break;
        }
    };

    try writer.print("{s}|\n", .{padded_string});
    _ = std.fmt.bufPrint(padded_string, "{d}", .{current_line}) catch |e| std.debug.panic("{}", .{e});
    try writer.print("{s}| ", .{padded_string});

    var buf: [131]u8 = undefined;
    var line_writer = std.Io.Writer.fixed(&buf);

    const written = reader.streamDelimiterLimit(&line_writer, '\n', .limited(128)) catch |e| switch (e) {
        error.StreamTooLong => wrt: {
            try line_writer.writeAll("...");
            break :wrt line_writer.end;
        },
        else => {
            try writer.writeAll(buf[0..line_writer.end]);
            try writerPrint(writer, " <dim>(...cutoff) read error: {t}<clear>\n", .{e});
            try writer.print("{s}|\n", .{padded_string});
            return;
        },
    };
    if (written == 0 and reader.seek == reader.end)
        return writePreviewError(writer, "Line EOF", .{});

    const content = buf[0..line_writer.end];

    try writer.writeAll(buf[0..line_writer.end]);

    try writer.writeByte('\n');

    @memset(padded_string, ' ');

    if (point) |color| {
        const front_pos = std.mem.indexOfNonePos(u8, content, 0, " \t") orelse 0;
        const end_pos = pos: {
            if (std.mem.lastIndexOfNone(u8, content, " \t\r")) |p|
                break :pos p + 1;
            break :pos front_pos;
        };
        const len = end_pos - front_pos;

        const space_slice = buf[0..front_pos];

        try writer.print("{s}| {s}", .{ padded_string, space_slice });
        @memset(buf[0..len], '^');
        switch (color) {
            .Red => try writerPrint(writer, "<red>{s}<clear>\n", .{buf[0..len]}),
            .Yellow => try writerPrint(writer, "<yellow>{s}<clear>\n", .{buf[0..len]}),
        }
    } else {
        try writer.print("{s}|\n", .{padded_string});
    }
}

pub fn dumpStackTrace(writer: *std.Io.Writer, trace: []const StackInfo, ref_level: ?usize) !void {
    var largest_line: usize = 1;
    for (trace) |info| {
        if (info.current_line) |line|
            largest_line = @max(largest_line, @as(usize, @intCast(line)));
        if (info.source_line) |line| {
            if (line > 0)
                largest_line = @max(largest_line, @as(usize, @intCast(line)));
        }
    }

    var padding_buf: [12]u8 = undefined;

    const padding = std.math.log10(largest_line) + 1;
    if (padding + 1 > padding_buf.len)
        return;

    const padded_string = padding_buf[0 .. padding + 1];
    @memset(padded_string, ' ');

    for (trace, 0..) |info, lvl| {
        if (info.current_line == null)
            continue;
        if (info.what != .lua)
            continue;
        try dumpStackInfo(
            writer,
            padded_string,
            info,
            if (ref_level != null and ref_level.? == lvl) .Red else null,
        );
    }
}

pub fn dumpDefinitionTrace(L: *VM.lua.State, idx: i32) !void {
    const allocator = luau.getallocator(L);

    std.debug.assert(idx < 0);
    std.debug.assert(L.typeOf(idx) == .Function);

    var stackInfo: ?StackInfo = null;
    defer if (stackInfo) |info| {
        if (info.name) |name|
            allocator.free(name);
        if (info.source) |source|
            allocator.free(source);
    };

    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    if (L.getinfo(idx, "sn", &ar)) {
        var info: StackInfo = .{
            .what = ar.what,
        };
        if (ar.name) |name|
            info.name = try allocator.dupe(u8, name);
        if (ar.linedefined) |line|
            info.source_line = line;
        if (ar.currentline) |line|
            info.current_line = line;
        info.source = try allocator.dupe(u8, ar.source.?);

        stackInfo = info;
    }

    var err_msg: []const u8 = undefined;
    var error_buf: ?[]const u8 = null;
    defer if (error_buf) |buf| allocator.free(buf);
    switch (L.typeOf(-1)) {
        .String, .Number => err_msg = L.tostring(-1).?,
        else => jmp: {
            if (!try L.checkstack(2)) {
                err_msg = "StackOverflow";
                break :jmp;
            }
            const TL = try L.newthread();
            defer L.pop(1); // drop: thread
            defer TL.resetthread() catch {};
            L.xpush(TL, -2);
            error_buf = try allocator.dupe(u8, TL.Ztolstring(1) catch |e| str: {
                switch (e) {
                    error.BadReturnType => break :str try TL.Ztolstringk(1),
                    error.Runtime => break :str try TL.Ztolstringk(1),
                    else => std.debug.panic("{}\n", .{e}),
                }
                return;
            });
            err_msg = error_buf.?;
        },
    }

    if (stackInfo != null and stackInfo.?.what == .lua and stackInfo.?.source_line != null) {
        const info = stackInfo.?;
        if (!try L.checkstack(4)) {
            print("Failed to show detailed error: StackOverflow\n", .{});
            print("<red>error<clear>: {s}\n", .{err_msg});
            print("{s}\n", .{L.debugtrace()});
            return;
        }

        const source_line = info.source_line.?;
        const padding = std.math.log10(source_line) + 1;

        jmp: {
            const source = info.source orelse break :jmp;
            const currentline = info.current_line orelse break :jmp;
            if (source.len < 1 or source[0] != '@')
                break :jmp;
            const strip = try std.fmt.allocPrint(allocator, "{s}:{d}: ", .{
                source[1..],
                currentline,
            });
            defer allocator.free(strip);

            const pos = std.mem.indexOfPosLinear(u8, err_msg, 0, strip);
            if (pos) |p|
                err_msg = err_msg[p + strip.len ..];
        }

        print("<red>error<clear>: {s}\n", .{err_msg});

        if (Zune.STATE.BUNDLE) |b|
            if (b.mode.compiled == .release)
                return;

        var padding_buf: [12]u8 = undefined;
        if (padding + 1 > padding_buf.len)
            return;
        const padded_string = padding_buf[0 .. padding + 1];

        @memset(padded_string, ' ');

        const stderr = std.debug.lockStderrWriter(&.{});
        defer std.debug.unlockStderrWriter();

        try dumpStackInfo(stderr, padded_string, info, null);
    } else {
        print("<green>error<clear>: {s}\n", .{err_msg});
        print("{s}\n", .{L.debugtrace()});
        return;
    }
}

pub fn freeStackTrace(allocator: std.mem.Allocator, trace: []const StackInfo) void {
    for (trace) |info| {
        if (info.name) |name|
            allocator.free(name);
        if (info.source) |source|
            allocator.free(source);
    }
}

pub fn getStackTrace(L: *VM.lua.State, allocator: std.mem.Allocator) !std.ArrayList(StackInfo) {
    var list: std.ArrayList(StackInfo) = try .initCapacity(allocator, 4);
    errdefer list.deinit(allocator);
    errdefer freeStackTrace(allocator, list.items);

    var level: i32 = 0;
    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    while (L.getinfo(level, "sln", &ar)) : (level += 1) {
        var info: StackInfo = .{
            .what = ar.what,
        };
        if (ar.name) |name|
            info.name = try allocator.dupe(u8, name);
        if (ar.linedefined) |line|
            info.source_line = line;
        if (ar.currentline) |line|
            info.current_line = line;
        info.source = try allocator.dupe(u8, ar.source.?);

        try list.append(allocator, info);
    }

    return list;
}

pub fn dumpErrorStackTrace(L: *VM.lua.State) !void {
    const allocator = luau.getallocator(L);

    var list: std.ArrayList(StackInfo) = try getStackTrace(L, allocator);
    defer list.deinit(allocator);
    defer freeStackTrace(allocator, list.items);

    var err_msg: []const u8 = undefined;
    var error_buf: ?[]const u8 = null;
    defer if (error_buf) |buf| allocator.free(buf);
    switch (L.typeOf(-1)) {
        .String, .Number => err_msg = L.tostring(-1).?,
        else => jmp: {
            if (!try L.checkstack(2)) {
                err_msg = "StackOverflow";
                break :jmp;
            }
            const TL = try L.newthread();
            defer L.pop(1); // drop: thread
            defer TL.resetthread() catch {};
            L.xpush(TL, -2);
            error_buf = try allocator.dupe(u8, TL.Ztolstring(1) catch |e| str: {
                switch (e) {
                    error.BadReturnType => break :str try TL.Ztolstringk(1),
                    error.Runtime => break :str try TL.Ztolstringk(1),
                    else => std.debug.panic("{}\n", .{e}),
                }
                return;
            });
            err_msg = error_buf.?;
        },
    }

    if (list.items.len < 1) {
        print("<green>error<clear>: {s}\n", .{err_msg});
        if (Zune.STATE.BUNDLE) |b|
            if (b.mode.compiled == .release)
                return;
        print("{s}\n", .{L.debugtrace()});
        return;
    }

    if (!try L.checkstack(5)) {
        print("Failed to show detailed error: StackOverflow\n", .{});
        print("<green>error<clear>: {s}\n", .{err_msg});
        if (Zune.STATE.BUNDLE) |b|
            if (b.mode.compiled == .release)
                return;
        print("{s}\n", .{L.debugtrace()});
        return;
    }

    var reference_level: ?usize = null;
    jmp: {
        const item = blk: {
            for (list.items, 0..) |item, lvl|
                if (item.what == .lua) {
                    reference_level = lvl;
                    break :blk item;
                };
            break :blk list.items[0];
        };
        const source = item.source orelse break :jmp;
        const currentline = item.current_line orelse break :jmp;
        if (source.len == 0 or source[0] != '@')
            break :jmp;

        const src_len = source[1..].len;
        if (!std.mem.startsWith(u8, err_msg, source[1..]))
            break :jmp;
        var line_buffer: [64]u8 = undefined;
        const line_number = try std.fmt.bufPrint(&line_buffer, ":{d}: ", .{currentline});
        const err_trimmed = err_msg[src_len..];
        if (!std.mem.startsWith(u8, err_trimmed, line_number))
            break :jmp;
        err_msg = err_trimmed[line_number.len..];
    }

    const stderr = std.debug.lockStderrWriter(&.{});
    defer std.debug.unlockStderrWriter();

    try writerPrint(stderr, "<red>error<clear>: {s}\n", .{err_msg});

    if (Zune.STATE.BUNDLE) |b|
        if (b.mode.compiled == .release)
            return;

    try dumpStackTrace(stderr, list.items, reference_level);
}

pub fn dumpErrorTrace(L: *VM.lua.State, err: anyerror, forceDetailed: bool) void {
    switch (err) {
        error.Runtime => {
            if (Zune.STATE.USE_DETAILED_ERROR or forceDetailed) {
                dumpErrorStackTrace(L) catch |e| std.debug.panic("{}", .{e});
            } else {
                switch (L.typeOf(-1)) {
                    .String, .Number => print("{s}\n", .{L.tostring(-1).?}),
                    else => jmp: {
                        if (!(L.checkstack(2) catch |e| std.debug.panic("{}", .{e}))) {
                            print("StackOverflow\n", .{});
                        }
                        const TL = L.newthread() catch |e| std.debug.panic("{}", .{e});
                        defer L.pop(1); // drop: thread
                        defer TL.resetthread() catch {};
                        L.xpush(TL, -2);
                        const str = TL.Ztolstring(1) catch |e| str: {
                            switch (e) {
                                error.BadReturnType => break :str TL.Ztolstringk(1) catch |er| std.debug.panic("{}", .{er}),
                                error.Runtime => break :str TL.Ztolstringk(1) catch |er| std.debug.panic("{}", .{er}),
                                else => std.debug.panic("{}\n", .{e}),
                            }
                            break :jmp;
                        };
                        print("{s}\n", .{str});
                    },
                }
                print("{s}\n", .{L.debugtrace()});
            }
        },
        else => {
            print("Error: {}\n", .{err});
        },
    }
}

pub fn dumpFunctionDefinition(L: *VM.lua.State, idx: i32) void {
    dumpDefinitionTrace(L, idx) catch |e| std.debug.panic("{}", .{e});
}
