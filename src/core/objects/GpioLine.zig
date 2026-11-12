const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const VM = luau.VM;

const GpioLine = @This();

pub const OBJECT_TAG = Zune.Tags.get("GPIO_LINE").?;

pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux => .Limited,
        else => null,
    };
}

fd: i32 = -1,
output: bool = false,

const linux = if (builtin.os.tag == .linux) struct {
    const LineValues = extern struct {
        bits: u64 align(8),
        mask: u64 align(8),
    };

    // linux/gpio.h — GPIO_V2_LINE_GET_VALUES_IOCTL / GPIO_V2_LINE_SET_VALUES_IOCTL.
    const get_values = std.os.linux.IOCTL.IOWR(0xB4, 0x0E, LineValues);
    const set_values = std.os.linux.IOCTL.IOWR(0xB4, 0x0F, LineValues);

    comptime {
        std.debug.assert(@sizeOf(LineValues) == 16);
    }

    fn ioctl(fd: i32, code: u32, arg: *anyopaque) !void {
        while (true) {
            const rc = std.os.linux.ioctl(fd, code, @intFromPtr(arg));
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .BUSY => return error.LineBusy,
                .NODEV, .NXIO, .NOTTY, .NOSYS, .OPNOTSUPP => return error.GpioUnsupported,
                .INVAL => return error.InvalidRequest,
                .ACCES, .PERM => return error.PermissionDenied,
                .NOMEM => return error.SystemResources,
                .FAULT => unreachable,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn scriptError(L: *VM.lua.State, err: anyerror) anyerror {
        return switch (err) {
            error.RaiseLuauError => err,
            error.GpioUnsupported => L.Zerror("gpio unsupported"),
            error.PermissionDenied => L.Zerror("permission denied"),
            error.LineBusy => L.Zerror("line busy"),
            error.InvalidRequest => L.Zerror("invalid request"),
            else => err,
        };
    }

    fn read(self: *GpioLine, L: *VM.lua.State) !i32 {
        if (self.fd < 0)
            return L.Zerror("closed");

        var values: LineValues = .{ .bits = 0, .mask = 1 };
        ioctl(self.fd, get_values, &values) catch |err| return scriptError(L, err);

        L.pushboolean((values.bits & 1) != 0);

        return 1;
    }

    fn write(self: *GpioLine, L: *VM.lua.State) !i32 {
        if (self.fd < 0)
            return L.Zerror("closed");
        if (!self.output)
            return L.Zerror("not writable");

        const level = try L.Zcheckvalue(bool, 2, null);
        var values: LineValues = .{
            .bits = if (level) 1 else 0,
            .mask = 1,
        };
        ioctl(self.fd, set_values, &values) catch |err| return scriptError(L, err);

        return 0;
    }

    fn close(self: *GpioLine) void {
        if (self.fd < 0)
            return;
        const fd = self.fd;

        self.fd = -1;
        _ = std.os.linux.close(fd);
    }
} else struct {};

pub fn lua_read(self: *GpioLine, L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    return linux.read(self, L);
}

pub fn lua_write(self: *GpioLine, L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    return linux.write(self, L);
}

pub fn lua_close(self: *GpioLine, L: *VM.lua.State) !i32 {
    _ = L;
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    linux.close(self);
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *GpioLine) void {
    _ = L;
    switch (comptime builtin.os.tag) {
        .linux => linux.close(self),
        else => {},
    }
}

pub fn create(L: *VM.lua.State, fd: i32, output: bool) !*GpioLine {
    const self = try L.newuserdatataggedwithmetatable(GpioLine, OBJECT_TAG);
    self.* = .{
        .fd = fd,
        .output = output,
    };
    return self;
}
