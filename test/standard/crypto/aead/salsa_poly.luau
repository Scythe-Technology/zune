--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local aead = crypto.aead;

local salsa_poly = aead.salsa_poly;

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

describe("salsa_poly", function()
    describe("XSalsa20Poly1305", function()
        test("Normal", function()
            examine(salsa_poly.XSalsa20Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = nil, cipher = "\x8BK\xC1\xE4\x93\xE2P\xA4\xD6", tag = ">C\x8B\xEBh\x8A^\x97L\x86\f^\xA0q\xA9\x82" },
            });
            examine(salsa_poly.XSalsa20Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = nil, cipher = "\x14-\x95\xC2\xCE\xF0\xCF", tag = "\xA6[a\xA1pT\x03\"\xC5~\x18E\xA4\x00Z\x06" },
            });
        end)
        test("With Associated Data", function()
            examine(salsa_poly.XSalsa20Poly1305, "abcdefghijklmnopqrstuvwxyz_abcde", "123456789012123456789012", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\x8BK\xC1\xE4\x93\xE2P\xA4\xD6", tag = "\xE8\xF8\xEC$\xB2O\xE1\x10[M\xEE\xEB\xB2\x15^Z" },
            });
            examine(salsa_poly.XSalsa20Poly1305, "00000000000000000000000000000000", "000000000000000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\x14-\x95\xC2\xCE\xF0\xCF", tag = "\xCF\x8CE\xD6j\xBC>\xB0\xACK|\xC5p9\xF8\xEF" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(24);
            examine(salsa_poly.XSalsa20Poly1305, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xBCK\xD5\x9A\xD5\xE9\xBBM\x9E", tag = "\x1B\xB9\xCDeNBh\x16-\x87\x06q\x04\x11\xCC>" },
            });
        end)
    end)
end)

return nil;
