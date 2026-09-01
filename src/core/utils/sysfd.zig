const std = @import("std");
const builtin = @import("builtin");

pub const context = switch (builtin.os.tag) {
    .windows => struct {
        pub const POLLIN: i16 = 0x0100;
        pub const POLLERR: i16 = 0x0001;
        pub const POLLHUP: i16 = 0x0002;
        pub const POLLNVAL: i16 = 0x0004;
        pub const INVALID_SOCKET = std.os.windows.ws2_32.INVALID_SOCKET;
        pub const pollfd = struct {
            fd: std.os.windows.HANDLE,
            events: std.os.windows.SHORT,
            revents: std.os.windows.SHORT,
        };
        pub const spollfd = std.os.windows.ws2_32.pollfd;
        pub fn spoll(fds: []spollfd, timeout: i32) !usize {
            const rc = std.os.windows.poll(fds.ptr, @intCast(fds.len), timeout);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                switch (std.os.windows.ws2_32.WSAGetLastError()) {
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSANOTINITIALISED => unreachable,
                    else => |err| return std.os.windows.unexpectedWSAError(err),
                }
            } else return @intCast(rc);
        }
        pub fn poll(fds: []pollfd, timeout: i32) !usize {
            var handles: [256]std.os.windows.HANDLE = undefined;
            if (fds.len > handles.len)
                return error.TooManyHandles;
            for (fds, 0..) |fd, i| handles[i] = fd.fd;

            const res = std.os.windows.kernel32.WaitForMultipleObjects(@intCast(fds.len), &handles, std.os.windows.FALSE, @intCast(timeout));

            if (res == std.os.windows.WAIT_TIMEOUT)
                return 0;

            if (res >= std.os.windows.WAIT_OBJECT_0 and @as(usize, @intCast(res)) < std.os.windows.WAIT_OBJECT_0 + fds.len) {
                const index = res - std.os.windows.WAIT_OBJECT_0;
                fds[index].revents = fds[index].events;
                return 1;
            }

            return error.UnexpectedWaitResult;
        }
    },
    .macos, .linux, .freebsd, .wasi => struct {
        pub const POLLIN: i16 = 0x0001;
        pub const POLLERR: i16 = 0x0008;
        pub const POLLHUP: i16 = 0x0010;
        pub const POLLNVAL: i16 = 0x0020;
        pub const INVALID_SOCKET = -1;
        pub const pollfd = std.posix.pollfd;
        pub const spollfd = std.posix.pollfd;
        pub const poll = std.posix.poll;
        pub const spoll = std.posix.poll;
    },
    else => @compileError("Unsupported OS"),
};

pub fn close(fd: std.posix.fd_t) void {
    switch (comptime builtin.os.tag) {
        .windows => std.os.windows.CloseHandle(fd),
        .linux => _ = std.os.linux.close(fd),
        else => _ = std.posix.system.close(fd),
    }
}

pub fn closeSocket(sock: std.posix.socket_t) void {
    switch (comptime builtin.os.tag) {
        .windows => std.os.windows.closesocket(sock) catch {},
        else => close(sock),
    }
}

pub fn listen(sock: std.posix.socket_t, backlog: u32) !void {
    const rc = std.os.linux.listen(sock, backlog);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        else => |e| std.posix.unexpectedErrno(e),
    };
}

pub fn ipFamily(address: std.Io.net.IpAddress) u32 {
    return switch (address) {
        .ip4 => std.posix.AF.INET,
        .ip6 => std.posix.AF.INET6,
    };
}

pub fn bindIp(sock: std.posix.socket_t, address: std.Io.net.IpAddress) !void {
    const linux = std.os.linux;
    switch (address) {
        .ip4 => |a| {
            var sa: linux.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, a.port),
                .addr = @bitCast(a.bytes),
            };
            const rc = linux.bind(sock, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
            return switch (linux.errno(rc)) {
                .SUCCESS => {},
                .ADDRINUSE => error.AddressInUse,
                .ACCES => error.AccessDenied,
                else => |e| std.posix.unexpectedErrno(e),
            };
        },
        .ip6 => |a| {
            var sa: linux.sockaddr.in6 = .{
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = 0,
                .addr = a.bytes,
                .scope_id = 0,
            };
            const rc = linux.bind(sock, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
            return switch (linux.errno(rc)) {
                .SUCCESS => {},
                .ADDRINUSE => error.AddressInUse,
                .ACCES => error.AccessDenied,
                else => |e| std.posix.unexpectedErrno(e),
            };
        },
    }
}

pub fn socket(domain: u32, flags: u32, protocol: u32) !std.posix.socket_t {
    switch (comptime builtin.os.tag) {
        .windows => return @import("os/windows.zig").socket(domain, flags, protocol),
        .linux => {
            const rc = std.os.linux.socket(domain, flags, protocol);
            return switch (std.os.linux.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => error.SystemResources,
                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                .PROTONOSUPPORT => error.ProtocolNotSupported,
                else => |e| std.posix.unexpectedErrno(e),
            };
        },
        else => {
            const rc = std.posix.system.socket(@intCast(domain), @intCast(flags), @intCast(protocol));
            return switch (std.posix.errno(@intCast(rc))) {
                .SUCCESS => @intCast(rc),
                else => |e| std.posix.unexpectedErrno(e),
            };
        },
    }
}
