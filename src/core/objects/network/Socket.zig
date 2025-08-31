const std = @import("std");
const xev = @import("xev").Dynamic;
const tls = @import("tls");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const tagged = Zune.tagged;

const VM = luau.VM;

const Socket = @This();

const TAG_NET_SOCKET = tagged.Tags.get("NET_SOCKET").?;
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub const TlsContext = union(enum) {
    none: void,
    server: *Server,
    client: *Client,
    server_ref: *ServerRef,

    pub const Client = struct {
        allocator: std.mem.Allocator,
        record_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
        cleartext_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
        ciphertext_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
        record: std.Io.Reader,
        cleartext: std.Io.Reader,
        ciphertext: std.Io.Reader,
        connection: union(enum) {
            handshake: struct {
                GL: *VM.lua.State,
                ca_ref: LuaHelper.Ref(void),
                client: tls.nonblock.Client,
                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    allocator.free(self.client.opt.host);
                    self.ca_ref.deref(self.GL);
                }
            },
            active: struct {
                tls: tls.nonblock.Connection,
            },
        },
        connecting: bool = false,

        pub fn deinit(self: *Client) void {
            const allocator = self.allocator;
            defer allocator.destroy(self);
            switch (self.connection) {
                .handshake => |*c| c.deinit(allocator),
                .active => {},
            }
        }
    };

    pub const Server = struct {
        allocator: std.mem.Allocator,
        record_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
        cleartext_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
        ciphertext_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
        record: std.Io.Reader,
        cleartext: std.Io.Reader,
        ciphertext: std.Io.Reader,
        connection: union(enum) {
            handshake: struct {
                GL: *VM.lua.State,
                ca_keypair_ref: LuaHelper.Ref(void),
                server: tls.nonblock.Server,
                pub fn deinit(self: *@This()) void {
                    self.ca_keypair_ref.deref(self.GL);
                }
            },
            active: struct {
                tls: tls.nonblock.Connection,
            },
        },
        stage: enum { nothing, handshake, completed } = .nothing,

        pub fn deinit(self: *Server) void {
            const allocator = self.allocator;
            defer allocator.destroy(self);
        }
    };

    pub const ServerRef = struct {
        GL: *VM.lua.State,
        ca_keypair_ref: LuaHelper.Ref(void),
        server: tls.nonblock.Server,
        pub fn deinit(self: *@This()) void {
            self.ca_keypair_ref.deref(self.GL);
        }
    };

    pub fn endingStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = r;
        _ = w;
        _ = limit;
        return error.EndOfStream;
    }

    pub fn deinit(self: *TlsContext) void {
        switch (self.*) {
            .none => {},
            inline else => |o| o.deinit(),
        }
        self.* = .none;
    }
};

socket: std.posix.socket_t,
open: OpenCase,
list: *Scheduler.CompletionLinkedList,
tls_context: TlsContext = .none,

const OpenCase = enum { created, accepted, closed };

fn closesocket(socket: std.posix.socket_t) void {
    switch (comptime builtin.os.tag) {
        .windows => std.os.windows.closesocket(socket) catch unreachable,
        else => std.posix.close(socket),
    }
}

pub const LONGEST_ADDRESS = 108;
pub fn AddressToString(buf: []u8, address: std.net.Address) []const u8 {
    switch (address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            const b = std.fmt.bufPrint(buf, "{f}", .{address}) catch @panic("OutOfMemory");
            var iter = std.mem.splitBackwardsAny(u8, b, ":");
            _ = iter.first();
            return iter.rest();
        },
        else => {
            return std.fmt.bufPrint(buf, "{f}", .{address}) catch @panic("OutOfMemory");
        },
    }
}

const AsyncSendContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,
    consumed: usize = 0,
    tls: TlsContext,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = w catch |err| {
            L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.pushunsigned(@intCast(len));
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }

    pub fn resumeWithError(
        self: *AsyncSendContext,
        err: anyerror,
    ) xev.CallbackAction {
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
        _ = Scheduler.resumeStateError(L, null) catch {};
        return .disarm;
    }

    pub fn write(
        self: *AsyncSendContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        tcp: xev.TCP,
        comptime callback: *const fn (
            ?*AsyncSendContext,
            *xev.Loop,
            *xev.Completion,
            xev.TCP,
            xev.WriteBuffer,
            xev.WriteError!usize,
        ) xev.CallbackAction,
    ) void {
        switch (self.tls) {
            .none => tcp.write(
                loop,
                completion,
                .{ .slice = self.buffer },
                AsyncSendContext,
                self,
                callback,
            ),
            inline .server, .client => |ctx, e| {
                const res = ctx.connection.active.tls.encrypt(self.buffer, ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch |err| {
                    _ = self.resumeWithError(err);
                    return;
                };
                self.consumed = res.cleartext_pos;
                ctx.ciphertext.end += res.ciphertext.len;
                tcp.write(
                    loop,
                    completion,
                    .{ .slice = ctx.ciphertext.buffered() },
                    AsyncSendContext,
                    self,
                    struct {
                        fn inner(
                            ud: ?*AsyncSendContext,
                            l: *xev.Loop,
                            c: *xev.Completion,
                            inner_tcp: xev.TCP,
                            _: xev.WriteBuffer,
                            w: xev.WriteError!usize,
                        ) xev.CallbackAction {
                            const inner_self = ud orelse unreachable;
                            const inner_ctx = @field(inner_self.tls, @tagName(e));
                            const ciphertext_written = w catch |err| return @call(.always_inline, callback, .{
                                ud,
                                l,
                                c,
                                inner_tcp,
                                xev.WriteBuffer{ .slice = inner_self.buffer },
                                err,
                            });
                            inner_ctx.ciphertext.toss(ciphertext_written);
                            inner_ctx.ciphertext.rebase(inner_ctx.ciphertext.buffer.len) catch unreachable; // shouldn't fail
                            if (inner_ctx.ciphertext.end > 0) {
                                inner_tcp.write(
                                    l,
                                    c,
                                    .{ .slice = inner_ctx.ciphertext.buffered() },
                                    AsyncSendContext,
                                    inner_self,
                                    @This().inner,
                                );
                                return .disarm;
                            }
                            return @call(.always_inline, callback, .{
                                ud,
                                l,
                                c,
                                inner_tcp,
                                xev.WriteBuffer{ .slice = inner_self.buffer },
                                inner_self.consumed,
                            });
                        }
                    }.inner,
                );
            },
            .server_ref => unreachable,
        }
    }
};

const AsyncSendMsgContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    state: xev.UDP.State,
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        _: xev.UDP,
        _: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = w catch |err| {
            L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.pushunsigned(@intCast(len));
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

const AsyncRecvContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,
    tls: TlsContext,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = r catch |err| {
            L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.Zpushbuffer(self.buffer[0..len]) catch |e| std.debug.panic("{}", .{e});

        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }

    pub fn resumeWithError(
        self: *AsyncRecvContext,
        err: anyerror,
    ) xev.CallbackAction {
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
        _ = Scheduler.resumeStateError(L, null) catch {};
        return .disarm;
    }

    pub fn read(
        self: *AsyncRecvContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        tcp: xev.TCP,
        comptime callback: *const fn (
            ?*AsyncRecvContext,
            *xev.Loop,
            *xev.Completion,
            xev.TCP,
            xev.ReadBuffer,
            xev.ReadError!usize,
        ) xev.CallbackAction,
    ) void {
        switch (self.tls) {
            .none => {
                tcp.read(
                    loop,
                    completion,
                    .{ .slice = self.buffer },
                    AsyncRecvContext,
                    self,
                    callback,
                );
            },
            inline .server, .client => |ctx, e| {
                if (ctx.cleartext.bufferedLen() > 0) {
                    const amount = ctx.cleartext.readSliceShort(self.buffer) catch unreachable; // shouldn't fail, entirely buffered
                    ctx.cleartext.rebase(ctx.cleartext.buffer.len) catch unreachable; // shouldn't fail
                    _ = @call(.always_inline, callback, .{
                        self,
                        loop,
                        completion,
                        tcp,
                        xev.ReadBuffer{ .slice = self.buffer },
                        amount,
                    });
                    return;
                }

                tcp.read(
                    loop,
                    completion,
                    .{ .slice = ctx.record.buffer[ctx.record.end..] },
                    AsyncRecvContext,
                    self,
                    struct {
                        fn inner(
                            ud: ?*AsyncRecvContext,
                            l: *xev.Loop,
                            c: *xev.Completion,
                            inner_tcp: xev.TCP,
                            _: xev.ReadBuffer,
                            r: xev.ReadError!usize,
                        ) xev.CallbackAction {
                            const inner_self = ud orelse unreachable;
                            const inner_ctx = @field(inner_self.tls, @tagName(e));
                            inner_ctx.record.end += r catch |err| return @call(.always_inline, callback, .{
                                ud,
                                l,
                                c,
                                inner_tcp,
                                xev.ReadBuffer{ .slice = inner_self.buffer },
                                err,
                            });
                            const res = inner_ctx.connection.active.tls.decrypt(
                                inner_ctx.record.buffered(),
                                inner_ctx.cleartext.buffer[inner_ctx.cleartext.end..],
                            ) catch |err| return inner_self.resumeWithError(err);
                            inner_ctx.record.toss(res.ciphertext_pos);
                            inner_ctx.record.rebase(inner_ctx.record.buffer.len) catch unreachable; // shouldn't fail
                            inner_ctx.cleartext.end += res.cleartext.len;
                            if (res.cleartext.len > 0) {
                                const amount = inner_ctx.cleartext.readSliceShort(inner_self.buffer) catch unreachable; // shouldn't fail, entirely buffered
                                inner_ctx.cleartext.rebase(inner_ctx.cleartext.buffer.len) catch unreachable; // shouldn't fail
                                _ = @call(.always_inline, callback, .{
                                    ud,
                                    l,
                                    c,
                                    inner_tcp,
                                    xev.ReadBuffer{ .slice = inner_self.buffer },
                                    amount,
                                });
                                return .disarm;
                            }
                            inner_tcp.read(
                                l,
                                c,
                                .{ .slice = inner_ctx.record.buffer[inner_ctx.record.end..] },
                                AsyncRecvContext,
                                inner_self,
                                @This().inner,
                            );
                            return .disarm;
                        }
                    }.inner,
                );
            },
            .server_ref => unreachable,
        }
    }
};

const AsyncRecvMsgContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    state: xev.UDP.State,
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        address: std.net.Address,
        _: xev.UDP,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = r catch |err| {
            L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.createtable(0, 3) catch |e| std.debug.panic("{}", .{e});
        L.Zsetfield(-1, "family", address.any.family) catch |e| std.debug.panic("{}", .{e});
        L.Zsetfield(-1, "port", address.getPort()) catch |e| std.debug.panic("{}", .{e});
        var buf: [LONGEST_ADDRESS]u8 = undefined;
        L.pushlstring(AddressToString(&buf, address)) catch |e| std.debug.panic("{}", .{e});
        L.rawsetfield(-2, "address") catch |e| std.debug.panic("{}", .{e});
        L.Zpushbuffer(self.buffer[0..len]) catch |e| std.debug.panic("{}", .{e});

        _ = Scheduler.resumeState(L, null, 2) catch {};

        return .disarm;
    }
};

const AsyncAcceptContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    ref: Scheduler.ThreadRef,
    list: *Scheduler.CompletionLinkedList,
    tls: TlsContext,
    accepted_ref: LuaHelper.Ref(void) = .empty,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);

        jmp: {
            if (L.status() != .Yield)
                break :jmp;

            const socket = s catch |err| {
                L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
                _ = Scheduler.resumeStateError(L, null) catch {};
                break :jmp;
            };

            const accepted_socket = push(
                L,
                switch (comptime builtin.os.tag) {
                    .windows => @ptrCast(@alignCast(socket.fd)),
                    .ios, .macos, .wasi => socket.fd,
                    .linux => socket.fd(),
                    else => @compileError("Unsupported OS"),
                },
                .accepted,
            ) catch |err| {
                L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
                _ = Scheduler.resumeStateError(L, null) catch {};
                break :jmp;
            };
            if (self.tls == .server_ref) {
                const context = scheduler.allocator.create(TlsContext.Server) catch |err| {
                    L.pop(1);
                    L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
                    _ = Scheduler.resumeStateError(L, null) catch {};
                    break :jmp;
                };
                context.* = .{
                    .allocator = scheduler.allocator,
                    .record = .fixed(&context.record_buffer),
                    .cleartext = .fixed(&context.cleartext_buffer),
                    .ciphertext = .fixed(&context.ciphertext_buffer),
                    .connection = .{
                        .handshake = .{
                            .GL = L.mainthread(),
                            .ca_keypair_ref = self.tls.server_ref.ca_keypair_ref.copy(L),
                            .server = self.tls.server_ref.server,
                        },
                    },
                };
                accepted_socket.tls_context = .{ .server = context };
                self.tls = accepted_socket.tls_context;

                self.accepted_ref = .init(L, -1, undefined);
                L.pop(1);

                const server_tls = self.tls.server;

                const tcp = xev.TCP.initFd(accepted_socket.socket);

                tcp.read(
                    l,
                    c,
                    .{ .slice = server_tls.record.buffer[server_tls.record.end..] },
                    AsyncAcceptContext,
                    self,
                    Handshake.onRecvComplete,
                );

                return .disarm;
            } else _ = Scheduler.resumeState(L, null, 1) catch {};
        }

        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        return .disarm;
    }

    pub fn resumeWithError(
        self: *AsyncAcceptContext,
        err: anyerror,
    ) xev.CallbackAction {
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);
        defer self.accepted_ref.deref(L);

        L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
        _ = Scheduler.resumeStateError(L, null) catch {};
        return .disarm;
    }

    const Handshake = struct {
        pub fn onRecvComplete(
            ud: ?*AsyncAcceptContext,
            l: *xev.Loop,
            c: *xev.Completion,
            tcp: xev.TCP,
            _: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = ud orelse unreachable;
            const L = self.ref.value;
            const ctx = self.tls.server;
            const handshake = &ctx.connection.handshake;
            const read = r catch |err| return self.resumeWithError(err);

            ctx.record.end += read;

            const result = handshake.server.run(ctx.record.buffered(), ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch |err| return self.resumeWithError(err);
            ctx.ciphertext.end += result.send.len;
            ctx.record.toss(result.recv_pos);
            ctx.record.rebase(ctx.record.buffer.len) catch unreachable; // shouldn't fail
            if (result.send.len > 0) {
                tcp.write(
                    l,
                    c,
                    .{ .slice = ctx.ciphertext.buffered() },
                    AsyncAcceptContext,
                    self,
                    onSendComplete,
                );
                return .disarm;
            } else {
                if (handshake.server.done()) {
                    const cipher = handshake.server.cipher().?;
                    handshake.deinit();
                    ctx.connection = .{ .active = .{ .tls = .init(cipher) } };

                    const scheduler = Scheduler.getScheduler(L);

                    defer scheduler.completeAsync(self);
                    defer self.ref.deref();
                    defer self.list.remove(&self.completion);

                    defer self.accepted_ref.deref(L);

                    if (L.status() != .Yield)
                        return .disarm;

                    if (self.accepted_ref.push(L))
                        _ = Scheduler.resumeState(L, null, 1) catch {}
                    else
                        _ = Scheduler.resumeState(L, null, 0) catch {};
                } else {
                    tcp.read(
                        l,
                        c,
                        .{ .slice = ctx.record.buffer[ctx.record.end..] },
                        AsyncAcceptContext,
                        self,
                        onRecvComplete,
                    );
                }
            }
            return .disarm;
        }

        pub fn onSendComplete(
            ud: ?*AsyncAcceptContext,
            l: *xev.Loop,
            c: *xev.Completion,
            tcp: xev.TCP,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const self = ud orelse unreachable;
            const ctx = self.tls.server;
            const written = r catch |err| return self.resumeWithError(err);

            ctx.ciphertext.toss(written);
            if (ctx.ciphertext.bufferedLen() > 0) {
                tcp.write(l, c, .{ .slice = ctx.ciphertext.buffered() }, AsyncAcceptContext, self, onSendComplete);
                return .disarm;
            }
            ctx.ciphertext.rebase(ctx.ciphertext.buffer.len) catch unreachable; // shouldn't fail
            tcp.read(
                l,
                c,
                .{ .slice = ctx.record.buffer[ctx.record.end..] },
                AsyncAcceptContext,
                self,
                onRecvComplete,
            );
            return .disarm;
        }
    };
};

const AsyncConnectContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .completion = .{},
    },
    ref: Scheduler.ThreadRef,
    list: *Scheduler.CompletionLinkedList,
    tls: TlsContext,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        l: *xev.Loop,
        c: *xev.Completion,
        tcp: xev.TCP,
        connect_res: xev.ConnectError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);

        jmp: {
            if (L.status() != .Yield)
                break :jmp;

            connect_res catch |err| {
                L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
                _ = Scheduler.resumeStateError(L, null) catch {};
                break :jmp;
            };

            if (self.tls == .client) {
                const ctx = self.tls.client;
                const res = ctx.connection.handshake.client.run(&[_]u8{}, ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch |err| {
                    L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
                    _ = Scheduler.resumeStateError(L, null) catch {};
                    break :jmp;
                };
                std.debug.assert(res.send.len > 0);
                ctx.ciphertext.end += res.send.len;
                tcp.write(
                    l,
                    c,
                    .{ .slice = ctx.ciphertext.buffered() },
                    AsyncConnectContext,
                    self,
                    Handshake.onSendComplete,
                );
                return .disarm;
            }

            _ = Scheduler.resumeState(L, null, 0) catch {};
        }

        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        return .disarm;
    }

    pub fn resumeWithError(
        self: *AsyncConnectContext,
        err: anyerror,
    ) xev.CallbackAction {
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        L.pushlstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e});
        _ = Scheduler.resumeStateError(L, null) catch {};
        return .disarm;
    }

    const Handshake = struct {
        pub fn onRecvComplete(
            ud: ?*AsyncConnectContext,
            l: *xev.Loop,
            c: *xev.Completion,
            tcp: xev.TCP,
            _: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = ud orelse unreachable;
            const ctx = self.tls.client;
            const handshake = &ctx.connection.handshake;

            const read = r catch |err| return self.resumeWithError(err);

            ctx.record.end += read;

            const result = handshake.client.run(ctx.record.buffered(), ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch |err| return self.resumeWithError(err);
            ctx.ciphertext.end += result.send.len;
            ctx.record.toss(result.recv_pos);
            ctx.record.rebase(ctx.record.buffer.len) catch unreachable; // shouldn't fail
            if (result.send.len > 0) {
                tcp.write(
                    l,
                    c,
                    .{ .slice = ctx.ciphertext.buffered() },
                    AsyncConnectContext,
                    self,
                    onSendComplete,
                );
                return .disarm;
            } else {
                tcp.read(
                    l,
                    c,
                    .{ .slice = ctx.record.buffer[ctx.record.end..] },
                    AsyncConnectContext,
                    self,
                    onRecvComplete,
                );
                return .disarm;
            }
        }

        pub fn onSendComplete(
            ud: ?*AsyncConnectContext,
            l: *xev.Loop,
            c: *xev.Completion,
            tcp: xev.TCP,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const self = ud orelse unreachable;
            const L = self.ref.value;
            const ctx = self.tls.client;
            const handshake = &ctx.connection.handshake;

            const written = r catch |err| return self.resumeWithError(err);

            ctx.ciphertext.toss(written);
            if (ctx.ciphertext.bufferedLen() > 0) {
                tcp.write(
                    l,
                    c,
                    .{ .slice = ctx.ciphertext.buffered() },
                    AsyncConnectContext,
                    self,
                    onSendComplete,
                );
                return .disarm;
            }
            ctx.ciphertext.rebase(ctx.ciphertext.buffer.len) catch unreachable; // shouldn't fail
            if (handshake.client.done()) {
                const cipher = handshake.client.cipher().?;
                handshake.deinit(ctx.allocator);
                ctx.connection = .{ .active = .{ .tls = .init(cipher) } };

                const scheduler = Scheduler.getScheduler(L);

                defer scheduler.completeAsync(self);
                defer self.ref.deref();
                defer self.list.remove(&self.completion);

                if (L.status() != .Yield)
                    return .disarm;

                _ = Scheduler.resumeState(L, null, 0) catch {};
            } else {
                tcp.read(
                    l,
                    c,
                    .{ .slice = ctx.record.buffer[ctx.record.end..] },
                    AsyncConnectContext,
                    self,
                    onRecvComplete,
                );
            }
            return .disarm;
        }
    };
};

fn lua_send(self: *Socket, L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const buf = try L.Zcheckvalue([]const u8, 2, null);
    const offset = L.Loptunsigned(3, 0);

    switch (self.tls_context) {
        .none => {},
        .server_ref => return L.Zerror("socket unable to send"),
        inline else => |i| if (i.connection == .handshake) return L.Zerror("Incomplete Handshake"),
    }

    if (offset >= buf.len)
        return L.Zerror("Offset is out of bounds");

    const input = try allocator.dupe(u8, buf[offset..]);
    errdefer allocator.free(input);

    const ptr = try scheduler.createAsyncCtx(AsyncSendContext);

    ptr.* = .{
        .buffer = input,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .tls = self.tls_context,
        .consumed = 0,
    };

    const socket = xev.TCP.initFd(self.socket);

    ptr.write(
        &scheduler.loop,
        &ptr.completion.completion,
        socket,
        AsyncSendContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_sendMsg(self: *Socket, L: *VM.lua.State) !i32 {
    if (self.tls_context != .none)
        return L.Zerror("Not supported with TLS");
    if (!L.isyieldable())
        return L.Zyielderror();
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const port = L.Lcheckunsigned(2);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const address_str = try L.Zcheckvalue([:0]const u8, 3, null);
    const data = try L.Zcheckvalue([]const u8, 4, null);
    const offset = L.Loptunsigned(5, 0);
    if (offset >= data.len)
        return L.Zerror("Offset is out of bounds");

    const buf = try allocator.dupe(u8, data[offset..]);
    errdefer allocator.free(buf);

    const address = if (address_str.len <= 15)
        try std.net.Address.parseIp4(address_str, @intCast(port))
    else
        try std.net.Address.parseIp6(address_str, @intCast(port));

    const ptr = try scheduler.createAsyncCtx(AsyncSendMsgContext);

    ptr.* = .{
        .buffer = buf,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .state = undefined,
    };

    const socket = xev.UDP.initFd(self.socket);

    socket.write(
        &scheduler.loop,
        &ptr.completion.completion,
        &ptr.state,
        address,
        .{ .slice = buf },
        AsyncSendMsgContext,
        ptr,
        AsyncSendMsgContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_recv(self: *Socket, L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, 8192);
    if (size > LuaHelper.MAX_LUAU_SIZE)
        return L.Zerror("SizeTooLarge");

    switch (self.tls_context) {
        .none => {},
        .server_ref => return L.Zerror("socket unable to receive"),
        inline else => |i| if (i.connection == .handshake) return L.Zerror("Incomplete Handshake"),
    }

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const ptr = try scheduler.createAsyncCtx(AsyncRecvContext);

    ptr.* = .{
        .buffer = buf,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .tls = self.tls_context,
    };

    const socket = xev.TCP.initFd(self.socket);

    ptr.read(
        &scheduler.loop,
        &ptr.completion.completion,
        socket,
        AsyncRecvContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_recvMsg(self: *Socket, L: *VM.lua.State) !i32 {
    if (self.tls_context != .none)
        return L.Zerror("Not supported with TLS");
    if (!L.isyieldable())
        return L.Zyielderror();
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, 8192);
    if (size > LuaHelper.MAX_LUAU_SIZE)
        return L.Zerror("SizeTooLarge");

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const ptr = try scheduler.createAsyncCtx(AsyncRecvMsgContext);

    ptr.* = .{
        .buffer = buf,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .state = undefined,
    };

    const socket = xev.UDP.initFd(self.socket);

    socket.read(
        &scheduler.loop,
        &ptr.completion.completion,
        &ptr.state,
        .{ .slice = buf },
        AsyncRecvMsgContext,
        ptr,
        AsyncRecvMsgContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_accept(self: *Socket, L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const scheduler = Scheduler.getScheduler(L);

    const ptr = try scheduler.createAsyncCtx(AsyncAcceptContext);

    ptr.* = .{
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .tls = self.tls_context,
    };

    const socket = xev.TCP.initFd(self.socket);

    socket.accept(
        &scheduler.loop,
        &ptr.completion.completion,
        AsyncAcceptContext,
        ptr,
        AsyncAcceptContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_connect(self: *Socket, L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const scheduler = Scheduler.getScheduler(L);

    switch (self.tls_context) {
        .none => {},
        .server => return L.Zerror("socket created with server"),
        .server_ref => return L.Zerror("socket unable to connect"),
        .client => |c| if (c.connecting) {
            return L.Zerror("already connecting");
        } else if (c.connection != .handshake) {
            return L.Zerror("already connected");
        },
    }

    const address_str = try L.Zcheckvalue([:0]const u8, 2, null);
    const port = L.Lcheckunsigned(3);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");

    const address = if (address_str.len <= 15)
        try std.net.Address.parseIp4(address_str, @intCast(port))
    else
        try std.net.Address.parseIp6(address_str, @intCast(port));

    const ptr = try scheduler.createAsyncCtx(AsyncConnectContext);

    const socket = xev.TCP.initFd(self.socket);

    ptr.* = .{
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .tls = self.tls_context,
    };

    socket.connect(
        &scheduler.loop,
        &ptr.completion.completion,
        address,
        AsyncConnectContext,
        ptr,
        AsyncConnectContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_listen(self: *Socket, L: *VM.lua.State) !i32 {
    const backlog = L.Loptunsigned(2, 128);
    if (backlog > std.math.maxInt(u31))
        return L.Zerror("BacklogTooLarge");
    try std.posix.listen(self.socket, @intCast(backlog));
    return 0;
}

fn lua_bindIp(self: *Socket, L: *VM.lua.State) !i32 {
    const address_ip = try L.Zcheckvalue([:0]const u8, 2, null);
    const port = L.Lcheckunsigned(3);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const address = if (address_ip.len <= 15)
        try std.net.Address.parseIp4(address_ip, @intCast(port))
    else
        try std.net.Address.parseIp6(address_ip, @intCast(port));
    _ = try std.posix.bind(self.socket, &address.any, address.getOsSockLen());
    return 0;
}

fn lua_getName(self: *Socket, L: *VM.lua.State) !i32 {
    var address: std.net.Address = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(self.socket, &address.any, &len);
    try L.createtable(0, 3);
    try L.Zsetfield(-1, "family", address.any.family);
    try L.Zsetfield(-1, "port", address.getPort());
    var buf: [LONGEST_ADDRESS]u8 = undefined;
    try L.pushlstring(AddressToString(&buf, address));
    try L.rawsetfield(-2, "address");
    return 1;
}

fn lua_setOption(self: *Socket, L: *VM.lua.State) !i32 {
    const level = try L.Zcheckvalue(i32, 2, null);
    const optname = try L.Zcheckvalue(u32, 3, null);
    const value = switch (L.typeOf(4)) {
        .Boolean => &std.mem.toBytes(@as(c_int, 1)),
        .Buffer, .String => try L.Zcheckvalue([]const u8, 4, null),
        else => return L.Zerror("Invalid value type"),
    };
    try std.posix.setsockopt(
        self.socket,
        level,
        optname,
        value,
    );
    return 0;
}

pub const AsyncCloseContext = struct {
    completion: xev.Completion = .{},
    ref: Scheduler.ThreadRef,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();

        if (L.status() != .Yield)
            return .disarm;

        _ = Scheduler.resumeState(L, null, 0) catch {};
        return .disarm;
    }
};

fn lua_close(self: *Socket, L: *VM.lua.State) !i32 {
    if (self.open != .closed) {
        self.open = .closed;
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);
        const socket = xev.TCP.initFd(self.socket);

        const ptr = try scheduler.createAsyncCtx(AsyncCloseContext);
        ptr.* = .{
            .ref = Scheduler.ThreadRef.init(L),
        };

        switch (comptime builtin.os.tag) {
            .windows => _ = std.os.windows.kernel32.CancelIoEx(self.socket, null),
            else => {
                var node = self.list.list.first;
                while (node) |n| {
                    scheduler.cancelAsyncTask(&Scheduler.CompletionLinkedList.Node.from(n).completion);
                    node = n.next;
                }
            },
        }

        socket.close(
            &scheduler.loop,
            &ptr.completion,
            AsyncCloseContext,
            ptr,
            AsyncCloseContext.complete,
        );

        self.tls_context.deinit();

        return L.yield(0);
    }
    return 0;
}

fn lua_isOpen(self: *Socket, L: *VM.lua.State) !i32 {
    L.pushboolean(self.open != .closed);
    return 1;
}

fn lua_kind(self: *Socket, L: *VM.lua.State) !i32 {
    try switch (self.tls_context) {
        .none => L.pushlstring("socket"),
        .client => L.pushlstring("tls_socket:client"),
        .server => L.pushlstring("tls_socket:server_client"),
        .server_ref => L.pushlstring("tls_socket:server"),
    };
    return 1;
}

fn before_method(self: *Socket, L: *VM.lua.State) !void {
    if (self.open == .closed)
        return L.Zerror("SocketClosed");
}

const __index = MethodMap.CreateStaticIndexMap(Socket, TAG_NET_SOCKET, .{
    .{ "send", MethodMap.WithFn(Socket, lua_send, before_method) },
    .{ "sendMsg", MethodMap.WithFn(Socket, lua_sendMsg, before_method) },
    .{ "recv", MethodMap.WithFn(Socket, lua_recv, before_method) },
    .{ "recvMsg", MethodMap.WithFn(Socket, lua_recvMsg, before_method) },
    .{ "accept", MethodMap.WithFn(Socket, lua_accept, before_method) },
    .{ "connect", MethodMap.WithFn(Socket, lua_connect, before_method) },
    .{ "listen", MethodMap.WithFn(Socket, lua_listen, before_method) },
    .{ "bindIp", MethodMap.WithFn(Socket, lua_bindIp, before_method) },
    .{ "getName", MethodMap.WithFn(Socket, lua_getName, before_method) },
    .{ "setOption", MethodMap.WithFn(Socket, lua_setOption, before_method) },
    .{ "kind", MethodMap.WithFn(Socket, lua_kind, before_method) },
    .{ "close", lua_close },
    .{ "isOpen", lua_isOpen },
});

pub fn __dtor(L: *VM.lua.State, self: *Socket) void {
    const allocator = luau.getallocator(L);
    if (self.open != .closed)
        closesocket(self.socket);
    self.tls_context.deinit();
    self.list.deinit(allocator);
}

pub inline fn load(L: *VM.lua.State) !void {
    _ = try L.Znewmetatable(@typeName(@This()), .{
        .__metatable = "Metatable is locked",
        .__type = "SocketHandle",
    });
    try __index(L, -1);
    L.setreadonly(-1, true);
    L.setuserdatametatable(TAG_NET_SOCKET);
    L.setuserdatadtor(Socket, TAG_NET_SOCKET, __dtor);
}

pub fn push(L: *VM.lua.State, value: std.posix.socket_t, open: OpenCase) !*Socket {
    const allocator = luau.getallocator(L);
    const self = try L.newuserdatataggedwithmetatable(Socket, TAG_NET_SOCKET);
    const list = try allocator.create(Scheduler.CompletionLinkedList);
    list.* = .init(allocator);
    self.* = .{
        .open = open,
        .socket = value,
        .list = list,
    };
    return self;
}
