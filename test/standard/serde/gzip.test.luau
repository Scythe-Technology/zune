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
    local compressed_sample_default = "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xC1\r\xC4 \f\x04\xC0\xFFU\xB1\x05\x9CRI\x9A@`E+\x01F\xB6\xE9?\x8F|\x92\x1E<\x05\f\xF08\xD5d\x80\xCB\xF7@\xD3\xAE\x06g\xA0\f\x89?\xAAN\x97\x1A\x12\xDBP\x1A\x17\xBDr^\x90\xCE8~x\xC9$\x93L2\xC9\xE4\x93\xDC=\x87\xB4fd\x05\x00\x00";
    local compressed_sample_fast = "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xB1\r\xC5 \fE\xD1\xFEO\xF1\x06\xF8\xCA$Y\x02\x81\x15=\t0\xB2\xCD\xFE)\x92.+\xF8\xF6\xF7\x00O\xA7\x9A\fp\xF9\x1Eh\xDA\xD5\xE0\f\x94!\xF1G\xD5\xE9RCb\x1BJ\xE3\xA2W\xCE\v\xD2\x19\xC7\xEF\xFD\x13I$\x91D\x12\xF9\"7=\x87\xB4fd\x05\x00\x00";

    describe("Compression", function()
        test("Default", function()
            expect(serde.gzip.compress(sample)).toBe(compressed_sample_default);
        end)
        test("Buffer (Default)", function()
            local buf = serde.gzip.compress(buffer.fromstring(sample));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(compressed_sample_default);
        end)
        test("Level 4", function()
            expect(serde.gzip.compress(sample, {level = 4})).toBe(compressed_sample_fast);
        end)
        test("Level 9", function()
            expect(serde.gzip.compress(sample, {level = 9})).toBe(compressed_sample_default);
        end)
        test("Fast", function()
            expect(serde.gzip.compress(sample, {level = 11})).toBe(compressed_sample_fast);
        end)
        test("Best", function()
            expect(serde.gzip.compress(sample, {level = 13})).toBe(compressed_sample_default);
        end)
        test("Fail", function()
            expect(function() serde.gzip.compress(sample, {level = 10}) end).toThrow("options 'level' cannot be 10, level does not exist");
            expect(function() serde.gzip.compress(sample, {level = 3}) end).toThrow("options 'level' must not be over 13 or less than 4 or equal to 10");
            expect(function() serde.gzip.compress(sample, {level = 14}) end).toThrow("options 'level' must not be over 13 or less than 4 or equal to 10");
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
