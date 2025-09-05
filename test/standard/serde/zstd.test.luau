--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Zlib", function()
    local sample = string.rep([[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]], 20);
    local compressed_sample_default = "(\xB5/\xFD`d\x04M\x02\x00\xC4\x03  Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11b\x00\v";
    local compressed_sample_1 = "(\xB5/\xFD`d\x04M\x02\x00\xC4\x03  Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11b\x00\v";
    local compressed_sample_6 = "(\xB5/\xFD`d\x04E\x02\x00\xB4\x03 Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11p\x1D\x1B";
    local compressed_sample_10 = "(\xB5/\xFD`d\x04M\x02\x00\xC4\x03  Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11b\x00\v";
    local compressed_sample_22 = "(\xB5/\xFD`d\x04\xED\x01\x00\xE2C\f\x10\xB0k\f\xB2\xB7L\x90\x8D\xD8\x83\x8Es\xD1\xBCE\f\xFF@,\xA2\xFB(,\x8A\v\r\x99\xB5\xBD-\xA7*\xCBa/\x91\x17u\x96(\xCD\xA9\xE9\xC2\xD3\xB1\x1C\a\x02\x00\xCD\x11\x12>\xB8\x80\r";

    describe("Compression", function()
        test("Default", function()
            expect(serde.zstd.compress(sample)).toBe(compressed_sample_default);
        end)
        test("Buffer (Default)", function()
            local buf = serde.zstd.compress(buffer.fromstring(sample));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(compressed_sample_default);
        end)
        test("Level 1", function()
            expect(serde.zstd.compress(sample, {level = 1})).toBe(compressed_sample_1);
        end)
        test("Level 6", function()
            expect(serde.zstd.compress(sample, {level = 6})).toBe(compressed_sample_6);
        end)
        test("Level 10", function()
            expect(serde.zstd.compress(sample, {level = 10})).toBe(compressed_sample_10);
        end)
        test("Level 22", function()
            expect(serde.zstd.compress(sample, {level = 22})).toBe(compressed_sample_22);
        end)
        test("Fail", function()
            expect(function() serde.zstd.compress(sample, {level = 23}) end).toThrow("options 'level' must not be over 22 or less than -131072");
            expect(function() serde.zstd.compress(sample, {level = -131073}) end).toThrow("options 'level' must not be over 22 or less than -131072");
            expect(function() serde.zstd.compress(true) end).toThrow("invalid argument #1 to 'compress' (string expected, got boolean)");
        end)
    end)

    describe("Decompression", function()
        test("Default", function()
            expect(serde.zstd.decompress(compressed_sample_default)).toBe(sample);
        end)
        test("Buffer (Default)", function()
            local buf = serde.zstd.decompress(buffer.fromstring(compressed_sample_default));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(sample);
        end)
        test("Level 1", function()
            expect(serde.zstd.decompress(compressed_sample_1)).toBe(sample);
        end)
        test("Level 6", function()
            expect(serde.zstd.decompress(compressed_sample_6)).toBe(sample);
        end)
        test("Level 10", function()
            expect(serde.zstd.decompress(compressed_sample_10)).toBe(sample);
        end)
        test("Level 22", function()
            expect(serde.zstd.decompress(compressed_sample_22)).toBe(sample);
        end)
        test("Fail", function()
            expect(function() serde.zstd.decompress(buffer.create(20)) end).toThrow("UnknownPrefix");
        end)
    end)
end)

return nil;
