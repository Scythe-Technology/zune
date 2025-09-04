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
    .macos, .linux, .freebsd => struct {
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
