const std = @import("std");
const builtin = @import("builtin");

const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const unicode = std.unicode;
const process = std.process;
const windows = std.os.windows;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;

const assert = std.debug.assert;

const StdIo = ChildProcess.StdIo;

pub fn socket(domain: u32, flags: u32, protocol: u32) !windows.ws2_32.SOCKET {
    // NOTE: windows translates the SOCK.NONBLOCK/SOCK.CLOEXEC flags into
    // windows-analogous operations
    const filtered_sock_type = flags & ~@as(u32, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
    const dwflags: u32 = if ((flags & std.posix.SOCK.CLOEXEC) != 0)
        windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT
    else
        0;
    const rc = try windows.WSASocketW(
        @bitCast(domain),
        @bitCast(filtered_sock_type),
        @bitCast(protocol),
        null,
        0,
        dwflags | windows.ws2_32.WSA_FLAG_OVERLAPPED,
    );
    errdefer windows.closesocket(rc) catch unreachable;
    if ((flags & std.posix.SOCK.NONBLOCK) != 0) {
        var mode: c_ulong = 1; // nonblocking
        if (windows.ws2_32.SOCKET_ERROR == windows.ws2_32.ioctlsocket(rc, windows.ws2_32.FIONBIO, &mode)) {
            switch (windows.ws2_32.WSAGetLastError()) {
                // have not identified any error codes that should be handled yet
                else => unreachable,
            }
        }
    }
    return rc;
}

const OpenFileOptions = struct {
    accessMode: windows.DWORD,
    shareMode: windows.DWORD = windows.FILE_SHARE_WRITE | windows.FILE_SHARE_READ | windows.FILE_SHARE_DELETE,
    creationDisposition: windows.DWORD,
};

pub fn OpenFile(self: fs.Dir, path: []const u8, opts: OpenFileOptions) fs.File.OpenError!fs.File {
    const path_w = try windows.sliceToPrefixedFileW(self.fd, path);
    const handle = windows.kernel32.CreateFileW(
        path_w.span(),
        opts.accessMode,
        opts.shareMode,
        null,
        opts.creationDisposition,
        windows.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        const err = windows.kernel32.GetLastError();
        return switch (err) {
            .FILE_NOT_FOUND => error.FileNotFound,
            .PATH_NOT_FOUND => error.FileNotFound,
            .INVALID_PARAMETER => unreachable,
            .SHARING_VIOLATION => return error.AccessDenied,
            .ACCESS_DENIED => return error.AccessDenied,
            .PIPE_BUSY => return error.PipeBusy,
            .FILE_EXISTS => return error.PathAlreadyExists,
            .USER_MAPPED_FILE => return error.AccessDenied,
            .INVALID_HANDLE => unreachable,
            .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
            else => windows.unexpectedError(err),
        };
    }
    return .{ .handle = handle };
}

pub extern "kernel32" fn ReOpenFile(
    hOriginalFile: ?windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

// based on std.process.Child
pub fn spawnWindows(self: *ChildProcess) ChildProcess.SpawnError!void {
    var saAttr = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = windows.TRUE,
        .lpSecurityDescriptor = null,
    };

    const any_ignore = (self.stdin_behavior == StdIo.Ignore or self.stdout_behavior == StdIo.Ignore or self.stderr_behavior == StdIo.Ignore);

    const nul_handle = if (any_ignore)
        // "\Device\Null" or "\??\NUL"
        windows.OpenFile(&[_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' }, .{
            .access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE | windows.SYNCHRONIZE,
            .share_access = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            .sa = &saAttr,
            .creation = windows.OPEN_EXISTING,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Unexpected, // not possible for "NUL"
            error.PipeBusy => return error.Unexpected, // not possible for "NUL"
            error.NoDevice => return error.Unexpected, // not possible for "NUL"
            error.FileNotFound => return error.Unexpected, // not possible for "NUL"
            error.AccessDenied => return error.Unexpected, // not possible for "NUL"
            error.NameTooLong => return error.Unexpected, // not possible for "NUL"
            error.WouldBlock => return error.Unexpected, // not possible for "NUL"
            error.NetworkNotFound => return error.Unexpected, // not possible for "NUL"
            error.AntivirusInterference => return error.Unexpected, // not possible for "NUL"
            else => |e| return e,
        }
    else
        undefined;
    defer {
        if (any_ignore) posix.close(nul_handle);
    }

    var g_hChildStd_IN_Rd: ?windows.HANDLE = null;
    var g_hChildStd_IN_Wr: ?windows.HANDLE = null;
    switch (self.stdin_behavior) {
        StdIo.Pipe => {
            try windowsMakeAsyncPipe(.in, &g_hChildStd_IN_Rd, &g_hChildStd_IN_Wr, &saAttr);
        },
        StdIo.Ignore => {
            g_hChildStd_IN_Rd = nul_handle;
        },
        StdIo.Inherit => {
            g_hChildStd_IN_Rd = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch null;
        },
        StdIo.Close => {
            g_hChildStd_IN_Rd = null;
        },
    }
    errdefer if (self.stdin_behavior == StdIo.Pipe) {
        windowsDestroyPipe(g_hChildStd_IN_Rd, g_hChildStd_IN_Wr);
    };

    var g_hChildStd_OUT_Rd: ?windows.HANDLE = null;
    var g_hChildStd_OUT_Wr: ?windows.HANDLE = null;
    switch (self.stdout_behavior) {
        StdIo.Pipe => {
            try windowsMakeAsyncPipe(.out, &g_hChildStd_OUT_Rd, &g_hChildStd_OUT_Wr, &saAttr);
        },
        StdIo.Ignore => {
            g_hChildStd_OUT_Wr = nul_handle;
        },
        StdIo.Inherit => {
            g_hChildStd_OUT_Wr = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch null;
        },
        StdIo.Close => {
            g_hChildStd_OUT_Wr = null;
        },
    }
    errdefer if (self.stdout_behavior == StdIo.Pipe) {
        windowsDestroyPipe(g_hChildStd_OUT_Rd, g_hChildStd_OUT_Wr);
    };

    var g_hChildStd_ERR_Rd: ?windows.HANDLE = null;
    var g_hChildStd_ERR_Wr: ?windows.HANDLE = null;
    switch (self.stderr_behavior) {
        StdIo.Pipe => {
            try windowsMakeAsyncPipe(.out, &g_hChildStd_ERR_Rd, &g_hChildStd_ERR_Wr, &saAttr);
        },
        StdIo.Ignore => {
            g_hChildStd_ERR_Wr = nul_handle;
        },
        StdIo.Inherit => {
            g_hChildStd_ERR_Wr = windows.GetStdHandle(windows.STD_ERROR_HANDLE) catch null;
        },
        StdIo.Close => {
            g_hChildStd_ERR_Wr = null;
        },
    }
    errdefer if (self.stderr_behavior == StdIo.Pipe) {
        windowsDestroyPipe(g_hChildStd_ERR_Rd, g_hChildStd_ERR_Wr);
    };

    var siStartInfo = windows.STARTUPINFOW{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .hStdError = g_hChildStd_ERR_Wr,
        .hStdOutput = g_hChildStd_OUT_Wr,
        .hStdInput = g_hChildStd_IN_Rd,
        .dwFlags = windows.STARTF_USESTDHANDLES,

        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
    };
    var piProcInfo: windows.PROCESS_INFORMATION = undefined;

    const cwd_w = if (self.cwd) |cwd| try unicode.wtf8ToWtf16LeAllocZ(self.allocator, cwd) else null;
    defer if (cwd_w) |cwd| self.allocator.free(cwd);
    const cwd_w_ptr = if (cwd_w) |cwd| cwd.ptr else null;

    const maybe_envp_buf = if (self.env_map) |env_map| try process.createWindowsEnvBlock(self.allocator, env_map) else null;
    defer if (maybe_envp_buf) |envp_buf| self.allocator.free(envp_buf);
    const envp_ptr = if (maybe_envp_buf) |envp_buf| envp_buf.ptr else null;

    const app_name_wtf8 = self.argv[0];
    const app_name_is_absolute = fs.path.isAbsolute(app_name_wtf8);

    // the cwd set in ChildProcess is in effect when choosing the executable path
    // to match posix semantics
    var cwd_path_w_needs_free = false;
    const cwd_path_w = x: {
        // If the app name is absolute, then we need to use its dirname as the cwd
        if (app_name_is_absolute) {
            cwd_path_w_needs_free = true;
            const dir = fs.path.dirname(app_name_wtf8).?;
            break :x try unicode.wtf8ToWtf16LeAllocZ(self.allocator, dir);
        } else if (self.cwd) |cwd| {
            cwd_path_w_needs_free = true;
            break :x try unicode.wtf8ToWtf16LeAllocZ(self.allocator, cwd);
        } else {
            break :x &[_:0]u16{}; // empty for cwd
        }
    };
    defer if (cwd_path_w_needs_free) self.allocator.free(cwd_path_w);

    // If the app name has more than just a filename, then we need to separate that
    // into the basename and dirname and use the dirname as an addition to the cwd
    // path. This is because NtQueryDirectoryFile cannot accept FileName params with
    // path separators.
    const app_basename_wtf8 = fs.path.basename(app_name_wtf8);
    // If the app name is absolute, then the cwd will already have the app's dirname in it,
    // so only populate app_dirname if app name is a relative path with > 0 path separators.
    const maybe_app_dirname_wtf8 = if (!app_name_is_absolute) fs.path.dirname(app_name_wtf8) else null;
    const app_dirname_w: ?[:0]u16 = x: {
        if (maybe_app_dirname_wtf8) |app_dirname_wtf8| {
            break :x try unicode.wtf8ToWtf16LeAllocZ(self.allocator, app_dirname_wtf8);
        }
        break :x null;
    };
    defer if (app_dirname_w != null) self.allocator.free(app_dirname_w.?);

    const app_name_w = try unicode.wtf8ToWtf16LeAllocZ(self.allocator, app_basename_wtf8);
    defer self.allocator.free(app_name_w);

    run: {
        const PATH: [:0]const u16 = process.getenvW(unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse &[_:0]u16{};
        const PATHEXT: [:0]const u16 = process.getenvW(unicode.utf8ToUtf16LeStringLiteral("PATHEXT")) orelse &[_:0]u16{};

        // In case the command ends up being a .bat/.cmd script, we need to escape things using the cmd.exe rules
        // and invoke cmd.exe ourselves in order to mitigate arbitrary command execution from maliciously
        // constructed arguments.
        //
        // We'll need to wait until we're actually trying to run the command to know for sure
        // if the resolved command has the `.bat` or `.cmd` extension, so we defer actually
        // serializing the command line until we determine how it should be serialized.
        var cmd_line_cache = WindowsCommandLineCache.init(self.allocator, self.argv);
        defer cmd_line_cache.deinit();

        var app_buf: std.ArrayListUnmanaged(u16) = .empty;
        defer app_buf.deinit(self.allocator);

        try app_buf.appendSlice(self.allocator, app_name_w);

        var dir_buf: std.ArrayListUnmanaged(u16) = .empty;
        defer dir_buf.deinit(self.allocator);

        if (cwd_path_w.len > 0) {
            try dir_buf.appendSlice(self.allocator, cwd_path_w);
        }
        if (app_dirname_w) |app_dir| {
            if (dir_buf.items.len > 0) try dir_buf.append(self.allocator, fs.path.sep);
            try dir_buf.appendSlice(self.allocator, app_dir);
        }
        if (dir_buf.items.len > 0) {
            // Need to normalize the path, openDirW can't handle things like double backslashes
            const normalized_len = windows.normalizePath(u16, dir_buf.items) catch return error.BadPathName;
            dir_buf.shrinkRetainingCapacity(normalized_len);
        }

        windowsCreateProcessPathExt(self.allocator, &dir_buf, &app_buf, PATHEXT, &cmd_line_cache, envp_ptr, cwd_w_ptr, &siStartInfo, &piProcInfo) catch |no_path_err| {
            const original_err = switch (no_path_err) {
                // argv[0] contains unsupported characters that will never resolve to a valid exe.
                error.InvalidArg0 => return error.FileNotFound,
                error.FileNotFound, error.InvalidExe, error.AccessDenied => |e| e,
                error.UnrecoverableInvalidExe => return error.InvalidExe,
                else => |e| return e,
            };

            // If the app name had path separators, that disallows PATH searching,
            // and there's no need to search the PATH if the app name is absolute.
            // We still search the path if the cwd is absolute because of the
            // "cwd set in ChildProcess is in effect when choosing the executable path
            // to match posix semantics" behavior--we don't want to skip searching
            // the PATH just because we were trying to set the cwd of the child process.
            if (app_dirname_w != null or app_name_is_absolute) {
                return original_err;
            }

            var it = mem.tokenizeScalar(u16, PATH, ';');
            while (it.next()) |search_path| {
                dir_buf.clearRetainingCapacity();
                try dir_buf.appendSlice(self.allocator, search_path);
                // Need to normalize the path, some PATH values can contain things like double
                // backslashes which openDirW can't handle
                const normalized_len = windows.normalizePath(u16, dir_buf.items) catch continue;
                dir_buf.shrinkRetainingCapacity(normalized_len);

                if (windowsCreateProcessPathExt(self.allocator, &dir_buf, &app_buf, PATHEXT, &cmd_line_cache, envp_ptr, cwd_w_ptr, &siStartInfo, &piProcInfo)) {
                    break :run;
                } else |err| switch (err) {
                    // argv[0] contains unsupported characters that will never resolve to a valid exe.
                    error.InvalidArg0 => return error.FileNotFound,
                    error.FileNotFound, error.AccessDenied, error.InvalidExe => continue,
                    error.UnrecoverableInvalidExe => return error.InvalidExe,
                    else => |e| return e,
                }
            } else {
                return original_err;
            }
        };
    }

    if (g_hChildStd_IN_Wr) |h| {
        self.stdin = File{ .handle = h };
    } else {
        self.stdin = null;
    }
    if (g_hChildStd_OUT_Rd) |h| {
        self.stdout = File{ .handle = h };
    } else {
        self.stdout = null;
    }
    if (g_hChildStd_ERR_Rd) |h| {
        self.stderr = File{ .handle = h };
    } else {
        self.stderr = null;
    }

    self.id = piProcInfo.hProcess;
    self.thread_handle = piProcInfo.hThread;
    self.term = null;

    if (self.stdin_behavior == StdIo.Pipe) {
        posix.close(g_hChildStd_IN_Rd.?);
    }
    if (self.stderr_behavior == StdIo.Pipe) {
        posix.close(g_hChildStd_ERR_Wr.?);
    }
    if (self.stdout_behavior == StdIo.Pipe) {
        posix.close(g_hChildStd_OUT_Wr.?);
    }
}

/// Expects `app_buf` to contain exactly the app name, and `dir_buf` to contain exactly the dir path.
/// After return, `app_buf` will always contain exactly the app name and `dir_buf` will always contain exactly the dir path.
/// Note: `app_buf` should not contain any leading path separators.
/// Note: If the dir is the cwd, dir_buf should be empty (len = 0).
fn windowsCreateProcessPathExt(
    allocator: mem.Allocator,
    dir_buf: *std.ArrayListUnmanaged(u16),
    app_buf: *std.ArrayListUnmanaged(u16),
    pathext: [:0]const u16,
    cmd_line_cache: *WindowsCommandLineCache,
    envp_ptr: ?[*]u16,
    cwd_ptr: ?[*:0]u16,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) !void {
    const app_name_len = app_buf.items.len;
    const dir_path_len = dir_buf.items.len;

    if (app_name_len == 0) return error.FileNotFound;

    defer app_buf.shrinkRetainingCapacity(app_name_len);
    defer dir_buf.shrinkRetainingCapacity(dir_path_len);

    // The name of the game here is to avoid CreateProcessW calls at all costs,
    // and only ever try calling it when we have a real candidate for execution.
    // Secondarily, we want to minimize the number of syscalls used when checking
    // for each PATHEXT-appended version of the app name.
    //
    // An overview of the technique used:
    // - Open the search directory for iteration (either cwd or a path from PATH)
    // - Use NtQueryDirectoryFile with a wildcard filename of `<app name>*` to
    //   check if anything that could possibly match either the unappended version
    //   of the app name or any of the versions with a PATHEXT value appended exists.
    // - If the wildcard NtQueryDirectoryFile call found nothing, we can exit early
    //   without needing to use PATHEXT at all.
    //
    // This allows us to use a <open dir, NtQueryDirectoryFile, close dir> sequence
    // for any directory that doesn't contain any possible matches, instead of having
    // to use a separate look up for each individual filename combination (unappended +
    // each PATHEXT appended). For directories where the wildcard *does* match something,
    // we iterate the matches and take note of any that are either the unappended version,
    // or a version with a supported PATHEXT appended. We then try calling CreateProcessW
    // with the found versions in the appropriate order.

    var dir = dir: {
        // needs to be null-terminated
        try dir_buf.append(allocator, 0);
        defer dir_buf.shrinkRetainingCapacity(dir_path_len);
        const dir_path_z = dir_buf.items[0 .. dir_buf.items.len - 1 :0];
        const prefixed_path = try windows.wToPrefixedFileW(null, dir_path_z);
        break :dir fs.cwd().openDirW(prefixed_path.span().ptr, .{ .iterate = true }) catch
            return error.FileNotFound;
    };
    defer dir.close();

    // Add wildcard and null-terminator
    try app_buf.append(allocator, '*');
    try app_buf.append(allocator, 0);
    const app_name_wildcard = app_buf.items[0 .. app_buf.items.len - 1 :0];

    // This 2048 is arbitrary, we just want it to be large enough to get multiple FILE_DIRECTORY_INFORMATION entries
    // returned per NtQueryDirectoryFile call.
    var file_information_buf: [2048]u8 align(@alignOf(windows.FILE_DIRECTORY_INFORMATION)) = undefined;
    const file_info_maximum_single_entry_size = @sizeOf(windows.FILE_DIRECTORY_INFORMATION) + (windows.NAME_MAX * 2);
    if (file_information_buf.len < file_info_maximum_single_entry_size) {
        @compileError("file_information_buf must be large enough to contain at least one maximum size FILE_DIRECTORY_INFORMATION entry");
    }
    var io_status: windows.IO_STATUS_BLOCK = undefined;

    const num_supported_pathext = @typeInfo(WindowsExtension).@"enum".fields.len;
    var pathext_seen = [_]bool{false} ** num_supported_pathext;
    var any_pathext_seen = false;
    var unappended_exists = false;

    // Fully iterate the wildcard matches via NtQueryDirectoryFile and take note of all versions
    // of the app_name we should try to spawn.
    // Note: This is necessary because the order of the files returned is filesystem-dependent:
    //       On NTFS, `blah.exe*` will always return `blah.exe` first if it exists.
    //       On FAT32, it's possible for something like `blah.exe.obj` to be returned first.
    while (true) {
        const app_name_len_bytes = std.math.cast(u16, app_name_wildcard.len * 2) orelse return error.NameTooLong;
        var app_name_unicode_string = windows.UNICODE_STRING{
            .Length = app_name_len_bytes,
            .MaximumLength = app_name_len_bytes,
            .Buffer = @constCast(app_name_wildcard.ptr),
        };
        const rc = windows.ntdll.NtQueryDirectoryFile(
            dir.fd,
            null,
            null,
            null,
            &io_status,
            &file_information_buf,
            file_information_buf.len,
            .FileDirectoryInformation,
            windows.FALSE, // single result
            &app_name_unicode_string,
            windows.FALSE, // restart iteration
        );

        // If we get nothing with the wildcard, then we can just bail out
        // as we know appending PATHEXT will not yield anything.
        switch (rc) {
            .SUCCESS => {},
            .NO_SUCH_FILE => return error.FileNotFound,
            .NO_MORE_FILES => break,
            .ACCESS_DENIED => return error.AccessDenied,
            else => return windows.unexpectedStatus(rc),
        }

        // According to the docs, this can only happen if there is not enough room in the
        // buffer to write at least one complete FILE_DIRECTORY_INFORMATION entry.
        // Therefore, this condition should not be possible to hit with the buffer size we use.
        std.debug.assert(io_status.Information != 0);

        var it = windows.FileInformationIterator(windows.FILE_DIRECTORY_INFORMATION){ .buf = &file_information_buf };
        while (it.next()) |info| {
            // Skip directories
            if (info.FileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
            const filename = @as([*]u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
            // Because all results start with the app_name since we're using the wildcard `app_name*`,
            // if the length is equal to app_name then this is an exact match
            if (filename.len == app_name_len) {
                // Note: We can't break early here because it's possible that the unappended version
                //       fails to spawn, in which case we still want to try the PATHEXT appended versions.
                unappended_exists = true;
            } else if (windowsCreateProcessSupportsExtension(filename[app_name_len..])) |pathext_ext| {
                pathext_seen[@intFromEnum(pathext_ext)] = true;
                any_pathext_seen = true;
            }
        }
    }

    const unappended_err = unappended: {
        if (unappended_exists) {
            if (dir_path_len != 0) switch (dir_buf.items[dir_buf.items.len - 1]) {
                '/', '\\' => {},
                else => try dir_buf.append(allocator, fs.path.sep),
            };
            try dir_buf.appendSlice(allocator, app_buf.items[0..app_name_len]);
            try dir_buf.append(allocator, 0);
            const full_app_name = dir_buf.items[0 .. dir_buf.items.len - 1 :0];

            const is_bat_or_cmd = bat_or_cmd: {
                const app_name = app_buf.items[0..app_name_len];
                const ext_start = std.mem.lastIndexOfScalar(u16, app_name, '.') orelse break :bat_or_cmd false;
                const ext = app_name[ext_start..];
                const ext_enum = windowsCreateProcessSupportsExtension(ext) orelse break :bat_or_cmd false;
                switch (ext_enum) {
                    .cmd, .bat => break :bat_or_cmd true,
                    else => break :bat_or_cmd false,
                }
            };
            const cmd_line_w = if (is_bat_or_cmd)
                try cmd_line_cache.scriptCommandLine(full_app_name)
            else
                try cmd_line_cache.commandLine();
            const app_name_w = if (is_bat_or_cmd)
                try cmd_line_cache.cmdExePath()
            else
                full_app_name;

            if (windowsCreateProcess(app_name_w.ptr, cmd_line_w.ptr, envp_ptr, cwd_ptr, lpStartupInfo, lpProcessInformation)) |_| {
                return;
            } else |err| switch (err) {
                error.FileNotFound,
                error.AccessDenied,
                => break :unappended err,
                error.InvalidExe => {
                    // On InvalidExe, if the extension of the app name is .exe then
                    // it's treated as an unrecoverable error. Otherwise, it'll be
                    // skipped as normal.
                    const app_name = app_buf.items[0..app_name_len];
                    const ext_start = std.mem.lastIndexOfScalar(u16, app_name, '.') orelse break :unappended err;
                    const ext = app_name[ext_start..];
                    if (windows.eqlIgnoreCaseWTF16(ext, unicode.utf8ToUtf16LeStringLiteral(".EXE"))) {
                        return error.UnrecoverableInvalidExe;
                    }
                    break :unappended err;
                },
                else => return err,
            }
        }
        break :unappended error.FileNotFound;
    };

    if (!any_pathext_seen) return unappended_err;

    // Now try any PATHEXT appended versions that we've seen
    var ext_it = mem.tokenizeScalar(u16, pathext, ';');
    while (ext_it.next()) |ext| {
        const ext_enum = windowsCreateProcessSupportsExtension(ext) orelse continue;
        if (!pathext_seen[@intFromEnum(ext_enum)]) continue;

        dir_buf.shrinkRetainingCapacity(dir_path_len);
        if (dir_path_len != 0) switch (dir_buf.items[dir_buf.items.len - 1]) {
            '/', '\\' => {},
            else => try dir_buf.append(allocator, fs.path.sep),
        };
        try dir_buf.appendSlice(allocator, app_buf.items[0..app_name_len]);
        try dir_buf.appendSlice(allocator, ext);
        try dir_buf.append(allocator, 0);
        const full_app_name = dir_buf.items[0 .. dir_buf.items.len - 1 :0];

        const is_bat_or_cmd = switch (ext_enum) {
            .cmd, .bat => true,
            else => false,
        };
        const cmd_line_w = if (is_bat_or_cmd)
            try cmd_line_cache.scriptCommandLine(full_app_name)
        else
            try cmd_line_cache.commandLine();
        const app_name_w = if (is_bat_or_cmd)
            try cmd_line_cache.cmdExePath()
        else
            full_app_name;

        if (windowsCreateProcess(app_name_w.ptr, cmd_line_w.ptr, envp_ptr, cwd_ptr, lpStartupInfo, lpProcessInformation)) |_| {
            return;
        } else |err| switch (err) {
            error.FileNotFound => continue,
            error.AccessDenied => continue,
            error.InvalidExe => {
                // On InvalidExe, if the extension of the app name is .exe then
                // it's treated as an unrecoverable error. Otherwise, it'll be
                // skipped as normal.
                if (windows.eqlIgnoreCaseWTF16(ext, unicode.utf8ToUtf16LeStringLiteral(".EXE"))) {
                    return error.UnrecoverableInvalidExe;
                }
                continue;
            },
            else => return err,
        }
    }

    return unappended_err;
}

fn windowsCreateProcess(
    app_name: [*:0]u16,
    cmd_line: [*:0]u16,
    envp_ptr: ?[*]u16,
    cwd_ptr: ?[*:0]u16,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) !void {
    // TODO the docs for environment pointer say:
    // > A pointer to the environment block for the new process. If this parameter
    // > is NULL, the new process uses the environment of the calling process.
    // > ...
    // > An environment block can contain either Unicode or ANSI characters. If
    // > the environment block pointed to by lpEnvironment contains Unicode
    // > characters, be sure that dwCreationFlags includes CREATE_UNICODE_ENVIRONMENT.
    // > If this parameter is NULL and the environment block of the parent process
    // > contains Unicode characters, you must also ensure that dwCreationFlags
    // > includes CREATE_UNICODE_ENVIRONMENT.
    // This seems to imply that we have to somehow know whether our process parent passed
    // CREATE_UNICODE_ENVIRONMENT if we want to pass NULL for the environment parameter.
    // Since we do not know this information that would imply that we must not pass NULL
    // for the parameter.
    // However this would imply that programs compiled with -DUNICODE could not pass
    // environment variables to programs that were not, which seems unlikely.
    // More investigation is needed.
    return windows.CreateProcessW(
        app_name,
        cmd_line,
        null,
        null,
        windows.TRUE,
        .{
            .create_unicode_environment = true,
        },
        @as(?*anyopaque, @ptrCast(envp_ptr)),
        cwd_ptr,
        lpStartupInfo,
        lpProcessInformation,
    );
}

fn windowsDestroyPipe(rd: ?windows.HANDLE, wr: ?windows.HANDLE) void {
    if (rd) |h| posix.close(h);
    if (wr) |h| posix.close(h);
}

fn windowsMakeAsyncPipe(comptime kind: enum { in, out }, rd: *?windows.HANDLE, wr: *?windows.HANDLE, sattr: *const windows.SECURITY_ATTRIBUTES) !void {
    var tmp_bufw: [128]u16 = undefined;

    // Anonymous pipes are built upon Named pipes.
    // https://docs.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createpipe
    // Asynchronous (overlapped) read and write operations are not supported by anonymous pipes.
    // https://docs.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations
    const pipe_path = blk: {
        var tmp_buf: [128]u8 = undefined;
        // Forge a random path for the pipe.
        const pipe_path = std.fmt.bufPrintZ(
            &tmp_buf,
            "\\\\.\\pipe\\zig-childprocess-{d}-{d}",
            .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
        ) catch unreachable;
        const len = std.unicode.wtf8ToWtf16Le(&tmp_bufw, pipe_path) catch unreachable;
        tmp_bufw[len] = 0;
        break :blk tmp_bufw[0..len :0];
    };

    // Create the read handle that is overlapped when kind is .out
    const read_handle = windows.kernel32.CreateNamedPipeW(
        pipe_path.ptr,
        windows.PIPE_ACCESS_INBOUND | if (comptime kind == .in) 0 else windows.FILE_FLAG_OVERLAPPED,
        windows.PIPE_TYPE_BYTE,
        1,
        4096,
        4096,
        0,
        sattr,
    );
    if (read_handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
    errdefer posix.close(read_handle);

    var sattr_copy = sattr.*;
    // Create a write handle that is overlapped when kind is .in
    const write_handle = windows.kernel32.CreateFileW(
        pipe_path.ptr,
        windows.GENERIC_WRITE,
        if (comptime kind == .in)
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE
        else
            0,
        &sattr_copy,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL | if (comptime kind == .in) windows.FILE_FLAG_OVERLAPPED else 0,
        null,
    );
    if (write_handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.GetLastError()) {
            else => |err| return windows.unexpectedError(err),
        }
    }
    errdefer posix.close(write_handle);

    switch (kind) {
        .in => try windows.SetHandleInformation(write_handle, windows.HANDLE_FLAG_INHERIT, 0),
        .out => try windows.SetHandleInformation(read_handle, windows.HANDLE_FLAG_INHERIT, 0),
    }

    rd.* = read_handle;
    wr.* = write_handle;
}

var pipe_name_counter = std.atomic.Value(u32).init(1);

/// File name extensions supported natively by `CreateProcess()` on Windows.
// Should be kept in sync with `windowsCreateProcessSupportsExtension`.
pub const WindowsExtension = enum {
    bat,
    cmd,
    com,
    exe,
};

/// Case-insensitive WTF-16 lookup
fn windowsCreateProcessSupportsExtension(ext: []const u16) ?WindowsExtension {
    if (ext.len != 4) return null;
    const State = enum {
        start,
        dot,
        b,
        ba,
        c,
        cm,
        co,
        e,
        ex,
    };
    var state: State = .start;
    for (ext) |c| switch (state) {
        .start => switch (c) {
            '.' => state = .dot,
            else => return null,
        },
        .dot => switch (c) {
            'b', 'B' => state = .b,
            'c', 'C' => state = .c,
            'e', 'E' => state = .e,
            else => return null,
        },
        .b => switch (c) {
            'a', 'A' => state = .ba,
            else => return null,
        },
        .c => switch (c) {
            'm', 'M' => state = .cm,
            'o', 'O' => state = .co,
            else => return null,
        },
        .e => switch (c) {
            'x', 'X' => state = .ex,
            else => return null,
        },
        .ba => switch (c) {
            't', 'T' => return .bat,
            else => return null,
        },
        .cm => switch (c) {
            'd', 'D' => return .cmd,
            else => return null,
        },
        .co => switch (c) {
            'm', 'M' => return .com,
            else => return null,
        },
        .ex => switch (c) {
            'e', 'E' => return .exe,
            else => return null,
        },
    };
    return null;
}

/// Serializes argv into a WTF-16 encoded command-line string for use with CreateProcessW.
///
/// Serialization is done on-demand and the result is cached in order to allow for:
/// - Only serializing the particular type of command line needed (`.bat`/`.cmd`
///   command line serialization is different from `.exe`/etc)
/// - Reusing the serialized command lines if necessary (i.e. if the execution
///   of a command fails and the PATH is going to be continued to be searched
///   for more candidates)
const WindowsCommandLineCache = struct {
    cmd_line: ?[:0]u16 = null,
    script_cmd_line: ?[:0]u16 = null,
    cmd_exe_path: ?[:0]u16 = null,
    argv: []const []const u8,
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator, argv: []const []const u8) WindowsCommandLineCache {
        return .{
            .allocator = allocator,
            .argv = argv,
        };
    }

    fn deinit(self: *WindowsCommandLineCache) void {
        if (self.cmd_line) |cmd_line| self.allocator.free(cmd_line);
        if (self.script_cmd_line) |script_cmd_line| self.allocator.free(script_cmd_line);
        if (self.cmd_exe_path) |cmd_exe_path| self.allocator.free(cmd_exe_path);
    }

    fn commandLine(self: *WindowsCommandLineCache) ![:0]u16 {
        if (self.cmd_line == null) {
            self.cmd_line = try argvToCommandLineWindows(self.allocator, self.argv);
        }
        return self.cmd_line.?;
    }

    /// Not cached, since the path to the batch script will change during PATH searching.
    /// `script_path` should be as qualified as possible, e.g. if the PATH is being searched,
    /// then script_path should include both the search path and the script filename
    /// (this allows avoiding cmd.exe having to search the PATH again).
    fn scriptCommandLine(self: *WindowsCommandLineCache, script_path: []const u16) ![:0]u16 {
        if (self.script_cmd_line) |v| self.allocator.free(v);
        self.script_cmd_line = try argvToScriptCommandLineWindows(
            self.allocator,
            script_path,
            self.argv[1..],
        );
        return self.script_cmd_line.?;
    }

    fn cmdExePath(self: *WindowsCommandLineCache) ![:0]u16 {
        if (self.cmd_exe_path == null) {
            self.cmd_exe_path = try windowsCmdExePath(self.allocator);
        }
        return self.cmd_exe_path.?;
    }
};

/// Returns the absolute path of `cmd.exe` within the Windows system directory.
/// The caller owns the returned slice.
fn windowsCmdExePath(allocator: mem.Allocator) error{ OutOfMemory, Unexpected }![:0]u16 {
    var buf = try std.ArrayListUnmanaged(u16).initCapacity(allocator, 128);
    errdefer buf.deinit(allocator);
    while (true) {
        const unused_slice = buf.unusedCapacitySlice();
        // TODO: Get the system directory from PEB.ReadOnlyStaticServerData
        const len = windows.kernel32.GetSystemDirectoryW(@ptrCast(unused_slice), @intCast(unused_slice.len));
        if (len == 0) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }
        if (len > unused_slice.len) {
            try buf.ensureUnusedCapacity(allocator, len);
        } else {
            buf.items.len = len;
            break;
        }
    }
    switch (buf.items[buf.items.len - 1]) {
        '/', '\\' => {},
        else => try buf.append(allocator, fs.path.sep),
    }
    try buf.appendSlice(allocator, unicode.utf8ToUtf16LeStringLiteral("cmd.exe"));
    return try buf.toOwnedSliceSentinel(allocator, 0);
}

const ArgvToCommandLineError = error{ OutOfMemory, InvalidWtf8, InvalidArg0 };

/// Serializes `argv` to a Windows command-line string suitable for passing to a child process and
/// parsing by the `CommandLineToArgvW` algorithm. The caller owns the returned slice.
///
/// To avoid arbitrary command execution, this function should not be used when spawning `.bat`/`.cmd` scripts.
/// https://flatt.tech/research/posts/batbadbut-you-cant-securely-execute-commands-on-windows/
///
/// When executing `.bat`/`.cmd` scripts, use `argvToScriptCommandLineWindows` instead.
fn argvToCommandLineWindows(
    allocator: mem.Allocator,
    argv: []const []const u8,
) ArgvToCommandLineError![:0]u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    if (argv.len != 0) {
        const arg0 = argv[0];

        // The first argument must be quoted if it contains spaces or ASCII control characters
        // (excluding DEL). It also follows special quoting rules where backslashes have no special
        // interpretation, which makes it impossible to pass certain first arguments containing
        // double quotes to a child process without characters from the first argument leaking into
        // subsequent ones (which could have security implications).
        //
        // Empty arguments technically don't need quotes, but we quote them anyway for maximum
        // compatibility with different implementations of the 'CommandLineToArgvW' algorithm.
        //
        // Double quotes are illegal in paths on Windows, so for the sake of simplicity we reject
        // all first arguments containing double quotes, even ones that we could theoretically
        // serialize in unquoted form.
        var needs_quotes = arg0.len == 0;
        for (arg0) |c| {
            if (c <= ' ') {
                needs_quotes = true;
            } else if (c == '"') {
                return error.InvalidArg0;
            }
        }
        if (needs_quotes) {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, arg0);
            try buf.append(allocator, '"');
        } else {
            try buf.appendSlice(allocator, arg0);
        }

        for (argv[1..]) |arg| {
            try buf.append(allocator, ' ');

            // Subsequent arguments must be quoted if they contain spaces, tabs or double quotes,
            // or if they are empty. For simplicity and for maximum compatibility with different
            // implementations of the 'CommandLineToArgvW' algorithm, we also quote all ASCII
            // control characters (again, excluding DEL).
            needs_quotes = for (arg) |c| {
                if (c <= ' ' or c == '"') {
                    break true;
                }
            } else arg.len == 0;
            if (!needs_quotes) {
                try buf.appendSlice(allocator, arg);
                continue;
            }

            try buf.append(allocator, '"');
            var backslash_count: usize = 0;
            for (arg) |byte| {
                switch (byte) {
                    '\\' => {
                        backslash_count += 1;
                    },
                    '"' => {
                        try buf.appendNTimes(allocator, '\\', backslash_count * 2 + 1);
                        try buf.append(allocator, '"');
                        backslash_count = 0;
                    },
                    else => {
                        try buf.appendNTimes(allocator, '\\', backslash_count);
                        try buf.append(allocator, byte);
                        backslash_count = 0;
                    },
                }
            }
            try buf.appendNTimes(allocator, '\\', backslash_count * 2);
            try buf.append(allocator, '"');
        }
    }

    return try unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}

const ArgvToScriptCommandLineError = error{
    OutOfMemory,
    InvalidWtf8,
    /// NUL (U+0000), LF (U+000A), CR (U+000D) are not allowed
    /// within arguments when executing a `.bat`/`.cmd` script.
    /// - NUL/LF signifiies end of arguments, so anything afterwards
    ///   would be lost after execution.
    /// - CR is stripped by `cmd.exe`, so any CR codepoints
    ///   would be lost after execution.
    InvalidBatchScriptArg,
};

/// Serializes `argv` to a Windows command-line string that uses `cmd.exe /c` and `cmd.exe`-specific
/// escaping rules. The caller owns the returned slice.
///
/// Escapes `argv` using the suggested mitigation against arbitrary command execution from:
/// https://flatt.tech/research/posts/batbadbut-you-cant-securely-execute-commands-on-windows/
///
/// The return of this function will look like
/// `cmd.exe /d /e:ON /v:OFF /c "<escaped command line>"`
/// and should be used as the `lpCommandLine` of `CreateProcessW`, while the
/// return of `windowsCmdExePath` should be used as `lpApplicationName`.
///
/// Should only be used when spawning `.bat`/`.cmd` scripts, see `argvToCommandLineWindows` otherwise.
/// The `.bat`/`.cmd` file must be known to both have the `.bat`/`.cmd` extension and exist on the filesystem.
fn argvToScriptCommandLineWindows(
    allocator: mem.Allocator,
    /// Path to the `.bat`/`.cmd` script. If this path is relative, it is assumed to be relative to the CWD.
    /// The script must have been verified to exist at this path before calling this function.
    script_path: []const u16,
    /// Arguments, not including the script name itself. Expected to be encoded as WTF-8.
    script_args: []const []const u8,
) ArgvToScriptCommandLineError![:0]u16 {
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 64);
    defer buf.deinit();

    // `/d` disables execution of AutoRun commands.
    // `/e:ON` and `/v:OFF` are needed for BatBadBut mitigation:
    // > If delayed expansion is enabled via the registry value DelayedExpansion,
    // > it must be disabled by explicitly calling cmd.exe with the /V:OFF option.
    // > Escaping for % requires the command extension to be enabled.
    // > If it’s disabled via the registry value EnableExtensions, it must be enabled with the /E:ON option.
    // https://flatt.tech/research/posts/batbadbut-you-cant-securely-execute-commands-on-windows/
    buf.appendSliceAssumeCapacity("cmd.exe /d /e:ON /v:OFF /c \"");

    // Always quote the path to the script arg
    buf.appendAssumeCapacity('"');
    // We always want the path to the batch script to include a path separator in order to
    // avoid cmd.exe searching the PATH for the script. This is not part of the arbitrary
    // command execution mitigation, we just know exactly what script we want to execute
    // at this point, and potentially making cmd.exe re-find it is unnecessary.
    //
    // If the script path does not have a path separator, then we know its relative to CWD and
    // we can just put `.\` in the front.
    if (mem.indexOfAny(u16, script_path, &[_]u16{ mem.nativeToLittle(u16, '\\'), mem.nativeToLittle(u16, '/') }) == null) {
        try buf.appendSlice(".\\");
    }
    // Note that we don't do any escaping/mitigations for this argument, since the relevant
    // characters (", %, etc) are illegal in file paths and this function should only be called
    // with script paths that have been verified to exist.
    try unicode.wtf16LeToWtf8ArrayList(&buf, script_path);
    buf.appendAssumeCapacity('"');

    for (script_args) |arg| {
        // Literal carriage returns get stripped when run through cmd.exe
        // and NUL/newlines act as 'end of command.' Because of this, it's basically
        // always a mistake to include these characters in argv, so it's
        // an error condition in order to ensure that the return of this
        // function can always roundtrip through cmd.exe.
        if (std.mem.indexOfAny(u8, arg, "\x00\r\n") != null) {
            return error.InvalidBatchScriptArg;
        }

        // Separate args with a space.
        try buf.append(' ');

        // Need to quote if the argument is empty (otherwise the arg would just be lost)
        // or if the last character is a `\`, since then something like "%~2" in a .bat
        // script would cause the closing " to be escaped which we don't want.
        var needs_quotes = arg.len == 0 or arg[arg.len - 1] == '\\';
        if (!needs_quotes) {
            for (arg) |c| {
                switch (c) {
                    // Known good characters that don't need to be quoted
                    'A'...'Z', 'a'...'z', '0'...'9', '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_' => {},
                    // When in doubt, quote
                    else => {
                        needs_quotes = true;
                        break;
                    },
                }
            }
        }
        if (needs_quotes) {
            try buf.append('"');
        }
        var backslashes: usize = 0;
        for (arg) |c| {
            switch (c) {
                '\\' => {
                    backslashes += 1;
                },
                '"' => {
                    try buf.appendNTimes('\\', backslashes);
                    try buf.append('"');
                    backslashes = 0;
                },
                // Replace `%` with `%%cd:~,%`.
                //
                // cmd.exe allows extracting a substring from an environment
                // variable with the syntax: `%foo:~<start_index>,<end_index>%`.
                // Therefore, `%cd:~,%` will always expand to an empty string
                // since both the start and end index are blank, and it is assumed
                // that `%cd%` is always available since it is a built-in variable
                // that corresponds to the current directory.
                //
                // This means that replacing `%foo%` with `%%cd:~,%foo%%cd:~,%`
                // will stop `%foo%` from being expanded and *after* expansion
                // we'll still be left with `%foo%` (the literal string).
                '%' => {
                    // the trailing `%` is appended outside the switch
                    try buf.appendSlice("%%cd:~,");
                    backslashes = 0;
                },
                else => {
                    backslashes = 0;
                },
            }
            try buf.append(c);
        }
        if (needs_quotes) {
            try buf.appendNTimes('\\', backslashes);
            try buf.append('"');
        }
    }

    try buf.append('"');

    return try unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
}
