const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const wire = @import("wire");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const CPointer = Zune.objects.CPointer;

const VM = luau.VM;

const DynamicLibrary = @This();

pub const OBJECT_TAG = Zune.Tags.get("C_DYNLIB").?;
pub const PlatformSupported = Zune.standard.libraries.c.PlatformSupported;

lib: if (builtin.os.tag == .windows) WinApi.HMODULE else std.DynLib,

const WinApi = struct {
    const w = std.os.windows;

    pub const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x100;
    pub const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS = 0x1000;
    pub const INVALID_FILE_ATTRIBUTES = 0xffffffff;

    pub const HMODULE = w.HMODULE;

    pub extern "kernel32" fn LoadLibraryExW(
        lpLibFileName: [*:0]const u16,
        hFile: ?*anyopaque,
        dwFlags: u32,
    ) callconv(.winapi) ?HMODULE;

    pub extern "kernel32" fn GetFullPathNameW(
        lpFileName: [*:0]const u16,
        nBufferLength: u32,
        lpBuffer: [*]u16,
        lpFilePart: ?*?[*:0]u16,
    ) callconv(.winapi) u32;

    pub extern "kernel32" fn GetProcAddress(
        hModule: HMODULE,
        lpProcName: [*:0]const u8,
    ) callconv(.winapi) ?w.FARPROC;
};

pub fn openLibrary(L: *VM.lua.State, path: [:0]const u8) !*DynamicLibrary {
    const ptr = try L.newuserdatataggedwithmetatable(DynamicLibrary, DynamicLibrary.OBJECT_TAG);

    const lib = switch (comptime builtin.os.tag) {
        .windows => win: {
            var wide_path: [std.fs.max_path_bytes:0]std.os.windows.WCHAR = undefined;
            const n = try std.unicode.utf8ToUtf16Le(&wide_path, path);
            wide_path[n] = 0;

            var flags: u32 = WinApi.LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
            var load_name: [*:0]const std.os.windows.WCHAR = @ptrCast(@alignCast(&wide_path));
            var abs_path: [std.os.windows.PATH_MAX_WIDE:0]std.os.windows.WCHAR = undefined;
            if (std.mem.indexOfAny(u8, path, "/\\") != null) {
                const abs_len = WinApi.GetFullPathNameW(load_name, abs_path.len, &abs_path, null);
                if (abs_len == 0) switch (std.os.windows.GetLastError()) {
                    .FILE_NOT_FOUND, .PATH_NOT_FOUND => return error.FileNotFound,
                    .ACCESS_DENIED => return error.PermissionDenied,
                    else => |e| return std.os.windows.unexpectedError(e),
                };
                if (abs_len >= abs_path.len)
                    return error.NameTooLong;
                abs_path[abs_len] = 0;
                load_name = @ptrCast(@alignCast(&abs_path));
                flags |= WinApi.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR;
            }

            break :win WinApi.LoadLibraryExW(
                load_name,
                null,
                flags,
            ) orelse {
                switch (std.os.windows.GetLastError()) {
                    .PROC_NOT_FOUND => return error.ProcNotFound,
                    .BAD_EXE_FORMAT => return error.BadExeFormat,
                    .INVALID_IMAGE_HASH => return error.InvalidImageHash,
                    .ACCESS_DENIED => return error.PermissionDenied,
                    .MOD_NOT_FOUND, .FILE_NOT_FOUND, .PATH_NOT_FOUND => return error.FileNotFound,
                    else => |e| return std.os.windows.unexpectedError(e),
                }
            };
        },
        else => try std.DynLib.open(path),
    };

    ptr.* = .{
        .lib = lib,
    };

    return ptr;
}

pub fn lua_getSymbol(self: *DynamicLibrary, L: *VM.lua.State) !i32 {
    const symbol = try L.Zcheckvalue([:0]const u8, 2, null);
    const sym_ptr: ?*anyopaque = switch (comptime builtin.os.tag) {
        .windows => @ptrCast(WinApi.GetProcAddress(self.lib, symbol) orelse {
            L.pushnil();
            return 1;
        }),
        else => self.lib.lookup(*anyopaque, symbol) orelse {
            L.pushnil();
            return 1;
        },
    };
    _ = try CPointer.newStaticPtr(L, sym_ptr);
    return 1;
}

pub fn __dtor(L: *VM.lua.State, self: *DynamicLibrary) void {
    _ = L;
    _ = self;
}
