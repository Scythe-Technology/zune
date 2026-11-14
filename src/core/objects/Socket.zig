const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Socket = @This();

pub const OBJECT_TAG = Zune.Tags.get("NET_SOCKET").?;
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => .Full,
        .freebsd, .openbsd, .netbsd => .Full,
        else => null,
    };
}

socket: zio.net.Socket,
state: State = .{},
staged: Scheduler.Async.Staged = .{},
ref: Scripting.CountedReference = .{},

const State = packed struct {
    binded: bool = false,
    connected: bool = false,
    listening: bool = false,
    closed: bool = false,

    pub const Enum = enum {
        nothing,
        binded,
        connected,
        listening,
        closed,
    };

    pub fn top(self: *State) Enum {
        if (self.closed)
            return .closed;
        if (self.listening)
            return .listening;
        if (self.connected)
            return .connected;
        if (self.binded)
            return .binded;
        return .nothing;
    }
};

pub fn pushAddress(L: *VM.lua.State, address: zio.net.Address) !void {
    var fixed: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&fixed);

    address.format(&writer) catch unreachable;

    const written = writer.buffered();
    switch (address.getType()) {
        .ip => try L.Zpushvalue(.{
            .address = written[0 .. std.mem.findScalarLast(u8, written, ':') orelse written.len],
            .port = address.ip.getPort(),
        }),
        .unix => try L.Zpushvalue(.{
            .address = written,
        }),
    }
}

pub fn getUnixSockAddrLen(un: zio.os.net.sockaddr.un) zio.os.net.socklen_t {
    const path_off = @offsetOf(zio.os.net.sockaddr.un, "path");
    // The abstract namespace is Linux-only: only there does a leading NUL select
    // an abstract (or unnamed/autobind) name whose length must exclude the
    // trailing NUL padding. Everywhere else a name is always a pathname.
    if (builtin.os.tag == .linux and un.path[0] == 0) {
        var len = un.path.len;
        while (len > 0 and un.path[len - 1] == 0) len -= 1;
        return @intCast(path_off + len);
    }
    // Pathname socket: NUL-terminated string; the terminator is part of the length.
    return @intCast(path_off + std.mem.sliceTo(&un.path, 0).len + 1);
}

pub fn getSockAddrLen(addr: zio.net.Address) zio.os.net.socklen_t {
    return switch (addr.any.family) {
        zio.os.net.AF.INET => @sizeOf(zio.os.net.sockaddr.in),
        zio.os.net.AF.INET6 => @sizeOf(zio.os.net.sockaddr.in6),
        zio.os.net.AF.UNIX => if (zio.os.net.has_unix_sockets) getUnixSockAddrLen(addr.unix.un) else unreachable,
        else => unreachable,
    };
}

fn getErrorWithTimeout(timer: ?zio.ev.Timer, err: anyerror) anyerror {
    if (err == error.Canceled and timer != null) {
        timer.?.getResult() catch |time_err|
            return time_err;
        return error.Timeout;
    }
    return err;
}

fn asyncCallback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const async: *Scheduler.Async = Scheduler.Async.fromCompletion(completion);
    const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));
    defer async.deinit(scheduler);

    const L = async.ref.value;

    const socket: *Socket = @ptrCast(@alignCast(completion.userdata));

    socket.ref.deref(L);
    socket.staged.remove(async);

    switch (async.op) {
        inline .net_send,
        .net_send_to,
        => |*e| {
            for (&e.buffer) |b| b.derefUnretained(L);

            if (L.status() != .Yield)
                return;

            const bytes = e.op_work.getResult() catch |err| {
                L.pushunsigned(0);
                L.pushlstring(@errorName(getErrorWithTimeout(e.op_timeout, err))) catch |oom|
                    return Scheduler.resumeStateError(L, null, oom) catch {};
                _ = Scheduler.resumeState(L, null, 2) catch {};
                return;
            };

            L.pushunsigned(@truncate(bytes));
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .net_recv,
        => |*e| {
            e.buffer_ref.deref(L);

            if (L.status() != .Yield)
                return;

            const bytes = e.op_work.getResult() catch |err| {
                L.pushunsigned(0);
                L.pushlstring(@errorName(getErrorWithTimeout(e.op_timeout, err))) catch |oom|
                    return Scheduler.resumeStateError(L, null, oom) catch {};
                _ = Scheduler.resumeState(L, null, 2) catch {};
                return;
            };

            L.pushunsigned(@truncate(bytes));
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        .net_recv_from => |*e| {
            e.buffer_ref.deref(L);

            if (L.status() != .Yield)
                return;

            const len = e.op_work.getResult() catch |err| {
                L.pushunsigned(0);
                L.pushnil();
                L.pushlstring(@errorName(getErrorWithTimeout(e.op_timeout, err))) catch |oom|
                    return Scheduler.resumeStateError(L, null, oom) catch {};
                _ = Scheduler.resumeState(L, null, 3) catch {};
                return;
            };

            L.pushunsigned(@intCast(len));
            var fixed: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&fixed);
            e.addr.format(&writer) catch unreachable;
            const written = writer.buffered();
            switch (e.addr.getType()) {
                .ip => L.Zpushvalue(.{
                    .address = written[0 .. std.mem.findScalarLast(u8, written, ':') orelse written.len],
                    .port = e.addr.ip.getPort(),
                }) catch |err| std.debug.print("{}", .{err}),
                .unix => L.Zpushvalue(.{
                    .address = written,
                }) catch |err| std.debug.print("{}", .{err}),
            }
            _ = Scheduler.resumeState(L, null, 2) catch {};
        },
        .net_accept => |*e| {
            if (L.status() != .Yield)
                return;

            const handle = e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = create(L, .{
                .handle = handle,
                .address = .fromPosix(&e.addr.any, e.addr_len),
            }, .{ .connected = true }) catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        inline .net_connect,
        .net_listen,
        .net_bind,
        .net_shutdown,
        => |*e, T| {
            e.op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            switch (T) {
                .net_listen => socket.state.listening = true,
                .net_connect => {
                    socket.state.connected = true;
                    socket.socket.address = e.addr;
                },
                .net_bind => {
                    socket.state.binded = true;
                    socket.socket.address = e.addr;
                },
                else => {},
            }

            _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        .net_close => |*e| {
            e.op.getResult() catch |err| switch (err) {
                error.Canceled => socket.socket.close(),
            };

            if (e.canceled)
                _ = scheduler.deferThread(.take(&async.ref), null, 0) catch {}
            else
                _ = Scheduler.resumeState(L, null, 0) catch {};
        },
        else => unreachable,
    }
}

pub fn startAsync(self: *Socket, async: *Scheduler.Async, L: *VM.lua.State, scheduler: *Scheduler) void {
    self.ref.ref(L, 1);

    const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));

    common.op.c.userdata = @ptrCast(@alignCast(self));
    common.op.c.callback = asyncCallback;

    self.staged.append(async);
    scheduler.loop.add(&common.op.c);
}

pub fn lua_send(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => {},
        else => return L.Zerror("socket not connected"),
    }
    if (!L.isyieldable())
        return L.Zyielderror();
    const buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };
    const timeout = try L.Zcheckvalue(?f64, 5, "invalid timeout");

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_send = .{
                .op = .init(.race),
            },
        },
    };

    const send = &async.op.net_send;

    send.buffer[0] = .init(L, 2);

    send.op_work = .init(self.socket.handle, .fromSlice(buf, &send.iovec), .{});

    send.op.add(&send.op_work.c);
    if (timeout) |time| {
        send.op_timeout = .init(.fromMilliseconds(@trunc(time * std.time.ms_per_s)));
        send.op.add(&send.op_timeout.?.c);
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_sendVec(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => {},
        else => return L.Zerror("socket not connected"),
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const size = @typeInfo(@FieldType(Scheduler.Async.Operation.NetSend, "buffer")).array.len;
    var slices: [size][]const u8 = undefined;
    var refs: [size]Scripting.Reference = @splat(.empty);
    const amount = try Scripting.collectVec(L, 2, &slices, &refs);
    if (amount == 0) {
        L.pushnumber(0);
        return 1;
    }

    const timeout = try L.Zcheckvalue(?f64, 3, "invalid timeout");

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_send = .{
                .op = .init(.race),
                .buffer = refs,
            },
        },
    };

    const send = &async.op.net_send;

    send.op_work = .init(self.socket.handle, .fromSlices(slices[0..amount], &send.iovec), .{});

    send.op.add(&send.op_work.c);
    if (timeout) |time| {
        send.op_timeout = .init(.fromMilliseconds(@trunc(time * std.time.ms_per_s)));
        send.op.add(&send.op_timeout.?.c);
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_sendToAddress(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket has peer"),
        .listening => return L.Zerror("socket is listening"),
        .binded, .nothing => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const address_ip = try L.Zcheckvalue([:0]const u8, 2, "invalid address");
    const port = try L.Zcheckvalue(u32, 3, "invalid port");
    if (port > std.math.maxInt(u16))
        return L.Zerror("port out of range");

    const address = try zio.net.IpAddress.parseIp(address_ip, @intCast(port));

    const buf = Scripting.getControlledBuffer(L, []const u8, 4) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };
    const timeout = try L.Zcheckvalue(?f64, 7, "invalid timeout");

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_send_to = .{
                .op = .init(.race),
                .addr = .{ .ip = address },
            },
        },
    };

    const send_to = &async.op.net_send_to;

    send_to.buffer[0] = .init(L, 4);

    send_to.op_work = .init(self.socket.handle, .fromSlice(buf, &send_to.iovec), .{}, &send_to.addr.any, getSockAddrLen(send_to.addr));

    send_to.op.add(&send_to.op_work.c);
    if (timeout) |time| {
        send_to.op_timeout = .init(.fromMilliseconds(@trunc(time * std.time.ms_per_s)));
        send_to.op.add(&send_to.op_timeout.?.c);
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_sendToUnix(self: *Socket, L: *VM.lua.State) !i32 {
    if (comptime !zio.os.net.has_unix_sockets)
        return L.Zerror("unix sockets not supported");
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket has peer"),
        .listening => return L.Zerror("socket is listening"),
        .binded, .nothing => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const path = try L.Zcheckvalue([:0]const u8, 2, "invalid path");

    const address = try zio.net.UnixAddress.init(path);

    const buf = Scripting.getControlledBuffer(L, []const u8, 3) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };
    const timeout = try L.Zcheckvalue(?f64, 6, "invalid timeout");

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_send_to = .{
                .op = .init(.race),
                .addr = .{ .unix = address },
            },
        },
    };

    const send_to = &async.op.net_send_to;

    send_to.buffer[0] = .init(L, 3);

    send_to.op_work = .init(self.socket.handle, .fromSlice(buf, &send_to.iovec), .{}, &send_to.addr.any, getSockAddrLen(send_to.addr));

    send_to.op.add(&send_to.op_work.c);
    if (timeout) |time| {
        const ms: u64 = @trunc(time * std.time.ms_per_s);
        if (ms == 0) {
            scheduler.destroyAsync(async);
            return L.Zerror("timeout must be greater than 0");
        }
        send_to.op_timeout = .init(.fromMilliseconds(ms));
        send_to.op.add(&send_to.op_timeout.?.c);
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_recv(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => {},
        else => return L.Zerror("socket not connected"),
    }
    if (!L.isyieldable())
        return L.Zyielderror();
    const buf = Scripting.getControlledBuffer(L, []u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };
    const timeout = try L.Zcheckvalue(?f64, 5, "invalid timeout");

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_recv = .{
                .op = .init(.race),
                .buffer_ref = .init(L, 2),
            },
        },
    };

    const recv = &async.op.net_recv;

    recv.op_work = .init(self.socket.handle, .fromSlice(buf, &recv.iovec), .{});

    recv.op.add(&recv.op_work.c);
    if (timeout) |time| {
        recv.op_timeout = .init(.fromMilliseconds(@trunc(time * std.time.ms_per_s)));
        recv.op.add(&recv.op_timeout.?.c);
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_recvFrom(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket has peer"),
        .listening => return L.Zerror("socket is listening"),
        .binded, .nothing => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const buf = Scripting.getControlledBuffer(L, []u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };
    const timeout = try L.Zcheckvalue(?f64, 5, "invalid timeout");

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_recv_from = .{
                .op = .init(.race),
                .addr_len = @sizeOf(zio.net.Address),
                .buffer_ref = .init(L, 2),
            },
        },
    };

    const recv_from = &async.op.net_recv_from;

    recv_from.op_work = .init(self.socket.handle, .fromSlice(buf, &recv_from.iovec), .{}, &recv_from.addr.any, &recv_from.addr_len);

    recv_from.op.add(&recv_from.op_work.c);
    if (timeout) |time| {
        recv_from.op_timeout = .init(.fromMilliseconds(@trunc(time * std.time.ms_per_s)));
        recv_from.op.add(&recv_from.op_timeout.?.c);
    }

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_accept(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket already connected"),
        .nothing => return L.Zerror("socket not binded"),
        .binded => return L.Zerror("socket not listening"),
        .listening => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_accept = .{
                .addr_len = @sizeOf(zio.net.Address),
            },
        },
    };

    const accept = &async.op.net_accept;

    accept.op = .init(self.socket.handle, &accept.addr.any, &accept.addr_len);

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_connectAddress(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket already connected"),
        .listening => return L.Zerror("socket already listening"),
        .nothing, .binded => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const address_ip = try L.Zcheckvalue([:0]const u8, 2, null);
    const port = try L.Zcheckvalue(u32, 3, null);
    if (port > std.math.maxInt(u16))
        return L.Zerror("port out of range");

    const address = try zio.net.IpAddress.parseIp(address_ip, @intCast(port));

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_connect = .{
                .addr = .{ .ip = address },
            },
        },
    };

    const connect = &async.op.net_connect;

    connect.op = .init(self.socket.handle, &connect.addr.any, getSockAddrLen(connect.addr));

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_connectUnix(self: *Socket, L: *VM.lua.State) !i32 {
    if (comptime !zio.os.net.has_unix_sockets)
        return L.Zerror("unix sockets not supported");
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket already connected"),
        .listening => return L.Zerror("socket already listening"),
        .nothing, .binded => {},
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const path = try L.Zcheckvalue([:0]const u8, 2, null);

    const address = try zio.net.UnixAddress.init(path);

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_connect = .{
                .addr = .{ .unix = address },
            },
        },
    };

    const connect = &async.op.net_connect;

    connect.op = .init(self.socket.handle, &connect.addr.any, getSockAddrLen(connect.addr));

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_listen(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket already connected"),
        .listening => return L.Zerror("socket already listening"),
        .nothing => return L.Zerror("socket not binded"),
        .binded => {},
    }
    const backlog = L.Loptunsigned(2, 128);
    if (backlog > std.math.maxInt(u31))
        return L.Zerror("too large");

    if (!L.isyieldable()) {
        // [SYNC]
        try self.socket.listen(@intCast(backlog));
        return 0;
    }

    // [ASYNC]
    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_listen = .{
                .op = .init(self.socket.handle, @intCast(backlog)),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_bindAddress(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket already connected"),
        .listening => return L.Zerror("socket already listening"),
        .binded => return L.Zerror("socket already binded"),
        .nothing => {},
    }

    const address_ip = try L.Zcheckvalue([:0]const u8, 2, null);
    const port = try L.Zcheckvalue(u32, 3, null);
    if (port > std.math.maxInt(u16))
        return L.Zerror("port out of range");

    const address = try zio.net.IpAddress.parseIp(address_ip, @intCast(port));

    if (!L.isyieldable()) {
        // [SYNC]
        try self.socket.bind(.{ .ip = address });
        return 0;
    }
    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_bind = .{
                .addr = .{ .ip = address },
                .addr_len = getSockAddrLen(.{ .ip = address }),
            },
        },
    };

    const bind = &async.op.net_bind;

    bind.op = .init(self.socket.handle, &bind.addr.any, &bind.addr_len);

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_bindUnix(self: *Socket, L: *VM.lua.State) !i32 {
    if (comptime !zio.os.net.has_unix_sockets)
        return L.Zerror("unix sockets not supported");

    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        .connected => return L.Zerror("socket already connected"),
        .listening => return L.Zerror("socket already listening"),
        .binded => return L.Zerror("socket already binded"),
        .nothing => {},
    }

    const path = try L.Zcheckvalue([:0]const u8, 2, null);

    const address = try zio.net.UnixAddress.init(path);

    if (!L.isyieldable()) {
        // [SYNC]
        try self.socket.bind(.{ .unix = address });
        return 0;
    }

    // [ASYNC]
    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_bind = .{
                .addr = .{ .unix = address },
                .addr_len = getSockAddrLen(.{ .unix = address }),
            },
        },
    };

    const bind = &async.op.net_bind;

    bind.op = .init(self.socket.handle, &bind.addr.any, &bind.addr_len);

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_setReuseAddress(self: *Socket, L: *VM.lua.State) !i32 {
    const reuse = try L.Zcheckvalue(bool, 2, null);
    try self.socket.setReuseAddress(reuse);
    return 0;
}

pub fn lua_setReusePort(self: *Socket, L: *VM.lua.State) !i32 {
    if (comptime builtin.os.tag == .windows)
        return 0;
    const reuse = try L.Zcheckvalue(bool, 2, null);
    try self.socket.setReusePort(reuse);
    return 0;
}

pub fn lua_setKeepAlive(self: *Socket, L: *VM.lua.State) !i32 {
    const keep_alive = try L.Zcheckvalue(bool, 2, null);
    try self.socket.setKeepAlive(keep_alive);
    return 0;
}

pub fn lua_setNoDelay(self: *Socket, L: *VM.lua.State) !i32 {
    const no_delay = try L.Zcheckvalue(bool, 2, null);
    try self.socket.setNoDelay(no_delay);
    return 0;
}

pub fn lua_setSendBufferSize(self: *Socket, L: *VM.lua.State) !i32 {
    const size = try L.Zcheckvalue(u32, 2, null);
    try self.socket.setSendBufferSize(size);
    return 0;
}

pub fn lua_setReceiveBufferSize(self: *Socket, L: *VM.lua.State) !i32 {
    const size = try L.Zcheckvalue(u32, 2, null);
    try self.socket.setReceiveBufferSize(size);
    return 0;
}

pub fn lua_getSendBufferSize(self: *Socket, L: *VM.lua.State) !i32 {
    const size = try self.socket.getSendBufferSize();
    L.pushnumber(@floatFromInt(size));
    return 1;
}

pub fn lua_getReceiveBufferSize(self: *Socket, L: *VM.lua.State) !i32 {
    const size = try self.socket.getReceiveBufferSize();
    L.pushnumber(@floatFromInt(size));
    return 1;
}

pub fn lua_shutdown(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .closed => return L.Zerror("socket closed"),
        else => {},
    }

    const HowMap = comptime Scripting.createEnumMap(zio.os.net.ShutdownHow);
    const how = HowMap.get(try L.Zcheckvalue([:0]const u8, 2, null)) orelse return L.Zerror("invalid shutdown how option");

    if (!L.isyieldable()) {
        // [SYNC]
        try self.socket.shutdown(how);
        return 0;
    }

    // [ASYNC]
    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .net_shutdown = .{ .op = .init(self.socket.handle, how) },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_close(self: *Socket, L: *VM.lua.State) !i32 {
    if (!self.state.closed) {
        const scheduler = Scheduler.fromState(L);

        const canceled = blk: {
            var node = self.staged.list.first;
            const had = node != null;
            while (node) |n| {
                const async: *Scheduler.Async = @alignCast(@fieldParentPtr("node", n));
                const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));
                scheduler.loop.cancel(&common.op.c);
                node = n.next;
            }
            break :blk had;
        };

        if (!L.isyieldable()) {
            // [SYNC]
            self.state.closed = true;
            self.socket.close();
            return 0;
        }

        // [ASYNC]
        const async = try scheduler.createAsync();

        self.state.closed = true;

        async.* = .{
            .ref = .init(L),
            .op = .{
                .net_close = .{
                    .op = .init(self.socket.handle),
                    .canceled = canceled,
                },
            },
        };

        self.startAsync(async, L, scheduler);

        return L.yield(0) catch unreachable;
    }
    return 0;
}

pub fn lua_direct_open(self: *Socket, res: *VM.lobject.TValue) void {
    res.setbvalue(!self.state.closed);
}

pub fn lua_address(self: *Socket, L: *VM.lua.State) !i32 {
    switch (self.state.top()) {
        .nothing,
        .closed,
        => {
            L.pushnil();
            return 1;
        },
        else => {},
    }

    try pushAddress(L, self.socket.address);

    return 1;
}

pub fn __dtor(_: *VM.lua.State, self: *Socket) void {
    if (!self.state.closed) {
        self.state.closed = true;
        self.socket.close();
    }
}

pub fn create(L: *VM.lua.State, value: zio.net.Socket, state: State) !*Socket {
    const self = try L.newuserdatataggedwithmetatable(Socket, OBJECT_TAG);
    self.* = .{
        .state = state,
        .socket = value,
    };
    return self;
}
