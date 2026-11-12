const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const hash = std.crypto.hash;

const CryptoHasher = @This();

pub const OBJECT_TAG = Zune.Tags.get("CRYPTO_HASHER").?;

state: []u8,
extra: ?[]u8,
algorithm: Algorithm,
used: bool = false,

pub const Algorithm = enum {
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    sha3_224,
    sha3_256,
    sha3_384,
    sha3_512,
    sha3_shake128,
    sha3_shake256,
    blake2b128,
    blake2b160,
    blake2b256,
    blake2b384,
    blake2b512,
    blake2s128,
    blake2s160,
    blake2s224,
    blake2s256,
    blake3,

    pub const LargestBlockLength = len: {
        var largest = 0;
        for (@typeInfo(Algorithm).@"enum".field_values) |field_value| {
            const value: Algorithm = @fromBackingInt(@intCast(field_value));
            largest = @max(largest, value.block_length());
        }
        break :len largest;
    };

    pub fn block_length(self: Algorithm) usize {
        return switch (self) {
            inline else => |algo| @field(algo.hasher(), "block_length"),
        };
    }

    pub fn digest_length(self: Algorithm) usize {
        return switch (self) {
            inline else => |algo| @field(algo.hasher(), "digest_length"),
        };
    }

    pub fn size(self: Algorithm) usize {
        return switch (self) {
            inline else => |algo| @sizeOf(algo.hasher()),
        };
    }

    pub fn alignment(self: Algorithm) u32 {
        return switch (self) {
            inline else => |algo| @alignOf(algo.hasher()),
        };
    }

    pub fn quickHash(self: Algorithm, value: []const u8, out: []u8) void {
        switch (self) {
            inline else => |algo| {
                const Hasher = algo.hasher();
                Hasher.hash(value, out[0..@field(Hasher, "digest_length")], .{});
            },
        }
    }

    pub fn update(self: Algorithm, state: []u8, value: []const u8) void {
        switch (self) {
            inline else => |algo| {
                algo.hasher().update(@ptrCast(@alignCast(state.ptr)), value);
            },
        }
    }

    pub fn final(self: Algorithm, state: []u8, buf: []u8) void {
        switch (self) {
            inline else => |algo| {
                const Hasher = algo.hasher();
                Hasher.final(@ptrCast(@alignCast(state.ptr)), buf[0..@field(Hasher, "digest_length")]);
            },
        }
    }

    pub fn init(self: Algorithm, state: []u8) void {
        return switch (self) {
            inline else => |algo| {
                const state_ptr: *algo.hasher() = @ptrCast(@alignCast(state.ptr));
                state_ptr.* = algo.hasher().init(.{});
            },
        };
    }

    pub fn hasher(comptime algo: Algorithm) type {
        return switch (algo) {
            .md5 => hash.Md5,
            .sha1 => hash.Sha1,
            .sha224 => hash.sha2.Sha224,
            .sha256 => hash.sha2.Sha256,
            .sha384 => hash.sha2.Sha384,
            .sha512 => hash.sha2.Sha512,
            .sha3_224 => hash.sha3.Sha3_224,
            .sha3_256 => hash.sha3.Sha3_256,
            .sha3_384 => hash.sha3.Sha3_384,
            .sha3_512 => hash.sha3.Sha3_512,
            .sha3_shake128 => hash.sha3.Shake128,
            .sha3_shake256 => hash.sha3.Shake256,
            .blake2b128 => hash.blake2.Blake2b128,
            .blake2b160 => hash.blake2.Blake2b160,
            .blake2b256 => hash.blake2.Blake2b256,
            .blake2b384 => hash.blake2.Blake2b384,
            .blake2b512 => hash.blake2.Blake2b512,
            .blake2s128 => hash.blake2.Blake2s128,
            .blake2s160 => hash.blake2.Blake2s160,
            .blake2s224 => hash.blake2.Blake2s224,
            .blake2s256 => hash.blake2.Blake2s256,
            .blake3 => hash.Blake3,
        };
    }
};

pub const AlgorithmMap = Scripting.createEnumMap(Algorithm);

pub fn lua_update(self: *CryptoHasher, L: *VM.lua.State) !i32 {
    if (self.extra != null and self.used)
        return L.Zerror("hasher already used");
    const value = try L.Zcheckvalue([]const u8, 2, null);

    switch (self.algorithm) {
        inline else => |algo| {
            algo.update(self.state, value);
        },
    }

    return 0;
}

const DigestEncoding = enum {
    hex,
    base64,
    binary,
};
const DigestEncodingMap = Scripting.createEnumMap(DigestEncoding);
pub fn lua_digest(self: *CryptoHasher, L: *VM.lua.State) !i32 {
    if (self.extra != null and self.used)
        return L.Zerror("hasher already used");
    const encoding_name = try L.Zcheckvalue(?[:0]const u8, 2, null);
    const encoding = if (encoding_name) |name|
        DigestEncodingMap.get(name) orelse return L.Zerrorf("invalid encoding: {s}", .{name})
    else
        null;
    switch (self.algorithm) {
        inline else => |algo| {
            const Hasher = algo.hasher();
            const digest_length = @field(Hasher, "digest_length");
            const block_length = @field(Hasher, "block_length");
            var buf: [digest_length]u8 = undefined;

            algo.final(self.state, &buf);

            if (self.extra) |e| {
                var ohash = Hasher.init(.{});
                ohash.update(e[0..block_length]);
                ohash.update(&buf);
                ohash.final(&buf);
                self.used = true;
            } else {
                algo.init(self.state);
            }

            if (encoding) |enc| {
                switch (enc) {
                    .hex => {
                        const hex = std.fmt.bytesToHex(&buf, .lower);
                        try L.pushlstring(&hex);
                    },
                    .base64 => {
                        const allocator = Scheduler.fromState(L).allocator();
                        const base64_buf = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(buf.len));
                        defer allocator.free(base64_buf);
                        try L.pushlstring(std.base64.standard.Encoder.encode(base64_buf, &buf));
                    },
                    .binary => try L.Zpushbuffer(&buf),
                }
            } else {
                try L.Zpushbuffer(&buf);
            }
        },
    }
    return 1;
}

pub fn lua_copy(self: *CryptoHasher, L: *VM.lua.State) !i32 {
    if (self.extra != null and self.used)
        return L.Zerror("hasher already used");
    const allocator = Scheduler.fromState(L).allocator();

    const state_alloc = allocator.rawAlloc(self.algorithm.size(), .fromByteUnits(self.algorithm.alignment()), @returnAddress()) orelse return error.OutOfMemory;
    const state = state_alloc[0..self.algorithm.size()];
    @memcpy(state, self.state);
    errdefer allocator.rawFree(state, .fromByteUnits(self.algorithm.alignment()), @returnAddress());

    const extra = if (self.extra) |e| try allocator.dupe(u8, e) else null;
    errdefer if (extra) |e| allocator.free(e);

    _ = try create(L, self.algorithm, state, extra);

    return 1;
}

pub fn __dtor(L: *VM.lua.State, self: *CryptoHasher) void {
    const allocator = Scheduler.fromState(L).allocator();

    allocator.rawFree(self.state, .fromByteUnits(self.algorithm.alignment()), @returnAddress());
    if (self.extra) |e|
        allocator.free(e);
}

pub fn create(L: *VM.lua.State, algorithm: CryptoHasher.Algorithm, state: []u8, extra: ?[]u8) !*CryptoHasher {
    const hasher = try L.newuserdatataggedwithmetatable(CryptoHasher, OBJECT_TAG);
    hasher.* = .{
        .algorithm = algorithm,
        .state = state,
        .extra = extra,
    };
    return hasher;
}
