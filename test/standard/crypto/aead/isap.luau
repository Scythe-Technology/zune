--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local aead = crypto.aead;

local isap = aead.isap;

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

describe("isap", function()
    describe("IsapA128A", function()
        test("Normal", function()
            examine(isap.IsapA128A, "abcdefghijklmnop", "1234567890121234", {
                { data = "zune+luau", ad = nil, cipher = "|\x19oh\xC0\xC9hY\xE6", tag = "\xEF\x9D\x17\xE6\xA4\xBD\xF3)\xF4\x8B\xFC}\x8Cy\x1Ds" },
            });
            examine(isap.IsapA128A, "0000000000000000", "0000000000000000", {
                { data = "runtime", ad = nil, cipher = "\x95d\x86\xA2y\xFA\xA3", tag = "*\xC4\x94\xCD\xE4\x98\x99\x9D\xE3\xB1\xCE\x0F\x9D\x95\xC0\xC4" },
            });
        end)
        test("With Associated Data", function()
            examine(isap.IsapA128A, "abcdefghijklmnop", "1234567890121234", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "|\x19oh\xC0\xC9hY\xE6", tag = "\f\xBD\xDA\xE3 \x91\xA3\x15\x12\xD3\xACj\xE8\x89X#" },
            });
            examine(isap.IsapA128A, "0000000000000000", "0000000000000000", {
                { data = "runtime", ad = "Some Associated Data", cipher = "\x95d\x86\xA2y\xFA\xA3", tag = "\xE0\x9F\x85\xD0\xE51\xA2\xF3\xFB\x19\x16S{j\xD5\x19" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(isap.IsapA128A, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\x83`\x93vd\xD9\xF57\x82", tag = "\x25\x03\xA7\xF2\xBC<\x1D\xB1lgon\t5\xEB`" },
            });
        end)
    end)
end)

return nil;
