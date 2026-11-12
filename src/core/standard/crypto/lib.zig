const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

const CryptoHasher = Zune.objects.CryptoHasher;

pub const LIB_NAME = "crypto";

pub fn lua_createHash(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const name = try L.Zcheckvalue([:0]const u8, 1, null);
    const secret = try L.Zcheckvalue(?[:0]const u8, 2, null);
    const algo = CryptoHasher.AlgorithmMap.get(name) orelse return L.Zerrorf("invalid algorithm: {s}", .{name});

    const block_length = algo.block_length();
    const digest_length = algo.digest_length();

    const state_alloc = allocator.rawAlloc(algo.size(), .fromByteUnits(algo.alignment()), @returnAddress()) orelse return error.OutOfMemory;
    const state = state_alloc[0..algo.size()];
    errdefer allocator.rawFree(state, .fromByteUnits(algo.alignment()), @returnAddress());

    const extra = if (secret != null) try allocator.alloc(u8, block_length) else null;

    algo.init(state);

    if (secret) |s| {
        // from std.crypto.auth.hmac
        const op_block_len = CryptoHasher.Algorithm.LargestBlockLength;
        var scratch: [op_block_len]u8 = undefined;
        var i_key_pad: [op_block_len]u8 = undefined;

        if (s.len > block_length) {
            algo.quickHash(s, scratch[0..digest_length]);
            @memset(scratch[digest_length..block_length], 0);
        } else if (s.len < block_length) {
            @memcpy(scratch[0..s.len], s);
            @memset(scratch[s.len..block_length], 0);
        } else {
            @memcpy(&scratch, s);
        }
        // Normalize key length to block size of hash
        for (extra.?, 0..) |*b, i| {
            b.* = scratch[i] ^ 0x5c;
        }

        for (i_key_pad[0..block_length], 0..) |*b, i| {
            b.* = scratch[i] ^ 0x36;
        }

        algo.update(state, i_key_pad[0..block_length]);
    }

    _ = try CryptoHasher.create(L, algo, state, extra);

    return 1;
}

pub const lua_password = @import("password.zig");
pub const lua_random = @import("random.zig");
pub const lua_aead = @import("aead.zig");
pub const lua_uuid = @import("uuid.zig");
pub const lua_tls = @import("tls.zig");

pub fn __setup(L: *VM.lua.State) !void {
    _ = L;
    lua_random.rng = .{ .io = Zune.io() };
}

test {
    _ = @import("tls.zig");
    _ = @import("random.zig");
    _ = @import("password.zig");
    _ = @import("aead.zig");
    _ = @import("uuid.zig");
}
