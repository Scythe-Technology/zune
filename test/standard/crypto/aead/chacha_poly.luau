--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local aead = crypto.aead;

local chacha_poly = aead.chacha_poly;

type Input = buffer | string;
local function getsize(input: Input): number
    return if (type(input) == "buffer") then buffer.len(input) else #input;
end
local function examine(algo: any, key: Input, nonce: Input, tests: {{data: Input, ad: Input?, cipher: string, tag: string}})
    for _, test in tests do
        expect(function()
            algo.encrypt(test.data, "", nonce, test.ad);
        end).toThrow(`invalid key length (expected size {getsize(key)})`);
        expect(function()
            algo.encrypt(test.data, buffer.create(0), nonce, test.ad);
        end).toThrow(`invalid key length (expected size {getsize(key)})`);
        expect(function()
            algo.encrypt(test.data, key, "", test.ad);
        end).toThrow(`invalid nonce length (expected size {getsize(nonce)})`);
        expect(function()
            algo.encrypt(test.data, key, buffer.create(0), test.ad);
        end).toThrow(`invalid nonce length (expected size {getsize(nonce)})`);
        local encrypted = algo.encrypt(test.data, key, nonce, test.ad);
        expect(encrypted).toBe(expect.similar({
            cipher = expect.type("buffer"),
            tag = expect.type("buffer"),
        }));
        expect({
            cipher = buffer.tostring(encrypted.cipher),
            tag = buffer.tostring(encrypted.tag),
        }).toBe(expect.similar({
            cipher = test.cipher :: string,
            tag = test.tag :: string,
        }));
        expect(algo.decrypt(encrypted.cipher, encrypted.tag, key, nonce, test.ad)).toBe(test.data);
        if (test.ad) then
            expect(function()
                algo.decrypt(encrypted.cipher, encrypted.tag, key, nonce);
            end).toThrow("AuthenticationFailed");
        else
            expect(function()
                algo.decrypt(encrypted.cipher, encrypted.tag, key, nonce, "\0\0\0\0");
            end).toThrow("AuthenticationFailed");
        end
        expect(function()
            algo.decrypt(encrypted.cipher, "", key, nonce, "\0\0\0\0");
        end).toThrow(`invalid tag length (expected size {getsize(encrypted.tag)})`);
        expect(function()
            algo.decrypt(encrypted.cipher, buffer.create(0), key, nonce, "\0\0\0\0");
        end).toThrow(`invalid tag length (expected size {getsize(encrypted.tag)})`);
        expect(function()
            algo.decrypt(encrypted.cipher, encrypted.tag, "", nonce, "\0\0\0\0");
        end).toThrow(`invalid key length (expected size {getsize(key)})`);
        expect(function()
            algo.decrypt(encrypted.cipher, encrypted.tag, buffer.create(0), nonce, "\0\0\0\0");
        end).toThrow(`invalid key length (expected size {getsize(key)})`);
        expect(function()
            algo.decrypt(encrypted.cipher, encrypted.tag, key, "", "\0\0\0\0");
        end).toThrow(`invalid nonce length (expected size {getsize(nonce)})`);
        expect(function()
            algo.decrypt(encrypted.cipher, encrypted.tag, key, buffer.create(0), "\0\0\0\0");
        end).toThrow(`invalid nonce length (expected size {getsize(nonce)})`);
    end
end

describe("chacha_poly", function()
    describe("ChaCha8Poly1305", function()
        test("Normal", function()
            examine(chacha_poly.ChaCha8Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "<\xB5\x1D7Wf\xAB\xCD.", tag = ".\xC9\xFE}X\xF1z\xBFZytx\xA4\xF6\t\x0F" },
            });
            examine(chacha_poly.ChaCha8Poly1305, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\xB5f\x12)\xF6\xBF\xA5", tag = "\xBBm\xBFF\x15C\x80F\x1E\xD9\x06\xF9\x00\xD6H\xC1" },
            });
        end)
        test("With Associated Data", function()
            examine(chacha_poly.ChaCha8Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "<\xB5\x1D7Wf\xAB\xCD.", tag = "\xB12P9\xA4\x7Fm\xC1y\x1C\xFB\xC6\xC4\xD1'(" },
            });
            examine(chacha_poly.ChaCha8Poly1305, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\xB5f\x12)\xF6\xBF\xA5", tag = ".\xF4\xB3\xBB\xD0\xCCB\xC16W\x19!f\xE5\xE4N" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            examine(chacha_poly.ChaCha8Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xA8\xDB\x94h\xC1\xC9\xB40\xCA", tag = "\x10\xEE\x9A8h\xE3\x0E.\xAD\x14r\xBC\xE0v\xEB\x9E" },
            });
        end)
    end)

    describe("ChaCha12Poly1305", function()
        test("Normal", function()
            examine(chacha_poly.ChaCha12Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "xn\xD2\xA2\xAF<\xBF+\xC1", tag = "\xB3~e\x16\x99H\xD4Ed\a\xC6$\x9C\xB1\x00P" },
            });
            examine(chacha_poly.ChaCha12Poly1305, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\xA5\x96\x88\x17\a<9", tag = " \x11\xAE\xF0\xADX\xBE=~#\x14\xD7,\xE1\xD2\x87" },
            });
        end)
        test("With Associated Data", function()
            examine(chacha_poly.ChaCha12Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "xn\xD2\xA2\xAF<\xBF+\xC1", tag = "\xC7\xD4\vb6\xE5\x95~\x96\x0E\xF0\n\xC35\x93\x92" },
            });
            examine(chacha_poly.ChaCha12Poly1305, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\xA5\x96\x88\x17\a<9", tag = "]\xA6\x88\xE8\xEB\x03\xBE\xE7\xB2\xB3\xD8\xC6\xEB\x03\xD7u" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            examine(chacha_poly.ChaCha12Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="q\xA0\xE6$\vR\x01\x9F\xF3", tag = "{Q6\x10\xAD\x15_+q-&\xE0\xB7\xCDx\xB4" },
            });
        end)
    end)

    describe("ChaCha20Poly1305", function()
        test("Normal", function()
            examine(chacha_poly.ChaCha20Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\xAE\xBC3\x8C/l8\x88\x06", tag = "\x89N\xE0\x17\t\xF7JC\x02\xCFWq\xD0\xE6\v\xBF" },
            });
            examine(chacha_poly.ChaCha20Poly1305, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\xEA\xDF\xE1\x1Ca\xA4\xEF", tag = "\x1F9X\x87?\xD1H\xBCr\x14\xD2i\xE3\x97|\x11" },
            });
        end)
        test("With Associated Data", function()
            examine(chacha_poly.ChaCha20Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xAE\xBC3\x8C/l8\x88\x06", tag = ")\xE2X\xA7\xDA\xE0\x02\xEBj\x93\xC0\x19\xF9\t\x9F\xF7" },
            });
            examine(chacha_poly.ChaCha20Poly1305, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\xEA\xDF\xE1\x1Ca\xA4\xEF", tag = "\xF2\a\xA8|\xE04\n\x9Es\x011\x9B\x99[\x1D\xC9" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            examine(chacha_poly.ChaCha20Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xE5r\x89\xDB~=M\x1B\xED", tag = "\xFF\x17\x020\x04o\xF7OfN\x94t\xDC\xCB|\xD9" },
            });
        end)
    end)

    describe("XChaCha8Poly1305", function()
        test("Normal", function()
            examine(chacha_poly.XChaCha8Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\x87\x9C\x1A\x16\xF4K\x92=U", tag = "\xEE\xAC\x86\x12\xD5\xBE#\xFB\x92 XO!\xDD\xF7\v" },
            });
            examine(chacha_poly.XChaCha8Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = nil, cipher = "U\xA9\x1E\xDB\x10\xA6\xAE", tag = "\xADK:\x11\x19\x1A\xF5\x93vgvh\xCF\xBD\x81\t" },
            });
        end)
        test("With Associated Data", function()
            examine(chacha_poly.XChaCha8Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\x87\x9C\x1A\x16\xF4K\x92=U", tag = "\xE6\xB4\xE6\xD89Tqi\x16\xCC9\xCE\xCF\x0F\xE5\x05" },
            });
            examine(chacha_poly.XChaCha8Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "U\xA9\x1E\xDB\x10\xA6\xAE", tag = "\xC1I\x11|\xD8a\x88\xFE'\xD2\xEAgH*)\xE1" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(24);
            examine(chacha_poly.XChaCha8Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\x8D\x18F?\xD3M\xEA\xCC\x8D", tag = "\xA7<9\x86\xE6\xC5\xA3\x8AI\x1D\x13\x86\xE1\x83\xB0\xAA" },
            });
        end)
    end)

    describe("XChaCha12Poly1305", function()
        test("Normal", function()
            examine(chacha_poly.XChaCha12Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\xE7\xC04i6\xB0\xE4\xE6\x16", tag = "*\xBB\xF9\x12c0\xBD\xC4\xD4\x9CHJ\xAC\xB0\xDDC" },
            });
            examine(chacha_poly.XChaCha12Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = nil, cipher = "\xD2f\f\xC9\xA3\xB1\xCF", tag = "\x0F\xF1\xA5&+\xEB\x90\xE2\x9D\xC6d\xD5\xBF\x92\xA7\xBC" },
            });
        end)
        test("With Associated Data", function()
            examine(chacha_poly.XChaCha12Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xE7\xC04i6\xB0\xE4\xE6\x16", tag = "\x10P\x95\xFD\x81{bo\xD8\xE1\xEAY\xB6\xFABk" },
            });
            examine(chacha_poly.XChaCha12Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\xD2f\f\xC9\xA3\xB1\xCF", tag = "@\xF6\xA7e\xF6\a\x06\xD1T_\x898\xBE\xF9\xD1\xA8" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(24);
            examine(chacha_poly.XChaCha12Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xC3\xA5\x9Ff\xE3Gkb\xA9", tag = "Z\xDD\xF1\xF8\x14\x9A\xCEW\x9B\xB5<\xF8)\xAF\xA6\xF1" },
            });
        end)
    end)

    describe("XChaCha20Poly1305", function()
        test("Normal", function()
            examine(chacha_poly.XChaCha20Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = nil, cipher = "zR\xCE\x13\xA8\x91\xB8<\xF2", tag = "\xA34k\x12\xFEi\xF6\x15&BH\xF9\xD5ut\xD2" },
            });
            examine(chacha_poly.XChaCha20Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = nil, cipher = "n\b\xF8\xE2\xBA\x19\xD3", tag = "\xC7X\xDB}Mn 3\xC1\xAA\x1Fua\xAB\xC9\xFD" },
            });
        end)
        test("With Associated Data", function()
            examine(chacha_poly.XChaCha20Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "zR\xCE\x13\xA8\x91\xB8<\xF2", tag = "zsJ\x1F\xEC\x8Dy\x8B\x9F\xEF\xCC0\xEF\xF8}\xA8" },
            });
            examine(chacha_poly.XChaCha20Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "n\b\xF8\xE2\xBA\x19\xD3", tag = "a\x9C\x82\x85\xA7e4\xDB\x93\xD4\x80c\xC0\xED\xC2?" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(24);
            examine(chacha_poly.XChaCha20Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\x02\xEB\xF8\xEC\xCEL\xF8\x1E\xAC", tag = "U$\xB8\xB9\x9C\x1Bq\x9B\xF7Aj/\xBC\x10`\xAA" },
            });
        end)
    end)
end)

return nil;
