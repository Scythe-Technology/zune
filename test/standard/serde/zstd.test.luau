--!strict
local serde = zune.serde

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("zstd", function()
    local sample = string.rep(
        [[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]],
        20
    )
    local compressed_sample_default =
        "(\xB5/\xFD`d\x04M\x02\x00\xC4\x03  Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11b\x00\v"
    local compressed_sample_1 =
        "(\xB5/\xFD`d\x04M\x02\x00\xC4\x03  Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11b\x00\v"
    local compressed_sample_6 =
        "(\xB5/\xFD`d\x04E\x02\x00\xB4\x03 Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11p\x1D\x1B"
    local compressed_sample_10 =
        "(\xB5/\xFD`d\x04M\x02\x00\xC4\x03  Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n \x03\x00\x14!\xE1\x03\x05\x11b\x00\v"
    local compressed_sample_22 =
        "(\xB5/\xFD`d\x04\xED\x01\x00\xE2C\f\x10\xB0k\f\xB2\xB7L\x90\x8D\xD8\x83\x8Es\xD1\xBCE\f\xFF@,\xA2\xFB(,\x8A\v\r\x99\xB5\xBD-\xA7*\xCBa/\x91\x17u\x96(\xCD\xA9\xE9\xC2\xD3\xB1\x1C\a\x02\x00\xCD\x11\x12>\xB8\x80\r"

    local function compress(src: string | buffer, lvl: number?): string
        local len = if type(src) == "string" then #src else buffer.len(src)
        local dest = buffer.create(serde.zstd.calcSize(len))
        local n = if lvl == nil
            then serde.zstd.compress(dest, 0, src, 0)
            else serde.zstd.compress(dest, 0, src, 0, nil, lvl)
        return buffer.readstring(dest, 0, n)
    end

    local function decompress(src: string | buffer): string
        local dest = buffer.create(#sample)
        local n = serde.zstd.decompress(dest, 0, src, 0)
        return buffer.readstring(dest, 0, n)
    end

    describe("compression", function()
        test("default", function()
            expect(compress(sample)).toBe(compressed_sample_default)
        end)
        test("buffer (default)", function()
            expect(compress(buffer.fromstring(sample))).toBe(compressed_sample_default)
        end)
        test("level 1", function()
            expect(compress(sample, 1)).toBe(compressed_sample_1)
        end)
        test("level 6", function()
            expect(compress(sample, 6)).toBe(compressed_sample_6)
        end)
        test("level 10", function()
            expect(compress(sample, 10)).toBe(compressed_sample_10)
        end)
        test("level 22", function()
            expect(compress(sample, 22)).toBe(compressed_sample_22)
        end)
        test("fail", function()
            local dest = buffer.create(serde.zstd.calcSize(#sample))
            expect(function()
                serde.zstd.compress(dest, 0, sample, 0, nil, 23)
            end).toThrow("options 'level' must not be over 22 or less than -131072")
            expect(function()
                serde.zstd.compress(dest, 0, sample, 0, nil, -131073)
            end).toThrow("options 'level' must not be over 22 or less than -131072")
            expect(function()
                serde.zstd.compress(true :: any, 0, sample, 0)
            end).toThrow("expected a buffer or userdata")
            expect(function()
                serde.zstd.compress(buffer.create(4), 0, sample, 0)
            end).toThrow("no space")
        end)
    end)

    describe("decompression", function()
        test("default", function()
            expect(decompress(compressed_sample_default)).toBe(sample)
        end)
        test("buffer (default)", function()
            expect(decompress(buffer.fromstring(compressed_sample_default))).toBe(sample)
        end)
        test("level 1", function()
            expect(decompress(compressed_sample_1)).toBe(sample)
        end)
        test("level 6", function()
            expect(decompress(compressed_sample_6)).toBe(sample)
        end)
        test("level 10", function()
            expect(decompress(compressed_sample_10)).toBe(sample)
        end)
        test("level 22", function()
            expect(decompress(compressed_sample_22)).toBe(sample)
        end)
        test("fail", function()
            expect(function()
                serde.zstd.decompress(buffer.create(#sample), 0, buffer.create(20), 0)
            end).toThrow("UnknownPrefix")
        end)
    end)
end)

return nil
