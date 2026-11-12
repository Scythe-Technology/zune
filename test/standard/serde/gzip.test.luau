--!strict
local serde = zune.serde

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("gzip", function()
    local sample = string.rep(
        [[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]],
        20
    )
    local compressed_sample_default =
        "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xC1\r\x800\b\x05\xD0\xBBS\xFC\x01\x8C\x93\xB8DC\x89!)\xA5)t\x7F/\x1E\xEC\x0E\xBC\x01\x1E>\xB7MV\xC8\xF0\xA5\xA8\xD6l\xC2\x25P\x94\xE3\x04Yw\xA6\xE0X\x13\xA5\xCA\x10'\xE9\x0F\xB8I\\\a~2\xC9$\x93L2\xD9\x92\x17=\x87\xB4fd\x05\x00\x00"
    local compressed_sample_fast =
        '\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xD1\t\x800\fE\xD1\x7F\xA7x\x03\x88\x93\xB8DI\x83\x04\xDA\xA64\xE9\xFE*(]"\xF7\xFF\x1E|\x9D:\xB8B\xBA\xCD\x8A\xACE\aL\x1C\xA9\xB2\xEF m\xC6\xE4\xECs e\xE9b$\xED\x02\x17\xF1c{\xE7\xBF@\x02\t$\x90\xA7@\x16r\x03=\x87\xB4fd\x05\x00\x00'
    local compressed_sample_med =
        "\x1F\x8B\b\x00\x00\x00\x00\x00\x00\x03\xED\xCC\xC1\r\x800\b\x05\xD0\xBBS\xFC\x01\x8C\x93\xB8DC\x89!)\xA5)t\x7F/\x1E\xEC\x0E\xBC\x01\x1E>\xB7MV\xC8\xF0\xA5\xA8\xD6l\xC2\x25P\x94\xE3\x04Yw\xA6\xE0X\x13\xA5\xCA\x10'\xE9\x0F\xB8I\\\a~2\xC9$\x93L2\xD9\x92\x17=\x87\xB4fd\x05\x00\x00"

    local function compress(src: string | buffer, lvl: number?): string
        local len = if type(src) == "string" then #src else buffer.len(src)
        local dest = buffer.create(serde.gzip.calcSize(len))
        local n = if lvl == nil
            then serde.gzip.compress(dest, 0, src, 0)
            else serde.gzip.compress(dest, 0, src, 0, nil, lvl)
        return buffer.readstring(dest, 0, n)
    end

    local function decompress(src: string | buffer): string
        local dest = buffer.create(#sample)
        local n = serde.gzip.decompress(dest, 0, src, 0)
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
            expect(compress(sample, 1)).toBe(compressed_sample_fast)
        end)
        test("level 6", function()
            expect(compress(sample, 6)).toBe(compressed_sample_default)
        end)
        test("fast", function()
            expect(compress(sample, 5)).toBe(compressed_sample_med)
        end)
        test("best", function()
            expect(compress(sample, 9)).toBe(compressed_sample_default)
        end)
        test("portion", function()
            local src = ">>" .. sample
            local dest = buffer.create(4 + serde.gzip.calcSize(#sample))
            local n = serde.gzip.compress(dest, 4, src, 2, #sample)
            expect(buffer.readstring(dest, 4, n)).toBe(compressed_sample_default)
        end)
        test("fail", function()
            local dest = buffer.create(serde.gzip.calcSize(#sample))
            expect(function()
                serde.gzip.compress(dest, 0, sample, 0, nil, 10)
            end).toThrow("options 'level' must be between 1 and 9")
            expect(function()
                serde.gzip.compress(dest, 0, sample, 0, nil, 0)
            end).toThrow("options 'level' must be between 1 and 9")
            expect(function()
                serde.gzip.compress(dest, 0, sample, 0, nil, 14)
            end).toThrow("options 'level' must be between 1 and 9")
            expect(function()
                serde.gzip.compress(true :: any, 0, sample, 0)
            end).toThrow("expected a buffer or userdata")
            expect(function()
                serde.gzip.compress(buffer.create(4), 0, sample, 0)
            end).toThrow("no space")
            expect(function()
                serde.gzip.compress(dest, 0, sample, #sample, 1)
            end).toThrow("access out of bounds")
        end)
    end)

    describe("decompression", function()
        test("default", function()
            expect(decompress(compressed_sample_default)).toBe(sample)
        end)
        test("buffer (default)", function()
            expect(decompress(buffer.fromstring(compressed_sample_default))).toBe(sample)
        end)
        test("fast", function()
            expect(decompress(compressed_sample_fast)).toBe(sample)
        end)
        test("no space", function()
            expect(function()
                serde.gzip.decompress(buffer.create(4), 0, compressed_sample_default, 0)
            end).toThrow("no space")
        end)
    end)
end)

return nil
