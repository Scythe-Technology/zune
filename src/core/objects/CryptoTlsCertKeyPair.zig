const std = @import("std");
const tls = @import("tls");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const hash = std.crypto.hash;

const CryptoTlsCertKeyPair = @This();

pub const OBJECT_TAG = Zune.Tags.get("CRYPTO_TLS_CERTKEYPAIR").?;

key_pair: tls.config.CertKeyPair,

pub fn __dtor(L: *VM.lua.State, self: *CryptoTlsCertKeyPair) void {
    self.key_pair.deinit(Scheduler.fromState(L).allocator());
}

pub fn create(L: *VM.lua.State, key_pair: tls.config.CertKeyPair) !*CryptoTlsCertKeyPair {
    const instance = try L.newuserdatataggedwithmetatable(CryptoTlsCertKeyPair, OBJECT_TAG);
    instance.* = .{
        .key_pair = key_pair,
    };
    return instance;
}
