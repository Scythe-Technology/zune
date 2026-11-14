const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const memory = @import("memory.zig");

pub const LIB_NAME = "platform";

pub fn lua_getPageSize(L: *VM.lua.State) i32 {
    L.pushnumber(@floatFromInt(std.heap.pageSize()));
    return 1;
}

pub fn lua_getTotalMemory(L: *VM.lua.State) !i32 {
    const amt = @divTrunc(try memory.getTotalSystemMemory(), memory.BYTES_PER_MB);
    L.pushnumber(@floatFromInt(amt));
    return 1;
}

pub fn lua_getFreeMemory(L: *VM.lua.State) !i32 {
    const amt = @divTrunc(try memory.getFreeMemory(), memory.BYTES_PER_MB);
    L.pushnumber(@floatFromInt(amt));
    return 1;
}

pub fn lua_getHostName(L: *VM.lua.State) !i32 {
    comptime {
        if (!builtin.link_libc)
            @compileError("libc needed for gethostname");
    }
    switch (comptime builtin.os.tag) {
        .windows => {
            const WinApi = struct {
                pub extern "ws2_32" fn GetHostNameW(
                    name: [*:0]u16,
                    namelen: i32,
                ) callconv(.winapi) i32;

                pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
            };
            var wtf16_buf: [256:0]std.os.windows.WCHAR = undefined;
            const rc = WinApi.GetHostNameW(&wtf16_buf, @sizeOf(@TypeOf(wtf16_buf)));
            if (rc != 0) {
                return switch (WinApi.WSAGetLastError()) {
                    10014 => unreachable, // WSAEFAULT
                    10093 => @panic("WSANOTINITIALISED"), // WSANOTINITIALISED
                    else => error.UnknownHostName,
                };
            }
            const bwtf16: [*:0]u16 = &wtf16_buf;
            const wtf16_name: []const u16 = std.mem.span(bwtf16);
            var wtf8_buf: [256 * 2:0]u8 = undefined;
            const wtf8_name = wtf8_buf[0..std.unicode.wtf16LeToWtf8(&wtf8_buf, wtf16_name)];
            try L.pushlstring(wtf8_name);
            return 1;
        },
        .wasi, .emscripten => return error.UnsupportedPlatform,
        else => {},
    }
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = try std.posix.gethostname(&buf);
    try L.pushlstring(name);
    return 1;
}

pub fn lua_getKernelVersion(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows => {
            var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
            info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);

            switch (std.os.windows.ntdll.RtlGetVersion(&info)) {
                .SUCCESS => {},
                else => return error.UnknownKernelVersion,
            }
            try L.pushfstring("Windows {d}.{d}", .{ info.dwMajorVersion, info.dwMinorVersion });
        },
        // whole Darwin family
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => {
            var version: [256:0]u8 = undefined;
            var len: usize = @sizeOf(@TypeOf(version));
            switch (std.posix.errno(std.posix.system.sysctlbyname("kern.osrelease", &version, &len, null, 0))) {
                .SUCCESS => {},
                else => return error.UnknownKernelVersion,
            }
            const b: [*:0]u8 = &version;
            const str: []const u8 = std.mem.span(b);
            try L.pushfstring("Darwin {s}", .{str});
        },
        .freebsd => {
            var version: [256:0]u8 = undefined;
            var len: usize = @sizeOf(@TypeOf(version));
            switch (std.posix.errno(std.posix.system.sysctlbyname("kern.osrelease", &version, &len, null, 0))) {
                .SUCCESS => {},
                else => return error.UnknownKernelVersion,
            }
            const b: [*:0]u8 = &version;
            const str: []const u8 = std.mem.span(b);
            try L.pushfstring("FreeBSD {s}", .{str});
        },
        .openbsd => {
            var version: [256]u8 = undefined;
            var len: usize = version.len;
            const mib = [_]c_int{
                std.posix.CTL.KERN,
                std.posix.KERN.OSRELEASE,
            };
            std.posix.sysctl(&mib, &version, &len, null, 0) catch return error.UnknownKernelVersion;
            if (len > version.len)
                return error.UnknownKernelVersion;
            const str = std.mem.sliceTo(version[0..len], 0);
            try L.pushfstring("OpenBSD {s}", .{str});
        },
        .netbsd => {
            var version: [256:0]u8 = undefined;
            var len: usize = @sizeOf(@TypeOf(version));
            switch (std.posix.errno(std.posix.system.sysctlbyname("kern.osrelease", &version, &len, null, 0))) {
                .SUCCESS => {},
                else => return error.UnknownKernelVersion,
            }
            const b: [*:0]u8 = &version;
            const str: []const u8 = std.mem.span(b);
            try L.pushfstring("NetBSD {s}", .{str});
        },
        .linux => {
            var info: std.c.utsname = undefined;
            if (std.c.uname(&info) != 0) {
                return error.UnknownKernelVersion;
            }
            const b: [*:0]u8 = &info.release;
            const str: []const u8 = std.mem.span(b);
            try L.pushfstring("Linux {s}", .{str});
        },
        else => return error.UnknownKernelVersion,
    }
    return 1;
}

pub const lua_os = @tagName(builtin.os.tag);
pub const lua_abi = @tagName(builtin.abi);
pub const lua_cpu = struct {
    pub const lua_arch = @tagName(builtin.cpu.arch);
    pub const lua_endian = @tagName(builtin.cpu.arch.endian());
};
pub fn lua_custom_async(L: *VM.lua.State) !void {
    switch (zio.ev.backend) {
        .linux => {
            const scheduler = Scheduler.fromState(L);
            const engine = scheduler.loop.backend.selectedEngine();
            try L.pushlstring(@tagName(engine));
        },
        else => |e| try L.pushlstring(@tagName(e)),
    }
}
