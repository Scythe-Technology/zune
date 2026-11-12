--!strict
local serde = zune.serde

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("lz4", function()
    local sample = string.rep(
        [[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]],
        20
    )

    local function srcLen(src: string | buffer): number
        return if type(src) == "string" then #src else buffer.len(src)
    end

    local function compress(src: string | buffer): string
        local dest = buffer.create(serde.lz4.calcSize(srcLen(src)))
        local n = serde.lz4.compress(dest, 0, src, 0)
        return buffer.readstring(dest, 0, n)
    end

    local function decompress(src: string | buffer): string
        local dest = buffer.create(#sample)
        local n = serde.lz4.decompress(dest, 0, src, 0)
        return buffer.readstring(dest, 0, n)
    end

    local function compressFrame(src: string | buffer, lvl: number?): string
        local dest = buffer.create(serde.lz4.calcFrameSize(srcLen(src)))
        local n = if lvl == nil
            then serde.lz4.compressFrame(dest, 0, src, 0)
            else serde.lz4.compressFrame(dest, 0, src, 0, nil, lvl)
        return buffer.readstring(dest, 0, n)
    end

    local function decompressFrame(src: string | buffer): string
        local view = if type(src) == "string" then buffer.fromstring(src) else src
        local dest = buffer.create(buffer.readu32(view, 0))
        local n = serde.lz4.decompressFrame(dest, 0, src, 0)
        return buffer.readstring(dest, 0, n)
    end

    describe("standard", function()
        local compressed_sample_default =
            "\x13 \x01\x00\xF3*Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n@\x00\x01\x02\x00\x0FE\x00\xFF\xFF\xFF\xFF\xFF\x04P\n    "

        describe("compression", function()
            test("default", function()
                expect(compress(sample)).toBe(compressed_sample_default)
            end)
            test("buffer (default)", function()
                expect(compress(buffer.fromstring(sample))).toBe(compressed_sample_default)
            end)
            test("portion", function()
                local src = ">>" .. sample
                local dest = buffer.create(4 + serde.lz4.calcSize(#sample))
                local n = serde.lz4.compress(dest, 4, src, 2, #sample)
                expect(buffer.readstring(dest, 4, n)).toBe(compressed_sample_default)
            end)
            test("fail", function()
                local dest = buffer.create(serde.lz4.calcSize(#sample))
                expect(function()
                    serde.lz4.compress(true :: any, 0, sample, 0)
                end).toThrow("expected a buffer or userdata")
                expect(function()
                    serde.lz4.compress(buffer.create(4), 0, sample, 0)
                end).toThrow("no space")
                expect(function()
                    serde.lz4.compress(dest, 0, sample, #sample, 1)
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
            test("fail", function()
                expect(function()
                    serde.lz4.decompress(buffer.create(4), 0, "\x01\x00\x00", 0)
                end).toThrow("Failed")
            end)
        end)
    end)

    describe("frame", function()
        local compressed_sample_default =
            'd\x05\x00\x00\x04"M\x18d@\xA7P\x00\x00\x00\x13 \x01\x00\xF4*Lorem ipsum dolor sit amet, consectetur adipiscing elit.\nA\x00\x0FE\x00\xFF\xFF\xFF\xFF\xFF\bP\n    \x00\x00\x00\x00\xC0rE3'
        local compressed_sample_level0 =
            'd\x05\x00\x00\x04"M\x18d@\xA7S\x00\x00\x00\x13 \x01\x00\xF3*Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n@\x00\x01\x02\x00\x0FE\x00\xFF\xFF\xFF\xFF\xFF\x04P\n    \x00\x00\x00\x00\xC0rE3'

        describe("compression", function()
            test("default", function()
                expect(compressFrame(sample)).toBe(compressed_sample_default)
            end)
            test("buffer (default)", function()
                expect(compressFrame(buffer.fromstring(sample))).toBe(compressed_sample_default)
            end)
            test("level 0", function()
                expect(compressFrame(sample, 0)).toBe(compressed_sample_level0)
            end)
            test("level 1", function()
                expect(compressFrame(sample, 1)).toBe(compressed_sample_level0)
            end)
            test("level 10", function()
                expect(compressFrame(sample, 10)).toBe(compressed_sample_default)
            end)
            test("level 50", function()
                expect(compressFrame(sample, 50)).toBe(compressed_sample_default)
            end)
            test("level 100", function()
                expect(compressFrame(sample, 100)).toBe(compressed_sample_default)
            end)
            test("level 1000", function()
                expect(compressFrame(sample, 1000)).toBe(compressed_sample_default)
            end)
            test("portion", function()
                local src = ">>" .. sample
                local dest = buffer.create(4 + serde.lz4.calcFrameSize(#sample))
                local n = serde.lz4.compressFrame(dest, 4, src, 2, #sample)
                expect(buffer.readstring(dest, 4, n)).toBe(compressed_sample_default)
            end)
            test("fail", function()
                local dest = buffer.create(serde.lz4.calcFrameSize(#sample))
                expect(function()
                    serde.lz4.compressFrame(dest, 0, sample, 0, nil, -1)
                end).toThrow("options 'level' must not be less than 0")
                expect(function()
                    serde.lz4.compressFrame(true :: any, 0, sample, 0)
                end).toThrow("expected a buffer or userdata")
                expect(function()
                    serde.lz4.compressFrame(buffer.create(4), 0, sample, 0)
                end).toThrow("no space")
                expect(function()
                    serde.lz4.compressFrame(dest, 0, sample, #sample, 1)
                end).toThrow("access out of bounds")
            end)
        end)

        describe("decompression", function()
            test("default", function()
                expect(decompressFrame(compressed_sample_default)).toBe(sample)
            end)
            test("buffer (default)", function()
                expect(decompressFrame(buffer.fromstring(compressed_sample_default))).toBe(sample)
            end)
            test("level 0", function()
                expect(decompressFrame(compressed_sample_level0)).toBe(sample)
            end)
            test("no space", function()
                expect(function()
                    serde.lz4.decompressFrame(buffer.create(4), 0, compressed_sample_default, 0)
                end).toThrow("no space")
            end)
            test("fail", function()
                expect(function()
                    serde.lz4.decompressFrame(buffer.create(4), 0, "\x01\x00\x00", 0)
                end).toThrow("invalid header")
            end)
        end)
    end)
end)

return nil
