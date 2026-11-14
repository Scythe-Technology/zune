const std = @import("std");
const builtin = @import("builtin");

const Zune = @import("zune");

const WindowsSettings = struct {
    stdin_mode: std.os.windows.DWORD,
    stdout_mode: std.os.windows.DWORD,
    codepoint: std.os.windows.UINT,
};

const Modes = enum {
    Virtual,
    Plain,
};

pub const State = struct {
    stdin_istty: ?bool = null,
    stdout_istty: ?bool = null,
    stderr_istty: ?bool = null,

    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
    stderr_file: std.Io.File,
    settings: ?if (builtin.os.tag == .windows) WindowsSettings else std.posix.termios = null,
    current_settings: if (builtin.os.tag == .windows) WindowsSettings else void = if (builtin.os.tag == .windows) .{
        .stdin_mode = 0,
        .stdout_mode = 0,
        .codepoint = 0,
    },

    mode: Modes,
};

pub const NEW_LINE = if (builtin.os.tag == .windows) '\r' else '\n';
pub const C_EXIT = if (builtin.os.tag == .windows) 3 else null;

pub const MoveCursorAction = enum {
    Left,
    Right,
};

pub fn SupportedPlatform() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .windows, .macos => true,
        .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
}

const WinApi = struct {
    const w = std.os.windows;

    pub extern "kernel32" fn GetConsoleScreenBufferInfo(
        hConsoleOutput: w.HANDLE,
        lpConsoleScreenBufferInfo: *w.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO,
    ) callconv(w.WINAPI) w.BOOL;

    pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) w.UINT;
    pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: w.UINT) callconv(.winapi) w.BOOL;

    pub extern "kernel32" fn GetConsoleMode(
        hConsoleHandle: w.HANDLE,
        lpMode: *w.DWORD,
    ) callconv(.winapi) w.BOOL;

    pub extern "kernel32" fn SetConsoleMode(
        hConsoleHandle: w.HANDLE,
        dwMode: w.DWORD,
    ) callconv(.winapi) w.BOOL;
};

pub threadlocal var state: State = undefined;
pub fn init(stdin_file: std.Io.File, stdout_file: std.Io.File, stderr_file: std.Io.File) void {
    state = .{
        .stdin_istty = null,
        .stdout_istty = null,
        .stderr_istty = null,
        .stdin_file = stdin_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .mode = .Plain, // prob best to assume plain text.
    };
}

pub fn probeTtyStdIn() void {
    if (state.stdin_istty == null)
        state.stdin_istty = state.stdin_file.isTty(Zune.io()) catch false;
}

pub fn probeTtyStdOut() void {
    if (state.stdout_istty == null)
        state.stdout_istty = state.stdout_file.isTty(Zune.io()) catch false;
}

pub fn probeTtyStdErr() void {
    if (state.stderr_istty == null)
        state.stderr_istty = state.stderr_file.isTty(Zune.io()) catch false;
}

pub fn isStdInTty() bool {
    probeTtyStdIn();
    return state.stdin_istty.?;
}

pub fn isStdOutTty() bool {
    probeTtyStdOut();
    return state.stdout_istty.?;
}

pub fn isStdErrTty() bool {
    probeTtyStdErr();
    return state.stderr_istty.?;
}

pub fn getSize() !struct { u16, u16 } {
    comptime std.debug.assert(SupportedPlatform());
    if (!isStdOutTty())
        return std.posix.TIOCError.NotATerminal;
    if (comptime builtin.os.tag == .windows) {
        var console_info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        switch (try console_info.operate(Zune.io(), state.stdout_file)) {
            .SUCCESS => return .{
                @intCast(console_info.Data.dwWindowSize.X),
                @intCast(console_info.Data.dwWindowSize.Y),
            },
            else => return error.Unexpected,
        }
    } else {
        var buf: std.posix.system.winsize = undefined;
        switch (std.posix.errno(std.posix.system.ioctl(state.stdout_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&buf)))) {
            .SUCCESS => return .{ buf.col, buf.row },
            else => return error.IoctlError,
        }
    }
}

pub fn saveSettings() !void {
    comptime std.debug.assert(SupportedPlatform());
    switch (comptime builtin.os.tag) {
        .linux, .windows, .macos => {},
        .freebsd, .openbsd, .netbsd, .dragonfly => {},
        else => return error.UnsupportedPlatform,
    }
    if (!isStdInTty() or !isStdOutTty())
        return;
    if (state.settings != null)
        return;
    if (builtin.os.tag != .windows) {
        state.settings = try std.posix.tcgetattr(state.stdin_file.handle);
    } else {
        var settings: WindowsSettings = .{
            .stdin_mode = 0,
            .stdout_mode = 0,
            .codepoint = 0,
        };

        // stdin modes
        if (WinApi.GetConsoleMode(state.stdin_file.handle, &settings.stdin_mode) == .FALSE) return error.Fail;
        state.current_settings.stdin_mode = settings.stdin_mode;
        // stdout modes
        if (WinApi.GetConsoleMode(state.stdout_file.handle, &settings.stdout_mode) == .FALSE) return error.Fail;
        state.current_settings.stdout_mode = settings.stdout_mode;
        // stdout codepoint
        settings.codepoint = WinApi.GetConsoleOutputCP();
        state.current_settings.codepoint = settings.codepoint;

        state.settings = settings;
    }
}

pub fn setOutputMode() !void {
    if (builtin.os.tag == .windows) {
        if (!(state.stdout_istty orelse false))
            return;
        const CP_UTF8 = 65001;
        state.current_settings.codepoint = WinApi.GetConsoleOutputCP();
        _ = WinApi.SetConsoleOutputCP(CP_UTF8);
    }
}

pub fn restoreOutputMode() !void {
    if (builtin.os.tag == .windows) {
        if (!(state.stdout_istty orelse false))
            return;
        if (state.current_settings.codepoint != 0) {
            _ = WinApi.SetConsoleOutputCP(state.current_settings.codepoint);
        }
    }
}

pub fn setRawMode() !void {
    comptime std.debug.assert(SupportedPlatform());
    if (!isStdInTty() or !isStdOutTty())
        return;
    try saveSettings();
    state.mode = .Virtual;
    errdefer state.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        const before_stdin_mode = state.current_settings.stdin_mode;
        // ENABLE_PROCESSED_INPUT
        if (state.current_settings.stdin_mode & 0x0001 != 0) state.current_settings.stdin_mode &= ~@as(u32, 0x0001);
        // ENABLE_ECHO_INPUT
        if (state.current_settings.stdin_mode & 0x0004 != 0) state.current_settings.stdin_mode &= ~@as(u32, 0x0004);
        // ENABLE_LINE_INPUT
        if (state.current_settings.stdin_mode & 0x0002 != 0) state.current_settings.stdin_mode &= ~@as(u32, 0x0002);
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (state.current_settings.stdin_mode & 0x0200 == 0) state.current_settings.stdin_mode |= 0x0200;
        if (state.current_settings.stdin_mode != before_stdin_mode) {
            // ENABLE_PROCESSED_INPUT
            if (WinApi.SetConsoleMode(state.stdin_file.handle, state.current_settings.stdin_mode) == .FALSE) {
                switch (std.os.windows.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
        const before_stdout_mode = state.current_settings.stdout_mode;
        // ENABLE_PROCESSED_OUTPUT
        if (state.current_settings.stdout_mode & 0x0001 == 0) state.current_settings.stdout_mode |= 0x0001;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (state.current_settings.stdout_mode & 0x0004 == 0) state.current_settings.stdout_mode |= 0x0004;
        if (state.current_settings.stdout_mode != before_stdout_mode) {
            if (WinApi.SetConsoleMode(state.stdout_file.handle, state.current_settings.stdout_mode) == .FALSE) {
                switch (std.os.windows.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
    } else {
        var newSettings = try std.posix.tcgetattr(state.stdin_file.handle);
        newSettings.lflag.ICANON = false;
        newSettings.lflag.ECHO = false;
        try std.posix.tcsetattr(state.stdin_file.handle, std.posix.TCSA.NOW, newSettings);
    }
}

pub fn setNormalMode() !void {
    comptime std.debug.assert(SupportedPlatform());
    probeTtyStdIn();
    probeTtyStdOut();
    if (!state.stdin_istty.? or !state.stdout_istty.?)
        return;
    try saveSettings();
    state.mode = .Virtual;
    errdefer state.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        const before_stdin_mode = state.current_settings.stdin_mode;
        // ENABLE_PROCESSED_INPUT
        if (state.current_settings.stdin_mode & 0x0001 == 0) state.current_settings.stdin_mode |= 0x0001;
        // ENABLE_ECHO_INPUT
        if (state.current_settings.stdin_mode & 0x0004 == 0) state.current_settings.stdin_mode |= 0x0004;
        // ENABLE_LINE_INPUT
        if (state.current_settings.stdin_mode & 0x0002 == 0) state.current_settings.stdin_mode |= 0x0002;
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (state.current_settings.stdin_mode & 0x0200 != 0) state.current_settings.stdin_mode &= ~@as(u32, 0x0200);
        if (state.current_settings.stdin_mode != before_stdin_mode) {
            // ENABLE_PROCESSED_INPUT
            if (WinApi.SetConsoleMode(state.stdin_file.handle, state.current_settings.stdin_mode) == .FALSE) {
                switch (std.os.windows.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
        const before_stdout_mode = state.current_settings.stdout_mode;
        // ENABLE_PROCESSED_OUTPUT
        if (state.current_settings.stdout_mode & 0x0001 == 0) state.current_settings.stdout_mode |= 0x0001;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (state.current_settings.stdout_mode & 0x0004 != 0) state.current_settings.stdout_mode &= ~@as(u32, 0x0004);
        if (state.current_settings.stdout_mode != before_stdout_mode) {
            if (WinApi.SetConsoleMode(state.stdout_file.handle, state.current_settings.stdout_mode) == .FALSE) {
                switch (std.os.windows.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
        }
    } else {
        var newSettings = try std.posix.tcgetattr(state.stdin_file.handle);
        newSettings.lflag.ICANON = true;
        newSettings.lflag.ECHO = true;
        try std.posix.tcsetattr(state.stdin_file.handle, std.posix.TCSA.NOW, newSettings);
    }
}

pub fn restoreSettings() !void {
    comptime std.debug.assert(SupportedPlatform());
    probeTtyStdIn();
    probeTtyStdOut();
    if (!state.stdin_istty.? or !state.stdout_istty.?)
        return;
    const settings = state.settings orelse return;
    if (state.mode == .Plain) return;
    state.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (WinApi.SetConsoleMode(state.stdin_file.handle, settings.stdin_mode) == .FALSE) {
            switch (std.os.windows.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            }
        }
        state.current_settings.stdin_mode = settings.stdin_mode;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (WinApi.SetConsoleMode(state.stdout_file.handle, settings.stdout_mode) == .FALSE) {
            switch (std.os.windows.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            }
        }
        state.current_settings.stdout_mode = settings.stdout_mode;
    } else {
        if (state.settings) |old_settings| {
            try std.posix.tcsetattr(state.stdin_file.handle, std.posix.TCSA.NOW, old_settings);
        }
    }
}
