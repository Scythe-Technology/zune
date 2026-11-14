const std = @import("std");
const tls = @import("tls");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const hash = std.crypto.hash;

const CryptoTls = @This();

pub const OBJECT_TAG = Zune.Tags.get("CRYPTO_TLS").?;

cert_ref: Scripting.Reference,
state: union(enum) {
    dead: void,
    handshake: Handshake,
    established: tls.nonblock.Connection,
},

pub const Handshake = union(enum) {
    client: tls.nonblock.Client,
    server: tls.nonblock.Server,
};

pub fn lua_handshake(self: *CryptoTls, L: *VM.lua.State) !i32 {
    if (self.state != .handshake)
        return L.Zerror("invalid state");

    const recv_buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => &.{},
        else => return err,
    };
    const send_buf = Scripting.getControlledBuffer(L, []u8, 5) catch |err| switch (err) {
        error.NoSpace => {
            L.pushboolean(false);
            L.pushnumber(0);
            L.pushnumber(0);
            return 3;
        },
        else => return err,
    };

    switch (self.state) {
        .handshake => |*handshake| switch (handshake.*) {
            inline .server, .client => |*instance, e| {
                const result = try instance.run(recv_buf, send_buf);
                const done = instance.done();
                if (done) {
                    if (comptime e == .client) {
                        const allocator = Scheduler.fromState(L).allocator();
                        allocator.free(handshake.client.opt.host);
                    }
                    self.state = .{
                        .established = .init(instance.cipher().?),
                    };
                    self.cert_ref.deref(L);
                }
                L.pushboolean(done);
                L.pushnumber(@floatFromInt(result.recv_pos));
                L.pushnumber(@floatFromInt(result.send_pos));
                return 3;
            },
        },
        .established => return L.Zerror("already established"),
        .dead => return L.Zerror("dead state"),
    }
}

pub fn lua_encrypt(self: *CryptoTls, L: *VM.lua.State) !i32 {
    if (self.state != .established)
        return L.Zerror("not established");

    const cleartext_buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            L.pushnumber(0);
            return 2;
        },
        else => return err,
    };
    const ciphertext_buf = Scripting.getControlledBuffer(L, []u8, 5) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            L.pushnumber(0);
            return 2;
        },
        else => return err,
    };

    const result = try self.state.established.encrypt(cleartext_buf, ciphertext_buf);
    L.pushnumber(@floatFromInt(result.cleartext_pos));
    L.pushnumber(@floatFromInt(result.ciphertext.len));
    return 2;
}

pub fn lua_decrypt(self: *CryptoTls, L: *VM.lua.State) !i32 {
    if (self.state != .established)
        return L.Zerror("not established");

    const ciphertext_buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            L.pushnumber(0);
            L.pushboolean(false);
            return 3;
        },
        else => return err,
    };
    const cleartext_buf = Scripting.getControlledBuffer(L, []u8, 5) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            L.pushnumber(0);
            L.pushboolean(false);
            return 3;
        },
        else => return err,
    };

    const result = try self.state.established.decrypt(ciphertext_buf, cleartext_buf);
    L.pushnumber(@floatFromInt(result.ciphertext_pos));
    L.pushnumber(@floatFromInt(result.cleartext.len));
    L.pushboolean(result.closed);
    return 3;
}

pub fn lua_close(self: *CryptoTls, L: *VM.lua.State) !i32 {
    if (self.state != .established)
        return L.Zerror("not established");

    const ciphertext_buf = Scripting.getControlledBuffer(L, []u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(0);
            return 1;
        },
        else => return err,
    };

    self.state = .dead;

    const result = try self.state.established.close(ciphertext_buf);
    L.pushnumber(@floatFromInt(result.len));
    return 1;
}

pub fn lua_direct_established(self: *CryptoTls, res: *VM.lobject.TValue) void {
    res.setbvalue(self.state == .established);
}

pub fn __dtor(L: *VM.lua.State, self: *CryptoTls) void {
    self.cert_ref.deref(L);
    if (self.state == .handshake) {
        if (self.state.handshake == .client) {
            const allocator = Scheduler.fromState(L).allocator();
            allocator.free(self.state.handshake.client.opt.host);
        }
    }
}

pub fn create(L: *VM.lua.State, cert_ref: Scripting.Reference, handshake: Handshake) !*CryptoTls {
    const instance = try L.newuserdatataggedwithmetatable(CryptoTls, OBJECT_TAG);
    instance.* = .{
        .cert_ref = cert_ref,
        .state = .{ .handshake = handshake },
    };
    return instance;
}
