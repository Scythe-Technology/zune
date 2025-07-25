--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local aead = crypto.aead;

local aes_gcm = aead.aes_gcm;

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

describe("aes_gcm", function()
    describe("Aes128Gcm", function()
        test("Normal", function()
            examine(aes_gcm.Aes128Gcm, "abcdefghijklmnop", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\xF1L\x8D\xD4MI\xE9\xAC\xFD", tag = "\xDB\x17\x10\xF8\xB6^\x0F\x8C\xBA\fA\xAEZ9\xF0\xA8" },
            });
            examine(aes_gcm.Aes128Gcm, "0000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\xFC\x02sm\x9C\x97\xF8", tag = "\xD74\x90\x9D\xA7\xEC\xD7|y\xFD\xB8\x9A\r\xB3\xDA\xA5" },
            });
        end)
        test("With Associated Data", function()
            examine(aes_gcm.Aes128Gcm, "abcdefghijklmnop", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xF1L\x8D\xD4MI\xE9\xAC\xFD", tag = "\xCC\xBD5e\v`*0\x1C\xAF\xE1\xFB\x99\x0F\x25<" },
            });
            examine(aes_gcm.Aes128Gcm, "0000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\xFC\x02sm\x9C\x97\xF8", tag = "\x8B\x91\xB5\xA52W\xBA\r\xD3\x82\x03\xA3\x15\x11\xCB\xB4" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(12);
            examine(aes_gcm.Aes128Gcm, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="y\xFD\xB4\xABK\xDA\xD6\xF3\x86", tag = "\xD6\xD7\xF8X\x88$q\x86$\xC0V54\x96\xA7<" },
            });
        end)
    end)

    describe("Aes256Gcm", function()
        test("Normal", function()
            examine(aes_gcm.Aes256Gcm, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\x84\x90\xF0\xCA\xDAp\xBF:[", tag = "\xC0K\xFAw[U\xDF\xA5i\xAA!\x8C\xD2\xC7\xF6k" },
            });
            examine(aes_gcm.Aes256Gcm, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\xCB\xCA\xA9E\xCE\xE5\x91", tag = "\xB4\xB6\xF4\x93\xC5\xD6\x18\xDA\xC6y\x90\x0Ey.\xF4\xAC" },
            });
        end)
        test("With Associated Data", function()
            examine(aes_gcm.Aes256Gcm, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\x84\x90\xF0\xCA\xDAp\xBF:[", tag = "\xE0\x11\x98\xB3\xCC\xB8y\xB0\xA0\xB4;\xAF\xADY\xF0\xCE" },
            });
            examine(aes_gcm.Aes256Gcm, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\xCB\xCA\xA9E\xCE\xE5\x91", tag = "\xD3\xB9\xD0\xFF\xFB\xF0\xC8\xD2\x8F\x85O\xFE\xEB\x9C-\xCF" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            examine(aes_gcm.Aes256Gcm, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xB4\xD2.Xf\f\x1E\x0Fr", tag = "9\xC4\xF9h\xB1\xBAOH\n\x04\xB0\x25\x9B\xD8\x86T" },
            });
        end)
    end)
end)

return nil;
