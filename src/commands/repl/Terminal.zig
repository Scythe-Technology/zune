const std = @import("std");
const builtin = @import("builtin");

const Terminal = @This();

const WindowsSettings = struct {
    stdin_mode: std.os.windows.DWORD,
    stdout_mode: std.os.windows.DWORD,
    codepoint: std.os.windows.UINT,
};

const Modes = enum {
    Virtual,
    Plain,
};

stdin_istty: bool,
stdout_istty: bool,

stdin_file: std.fs.File,
stdout_file: std.fs.File,
settings: ?if (builtin.os.tag == .windows) WindowsSettings else std.posix.termios = null,
current_settings: if (builtin.os.tag == .windows) WindowsSettings else void = if (builtin.os.tag == .windows) .{
    .stdin_mode = 0,
    .stdout_mode = 0,
    .codepoint = 0,
},

mode: Modes,

pub const NEW_LINE = if (builtin.os.tag == .windows) '\r' else '\n';
pub const C_EXIT = if (builtin.os.tag == .windows) 3 else null;

pub const NON_LETTER = " `~!@#$%^&*()-_=+[]{}\\|;:'\",<.>/?";

pub const MODIFIER = packed struct {
    Ctrl: bool = false,
    Alt: bool = false,
    Shift: bool = false,

    pub fn init(ctrl: bool, alt: bool, shift: bool) MODIFIER {
        return .{ .Ctrl = ctrl, .Alt = alt, .Shift = shift };
    }

    pub inline fn onlyCtrl(self: MODIFIER) bool {
        return self.Ctrl and !self.Alt and !self.Shift;
    }

    pub inline fn none(self: MODIFIER) bool {
        return !self.Ctrl and !self.Alt and !self.Shift;
    }
};

pub const MoveCursorAction = enum {
    Left,
    Right,
};

fn AssertPlatform() !void {
    switch (comptime builtin.os.tag) {
        .linux, .windows, .macos => {},
        else => return error.UnsupportedPlatform,
    }
}

pub fn init(stdin_file: std.fs.File, stdout_file: std.fs.File) Terminal {
    return .{
        .stdin_istty = std.posix.isatty(stdin_file.handle),
        .stdout_istty = std.posix.isatty(stdout_file.handle),
        .stdin_file = stdin_file,
        .stdout_file = stdout_file,
        .mode = .Plain, // prob best to assume plain text.
    };
}

pub fn validateInteractive(self: *Terminal) !void {
    comptime try AssertPlatform();
    if (!self.stdin_istty)
        return std.posix.TIOCError.NotATerminal;
    if (!self.stdout_istty)
        return std.posix.TIOCError.NotATerminal;
}

pub fn getSize(self: *Terminal) !struct { u16, u16 } {
    comptime try AssertPlatform();
    if (!self.stdout_istty) return std.posix.TIOCError.NotATerminal;
    if (builtin.os.tag == .windows) {
        var buf: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        switch (std.os.windows.kernel32.GetConsoleScreenBufferInfo(self.stdout_file.handle, &buf)) {
            std.os.windows.TRUE => return .{ @intCast(buf.srWindow.Right - buf.srWindow.Left + 1), @intCast(buf.srWindow.Bottom - buf.srWindow.Top + 1) },
            else => return error.Unexpected,
        }
    } else {
        var buf: std.posix.system.winsize = undefined;
        switch (std.posix.errno(std.posix.system.ioctl(self.stdout_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&buf)))) {
            .SUCCESS => return .{ buf.col, buf.row },
            else => return error.IoctlError,
        }
    }
}

pub fn saveSettings(self: *Terminal) !void {
    comptime try AssertPlatform();
    switch (comptime builtin.os.tag) {
        .linux, .windows, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    if (!self.stdin_istty or !self.stdout_istty)
        return;
    if (self.settings != null)
        return;
    if (builtin.os.tag != .windows) {
        self.settings = try std.posix.tcgetattr(self.stdin_file.handle);
    } else {
        var settings = WindowsSettings{
            .stdin_mode = 0,
            .stdout_mode = 0,
            .codepoint = 0,
        };
        // stdin modes
        if (std.os.windows.kernel32.GetConsoleMode(self.stdin_file.handle, &settings.stdin_mode) == std.os.windows.FALSE) return error.Fail;
        self.current_settings.stdin_mode = settings.stdin_mode;
        // stdout modes
        if (std.os.windows.kernel32.GetConsoleMode(self.stdout_file.handle, &settings.stdout_mode) == std.os.windows.FALSE) return error.Fail;
        self.current_settings.stdout_mode = settings.stdout_mode;
        // stdout codepoint
        settings.codepoint = std.os.windows.kernel32.GetConsoleOutputCP();
        self.current_settings.codepoint = settings.codepoint;

        self.settings = settings;
    }
}

pub fn generateSequenceWriter(seq: []const u8) fn (self: *Terminal) anyerror!void {
    return struct {
        fn inner(self: *Terminal) !void {
            var buffer: [6]u8 = undefined;
            var writer = self.stdout_file.writer(&buffer);
            try writer.interface.writeAll(seq);
            try writer.interface.flush();
        }
    }.inner;
}

pub const newLine = generateSequenceWriter("\n");
pub const clearLine = generateSequenceWriter("\x1b[2K\r");
pub const clearStyles = generateSequenceWriter("\x1b[0m");
pub const clearEndToCursor = generateSequenceWriter("\x1b[0J");

pub fn writeAllRetainCursor(self: *Terminal, string: []const u8) !void {
    var buffer: [64]u8 = undefined;
    var writer = self.stdout_file.writer(&buffer);
    try writer.interface.writeAll(string);
    try writer.interface.print("\x1b[{d}D", .{string.len});
    try writer.interface.flush();
}
pub fn moveCursor(self: *Terminal, comptime action: MoveCursorAction, amount: usize) !void {
    var buffer: [8]u8 = undefined;
    var writer = self.stdout_file.writer(&buffer);
    switch (amount) {
        0 => return,
        1 => try writer.interface.writeAll("\x1b[" ++ switch (action) {
            .Left => "D",
            .Right => "C",
        }),
        else => |d| try writer.interface.print("\x1b[{d}" ++ switch (action) {
            .Left => "D",
            .Right => "C",
        }, .{d}),
    }
    try writer.interface.flush();
}

pub fn setOutputMode(self: *Terminal) !void {
    if (builtin.os.tag == .windows) {
        if (!self.stdout_istty)
            return;
        const CP_UTF8 = 65001;
        self.current_settings.codepoint = std.os.windows.kernel32.GetConsoleOutputCP();
        _ = std.os.windows.kernel32.SetConsoleOutputCP(CP_UTF8);
    }
}

pub fn restoreOutputMode(self: *Terminal) !void {
    if (builtin.os.tag == .windows) {
        if (!self.stdout_istty)
            return;
        if (self.current_settings.codepoint != 0) {
            _ = std.os.windows.kernel32.SetConsoleOutputCP(self.current_settings.codepoint);
        }
    }
}

pub fn setRawMode(self: *Terminal) !void {
    comptime try AssertPlatform();
    if (!self.stdin_istty or !self.stdout_istty)
        return;
    try self.saveSettings();
    self.mode = .Virtual;
    errdefer self.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        const before_stdin_mode = self.current_settings.stdin_mode;
        // ENABLE_PROCESSED_INPUT
        if (self.current_settings.stdin_mode & 0x0001 != 0) self.current_settings.stdin_mode &= ~@as(u32, 0x0001);
        // ENABLE_ECHO_INPUT
        if (self.current_settings.stdin_mode & 0x0004 != 0) self.current_settings.stdin_mode &= ~@as(u32, 0x0004);
        // ENABLE_LINE_INPUT
        if (self.current_settings.stdin_mode & 0x0002 != 0) self.current_settings.stdin_mode &= ~@as(u32, 0x0002);
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (self.current_settings.stdin_mode & 0x0200 == 0) self.current_settings.stdin_mode |= 0x0200;
        if (self.current_settings.stdin_mode != before_stdin_mode) {
            // ENABLE_PROCESSED_INPUT
            if (std.os.windows.kernel32.SetConsoleMode(self.stdin_file.handle, self.current_settings.stdin_mode) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
        const before_stdout_mode = self.current_settings.stdout_mode;
        // ENABLE_PROCESSED_OUTPUT
        if (self.current_settings.stdout_mode & 0x0001 == 0) self.current_settings.stdout_mode |= 0x0001;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (self.current_settings.stdout_mode & 0x0004 == 0) self.current_settings.stdout_mode |= 0x0004;
        if (self.current_settings.stdout_mode != before_stdout_mode) {
            if (std.os.windows.kernel32.SetConsoleMode(self.stdout_file.handle, self.current_settings.stdout_mode) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
    } else {
        var newSettings = try std.posix.tcgetattr(self.stdin_file.handle);
        newSettings.lflag.ICANON = false;
        newSettings.lflag.ECHO = false;
        try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, newSettings);
    }
}

pub fn setNormalMode(self: *Terminal) !void {
    comptime try AssertPlatform();
    if (!self.stdin_istty or !self.stdout_istty)
        return;
    try self.saveSettings();
    self.mode = .Virtual;
    errdefer self.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        const before_stdin_mode = self.current_settings.stdin_mode;
        // ENABLE_PROCESSED_INPUT
        if (self.current_settings.stdin_mode & 0x0001 == 0) self.current_settings.stdin_mode |= 0x0001;
        // ENABLE_ECHO_INPUT
        if (self.current_settings.stdin_mode & 0x0004 == 0) self.current_settings.stdin_mode |= 0x0004;
        // ENABLE_LINE_INPUT
        if (self.current_settings.stdin_mode & 0x0002 == 0) self.current_settings.stdin_mode |= 0x0002;
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (self.current_settings.stdin_mode & 0x0200 != 0) self.current_settings.stdin_mode &= ~@as(u32, 0x0200);
        if (self.current_settings.stdin_mode != before_stdin_mode) {
            // ENABLE_PROCESSED_INPUT
            if (std.os.windows.kernel32.SetConsoleMode(self.stdin_file.handle, self.current_settings.stdin_mode) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
        const before_stdout_mode = self.current_settings.stdout_mode;
        // ENABLE_PROCESSED_OUTPUT
        if (self.current_settings.stdout_mode & 0x0001 == 0) self.current_settings.stdout_mode |= 0x0001;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (self.current_settings.stdout_mode & 0x0004 != 0) self.current_settings.stdout_mode &= ~@as(u32, 0x0004);
        if (self.current_settings.stdout_mode != before_stdout_mode) {
            if (std.os.windows.kernel32.SetConsoleMode(self.stdout_file.handle, self.current_settings.stdout_mode) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
    } else {
        var newSettings = try std.posix.tcgetattr(self.stdin_file.handle);
        newSettings.lflag.ICANON = true;
        newSettings.lflag.ECHO = true;
        try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, newSettings);
    }
}

pub fn restoreSettings(self: *Terminal) !void {
    comptime try AssertPlatform();
    if (!self.stdin_istty or !self.stdout_istty)
        return;
    const settings = self.settings orelse return;
    if (self.mode == .Plain) return;
    self.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (std.os.windows.kernel32.SetConsoleMode(self.stdin_file.handle, settings.stdin_mode) == std.os.windows.FALSE) {
            switch (std.os.windows.kernel32.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            }
        }
        self.current_settings.stdin_mode = settings.stdin_mode;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (std.os.windows.kernel32.SetConsoleMode(self.stdout_file.handle, settings.stdout_mode) == std.os.windows.FALSE) {
            switch (std.os.windows.kernel32.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            }
        }
        self.current_settings.stdout_mode = settings.stdout_mode;
    } else {
        if (self.settings) |old_settings| try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, old_settings);
    }
}
