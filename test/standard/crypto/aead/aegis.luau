--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local aead = crypto.aead;

local aegis = aead.aegis;

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

describe("aegis", function()
    describe("Aegis128X4", function()
        test("Normal", function()
            examine(aegis.Aegis128X4, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "9\xB2\xD7\xD6\x06}>pE", tag = "B\x13r'\xC6\"\x86\xE1\a\xD7\xA0b\xD2\xFB2\xAA" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis128X4, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "#Ne\xCF\x9C\x1F-\xD2\xC4", tag = "\xAF_\xFA'\xAB\xDC\x89\x80\xE9\x1E\xCD${\xD4\xE92" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(aegis.Aegis128X4, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\x81\xD1\xFB\x13>\xBB\xE0\xD9\xFD", tag = "\v\xC8'\x25\xB7\rM\x03\x02u\xA4\x93\x81\xEB\x81\xA8" },
            });
        end)
    end)

    describe("Aegis128X2", function()
        test("Normal", function()
            examine(aegis.Aegis128X2, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\xF5\x86\xD5\x9E\xB68\x86\xE0\xF8", tag = ">?\xAA\xB9\xE5\xB4\x82y\x1C\xF2a\xAA{k\x82\x83" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis128X2, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xA2\xA5\xE4\xD2Y\xFF\xF8\xDF[", tag = "\xA2\x16!\xBA\xE1\xC0l\xAD:\x8A\xDF\xE2\x107\x81\xFD" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(aegis.Aegis128X2, key, nonce, {
                { data = "zune+luau", ad = nil, cipher =")\x12ZV@\xB3\xF0\xD7\xFC", tag = "\x97r4\x17\xAF\xB8b\xDD\xB6\x93Yp\xB6\x91dl" },
            });
        end)
    end)

    describe("Aegis128L", function()
        test("Normal", function()
            examine(aegis.Aegis128L, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\a\x9D\x13\xB9\x8C\x02\x97\xC8\xEC", tag = "\xFB\x1D\xDD<t=\xA4\x25\xEE\x10!\x02\xB4e\xB7\xAE" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis128L, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "F\xA9\xF8\x12,\x94~Q\x19", tag = "5\xFFvm\xE9\xE4'\xA5u\xF3Y\xB8\xBC\x05\xB42" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(aegis.Aegis128L, key, nonce, {
                { data = "zune+luau", ad = nil, cipher =";\xAB\xFEe\x8C\xD9\x91oX", tag = "Q\xBD\x25\xF7C\x0F\xF1\xA5\x17\x91t\x99\x9A\x8B\x9C\x86" },
            });
        end)
    end)

    describe("Aegis256X4", function()
        test("Normal", function()
            examine(aegis.Aegis256X4, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\xD2\xCCY\x13\x03\x1F\xD0\xCB=", tag = "I\xEEX\x91s\x06\xA5W\x94\xAF8\x90C\x0F\x05\x9B" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis256X4, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xCD|f\x8F\x8BV\x11p?", tag = "\xC7V\xFB\x99\x86\x15a\xC1nYR\xCE\xFD\xE2\x92;" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(32);
            examine(aegis.Aegis256X4, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="O\x89Y?\xD9\xD0r\xB9H", tag = "\x13\xBEpn\xEE\x98\x1Cmz\xFC\xB5 \xD5\xD1\x8F\xD4" },
            });
        end)
    end)

    describe("Aegis256X2", function()
        test("Normal", function()
            examine(aegis.Aegis256X2, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\xF6Jb\x8A\xDF\xCC\xFEZ\x02", tag = "\xAE;#\xE5\xF3d\xF2\xC5\x8EZE\x00\xAA0\x1Ak" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis256X2, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xC1\xE1!\xE7\x06P\x95\xB1\xC1", tag = "\xED\x02,\x1E{>\x8E\x00)\x04\xBEVE\x8BJV" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(32);
            examine(aegis.Aegis256X2, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xE6\x99f\x18j\x10W\x95\x12", tag = "\xE8\xD5\x1C_\xC5\x91=>\xA1\xE5\x15\x7F\xB5\x90\xB2L" },
            });
        end)
    end)

    describe("Aegis256", function()
        test("Normal", function()
            examine(aegis.Aegis256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\aP\xE8\xDBv\x94\x83x\xE1", tag = "s\xD9\x9A\xFCu\xBDC\xD0\xBC\x9C\x1C@\xE4F\xE9\x91" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "e\x8C\x9A}\xAB\x91\xE3\xBE\x1C", tag = "+\x80e*\xE0rl:\x06+\t\xD7a\xD1\f\xD9" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(32);
            examine(aegis.Aegis256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xC3\xFAm\xCCl\xEC\x02r\xA2", tag = "\xA3\x9Ag\x84\xEB\xA6if\xE0\x93\xF5t\xD0\xE9sX" },
            });
        end)
    end)

    describe("Aegis128X4_256", function()
        test("Normal", function()
            examine(aegis.Aegis128X4_256, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "9\xB2\xD7\xD6\x06}>pE", tag = "\xC8\xDA\x9D}\xBA\r\xD7\xCF\xA0\xEC\x1B[z\xF76\x15\x8C\xE8\x97\xB6i\x04\xF4,\x90\xBC<\xA2\xBES\x84&" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis128X4_256, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "#Ne\xCF\x9C\x1F-\xD2\xC4", tag = "R\x8E_\x91k_\xA5v\x94\x84N\xDDi\xE2\xE0\xC4\xA4\n=t-X\x10\xB6\xD7>\x01z\xDC\xF4\xA7\xF8" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(aegis.Aegis128X4_256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\x81\xD1\xFB\x13>\xBB\xE0\xD9\xFD", tag = "\xDD:\xDF\x1A\x87\xC2\x88\xFF8t\x1AQ\xD6\xE4\x8D\x14\x82\xFEV\xE6\xEC/\x8B]$\xE3O\xF1\xB8\xA9\x1CN" },
            });
        end)
    end)

    describe("Aegis128X2_256", function()
        test("Normal", function()
            examine(aegis.Aegis128X2_256, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\xF5\x86\xD5\x9E\xB68\x86\xE0\xF8", tag = ".\xB3'`\xE8\xE8\xC2\x87$\xC9\xE4p\x15\xD1\xA1\x16q\x9A\xFD\xDE1\xD4\xA1\xB0\x86\x03\x0FO&\x93\xE9-" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis128X2_256, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xA2\xA5\xE4\xD2Y\xFF\xF8\xDF[", tag = "\xF5\xD2\xD7\xD8\x92\xD9\xBA\x80\x96\xBC\x99\x82\xBA\xD0\xDD\xBA7\x13\x7F+>\xD6\x06Tj\x9Ad.33\xA2\xA9" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(aegis.Aegis128X2_256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher =")\x12ZV@\xB3\xF0\xD7\xFC", tag = "\xA2\f\x1A\x8A\xA74{\xC0h\x19\x85g\x16\n v\xA1\x8E\xD8\xC2\x9E\x1CI\xCF\xACZP\xCA*\xF3h\xB1" },
            });
        end)
    end)

    describe("Aegis128L_256", function()
        test("Normal", function()
            examine(aegis.Aegis128L_256, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\a\x9D\x13\xB9\x8C\x02\x97\xC8\xEC", tag = "\x9C?\x86h\x06\x01\xD8\xCFo\xF9P2\x82\x89Sm\xA1\x0F#\x1C\x97y\x13\xCC`G\xBA\xC8Q'X\a" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis128L_256, "abcdefghijklmnop", "1234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "F\xA9\xF8\x12,\x94~Q\x19", tag = "\xD3\xA1\xD3.\xAE\xD0\x94\xFE\x13\xE2\v\xBDl\xF5\xE9 ]\x14\n\b\xBD\xDE6t\xEAK\x917~\xE2\xD3\xA8" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(16);
            local nonce = buffer.create(16);
            examine(aegis.Aegis128L_256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher =";\xAB\xFEe\x8C\xD9\x91oX", tag = "pP+\x98\x8E\xD9cd\xFF\xBF\xF9b\x97\xA04`\xF2\x7F\x01\xB2\xA1AFrE\xF9\xC94\xA8\x14l\x16" },
            });
        end)
    end)

    describe("Aegis256X4_256", function()
        test("Normal", function()
            examine(aegis.Aegis256X4_256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\xD2\xCCY\x13\x03\x1F\xD0\xCB=", tag = "\xAEG2\r\xA5\xF6\x89\xEC\xFAY\x92`\xFE\x9E\x8C\xDD\xE7\xA9j\x9C\xD6\xF0,\xBBn\xF6\xAA\xF0\xBD\x91\x89F" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis256X4_256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xCD|f\x8F\x8BV\x11p?", tag = "\x13\xB4\xF7-Z\x86\\\x1CGm\x91\xF8JQ?b\xD4\xE2\f\xB4\xDC\x93=\xDD)4\xC36\xB7\xB3\xADY" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(32);
            examine(aegis.Aegis256X4_256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="O\x89Y?\xD9\xD0r\xB9H", tag = "(r5\x1Dn\xBD\x05\x04sP\xAA\x9A\vU\x1D\xC9;\xCCEs\x80\x25\x19i\t\xAC\x1F\xBA\xDE\x84\x92\x1D" },
            });
        end)
    end)

    describe("Aegis256X2_256", function()
        test("Normal", function()
            examine(aegis.Aegis256X2_256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\xF6Jb\x8A\xDF\xCC\xFEZ\x02", tag = "\xA0\xC9\xBEu\xCC\xF2d\x17\xCA\x86\xB5j\x1F\xE7n\x87\x0E\xF2\x9D\x90?\x96\x96\xD2D\xDC\xF0j\xB5\xD7t\xEC" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis256X2_256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "\xC1\xE1!\xE7\x06P\x95\xB1\xC1", tag = "f\xA9\xFDS\xEF\x01\xB3\xF5\\T\xF3\x8BmD\xCB\x1D\x8B\xAB\xD1M\x94?=\xF5uPM\xDD(\xCF\x81K" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(32);
            examine(aegis.Aegis256X2_256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xE6\x99f\x18j\x10W\x95\x12", tag = "\x85\xC4\x06\xCD\xBB\x92\x941\x91e6\xFC9\v\xBB\xEBm\x11\x1A\x92~\x03\xA9\x0F0\x80#\x83\x8C\x9B\t\xA7" },
            });
        end)
    end)

    describe("Aegis256_256", function()
        test("Normal", function()
            examine(aegis.Aegis256_256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = nil, cipher = "\aP\xE8\xDBv\x94\x83x\xE1", tag = "\x8F\x95\x1C\x15T22\x1Cd\x83\x1F\xD6\xD5\xA39\x8D\xFCL\x86\xE9!\x8Fq\xCC\xD8\x1F\x03\x961\xE5\xD0\x1C" },
            });
        end)
        test("With Associated Data", function()
            examine(aegis.Aegis256_256, "abcdefghijklmnopqrstuvwxyz_abcde", "12345678901234561234567890123456", {
                { data = "zune+luau", ad = "Some Associated Data", cipher = "e\x8C\x9A}\xAB\x91\xE3\xBE\x1C", tag = "\x14\xEE]\x96\x05\xE1\xA2|n\xDF\v\xFE\xE4\xE73c?n8\xBC\xE5\x93\xCEFh\xF4\x02)\x856?\xBA" },
            });
        end)
        test("Buffers", function()
            local key = buffer.create(32);
            local nonce = buffer.create(32);
            examine(aegis.Aegis256_256, key, nonce, {
                { data = "zune+luau", ad = nil, cipher ="\xC3\xFAm\xCCl\xEC\x02r\xA2", tag = "<\x117L\xBA\xD7\xEAl\xF6Tg\x1E\xD0\xC8\xB9\x16\x9F\x8BP\xC8Qq\x83\n\x16\xC7\x92j\x00!\xCAN" },
            });
        end)
    end)
end)

return nil;
