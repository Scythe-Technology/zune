--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Brotli", function()
    local sample = string.rep([[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]], 20);
    local compressed_sample_default = "\x1Bc\x05\xF8\x8D\x93\xE5\x8A\xD3\xA0\x95 \nL\xBA\xCD\xEB\x95?:\x7F\xB1\x11\x83\xAC\xC8\x95\x8D\fdb\"@\x05:\xA8\xCFC\x1Ao\xFD|~fS\x94yBM\x9C]\bA\xFF\x99\x0F^VpO\xC3\xA2z\x10";

    describe("Compression", function()
        test("Default", function()
            expect(serde.brotli.compress(sample)).toBe(compressed_sample_default);
        end)
        test("Buffer (Default)", function()
            local buf = serde.brotli.compress(buffer.fromstring(sample));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(compressed_sample_default);
        end)
        test("Fail", function()
            expect(function() serde.brotli.compress(true) end).toThrow("invalid argument #1 to 'compress' (string expected, got boolean)");
        end)
    end)

    describe("Decompression", function()
        test("Default", function()
            expect(serde.brotli.decompress(compressed_sample_default)).toBe(sample);
        end)
        test("Buffer (Default)", function()
            local buf = serde.brotli.decompress(buffer.fromstring(compressed_sample_default));
            expect(buf).toBe(expect.type("buffer"));
            expect(buffer.tostring(buf)).toBe(sample);
        end)
    end)
end)

return nil;
