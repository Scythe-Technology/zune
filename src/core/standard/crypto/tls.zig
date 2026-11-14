const std = @import("std");
const luau = @import("luau");
const tls = @import("tls");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const LuaHelper = Zune.Utils.LuaHelper;

const CryptoTls = Zune.objects.CryptoTls;
const CryptoTlsCertBundle = Zune.objects.CryptoTlsCertBundle;
const CryptoTlsCertKeyPair = Zune.objects.CryptoTlsCertKeyPair;

const VM = luau.VM;

pub const lua_MAX_RECORD_SIZE = tls.max_ciphertext_record_len;

pub fn lua_bundleFromSystem(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    var bundle = try tls.config.cert.fromSystem(allocator, Zune.io());
    errdefer bundle.deinit(allocator);

    _ = try CryptoTlsCertBundle.create(L, bundle);

    return 1;
}

pub fn lua_bundleFromFile(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const path = try L.Zcheckvalue([]const u8, 1, null);
    const dir = std.Io.Dir.cwd();

    var bundle = try tls.config.cert.fromFilePath(allocator, Zune.io(), dir, path);
    errdefer bundle.deinit(allocator);

    _ = try CryptoTlsCertBundle.create(L, bundle);

    return 1;
}

pub fn lua_keyPairFromFile(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const cert_path = try L.Zcheckvalue([]const u8, 1, null);
    const key_path = try L.Zcheckvalue([]const u8, 2, null);

    const dir = std.Io.Dir.cwd();

    var key_pair = try tls.config.CertKeyPair.fromFilePath(allocator, Zune.io(), dir, cert_path, key_path);
    errdefer key_pair.deinit(allocator);

    _ = try CryptoTlsCertKeyPair.create(L, key_pair);

    return 1;
}

threadlocal var rng: std.Random.IoSource = .{ .io = undefined };
pub fn lua_createClient(L: *VM.lua.State) !i32 {
    const options = try L.Zcheckvalue(struct {
        host: [:0]const u8,
    }, 2, null);

    if (L.rawgetfield(2, "ca") != .Userdata or L.userdatatag(-1) != CryptoTlsCertBundle.OBJECT_TAG)
        return L.Zerror("argument #2 field 'ca' must be a CertBundle");

    const ca_bundle = L.touserdatatagged(CryptoTlsCertBundle, -1, CryptoTlsCertBundle.OBJECT_TAG).?;

    const allocator = Scheduler.fromState(L).allocator();

    const host = try allocator.dupe(u8, options.host);
    errdefer allocator.free(host);

    var ref: Scripting.Reference = .init(L, -1);
    errdefer ref.deref(L);

    rng = .{ .io = Zune.io() };
    _ = try CryptoTls.create(L, ref, .{
        .client = .init(.{
            .rng = rng.interface(),
            .now = std.Io.Clock.now(.real, Zune.io()),
            .host = host,
            .root_ca = ca_bundle.bundle,
            .cipher_suites = tls.config.cipher_suites.secure,
        }),
    });

    return 1;
}

pub fn lua_createServer(L: *VM.lua.State) !i32 {
    try L.Zchecktype(2, .Table);

    if (L.rawgetfield(2, "auth") != .Userdata or L.userdatatag(-1) != CryptoTlsCertKeyPair.OBJECT_TAG)
        return L.Zerror("argument #2 field 'auth' must be a CertKeyPair");

    const ca_keypair = L.touserdatatagged(CryptoTlsCertKeyPair, -1, CryptoTlsCertKeyPair.OBJECT_TAG).?;

    var ref: Scripting.Reference = .init(L, -1);
    errdefer ref.deref(L);

    rng = .{ .io = Zune.io() };
    _ = try CryptoTls.create(L, ref, .{
        .server = .init(.{
            .rng = rng.interface(),
            .now = std.Io.Clock.now(.real, Zune.io()),
            .auth = &ca_keypair.key_pair,
        }),
    });

    return 1;
}
