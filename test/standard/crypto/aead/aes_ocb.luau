--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local aead = crypto.aead;

local aes_ocb = aead.aes_ocb;

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

describe("aes_ocb", function()
    describe("Aes128Ocb", function()
        test("Normal", function()
            examine(aes_ocb.Aes128Ocb, "abcdefghijklmnop", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\x8E,1\x95\xDF\xE8\xE6\x8A^", tag = "\xF6\n\xDE\xD0\x89\x03\xB4\x8F\xC9\x18R\x9B]\xE7\x99\xC9" },
            });
            examine(aes_ocb.Aes128Ocb, "0000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\x02o\xA8pI+\xCA", tag = "\x87\xB4\aCt@\xC1\xC4\xAC\xD5\xECo\xBF\x91\x1C\x97" },
            });
        end)
        test("With Associated Data", function()
            examine(aes_ocb.Aes128Ocb, "abcdefghijklmnop", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\x8E,1\x95\xDF\xE8\xE6\x8A^", tag = "1\xA4\xD5\xFD\xB1Vh\xA4\xFB\x8A\xBC\xF1\xDF\xCDC\x1B" },
            });
            examine(aes_ocb.Aes128Ocb, "0000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\x02o\xA8pI+\xCA", tag = "\xB3G\x01\x97\x99\xC9\x18\x82K\xF9\xE4W\x19@\x99\x1A" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(12);
            examine(aes_ocb.Aes128Ocb, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\x01\xA7nyM\xA6\x12<\xD5", tag = "\xC1\n\x89[\xEA\xB4\xA6\x92\xB8\xE0\r:\x15x2\x00" },
            });
        end)
    end)

    describe("Aes256Ocb", function()
        test("Normal", function()
            examine(aes_ocb.Aes256Ocb, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\xA5\xF9\xF4\x056\x1A\xCD\xD2\xA5", tag = "\x9B\xBD\xB0\xF7C\x1C\xC6\x8DZ\xCE\n\xA7\xC9\xC1\xDA\xC4" },
            });
            examine(aes_ocb.Aes256Ocb, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = nil, cipher = "\b\a\xA0\x05$\xC2\\", tag = "\xA8&\xF4\xED\x1B\x1C\xCFR\xE5\xEF\x17:Q\t\x88\xFB" },
            });
        end)
        test("With Associated Data", function()
            examine(aes_ocb.Aes256Ocb, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xA5\xF9\xF4\x056\x1A\xCD\xD2\xA5", tag = "\xEB$\xCB0\\\xE9\x9B\x9C\n\xCBu\x18\xBF\x9B\xA9\xCF" },
            });
            examine(aes_ocb.Aes256Ocb, "00000000000000000000000000000000", "000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\b\a\xA0\x05$\xC2\\", tag = "3(a\xEC\xF2\r\x19\xA9\xCBo\xFFx\xB4@\xFB\xB8" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(12);
            examine(aes_ocb.Aes256Ocb, key, nonce, {
                { data = "zune+luau", ad = nil, cipher =":\x82\x04\xCCh\x98\xD3\xBF\x8D", tag = "T\xD3\xFC\x0E\xC2I!$\x87 \xFA\xC9\xA4\xA2H\x00" },
            });
        end)
    end)
end)

return nil;
