const std = @import("std");
const luau = @import("luau");
const tls = @import("tls");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;

const Socket = @import("../../objects/network/Socket.zig");

const TAG_NET_SOCKET = Zune.Tags.get("NET_SOCKET").?;
const TAG_CRYPTO_TLS_CERTBUNDLE = Zune.Tags.get("CRYPTO_TLS_CERTBUNDLE").?;
const TAG_CRYPTO_TLS_CERTKEYPAIR = Zune.Tags.get("CRYPTO_TLS_CERTKEYPAIR").?;

const VM = luau.VM;

const BundleMapContext = struct {
    const der = std.crypto.Certificate.der;

    cb: *const tls.config.cert.Bundle,

    pub fn hash(ctx: BundleMapContext, k: der.Element.Slice) u64 {
        return std.hash_map.hashString(ctx.cb.bytes.items[k.start..k.end]);
    }

    pub fn eql(ctx: BundleMapContext, a: der.Element.Slice, b: der.Element.Slice) bool {
        const bytes = ctx.cb.bytes.items;
        return std.mem.eql(
            u8,
            bytes[a.start..a.end],
            bytes[b.start..b.end],
        );
    }
};

pub fn cloneCertBundle(allocator: std.mem.Allocator, bundle: tls.config.cert.Bundle) !tls.config.cert.Bundle {
    var bytes = try bundle.bytes.clone(allocator);
    errdefer bytes.deinit(allocator);

    var b: tls.config.cert.Bundle = .{
        .bytes = bytes,
        .map = .empty,
    };
    const context: BundleMapContext = .{ .cb = @ptrCast(&b) };

    const map = try bundle.map.cloneContext(allocator, context);
    b.map = @as(*const @TypeOf(b.map), @ptrCast(&map)).*;

    return b;
}

pub fn cloneCertKeyPair(allocator: std.mem.Allocator, pair: tls.config.CertKeyPair) !tls.config.CertKeyPair {
    return .{
        .bundle = try cloneCertBundle(allocator, pair.bundle),
        .key = pair.key,
    };
}

pub fn lua_bundleFromSystem(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const self = try L.newuserdatatagged(tls.config.cert.Bundle, TAG_CRYPTO_TLS_CERTBUNDLE);

    self.* = try tls.config.cert.fromSystem(allocator);

    return 1;
}

pub fn lua_bundleFromFile(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const path = try L.Zcheckvalue([]const u8, 1, null);
    const dir = std.fs.cwd();

    const self = try L.newuserdatatagged(tls.config.cert.Bundle, TAG_CRYPTO_TLS_CERTBUNDLE);

    self.* = try tls.config.cert.fromFilePath(allocator, dir, path);

    return 1;
}

pub fn lua_keyPairFromFile(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const cert_path = try L.Zcheckvalue([]const u8, 1, null);
    const key_path = try L.Zcheckvalue([]const u8, 2, null);

    const dir = std.fs.cwd();

    const self = try L.newuserdatatagged(tls.config.CertKeyPair, TAG_CRYPTO_TLS_CERTKEYPAIR);

    self.* = try tls.config.CertKeyPair.fromFilePath(allocator, dir, cert_path, key_path);

    return 1;
}

pub fn lua_setupClient(L: *VM.lua.State) !i32 {
    const socket = L.touserdatatagged(Socket, 1, TAG_NET_SOCKET) orelse return L.Zerror("argument #1 must be a Socket");

    if (socket.tls != .none)
        return L.Zerror("socket already has a TLS context");

    switch (socket.open) {
        .created => {},
        .accepted => return L.Zerror("socket is server accepted"),
        .closed => return L.Zerror("socket is closed"),
    }

    const options = try L.Zcheckvalue(struct {
        host: [:0]const u8,
    }, 2, null);

    if (L.rawgetfield(2, "ca") != .Userdata or L.userdatatag(-1) != TAG_CRYPTO_TLS_CERTBUNDLE)
        return L.Zerror("argument #2 field 'ca' must be a CertBundle");

    const allocator = luau.getallocator(L);

    const ca_bundle = try cloneCertBundle(allocator, L.touserdatatagged(tls.config.cert.Bundle, -1, TAG_CRYPTO_TLS_CERTBUNDLE).?.*);
    L.pop(1);

    const client_context = try allocator.create(Socket.TlsContext.Client);
    errdefer allocator.destroy(client_context);

    const host = try allocator.dupe(u8, options.host);
    errdefer allocator.free(host);

    client_context.* = .{
        .record = .{
            .buffer = &client_context.record_buffer,
            .end = 0,
            .seek = 0,
            .vtable = &.{
                .stream = Socket.TlsContext.endingStream,
            },
        },
        .cleartext = .{
            .buffer = &client_context.cleartext_buffer,
            .end = 0,
            .seek = 0,
            .vtable = &.{
                .stream = Socket.TlsContext.endingStream,
            },
        },
        .ciphertext = .{
            .buffer = &client_context.ciphertext_buffer,
            .end = 0,
            .seek = 0,
            .vtable = &.{
                .stream = Socket.TlsContext.endingStream,
            },
        },
        .connection = .{
            .handshake = .{
                .client = .init(.{
                    .host = host,
                    .root_ca = ca_bundle,
                    .cipher_suites = tls.config.cipher_suites.secure,
                    .key_log_callback = tls.config.key_log.callback,
                }),
            },
        },
    };

    socket.tls = .{
        .client = client_context,
    };

    return 0;
}

pub fn lua_setupServer(L: *VM.lua.State) !i32 {
    const socket = L.touserdatatagged(Socket, 1, TAG_NET_SOCKET) orelse return L.Zerror("argument #1 must be a Socket");

    if (socket.tls != .none)
        return L.Zerror("socket already has a TLS context");

    switch (socket.open) {
        .created => {},
        .accepted => return L.Zerror("socket is server accepted"),
        .closed => return L.Zerror("socket is closed"),
    }

    try L.Zchecktype(2, .Table);

    if (L.rawgetfield(2, "auth") != .Userdata or L.userdatatag(-1) != TAG_CRYPTO_TLS_CERTKEYPAIR)
        return L.Zerror("argument #2 field 'ca' must be a CertBundle");

    const allocator = luau.getallocator(L);

    var ca_keypair = try cloneCertKeyPair(allocator, L.touserdatatagged(tls.config.CertKeyPair, -1, TAG_CRYPTO_TLS_CERTKEYPAIR).?.*);
    errdefer ca_keypair.deinit(allocator);

    L.pop(1);

    const context = try allocator.create(Socket.TlsContext.ServerRef);
    errdefer allocator.destroy(context);

    context.* = .{
        .server = ca_keypair,
    };

    socket.tls = .{
        .server_ref = context,
    };

    return 0;
}

pub fn certbundle_dtor(L: *VM.lua.State, self: *tls.config.cert.Bundle) void {
    self.deinit(luau.getallocator(L));
}

pub fn certkeypair_dtor(L: *VM.lua.State, self: *tls.config.CertKeyPair) void {
    self.deinit(luau.getallocator(L));
}

pub fn load(L: *VM.lua.State) void {
    L.setuserdatadtor(tls.config.cert.Bundle, TAG_CRYPTO_TLS_CERTBUNDLE, certbundle_dtor);
    L.setuserdatadtor(tls.config.CertKeyPair, TAG_CRYPTO_TLS_CERTKEYPAIR, certkeypair_dtor);
}
