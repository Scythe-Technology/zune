const std = @import("std");
const luau = @import("luau");
const tls = @import("tls");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;

const Socket = @import("../../objects/network/Socket.zig");

const TAG_NET_SOCKET = Zune.tagged.Tags.get("NET_SOCKET").?;
const TAG_CRYPTO_TLS_CERTBUNDLE = Zune.tagged.Tags.get("CRYPTO_TLS_CERTBUNDLE").?;
const TAG_CRYPTO_TLS_CERTKEYPAIR = Zune.tagged.Tags.get("CRYPTO_TLS_CERTKEYPAIR").?;

const VM = luau.VM;

pub fn lua_bundleFromSystem(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const self = L.newuserdatatagged(tls.config.CertBundle, TAG_CRYPTO_TLS_CERTBUNDLE);

    self.* = try tls.config.CertBundle.fromSystem(allocator);

    return 1;
}

pub fn lua_bundleFromFile(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const path = try L.Zcheckvalue([]const u8, 1, null);
    const dir = std.fs.cwd();

    const self = L.newuserdatatagged(tls.config.CertBundle, TAG_CRYPTO_TLS_CERTBUNDLE);

    self.* = try tls.config.CertBundle.fromFile(allocator, dir, path);

    return 1;
}

pub fn lua_keyPairFromFile(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const cert_path = try L.Zcheckvalue([]const u8, 1, null);
    const key_path = try L.Zcheckvalue([]const u8, 2, null);

    const dir = std.fs.cwd();

    const self = L.newuserdatatagged(tls.config.CertKeyPair, TAG_CRYPTO_TLS_CERTKEYPAIR);

    self.* = try tls.config.CertKeyPair.load(allocator, dir, cert_path, key_path);

    return 1;
}

pub fn lua_setupClient(L: *VM.lua.State) !i32 {
    const socket = L.touserdatatagged(Socket, 1, TAG_NET_SOCKET) orelse return L.Zerror("argument #1 must be a Socket");

    if (socket.tls_context != .none)
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

    const ca_bundle = L.touserdatatagged(tls.config.CertBundle, -1, TAG_CRYPTO_TLS_CERTBUNDLE) orelse @panic("unreachable");

    const ca_ref: LuaHelper.Ref(void) = .init(L, -1, undefined);

    L.pop(1);

    const allocator = luau.getallocator(L);

    const client_context = try allocator.create(Socket.TlsContext.Client);
    errdefer allocator.destroy(client_context);

    const host = try allocator.dupe(u8, options.host);
    errdefer allocator.free(host);

    client_context.* = .{
        .allocator = allocator,
        .connection = .{
            .handshake = .{
                .GL = L.mainthread(),
                .ca_ref = ca_ref,
                .client = .init(.{
                    .host = host,
                    .root_ca = ca_bundle.*,
                    .cipher_suites = tls.config.cipher_suites.secure,
                    .key_log_callback = tls.config.key_log.callback,
                }),
            },
        },
    };

    socket.tls_context = .{
        .client = client_context,
    };

    return 0;
}

pub fn lua_setupServer(L: *VM.lua.State) !i32 {
    const socket = L.touserdatatagged(Socket, 1, TAG_NET_SOCKET) orelse return L.Zerror("argument #1 must be a Socket");

    if (socket.tls_context != .none)
        return L.Zerror("socket already has a TLS context");

    switch (socket.open) {
        .created => {},
        .accepted => return L.Zerror("socket is server accepted"),
        .closed => return L.Zerror("socket is closed"),
    }

    try L.Zchecktype(2, .Table);

    if (L.rawgetfield(2, "auth") != .Userdata or L.userdatatag(-1) != TAG_CRYPTO_TLS_CERTKEYPAIR)
        return L.Zerror("argument #2 field 'ca' must be a CertBundle");

    const ca_keypair = L.touserdatatagged(tls.config.CertKeyPair, -1, TAG_CRYPTO_TLS_CERTKEYPAIR) orelse @panic("unreachable");

    const ca_ref: LuaHelper.Ref(void) = .init(L, -1, undefined);

    L.pop(1);

    const allocator = luau.getallocator(L);

    const context = try allocator.create(Socket.TlsContext.ServerRef);
    errdefer allocator.destroy(context);

    context.* = .{
        .GL = L.mainthread(),
        .ca_keypair_ref = ca_ref,
        .server = .init(.{
            .auth = ca_keypair,
        }),
    };

    socket.tls_context = .{
        .server_ref = context,
    };

    return 0;
}

pub fn certbundle_dtor(L: *VM.lua.State, self: *tls.config.CertBundle) void {
    self.deinit(luau.getallocator(L));
}

pub fn certkeypair_dtor(L: *VM.lua.State, self: *tls.config.CertKeyPair) void {
    self.deinit(luau.getallocator(L));
}

pub fn load(L: *VM.lua.State) void {
    L.setuserdatadtor(tls.config.CertBundle, TAG_CRYPTO_TLS_CERTBUNDLE, certbundle_dtor);
    L.setuserdatadtor(tls.config.CertKeyPair, TAG_CRYPTO_TLS_CERTKEYPAIR, certkeypair_dtor);
}
