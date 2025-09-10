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

const VM = luau.VM;

const ZUNE_CLIENT_HEADER = "zune/" ++ Zune.info.version;

const Self = @This();

completion: xev.Completion,
cancel_completion: xev.Completion,
read_buffer: [8192]u8 = undefined,
parser: Response.Parser,
lua_ref: Scheduler.ThreadRef,
state: State,
timer: Timer,

pub const Timer = struct {
    started: bool = false,
    completion: xev.Completion,
    reset_completion: xev.Completion,
};

pub const State = struct {
    stage: enum(u2) { sending, receiving, closed } = .sending,
    close_code: u16 = 1006,
    http_request: []const u8,
    tls: ?*TlsContext = null,
    timeout: ?f64 = null,
    address_list: ?*std.net.AddressList,
    socket: std.posix.socket_t,
    address_index: usize = 0,
    body_type: VM.lua.Type = .String,

    @"error": ?anyerror = null,
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
            loop: *xev.Loop,
            completion: *xev.Completion,
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
                    loop,
                    completion,
                    .{ .slice = ctx.ciphertext.buffered() },
                    Self,
                    self,
                    Handshake.onSendComplete,
                );
                return .disarm;
            } else {
                tcp.read(
                    loop,
                    completion,
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
            loop: *xev.Loop,
            completion: *xev.Completion,
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
                tcp.write(
                    loop,
                    completion,
                    .{ .slice = ctx.ciphertext.buffered() },
                    Self,
                    self,
                    onSendComplete,
                );
                return .disarm;
            }
            ctx.ciphertext.rebase(ctx.ciphertext.buffer.len) catch unreachable; // shouldn't fail
            if (handshake.client.done()) {
                const cipher = handshake.client.cipher().?;
                handshake.deinit(self.parser.arena.child_allocator);
                ctx.connection = .{ .active = .{ .client = .init(cipher) } };
                self.stream_write(
                    loop,
                    completion,
                    tcp,
                    self.state.http_request,
                    onWrite,
                );
            } else {
                tcp.read(
                    loop,
                    completion,
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
        const res = ctx.connection.active.client.encrypt(buf, ctx.ciphertext.buffer[ctx.ciphertext.end..]) catch {
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
                    const amt = r catch |err| return @call(.always_inline, callback, .{
                        ud,
                        l,
                        c,
                        inner_tcp,
                        xev.ReadBuffer{ .slice = &inner_self.read_buffer },
                        err,
                    });
                    inner_ctx.record.end += amt;
                    const res = inner_ctx.connection.active.client.decrypt(inner_ctx.record.buffered(), inner_ctx.cleartext.buffer[inner_ctx.cleartext.end..]) catch {
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
    defer self.deinit();
    return .disarm;
}

fn close(self: *Self, loop: *xev.Loop, tcp: xev.TCP) void {
    self.state.stage = .closed;
    if (self.timer.started) {
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
    } else {
        tcp.close(
            loop,
            &self.completion,
            Self,
            self,
            onClose,
        );
    }
}

fn onRecv(
    ud: ?*Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
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

    if (self.parser.parse(read_slice) catch |err| return self.safeResumeWithError(err)) {
        defer self.close(loop, tcp);
        const L = self.lua_ref.value;

        if (L.status() != .Yield)
            return .disarm;

        self.parser.push(L, self.state.body_type == .Buffer) catch |e| std.debug.panic("{}", .{e});
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    } else {
        self.stream_read(
            loop,
            completion,
            tcp,
            onRecv,
        );
        return .disarm;
    }
    return .disarm;
}

pub fn onWrite(
    ud: ?*Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
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
            completion,
            tcp,
            remaining,
            onWrite,
        );
    } else {
        self.state.stage = .receiving;
        self.stream_read(
            loop,
            completion,
            tcp,
            onRecv,
        );
    }

    return .disarm;
}

fn resumeError(self: *Self, err: anyerror) void {
    const L = self.lua_ref.value;

    std.posix.close(self.state.socket);

    if (L.status() != .Yield)
        return self.deinit();
    L.pushfstring("{s}", .{@errorName(err)}) catch |e| std.debug.panic("{}", .{e});
    self.deinit();
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

    switch (self.state.stage) {
        .sending, .receiving => {
            self.state.stage = .closed;
            l.cancel(
                &self.completion,
                &self.cancel_completion,
                void,
                null,
                null,
            );
        },
        .closed => self.close(l, xev.TCP.initFd(self.state.socket)),
    }

    return .disarm;
}

fn onConnectComplete(
    ud: ?*Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
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
    if (self.state.stage == .closed)
        return self.safeResumeWithError(error.Timeout);
    if (self.state.tls) |ctx| {
        // start handshake
        const res = ctx.connection.handshake.client.run(&[_]u8{}, ctx.ciphertext.buffer[0..]) catch |err| return self.safeResumeWithError(err);
        std.debug.assert(res.send.len > 0); // client should always send first.
        ctx.ciphertext.end += res.send.len;
        tcp.write(
            loop,
            completion,
            .{ .slice = ctx.ciphertext.buffered() },
            Self,
            self,
            TlsContext.Handshake.onSendComplete,
        );
    } else {
        self.stream_write(
            loop,
            completion,
            tcp,
            self.state.http_request,
            onWrite,
        );
    }

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
        &self.completion,
        addr,
        Self,
        self,
        onConnectComplete,
    );
}

fn deinit(self: *Self) void {
    const allocator = self.parser.arena.child_allocator;
    defer allocator.destroy(self);
    defer self.lua_ref.deref();
    if (self.state.tls) |ctx| {
        switch (ctx.connection) {
            .handshake => |*c| c.deinit(allocator),
            .active => {},
        }
        allocator.destroy(ctx);
    }
    if (self.state.address_list) |addr|
        addr.deinit();
    allocator.free(self.state.http_request);
    self.parser.deinit();
}

// based on std.http.Client.validateUri
pub fn validateUri(uri: std.Uri, arena: std.mem.Allocator) !struct { std.http.Client.Protocol, std.Uri } {
    const protocol_map = std.StaticStringMap(std.http.Client.Protocol).initComptime(.{
        .{ "http", .plain },
        .{ "https", .tls },
    });
    const protocol = protocol_map.get(uri.scheme) orelse return error.UnsupportedUriScheme;
    var valid_uri = uri;
    valid_uri.host = .{
        .raw = try (uri.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena),
    };
    return .{ protocol, valid_uri };
}

pub fn lua_request(L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const uri_string = try L.Zcheckvalue([:0]const u8, 1, null);

    var method: std.http.Method = .GET;
    const body_type: VM.lua.Type = if (L.toboolean(3)) .Buffer else .String;

    const uri = try std.Uri.parse(uri_string);

    var timeout: ?u32 = 30;
    var payload: ?[]const u8 = null;
    var max_body_size: ?usize = null;
    var max_header_size: ?usize = null;
    var max_headers: ?u32 = null;

    var headers: std.ArrayListUnmanaged(u8) = .empty;
    defer headers.deinit(allocator);
    var host_handled = false;
    var user_agent_handled = false;

    if (!L.typeOf(2).isnoneornil()) {
        try L.Zchecktype(2, .Table);
        if (try L.Zcheckfield(?[]const u8, 2, "body")) |body|
            payload = body;
        L.pop(1);

        const headers_type = L.rawgetfield(2, "headers");
        if (headers_type == .Table) {
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
        } else if (!headers_type.isnoneornil()) return L.Zerror("invalid headers (expected table)");
        L.pop(1);

        if (try L.Zcheckfield(?u32, 2, "max_body_size")) |size|
            max_body_size = @min(size, LuaHelper.MAX_LUAU_SIZE);
        L.pop(1);

        if (try L.Zcheckfield(?u32, 2, "max_header_size")) |size|
            max_header_size = @min(size, LuaHelper.MAX_LUAU_SIZE);
        L.pop(1);

        if (try L.Zcheckfield(?u16, 2, "max_headers")) |size|
            max_headers = size;
        L.pop(1);

        if (try L.Zcheckfield(?[]const u8, 2, "method")) |method_str| blk: {
            inline for (@typeInfo(std.http.Method).@"enum".fields) |field| {
                if (comptime field.name.len < 3)
                    continue;
                if (std.mem.eql(u8, method_str, field.name)) {
                    method = @field(std.http.Method, field.name);
                    break :blk;
                }
            }
            return L.Zerror("invalid request method");
        }
        L.pop(1);

        if (try L.Zcheckfield(?u32, 2, "timeout")) |time| {
            if (time == 0)
                timeout = null // indefinite
            else
                timeout = time;
        }
        L.pop(1);
    }

    var uri_buffer: [1024 * 2]u8 = undefined;
    var fixedBuffer = std.heap.FixedBufferAllocator.init(&uri_buffer);

    const protocol, const valid_uri = try validateUri(uri, fixedBuffer.allocator());

    const host = valid_uri.host.?.raw;

    var buf_content_len: [12]u8 = undefined;
    const content_len_str = std.fmt.bufPrint(buf_content_len[0..], "{d}", .{if (payload) |p| p.len else 0}) catch unreachable;

    const request = try std.mem.concat(allocator, u8, &.{
        @tagName(method),
        " ",
        if (valid_uri.path.percent_encoded.len > 0) valid_uri.path.percent_encoded else "/",
        if (valid_uri.query != null) "?" else "",
        if (valid_uri.query) |query| query.percent_encoded else "",
        " HTTP/1.1",
        if (!host_handled) "\r\nHost: " else "",
        if (!host_handled) host else "",
        if (headers.items.len > 0) headers.items else "",
        "\r\nConnection: close",
        if (!user_agent_handled) "\r\nUser-Agent: " else "",
        if (!user_agent_handled) ZUNE_CLIENT_HEADER else "",
        if (payload != null) "\r\nContent-Length: " else "",
        if (payload != null) content_len_str else "",
        "\r\n\r\n",
        if (payload) |p| p else "",
    });
    errdefer allocator.free(request);

    const list = try std.net.getAddressList(allocator, host, valid_uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    });
    errdefer list.deinit();

    if (list.addrs.len == 0)
        return error.UnknownHostName;

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

    const self = try allocator.create(Self);
    var parser: Response.Parser = .init(allocator, max_headers orelse 100);
    if (max_body_size) |size|
        parser.max_body_size = size;
    if (max_header_size) |size|
        parser.max_header_size = size;
    self.* = .{
        .lua_ref = .init(L),
        .parser = parser,
        .completion = .init(),
        .cancel_completion = .init(),
        .state = .{
            .socket = undefined,
            .address_index = 0,
            .address_list = list,
            .stage = .sending,
            .body_type = body_type,
            .http_request = request,
            .tls = tls_ctx,
        },
        .timer = .{
            .completion = .init(),
            .reset_completion = .init(),
        },
    };
    errdefer self.lua_ref.deref();

    try self.connectAddress(list.addrs[0]);

    if (timeout) |t| {
        self.timer.started = true;
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
