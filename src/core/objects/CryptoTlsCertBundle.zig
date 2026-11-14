const std = @import("std");
const tls = @import("tls");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const hash = std.crypto.hash;

const CryptoTlsCertBundle = @This();

pub const OBJECT_TAG = Zune.Tags.get("CRYPTO_TLS_CERTBUNDLE").?;

bundle: tls.config.cert.Bundle,

pub fn __dtor(L: *VM.lua.State, self: *CryptoTlsCertBundle) void {
    self.bundle.deinit(Scheduler.fromState(L).allocator());
}

pub fn create(L: *VM.lua.State, bundle: tls.config.cert.Bundle) !*CryptoTlsCertBundle {
    const instance = try L.newuserdatataggedwithmetatable(CryptoTlsCertBundle, OBJECT_TAG);
    instance.* = .{
        .bundle = bundle,
    };
    return instance;
}
