const std = @import("std");
const xev = @import("xev").Dynamic;
const tls = @import("tls");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const MethodMap = Zune.Utils.MethodMap;
const LuaHelper = Zune.Utils.LuaHelper;
const Lists = Zune.Utils.Lists;

const Response = @import("../response.zig");
const WebSocket = @import("../websocket.zig");

const TAG_NET_HTTP_WEBSOCKET = Zune.tagged.Tags.get("NET_HTTP_CLIENTWEBSOCKET").?;

const VM = luau.VM;

const ZUNE_CLIENT_HEADER = "zune/" ++ Zune.info.version;

const Self = @This();

recv_completion: xev.Completion,
send_completion: xev.Completion,
close_completion: xev.Completion,
allocator: std.mem.Allocator,
read_buffer: [8192]u8 = undefined,
message_queue: Lists.DoublyLinkedList = .{},
reader: WebSocket.Reader(false, 1024, .{ .safe = LuaHelper.MAX_LUAU_SIZE }) = .{},
ref: LuaHelper.Ref(void),
lua_ref: Scheduler.ThreadRef,
callbacks: FnHandlers,
state: State,
timer: Timer,

pub const FnHandlers = struct {
    accept: LuaHelper.Ref(void) = .empty,
    message: LuaHelper.Ref(void) = .empty,
    close: LuaHelper.Ref(void) = .empty,
    @"error": LuaHelper.Ref(void) = .empty,

    pub fn derefAll(self: *@This(), L: *VM.lua.State) void {
        self.accept.deref(L);
        self.message.deref(L);
        self.close.deref(L);
        self.@"error".deref(L);
    }
};

pub const Timer = struct {
    started: bool = false,
    can_handle: bool = false,
    completion: xev.Completion,
    reset_completion: xev.Completion,
};

pub const State = struct {
    stage: enum(u3) { connecting, upgrading, active, closing, closed } = .connecting,
    key: [28]u8 = undefined,
    close_code: u16 = 1006,
    handshake_request: ?[]const u8 = null,
    handshake_parser: ?*Response.Parser = null,
    tls: ?*TlsContext = null,
    timeout: ?f64 = null,
    address_list: ?*std.net.AddressList,
    socket: std.posix.socket_t,
    address_index: usize = 0,
    sending: bool = false,
    closed: enum { none, received, emitted } = .none,
    @"error": ?anyerror = null,
    frame: WebSocketFrame,

    pub const WebSocketFrame = struct {
        info: u8 = 0,
        written: usize = 0,
        allocated: ?[]u8 = null,
        static: [10 + 1024]u8 = undefined,
    };
};

pub const Message = struct {
    node: Lists.DoublyLinkedList.Node = .{},
    opcode: WebSocket.Opcode = .Text,
    data: []u8,

    fn create(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!*Message {
        const struct_size = @sizeOf(Message);
        const total_size = struct_size + size;

        const raw_ptr = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Message)), total_size);
        const message_ptr: *Message = @ptrCast(raw_ptr);

        message_ptr.* = .{
            .node = .{},
            .data = raw_ptr[struct_size .. struct_size + size],
        };

        return message_ptr;
    }

    fn destroy(self: *Message, allocator: std.mem.Allocator) void {
        const raw_ptr: [*]u8 = @ptrCast(self);
        const total_size = @sizeOf(Message) + self.data.len;
        const slice = raw_ptr[0..total_size];
        allocator.rawFree(slice, .fromByteUnits(@alignOf(Message)), @returnAddress());
    }
};

const TlsContext = struct {
    record_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
    cleartext_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
    ciphertext_buffer: [tls.max_ciphertext_record_len]u8 = undefined,
    record: std.Io.Reader,
    cleartext: std.Io.Reader,
    ciphertext: std.Io.Reader,
    connection: union(enum) {
        handshake: struct {
            client: tls.nonblock.Client,
            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.client.opt.root_ca.deinit(allocator);
                allocator.free(self.client.opt.host);
            }
        },
        active: struct {
            client: tls.nonblock.Connection,
            write_buffer: []const u8 = undefined,
            consumed: usize = 0,
        },
    },

    pub const Handshake = struct {
        pub fn onRecvComplete(
            ud: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            tcp: xev.TCP,
            _: xev.ReadBuffer,
            r: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = ud orelse unreachable;
            const ctx = self.state.tls orelse unreachable;
            const handshake = &ctx.connection.handshake;
            const read = r catch |err| switch (err) {
                error.EOF, error.ConnectionResetByPeer => return self.safeResumeWithError(error.HandshakeConnectionClosed),
                error.Canceled => return self.safeResumeWithError(error.Timeout),
                else => return self.safeResumeWithError(err),
            };
            ctx.record.end += read;
            const result = handshake.client.run(ctx.record.buffered(), ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch |err| return self.safeResumeWithError(err);
            ctx.ciphertext.end += result.send.len;
            ctx.record.toss(result.recv_pos);
            ctx.record.rebase(ctx.record.buffer.len) catch unreachable; // shouldn't fail
            if (result.send.len > 0) {
                tcp.write(
                    l,
                    c,
                    .{ .slice = ctx.ciphertext.buffered() },
                    Self,
                    self,
                    Handshake.onSendComplete,
                );
                return .disarm;
            } else {
                tcp.read(
                    l,
                    c,
                    .{ .slice = ctx.record.buffer[ctx.record.end..] },
                    Self,
                    self,
                    Handshake.onRecvComplete,
                );
                return .disarm;
            }
        }

        pub fn onSendComplete(
            ud: ?*Self,
            l: *xev.Loop,
            c: *xev.Completion,
            tcp: xev.TCP,
            _: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            const self = ud orelse unreachable;
            const ctx = self.state.tls orelse unreachable;
            const handshake = &ctx.connection.handshake;
            const written = r catch |err| switch (err) {
                error.Canceled => return self.safeResumeWithError(error.Timeout),
                else => return self.safeResumeWithError(err),
            };
            ctx.ciphertext.toss(written);
            if (ctx.ciphertext.bufferedLen() > 0) {
                tcp.write(l, c, .{ .slice = ctx.ciphertext.buffered() }, Self, self, onSendComplete);
                return .disarm;
            }
            ctx.ciphertext.rebase(ctx.ciphertext.buffer.len) catch unreachable; // shouldn't fail
            if (handshake.client.done()) {
                const cipher = handshake.client.cipher().?;
                handshake.deinit(self.allocator);
                ctx.connection = .{ .active = .{ .client = .init(cipher) } };
                UpgradeHandshake.start(self, l, tcp);
            } else {
                tcp.read(
                    l,
                    c,
                    .{ .slice = ctx.record.buffer[ctx.record.end..] },
                    Self,
                    self,
                    Handshake.onRecvComplete,
                );
            }
            return .disarm;
        }
    };

    pub fn endingStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = r;
        _ = w;
        _ = limit;
        return error.EndOfStream;
    }
};

fn stream_write(
    self: *Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
    tcp: xev.TCP,
    buf: []const u8,
    comptime callback: *const fn (
        ?*Self,
        *xev.Loop,
        *xev.Completion,
        xev.TCP,
        xev.WriteBuffer,
        xev.WriteError!usize,
    ) xev.CallbackAction,
) void {
    if (self.state.tls) |ctx| {
        const res = ctx.connection.active.client.encrypt(buf, ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch |err| {
            if (self.lua_ref.value == self.lua_ref.value.mainthread())
                self.emitError(.tls, err);
            _ = @call(.always_inline, callback, .{
                self,
                loop,
                completion,
                tcp,
                xev.WriteBuffer{ .slice = buf },
                error.Unexpected,
            });
            return;
        };
        ctx.connection.active.consumed = res.cleartext_pos;
        ctx.connection.active.write_buffer = buf;
        ctx.ciphertext.end += res.ciphertext.len;
        tcp.write(
            loop,
            completion,
            .{ .slice = ctx.ciphertext.buffered() },
            Self,
            self,
            struct {
                fn inner(
                    ud: ?*Self,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    inner_tcp: xev.TCP,
                    _: xev.WriteBuffer,
                    w: xev.WriteError!usize,
                ) xev.CallbackAction {
                    const inner_self = ud orelse unreachable;
                    const inner_ctx = inner_self.state.tls orelse unreachable;
                    const ciphertext_written = w catch |err| return @call(.always_inline, callback, .{
                        ud,
                        l,
                        c,
                        inner_tcp,
                        xev.WriteBuffer{ .slice = inner_ctx.connection.active.write_buffer },
                        err,
                    });
                    inner_ctx.ciphertext.toss(ciphertext_written);
                    inner_ctx.ciphertext.rebase(inner_ctx.ciphertext.buffer.len) catch unreachable; // shouldn't fail
                    if (inner_ctx.ciphertext.end > 0) {
                        inner_tcp.write(
                            l,
                            c,
                            .{ .slice = inner_ctx.ciphertext.buffered() },
                            Self,
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
                        xev.WriteBuffer{ .slice = inner_ctx.connection.active.write_buffer },
                        inner_ctx.connection.active.consumed,
                    });
                }
            }.inner,
        );
    } else {
        tcp.write(
            loop,
            completion,
            .{ .slice = buf },
            Self,
            self,
            callback,
        );
    }
}

fn stream_read(
    self: *Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
    tcp: xev.TCP,
    comptime callback: *const fn (
        ?*Self,
        *xev.Loop,
        *xev.Completion,
        xev.TCP,
        xev.ReadBuffer,
        xev.ReadError!usize,
    ) xev.CallbackAction,
) void {
    if (self.state.tls) |ctx| {
        if (ctx.cleartext.bufferedLen() > 0) {
            const amount = ctx.cleartext.readSliceShort(&self.read_buffer) catch unreachable; // shouldn't fail, entirely buffered
            ctx.cleartext.rebase(ctx.cleartext.buffer.len) catch unreachable; // shouldn't fail
            switch (@call(.always_inline, callback, .{
                self,
                loop,
                completion,
                tcp,
                xev.ReadBuffer{ .slice = &self.read_buffer },
                amount,
            })) {
                .disarm => {},
                .rearm => self.stream_read(
                    loop,
                    completion,
                    tcp,
                    callback,
                ),
            }
            return;
        }

        tcp.read(
            loop,
            completion,
            .{ .slice = ctx.record.buffer[ctx.record.end..] },
            Self,
            self,
            struct {
                fn inner(
                    ud: ?*Self,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    inner_tcp: xev.TCP,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const inner_self = ud orelse unreachable;
                    const inner_ctx = inner_self.state.tls orelse unreachable;
                    inner_ctx.record.end += r catch |err| return @call(.always_inline, callback, .{
                        ud,
                        l,
                        c,
                        inner_tcp,
                        xev.ReadBuffer{ .slice = &inner_self.read_buffer },
                        err,
                    });
                    const res = inner_ctx.connection.active.client.decrypt(inner_ctx.record.buffered(), inner_ctx.cleartext.buffer[inner_ctx.cleartext.end..]) catch |err| {
                        if (inner_self.lua_ref.value == inner_self.lua_ref.value.mainthread())
                            inner_self.emitError(.tls, err);
                        _ = @call(.always_inline, callback, .{
                            ud,
                            l,
                            c,
                            inner_tcp,
                            xev.ReadBuffer{ .slice = &inner_self.read_buffer },
                            error.Unexpected,
                        });
                        return .disarm;
                    };
                    inner_ctx.record.toss(res.ciphertext_pos);
                    inner_ctx.record.rebase(inner_ctx.record.buffer.len) catch unreachable; // shouldn't fail
                    inner_ctx.cleartext.end += res.cleartext.len;
                    if (res.cleartext.len > 0) {
                        const amount = inner_ctx.cleartext.readSliceShort(&inner_self.read_buffer) catch unreachable; // shouldn't fail;
                        inner_ctx.cleartext.rebase(inner_ctx.cleartext.buffer.len) catch unreachable; // shouldn't fail
                        switch (@call(.always_inline, callback, .{
                            ud,
                            l,
                            c,
                            inner_tcp,
                            xev.ReadBuffer{ .slice = &inner_self.read_buffer },
                            amount,
                        })) {
                            .disarm => {},
                            .rearm => inner_self.stream_read(
                                l,
                                c,
                                inner_tcp,
                                callback,
                            ),
                        }
                        return .disarm;
                    }
                    inner_tcp.read(
                        l,
                        c,
                        .{ .slice = inner_ctx.record.buffer[inner_ctx.record.end..] },
                        Self,
                        inner_self,
                        @This().inner,
                    );
                    return .disarm;
                }
            }.inner,
        );
    } else {
        tcp.read(
            loop,
            completion,
            .{ .slice = &self.read_buffer },
            Self,
            self,
            callback,
        );
    }
}

pub fn onClose(
    ud: ?*Self,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    const GL = self.lua_ref.value;
    defer self.ref.deref(GL);

    self.state.stage = .closed;

    if (self.callbacks.close.hasRef()) {
        const L = GL.newthread() catch |e| std.debug.panic("{}", .{e});
        defer GL.pop(1);
        _ = self.callbacks.close.push(L);
        _ = self.ref.push(L);
        L.pushunsigned(self.state.close_code);
        _ = Scheduler.resumeState(L, null, 2) catch {};
    }

    return .disarm;
}

pub fn kill(self: *Self, loop: *xev.Loop, tcp: xev.TCP) void {
    tcp.close(
        loop,
        &self.close_completion,
        Self,
        self,
        onClose,
    );
}

// Handles stopping the websocket writer (if active)
// canceling the writer would eventually call `close`.
fn close(self: *Self, loop: *xev.Loop, tcp: xev.TCP) void {
    if (self.state.stage == .closed)
        return;

    self.state.stage = .closing;
    if (!self.state.sending) {
        if (!self.timer.started) {
            self.kill(loop, tcp);
        } else {
            var timer = xev.Timer.init() catch unreachable;
            timer.reset(
                loop,
                &self.timer.completion,
                &self.timer.reset_completion,
                0,
                Self,
                self,
                onTimerComplete,
            );
        }
    } else {}
}

fn onRecv(
    ud: ?*Self,
    loop: *xev.Loop,
    _: *xev.Completion,
    tcp: xev.TCP,
    _: xev.ReadBuffer,
    res: xev.ReadError!usize,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    const read = res catch |err| switch (err) {
        error.Canceled => {
            self.close(loop, tcp);
            return .disarm;
        },
        error.EOF, error.ConnectionResetByPeer => {
            self.close(loop, tcp);
            return .disarm;
        },
        else => {
            self.emitError(.raw_receive, err);
            self.close(loop, tcp);
            return .disarm;
        },
    };

    const allocator = self.allocator;

    const reader = &self.reader;

    var pos: usize = 0;
    while (true) {
        const buf = self.read_buffer[pos..read];
        if (buf.len == 0)
            return .rearm;
        var consumed: usize = 0;
        defer pos += consumed;
        if (reader.next(allocator, buf, &consumed) catch |rerr| switch (rerr) {
            error.MaskedMessage => {
                defer self.state.closed = .emitted;
                self.sendCloseFrame(loop, 1002);
                continue;
            },
            error.MessageTooLarge => {
                self.emitError(.receiver, error.MessageTooLarge);
                continue;
            },
            else => {
                self.emitError(.receiver, rerr);
                self.close(loop, tcp);
                return .disarm;
            },
        }) {
            defer reader.reset(allocator);
            const data = reader.getData();

            switch (self.reader.header.opcode) {
                .Binary, .Text => {},
                .Ping => {
                    self.sendPongFrame(loop);
                    continue;
                },
                .Pong => continue,
                .Close => {
                    if (self.state.closed == .none) {
                        defer self.state.closed = .received;
                        const code = if (data.len >= 2) std.mem.readVarInt(u16, data[0..2], .big) else 1000;
                        // we received a close frame, we should send a close frame back.
                        // its possible we might have messages in queue
                        self.sendCloseFrame(loop, code);
                        return .rearm;
                    }
                    self.close(loop, tcp);
                    return .disarm;
                },
                .Continue => continue,
                else => {
                    self.emitError(.receiver, error.InvalidOpcode);
                    self.close(loop, tcp);
                    return .disarm;
                },
            }

            if (self.callbacks.message.hasRef()) {
                const GL = self.lua_ref.value;
                const L = GL.newthread() catch |e| std.debug.panic("{}", .{e});
                defer GL.pop(1);

                _ = self.callbacks.message.push(L);
                _ = self.ref.push(L);
                switch (reader.header.opcode) {
                    .Binary => L.Zpushbuffer(data) catch |e| std.debug.panic("{}", .{e}),
                    .Text => L.pushlstring(data) catch |e| std.debug.panic("{}", .{e}),
                    else => unreachable,
                }
                _ = Scheduler.resumeState(L, null, 2) catch {};
            }
        } else return .rearm;
    }
}

pub fn onWrite(
    ud: ?*Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
    tcp: xev.TCP,
    b: xev.WriteBuffer,
    res: xev.WriteError!usize,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    const written = res catch {
        self.state.sending = false;

        var timer = xev.Timer.init() catch unreachable;

        self.timer.started = true;
        self.timer.can_handle = true;
        timer.reset(
            loop,
            &self.timer.completion,
            &self.timer.reset_completion,
            0,
            Self,
            self,
            onTimerComplete,
        );
        return .disarm;
    };

    const remaining = b.slice[written..];
    if (remaining.len == 0) {
        self.state.sending = false;

        const node = self.message_queue.popFirst() orelse unreachable;
        const message: *Message = @fieldParentPtr("node", node);
        defer message.destroy(self.allocator);

        if (message.opcode == .Close) {
            std.debug.assert(self.message_queue.len == 0);

            var timer = xev.Timer.init() catch unreachable;

            self.timer.started = true;
            self.timer.can_handle = true;
            timer.reset(
                loop,
                &self.timer.completion,
                &self.timer.reset_completion,
                if (self.state.closed == .emitted) 3 * std.time.ms_per_s else 0,
                Self,
                self,
                onTimerComplete,
            );

            return .disarm;
        }

        self.flushMessages(loop);
    } else {
        self.stream_write(
            loop,
            completion,
            tcp,
            remaining,
            onWrite,
        );
    }
    return .disarm;
}

fn startWebSocket(self: *Self, loop: *xev.Loop, tcp: xev.TCP) void {
    self.state.stage = .active;

    self.stream_read(
        loop,
        &self.recv_completion,
        tcp,
        onRecv,
    );

    if (self.timer.started) {
        self.timer.can_handle = false;
        loop.cancel(
            &self.timer.completion,
            &self.timer.reset_completion,
            void,
            null,
            null,
        );
    }

    const L = self.lua_ref.value;
    const GL = L.mainthread();
    self.lua_ref.deref();
    self.lua_ref.value = GL;

    if (L.status() != .Yield)
        return;
    _ = self.ref.push(L);
    _ = Scheduler.resumeState(L, null, 1) catch {};
}

pub const UpgradeHandshake = struct {
    fn onRecvComplete(
        ud: ?*Self,
        loop: *xev.Loop,
        c: *xev.Completion,
        tcp: xev.TCP,
        b: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const read = r catch |err| switch (err) {
            error.EOF, error.ConnectionResetByPeer => return self.safeResumeWithError(error.ConnectionClosed),
            error.Canceled => return self.safeResumeWithError(error.Timeout),
            else => return self.safeResumeWithError(err),
        };

        const read_slice = b.slice[0..read];

        const parser = self.state.handshake_parser.?;
        if (parser.parse(read_slice) catch |err| return self.safeResumeWithError(err)) {
            defer self.allocator.destroy(parser);
            defer parser.deinit();
            self.state.handshake_parser = null;

            var approved = true;
            if (self.callbacks.accept.hasRef()) {
                const GL = self.lua_ref.value.mainthread();
                const L = GL.newthread() catch |e| std.debug.panic("{}", .{e});
                defer GL.pop(1);
                _ = self.callbacks.accept.push(L);
                L.pushvalue(-1);
                _ = self.ref.push(L);
                parser.push(L, false) catch |e| std.debug.panic("{}", .{e});
                _ = L.pcall(2, 1, 0).check() catch {
                    Zune.Runtime.Engine.logFnDef(L, 1);
                    return .disarm;
                };
                approved = L.toboolean(-1);
            }

            if (approved) blk: {
                if (parser.headers.get("sec-websocket-accept")) |accept_key| {
                    if (!std.mem.eql(u8, accept_key, &self.state.key))
                        break :blk;
                } else break :blk;
                if (parser.status_code != 101)
                    break :blk;
                @memset(&self.state.key, 0);
                if (self.state.stage == .upgrading)
                    self.startWebSocket(loop, tcp)
                else
                    return self.safeResumeWithError(error.Timeout);
                return .disarm;
            } else return self.safeResumeWithError(error.UpgradeRejected);
            return self.safeResumeWithError(error.UpgradeFailed);
        } else {
            self.stream_read(
                loop,
                c,
                tcp,
                UpgradeHandshake.onRecvComplete,
            );
            return .disarm;
        }
        return .disarm;
    }

    fn onSendComplete(
        ud: ?*Self,
        loop: *xev.Loop,
        c: *xev.Completion,
        tcp: xev.TCP,
        b: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const written = w catch |err| switch (err) {
            error.Canceled => return self.safeResumeWithError(error.Timeout),
            else => return self.safeResumeWithError(err),
        };

        const remaining = b.slice[written..];
        if (remaining.len > 0) {
            self.stream_write(
                loop,
                c,
                tcp,
                remaining,
                onSendComplete,
            );
        } else {
            self.allocator.free(self.state.handshake_request.?);
            self.state.handshake_request = null;
            self.stream_read(
                loop,
                c,
                tcp,
                UpgradeHandshake.onRecvComplete,
            );
        }

        return .disarm;
    }

    fn start(self: *Self, loop: *xev.Loop, tcp: xev.TCP) void {
        self.state.stage = .upgrading;

        self.stream_write(
            loop,
            &self.send_completion,
            tcp,
            self.state.handshake_request.?,
            UpgradeHandshake.onSendComplete,
        );
    }
};

fn resumeError(self: *Self, err: anyerror) void {
    const L = self.lua_ref.value;
    defer self.ref.deref(L);
    defer self.lua_ref.deref();

    std.posix.close(self.state.socket);

    if (L.status() != .Yield)
        return;
    L.pushfstring("{s}", .{@errorName(err)}) catch |e| std.debug.panic("{}", .{e});
    _ = Scheduler.resumeStateError(L, null) catch {};
}

fn safeResumeWithError(
    self: *Self,
    err: anyerror,
) xev.CallbackAction {
    const scheduler = Scheduler.getScheduler(self.lua_ref.value);
    if (self.timer.started) {
        self.state.@"error" = err;
        self.state.stage = .closed;
        var timer = xev.Timer.init() catch unreachable;
        timer.reset(
            &scheduler.loop,
            &self.timer.completion,
            &self.timer.reset_completion,
            0,
            Self,
            self,
            onTimerComplete,
        );
    } else self.resumeError(err);
    return .disarm;
}

fn emitError(
    self: *Self,
    comptime scope: @Type(.enum_literal),
    err: anyerror,
) void {
    if (!self.callbacks.@"error".hasRef())
        return;
    const GL = self.lua_ref.value;
    const L = GL.newthread() catch |e| std.debug.panic("{}", .{e});
    defer GL.pop(1);
    _ = self.ref.push(L);
    _ = self.callbacks.@"error".push(L);
    L.pushfstring("{s}", .{@tagName(scope)}) catch |e| std.debug.panic("{}", .{e});
    L.pushfstring("{s}", .{@errorName(err)}) catch |e| std.debug.panic("{}", .{e});
    _ = Scheduler.resumeState(L, null, 3) catch {};
}

fn onTimerComplete(
    ud: ?*Self,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    if (self.state.stage == .closed and self.state.@"error" != null) {
        self.resumeError(self.state.@"error".?);
        return .disarm;
    }

    self.timer.started = false;
    r catch |err| switch (err) {
        else => return .disarm,
    };

    if (!self.timer.can_handle)
        return .disarm;

    switch (self.state.stage) {
        .connecting, .upgrading => {
            l.cancel(
                &self.send_completion,
                &self.close_completion,
                void,
                null,
                null,
            );
            self.state.stage = .closing;
        },
        .active => {
            l.cancel(
                &self.recv_completion,
                &self.send_completion,
                void,
                null,
                null,
            );
        },
        .closed => unreachable, // should never happen
        .closing => self.kill(l, xev.TCP.initFd(self.state.socket)),
    }

    return .disarm;
}

fn onConnectComplete(
    ud: ?*Self,
    l: *xev.Loop,
    c: *xev.Completion,
    tcp: xev.TCP,
    r: xev.ConnectError!void,
) xev.CallbackAction {
    const self = ud orelse unreachable;
    r catch |err| switch (err) {
        error.Canceled => return self.safeResumeWithError(error.Timeout),
        else => {
            self.state.address_index += 1;
            if (self.state.address_list.?.addrs.len == self.state.address_index)
                return self.safeResumeWithError(error.ConnectionRefused);
            const addr = self.state.address_list.?.addrs[self.state.address_index];
            const socket = self.state.socket;
            self.connectAddress(addr) catch |cerr| return self.safeResumeWithError(cerr);
            std.posix.close(socket);
            return .disarm;
        },
    };
    self.state.address_list.?.deinit();
    self.state.address_list = null;
    if (self.state.stage == .closing)
        return self.safeResumeWithError(error.Timeout);
    if (self.state.tls) |ctx| {
        // start handshake
        const res = ctx.connection.handshake.client.run(&[_]u8{}, ctx.ciphertext.buffer[0..]) catch |err| return self.safeResumeWithError(err);
        std.debug.assert(res.send.len > 0); // client should always send first.
        ctx.ciphertext.end += res.send.len;
        tcp.write(
            l,
            c,
            .{ .slice = ctx.ciphertext.buffered() },
            Self,
            self,
            TlsContext.Handshake.onSendComplete,
        );
    } else UpgradeHandshake.start(self, l, tcp);

    return .disarm;
}

fn connectAddress(self: *Self, addr: std.net.Address) !void {
    const scheduler = Scheduler.getScheduler(self.lua_ref.value);
    const socket = try @import("../../lib.zig").createSocket(
        addr.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );

    self.state.socket = socket;
    const tcp = xev.TCP.initFd(socket);

    tcp.connect(
        &scheduler.loop,
        &self.send_completion,
        addr,
        Self,
        self,
        onConnectComplete,
    );
}

pub fn flushMessages(self: *Self, loop: *xev.Loop) void {
    if (self.state.sending)
        return;
    if (self.message_queue.len == 0)
        return;
    self.state.sending = true;
    const node = self.message_queue.first orelse unreachable;
    const message: *Message = @fieldParentPtr("node", node);
    const tcp = xev.TCP.initFd(self.state.socket);
    self.stream_write(
        loop,
        &self.send_completion,
        tcp,
        message.data,
        onWrite,
    );
}

pub fn sendFrame(self: *Self, loop: *xev.Loop, dataframe: WebSocket.DataFrame) void {
    if (self.state.closed != .none)
        return;
    const web_message = Message.create(self.allocator, WebSocket.calcWriteSize(dataframe.data.len, true)) catch |err| @panic(@errorName(err));
    errdefer web_message.destroy(self.allocator);

    web_message.opcode = dataframe.header.opcode;
    WebSocket.writeDataFrame(web_message.data, dataframe);

    self.message_queue.append(&web_message.node);

    self.flushMessages(loop);
}

pub fn sendPongFrame(self: *Self, loop: *xev.Loop) void {
    self.sendFrame(loop, .{
        .header = .{
            .final = true,
            .opcode = .Pong,
            .mask = true,
            .len = WebSocket.Header.packLength(0),
        },
        .data = &.{},
    });
}

pub fn sendCloseFrame(self: *Self, loop: *xev.Loop, code: u16) void {
    self.state.close_code = code;

    const c = @byteSwap(code);
    const data = @as([2]u8, @bitCast(c));

    self.sendFrame(loop, .{
        .header = .{
            .final = true,
            .opcode = .Close,
            .mask = true,
            .len = WebSocket.Header.packLength(2),
        },
        .data = &data,
    });
}

fn lua_send(self: *Self, L: *VM.lua.State) !i32 {
    if (self.state.closed != .none)
        return error.Closed;
    const scheduler = Scheduler.getScheduler(L);

    const message = try L.Zcheckvalue([]const u8, 2, null);

    self.sendFrame(&scheduler.loop, .{
        .header = .{
            .final = true,
            .opcode = switch (L.typeOf(2)) {
                .Buffer => .Binary,
                .String => .Text,
                else => unreachable,
            },
            .mask = true,
            .len = WebSocket.Header.packLength(message.len),
        },
        .data = message,
    });

    return 0;
}

fn lua_close(self: *Self, L: *VM.lua.State) !i32 {
    switch (self.state.stage) {
        .closed, .closing => return 0,
        else => {},
    }
    defer self.state.closed = .emitted;

    const code = try L.Zcheckvalue(?u16, 2, null) orelse 1000;

    switch (code) {
        1005, 1006, 1015 => return L.Zerror("invalid close code, cannot be used"),
        else => {},
    }

    const scheduler = Scheduler.getScheduler(L);

    self.sendCloseFrame(&scheduler.loop, code);

    return 0;
}

fn lua_isConnected(self: *Self, L: *VM.lua.State) !i32 {
    L.pushboolean(self.state.stage == .active or self.state.stage == .closing);
    return 1;
}

const __index = MethodMap.CreateStaticIndexMap(Self, TAG_NET_HTTP_WEBSOCKET, .{
    .{ "send", lua_send },
    .{ "close", lua_close },
    .{ "isConnected", lua_isConnected },
});

pub fn __dtor(L: *VM.lua.State, self: *Self) void {
    const allocator = self.allocator;
    if (self.state.tls) |ctx| {
        switch (ctx.connection) {
            .handshake => |*c| c.deinit(allocator),
            .active => {},
        }
        allocator.destroy(ctx);
    }
    if (self.state.address_list) |addr|
        addr.deinit();
    if (self.state.handshake_request) |req|
        allocator.free(req);
    if (self.state.handshake_parser) |parser| {
        parser.deinit();
        allocator.destroy(parser);
    }
    self.reader.deinit(allocator);
    self.callbacks.derefAll(L);
    var it: ?*Lists.DoublyLinkedList.Node = self.message_queue.first;
    while (it) |node| {
        const message: *Message = @fieldParentPtr("node", node);
        defer message.destroy(self.allocator);
        it = node.next;
    }
}

// based on std.http.Client.validateUri
pub fn validateUri(uri: std.Uri, arena: std.mem.Allocator) !struct { std.http.Client.Protocol, std.Uri } {
    const protocol_map = std.StaticStringMap(std.http.Client.Protocol).initComptime(.{
        .{ "ws", .plain },
        .{ "wss", .tls },
    });
    const protocol = protocol_map.get(uri.scheme) orelse return error.UnsupportedUriScheme;
    var valid_uri = uri;
    valid_uri.host = .{
        .raw = try (uri.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena),
    };
    return .{ protocol, valid_uri };
}

pub fn generateKey(encoded: []u8) void {
    var key: [16]u8 = undefined;
    std.crypto.random.bytes(&key);
    _ = std.base64.standard.Encoder.encode(encoded, &key);
}

pub fn lua_websocket(L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const uriString = try L.Zcheckvalue([:0]const u8, 1, null);

    var timeout: ?u32 = 30;

    try L.Zchecktype(2, .Table);

    var callbacks: FnHandlers = .{};
    errdefer callbacks.derefAll(L);

    const closeType = L.rawgetfield(2, "close");
    if (!closeType.isnoneornil()) {
        if (closeType != .Function)
            return L.Zerror("close must be a function");
        callbacks.close = .init(L, -1, undefined);
    }
    L.pop(1);

    const messageType = L.rawgetfield(2, "message");
    if (!messageType.isnoneornil()) {
        if (messageType != .Function)
            return L.Zerror("message must be a function");
        callbacks.message = .init(L, -1, undefined);
    }
    L.pop(1);

    const errorType = L.rawgetfield(2, "error");
    if (!errorType.isnoneornil()) {
        if (errorType != .Function)
            return L.Zerror("error must be a function");
        callbacks.@"error" = .init(L, -1, undefined);
    }
    L.pop(1);

    const acceptType = L.rawgetfield(2, "accept");
    if (!acceptType.isnoneornil()) {
        if (acceptType != .Function)
            return L.Zerror("accept must be a function");
        callbacks.accept = .init(L, -1, undefined);
    }
    L.pop(1);

    const timeoutType = L.rawgetfield(2, "timeout");
    if (!timeoutType.isnoneornil()) {
        if (timeoutType != .Number)
            return L.Zerror("timeout must be a number");
        const value = try L.Zcheckvalue(i32, -1, null);
        if (value == 0)
            return L.Zerror("timeout cannot be 0");
        if (value < 0)
            timeout = null // indefinite
        else
            timeout = @intCast(value);
    }
    L.pop(1);

    var headers: std.ArrayListUnmanaged(u8) = .empty;
    defer headers.deinit(allocator);
    var protocols: std.ArrayListUnmanaged(u8) = .empty;
    defer protocols.deinit(allocator);

    var host_handled = false;
    var user_agent_handled = false;

    if (LuaHelper.maybeKnownType(L.rawgetfield(2, "headers"))) |@"type"| {
        if (@"type" != .Table)
            return L.Zerror("headers must be a table");
        var iter: LuaHelper.TableIterator = .{ .L = L, .idx = -1 };
        while (iter.next()) |t| switch (t) {
            .String => {
                if (L.typeOf(-1) != .String)
                    return L.Zerrorf("header value must be a string (got {s})", .{VM.lapi.typename(L.typeOf(-1))});
                try headers.appendSlice(allocator, "\r\n");
                const key = L.tostring(-2).?;
                if (std.ascii.eqlIgnoreCase(key, "host")) {
                    host_handled = true;
                } else if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
                    user_agent_handled = true;
                } else if (std.ascii.eqlIgnoreCase(key, "sec-websocket-protocol")) {
                    return L.Zerror("sec-websocket-protocol must be set in protocols, not headers");
                } else if (std.ascii.eqlIgnoreCase(key, "sec-websocket-version")) {
                    return L.Zerror("sec-websocket-version cannot be set");
                } else if (std.ascii.eqlIgnoreCase(key, "sec-websocket-key")) {
                    return L.Zerror("sec-websocket-key cannot be set");
                } else if (std.ascii.eqlIgnoreCase(key, "upgrade")) {
                    return L.Zerror("upgrade cannot be set");
                } else if (std.ascii.eqlIgnoreCase(key, "connection")) {
                    return L.Zerror("connection cannot be set");
                } else if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    return L.Zerror("content-length cannot be set");
                }
                const value = L.tostring(-1).?;
                if (value.len == 0)
                    continue;
                try headers.appendSlice(allocator, key);
                try headers.appendSlice(allocator, ": ");
                try headers.appendSlice(allocator, L.tostring(-1).?);
            },
            else => return L.Zerrorf("header index is not a string (got {s})", .{VM.lapi.typename(t)}),
        };
    }

    if (LuaHelper.maybeKnownType(L.rawgetfield(2, "protocols"))) |@"type"| {
        if (@"type" != .Table)
            return L.Zerror("protocols must be a table");
        var iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = -1 };
        while (try iter.next()) |t| switch (t) {
            .String => {
                if (protocols.items.len > 0)
                    try protocols.appendSlice(allocator, ", ");
                try protocols.appendSlice(allocator, L.tostring(-1).?);
            },
            else => return L.Zerrorf("protocol value is not a string (got {s})", .{VM.lapi.typename(t)}),
        };
    }
    L.pop(1);

    var uri_buffer: [1024 * 2]u8 = undefined;
    var fixedBuffer = std.heap.FixedBufferAllocator.init(&uri_buffer);

    const protocol, const valid_uri = try validateUri(try std.Uri.parse(uriString), fixedBuffer.allocator());

    const host = valid_uri.host.?.raw;

    var encoded_key: [24]u8 = undefined;
    {
        var key: [16]u8 = undefined;
        std.crypto.random.bytes(&key);
        const out = std.base64.standard.Encoder.encode(&encoded_key, &key);
        std.debug.assert(out.len == encoded_key.len);
    }

    var accept_key: [28]u8 = undefined;

    WebSocket.acceptHashKey(&accept_key, &encoded_key);

    const request = try std.mem.concat(allocator, u8, &.{
        "GET ",
        if (valid_uri.path.percent_encoded.len > 0) valid_uri.path.percent_encoded else "/",
        if (valid_uri.query != null) "?" else "",
        if (valid_uri.query) |query| query.percent_encoded else "",
        " HTTP/1.1",
        if (!host_handled) "\r\nHost: " else "",
        if (!host_handled) host else "",
        if (headers.items.len > 0) headers.items else "",
        "\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
        &encoded_key,
        if (protocols.items.len > 0) "\r\nSec-WebSocket-Protocol: " else "",
        if (protocols.items.len > 0) protocols.items else "",
        if (!user_agent_handled) "\r\nUser-Agent: " else "",
        if (!user_agent_handled) ZUNE_CLIENT_HEADER else "",
        "\r\n\r\n",
    });
    errdefer allocator.free(request);

    const list = try std.net.getAddressList(allocator, host, valid_uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    });
    errdefer list.deinit();

    if (list.addrs.len == 0)
        return error.UnknownHostName;

    const parser = try allocator.create(Response.Parser);
    errdefer allocator.destroy(parser);
    parser.* = .init(allocator, 100);

    var tls_ctx: ?*TlsContext = null;
    errdefer if (tls_ctx) |ctx| allocator.destroy(ctx);
    if (protocol == .tls) {
        tls_ctx = try allocator.create(TlsContext);
        const host_copy = try allocator.dupe(u8, host);
        errdefer allocator.free(host_copy);
        const ca_bundle = try tls.config.cert.fromSystem(allocator);
        tls_ctx.?.* = .{
            .record = .{
                .buffer = &tls_ctx.?.record_buffer,
                .end = 0,
                .seek = 0,
                .vtable = &.{
                    .stream = TlsContext.endingStream,
                },
            },
            .cleartext = .{
                .buffer = &tls_ctx.?.cleartext_buffer,
                .end = 0,
                .seek = 0,
                .vtable = &.{
                    .stream = TlsContext.endingStream,
                },
            },
            .ciphertext = .{
                .buffer = &tls_ctx.?.ciphertext_buffer,
                .end = 0,
                .seek = 0,
                .vtable = &.{
                    .stream = TlsContext.endingStream,
                },
            },
            .connection = .{
                .handshake = .{
                    .client = .init(.{
                        .host = host_copy,
                        .root_ca = ca_bundle,
                        .cipher_suites = tls.config.cipher_suites.secure,
                        .key_log_callback = tls.config.key_log.callback,
                    }),
                },
            },
        };
    }

    const self = try L.newuserdatataggedwithmetatable(Self, TAG_NET_HTTP_WEBSOCKET);

    self.* = .{
        .allocator = allocator,
        .lua_ref = .init(L),
        .recv_completion = .init(),
        .send_completion = .init(),
        .close_completion = .init(),
        .callbacks = callbacks,
        .ref = .init(L, -1, undefined),
        .state = .{
            .socket = undefined,
            .address_index = 0,
            .address_list = list,
            .stage = .connecting,
            .tls = tls_ctx,
            .key = accept_key,
            .handshake_request = request,
            .handshake_parser = parser,
            .frame = .{},
        },
        .timer = .{
            .completion = .init(),
            .reset_completion = .init(),
        },
    };
    errdefer {
        self.ref.deref(L);
        self.lua_ref.deref();
    }

    try self.connectAddress(list.addrs[0]);

    if (timeout) |t| {
        self.timer.started = true;
        self.timer.can_handle = true;
        scheduler.timer.run(
            &scheduler.loop,
            &self.timer.completion,
            t * std.time.ms_per_s,
            Self,
            self,
            onTimerComplete,
        );
    }

    return L.yield(0);
}

pub fn lua_load(L: *VM.lua.State) !void {
    _ = try L.Znewmetatable(@typeName(Self), .{
        .__metatable = "Metatable is locked",
        .__type = "HTTPClientWebSocket",
    });
    try __index(L, -1);
    L.setreadonly(-1, true);
    L.setuserdatametatable(TAG_NET_HTTP_WEBSOCKET);
    L.setuserdatadtor(Self, TAG_NET_HTTP_WEBSOCKET, __dtor);
}
