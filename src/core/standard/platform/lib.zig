const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;
const EnumMap = Zune.Utils.EnumMap;

const VM = luau.VM;

const memory = @import("memory.zig");

pub const LIB_NAME = "platform";

fn lua_getPageSize(L: *VM.lua.State) i32 {
    L.pushnumber(@floatFromInt(std.heap.pageSize()));
    return 1;
}

fn lua_getTotalMemory(L: *VM.lua.State) !i32 {
    const amt = @divTrunc(try memory.getTotalSystemMemory(), memory.BYTES_PER_MB);
    L.pushnumber(@floatFromInt(amt));
    return 1;
}

fn lua_getFreeMemory(L: *VM.lua.State) !i32 {
    const amt = @divTrunc(try memory.getFreeMemory(), memory.BYTES_PER_MB);
    L.pushnumber(@floatFromInt(amt));
    return 1;
}

fn lua_getHostName(L: *VM.lua.State) !i32 {
    comptime {
        if (!builtin.link_libc)
            @compileError("libc needed for gethostname");
    }
    switch (comptime builtin.os.tag) {
        .windows => {
            const win = struct {
                pub extern "ws2_32" fn GetHostNameW(
                    name: [*:0]u16,
                    namelen: i32,
                ) callconv(.winapi) i32;
            };
            var wtf16_buf: [256:0]std.os.windows.WCHAR = undefined;
            const rc = win.GetHostNameW(&wtf16_buf, @sizeOf(@TypeOf(wtf16_buf)));
            if (rc != 0) {
                return switch (std.os.windows.ws2_32.WSAGetLastError()) {
                    .WSAEFAULT => unreachable,
                    .WSANOTINITIALISED => @panic("WSANOTINITIALISED"),
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
        else => {},
    }
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = try std.posix.gethostname(&buf);
    try L.pushlstring(name);
    return 1;
}

fn lua_getKernelVersion(L: *VM.lua.State) !i32 {
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
            std.posix.sysctlbynameZ("kern.osrelease", &version, &len, null, 0) catch |err| switch (err) {
                else => return error.UnknownKernelVersion,
            };
            const b: [*:0]u8 = &version;
            const str: []const u8 = std.mem.span(b);
            try L.pushfstring("Darwin {s}", .{str});
        },
        .freebsd => {
            var version: [256:0]u8 = undefined;
            var len: usize = @sizeOf(@TypeOf(version));
            std.posix.sysctlbynameZ("kern.osrelease", &version, &len, null, 0) catch |err| switch (err) {
                else => return error.UnknownKernelVersion,
            };
            const b: [*:0]u8 = &version;
            const str: []const u8 = std.mem.span(b);
            try L.pushfstring("FreeBSD {s}", .{str});
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

pub fn loadLib(L: *VM.lua.State) !void {
    try L.Zpushvalue(.{
        .os = @tagName(builtin.os.tag),
        .abi = @tagName(builtin.abi),
        .cpu = .{
            .arch = @tagName(builtin.cpu.arch),
            .endian = @tagName(builtin.cpu.arch.endian()),
        },
        .async = @tagName(xev.backend),
        .getPageSize = lua_getPageSize,
        .getTotalMemory = lua_getTotalMemory,
        .getFreeMemory = lua_getFreeMemory,
        .getHostName = lua_getHostName,
        .getKernelVersion = lua_getKernelVersion,
    });

    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test "platform" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/platform.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
