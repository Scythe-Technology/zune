const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

const aead = std.crypto.aead;

pub fn GenerateEncryptFn(comptime algorithm: anytype) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn encrypt(L: *VM.lua.State) !i32 {
            const allocator = Scheduler.fromState(L).allocator();

            const msg = try L.Zcheckvalue([]const u8, 1, null);
            const key = try L.Zcheckvalue([]const u8, 2, null);

            if (key.len != algorithm.key_length)
                return L.Zerrorf("invalid key length (expected size {d})", .{algorithm.key_length});

            const nonce = if (comptime @hasDecl(algorithm, "nonce_length")) blk: {
                const n = try L.Zcheckvalue([]const u8, 3, null);
                if (n.len != algorithm.nonce_length)
                    return L.Zerrorf("invalid nonce length (expected size {d})", .{algorithm.nonce_length});
                break :blk n;
            } else blk: {
                const n = try L.Zcheckvalue(?[]const u8, 3, null);
                break :blk n;
            };

            const ad = try L.Zcheckvalue(?[]const u8, 4, null) orelse "";

            var tag: [algorithm.tag_length]u8 = undefined;
            const c = try allocator.alloc(u8, msg.len);
            defer allocator.free(c);

            const snonce = if (@hasDecl(algorithm, "nonce_length")) blk: {
                var s: [algorithm.nonce_length]u8 = undefined;
                if (nonce.len != 0)
                    @memcpy(s[0..], nonce[0..nonce.len]);
                break :blk s;
            } else nonce;
            var skey: [algorithm.key_length]u8 = undefined;
            @memcpy(skey[0..], key[0..algorithm.key_length]);

            algorithm.encrypt(c, &tag, msg, ad, snonce, skey);

            try L.createtable(0, 2);

            try L.Zpushbuffer(c);
            try L.rawsetfield(-2, "cipher");

            try L.Zpushbuffer(&tag);
            try L.rawsetfield(-2, "tag");

            return 1;
        }
    }.encrypt;
}

pub fn GenerateDecryptFn(comptime algorithm: anytype) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn decrypt(L: *VM.lua.State) !i32 {
            const allocator = Scheduler.fromState(L).allocator();

            const cipher = try L.Zcheckvalue([]const u8, 1, null);
            const tag = try L.Zcheckvalue([]const u8, 2, null);

            if (tag.len != algorithm.tag_length)
                return L.Zerrorf("invalid tag length (expected size {})", .{algorithm.tag_length});

            const key = try L.Zcheckvalue([]const u8, 3, null);

            if (key.len != algorithm.key_length)
                return L.Zerrorf("invalid key length (expected size {})", .{algorithm.key_length});

            const nonce = if (comptime @hasDecl(algorithm, "nonce_length")) blk: {
                const n = try L.Zcheckvalue([]const u8, 4, null);
                if (n.len != algorithm.nonce_length)
                    return L.Zerrorf("invalid nonce length (expected size {d})", .{algorithm.nonce_length});
                break :blk n;
            } else blk: {
                const n = try L.Zcheckvalue(?[]const u8, 4, null);
                break :blk n;
            };

            const ad = try L.Zcheckvalue(?[]const u8, 5, null) orelse "";

            const msg = try allocator.alloc(u8, cipher.len);
            defer allocator.free(msg);

            var stag: [algorithm.tag_length]u8 = undefined;
            @memcpy(stag[0..], tag[0..algorithm.tag_length]);
            const snonce = if (@hasDecl(algorithm, "nonce_length")) blk: {
                var s: [algorithm.nonce_length]u8 = undefined;
                if (nonce.len != 0)
                    @memcpy(s[0..], nonce[0..nonce.len]);
                break :blk s;
            } else nonce;
            var skey: [algorithm.key_length]u8 = undefined;
            @memcpy(skey[0..], key[0..algorithm.key_length]);

            try algorithm.decrypt(msg, cipher, stag, ad, snonce, skey);

            try L.pushlstring(msg);

            return 1;
        }
    }.decrypt;
}

fn Generate(algo: type) type {
    return struct {
        pub const lua_encrypt = GenerateEncryptFn(algo);
        pub const lua_decrypt = GenerateDecryptFn(algo);
    };
}

pub const lua_aegis = struct {
    const aegis = aead.aegis;

    pub const lua_Aegis128X4 = Generate(aegis.Aegis128X4);
    pub const lua_Aegis128X2 = Generate(aegis.Aegis128X2);
    pub const lua_Aegis128L = Generate(aegis.Aegis128L);

    pub const lua_Aegis256X4 = Generate(aegis.Aegis256X4);
    pub const lua_Aegis256X2 = Generate(aegis.Aegis256X2);
    pub const lua_Aegis256 = Generate(aegis.Aegis256);

    pub const lua_Aegis128X4_256 = Generate(aegis.Aegis128X4_256);
    pub const lua_Aegis128X2_256 = Generate(aegis.Aegis128X2_256);
    pub const lua_Aegis128L_256 = Generate(aegis.Aegis128L_256);

    pub const lua_Aegis256X4_256 = Generate(aegis.Aegis256X4_256);
    pub const lua_Aegis256X2_256 = Generate(aegis.Aegis256X2_256);
    pub const lua_Aegis256_256 = Generate(aegis.Aegis256_256);
};

pub const lua_aes_gcm = struct {
    const aes_gcm = aead.aes_gcm;
    pub const lua_Aes128Gcm = Generate(aes_gcm.Aes128Gcm);
    pub const lua_Aes256Gcm = Generate(aes_gcm.Aes256Gcm);
};

pub const lua_aes_gcm_siv = struct {
    const aes_gcm_siv = aead.aes_gcm_siv;
    pub const lua_Aes128GcmSiv = Generate(aes_gcm_siv.Aes128GcmSiv);
    pub const lua_Aes256GcmSiv = Generate(aes_gcm_siv.Aes256GcmSiv);
};

pub const lua_aes_siv = struct {
    const aes_siv = aead.aes_siv;
    pub const lua_Aes128Siv = Generate(aes_siv.Aes128Siv);
    pub const lua_Aes256Siv = Generate(aes_siv.Aes256Siv);
};

pub const lua_aes_ocb = struct {
    const aes_ocb = aead.aes_ocb;
    pub const lua_Aes128Ocb = Generate(aes_ocb.Aes128Ocb);
    pub const lua_Aes256Ocb = Generate(aes_ocb.Aes256Ocb);
};

pub const lua_aes_ccm = struct {
    const aes_ccm = aead.aes_ccm;
    pub const lua_Aes128Ccm0 = Generate(aes_ccm.Aes128Ccm0);
    pub const lua_Aes128Ccm8 = Generate(aes_ccm.Aes128Ccm8);
    pub const lua_Aes128Ccm16 = Generate(aes_ccm.Aes128Ccm16);
    pub const lua_Aes256Ccm0 = Generate(aes_ccm.Aes256Ccm0);
    pub const lua_Aes256Ccm8 = Generate(aes_ccm.Aes256Ccm8);
    pub const lua_Aes256Ccm16 = Generate(aes_ccm.Aes256Ccm16);
};

pub const lua_ascon = struct {
    const ascon = aead.ascon;
    pub const lua_AsconAead128 = Generate(ascon.AsconAead128);
};

pub const lua_chacha_poly = struct {
    const chacha_poly = aead.chacha_poly;
    pub const lua_ChaCha20Poly1305 = Generate(chacha_poly.ChaCha20Poly1305);
    pub const lua_ChaCha12Poly1305 = Generate(chacha_poly.ChaCha12Poly1305);
    pub const lua_ChaCha8Poly1305 = Generate(chacha_poly.ChaCha8Poly1305);
    pub const lua_XChaCha20Poly1305 = Generate(chacha_poly.XChaCha20Poly1305);
    pub const lua_XChaCha12Poly1305 = Generate(chacha_poly.XChaCha12Poly1305);
    pub const lua_XChaCha8Poly1305 = Generate(chacha_poly.XChaCha8Poly1305);
};

pub const lua_isap = struct {
    pub const lua_IsapA128A = Generate(aead.isap.IsapA128A);
};

pub const lua_salsa_poly = struct {
    const salsa_poly = aead.salsa_poly;
    pub const lua_XSalsa20Poly1305 = Generate(salsa_poly.XSalsa20Poly1305);
};
