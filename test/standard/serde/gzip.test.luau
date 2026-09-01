--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Gzip", function()
    local sample = string.rep([[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]], 20);
    local compressed_sample_default = "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xC1\r\x800\b\x05\xD0\xBBS\xFC\x01\x8C\x93\xB8DC\x89!)\xA5)t\x7F/\x1E\xEC\x0E\xBC\x01\x1E>\xB7MV\xC8\xF0\xA5\xA8\xD6l\xC2\x25P\x94\xE3\x04Yw\xA6\xE0X\x13\xA5\xCA\x10'\xE9\x0F\xB8I\\\a~2\xC9$\x93L2\xD9\x92\x17=\x87\xB4fd\x05\x00\x00";
    local compressed_sample_fast = "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xD1\t\x800\fE\xD1\x7F\xA7x\x03\x88\x93\xB8DI\x83\x04\xDA\xA64\xE9\xFE*(]\"\xF7\xFF\x1E|\x9D:\xB8B\xBA\xCD\x8A\xACE\aL\x1C\xA9\xB2\xEF m\xC6\xE4\xECs e\xE9b$\xED\x02\x17\xF1c{\xE7\xBF@\x02\t$\x90\xA7@\x16r\x03=\x87\xB4fd\x05\x00\x00";
    local compressed_sample_med = "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xC1\r\x800\b\x05\xD0\xBBS\xFC\x01\x8C\x93\xB8DC\x89!)\xA5)t\x7F/\x1E\xEC\x0E\xBC\x01\x1E>\xB7MV\xC8\xF0\xA5\xA8\xD6l\xC2\x25P\x94\xE3\x04Yw\xA6\xE0X\x13\xA5\xCA\x10'\xE9\x0F\xB8I\\\a~2\xC9$\x93L2\xD9\x92\x17=\x87\xB4fd\x05\x00\x00";

    describe("Compression", function()
        test("Default", function()
            expect(serde.gzip.compress(sample)).toBe(compressed_sample_default);
        end)
        test("Buffer (Default)", function()
            local buf = serde.gzip.compress(buffer.fromstring(sample));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(compressed_sample_default);
        end)
        test("Level 1", function()
            expect(serde.gzip.compress(sample, {level = 1})).toBe(compressed_sample_fast);
        end)
        test("Level 6", function()
            expect(serde.gzip.compress(sample, {level = 6})).toBe(compressed_sample_default);
        end)
        test("Fast", function()
            expect(serde.gzip.compress(sample, {level = 5})).toBe(compressed_sample_med);
        end)
        test("Best", function()
            expect(serde.gzip.compress(sample, {level = 9})).toBe(compressed_sample_default);
        end)
        test("Fail", function()
            expect(function() serde.gzip.compress(sample, {level = 10}) end).toThrow("options 'level' must be between 1 and 9");
            expect(function() serde.gzip.compress(sample, {level = 0}) end).toThrow("options 'level' must be between 1 and 9");
            expect(function() serde.gzip.compress(sample, {level = 14}) end).toThrow("options 'level' must be between 1 and 9");
            expect(function() serde.gzip.compress(true) end).toThrow("invalid argument #1 to 'compress' (string expected, got boolean)");
        end)
    end)

    describe("Decompression", function()
        test("Default", function()
            expect(serde.gzip.decompress(compressed_sample_default)).toBe(sample);
        end)
        test("Buffer (Default)", function()
            local buf = serde.gzip.decompress(buffer.fromstring(compressed_sample_default));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(sample);
        end)
        test("Fast", function()
            expect(serde.gzip.decompress(compressed_sample_fast)).toBe(sample);
        end)
    end)
end)

return nil;
