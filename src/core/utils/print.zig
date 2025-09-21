const std = @import("std");

const Zune = @import("zune");

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
