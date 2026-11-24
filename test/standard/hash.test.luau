--!strict

local hash = zune.hash

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local ISO = 3421780262

describe("hash", function()
    test("crc32", function()
        expect(hash.crc32("")).toBe(0)
        expect(hash.crc32("a")).toBe(3904355907)
        expect(hash.crc32("123456789")).toBe(ISO)
        expect(hash.crc32(buffer.fromstring("123456789"))).toBe(ISO)

        local part = hash.crc32("12345")
        expect(part).toBe(3421846044)
        expect(hash.crc32("6789", part)).toBe(ISO)
        expect(hash.crc32("123456789", 0)).toBe(ISO)
        expect(hash.crc32("", ISO)).toBe(ISO)

        local raw = buffer.create(3)
        buffer.writeu8(raw, 0, 97) -- 'a'
        buffer.writeu8(raw, 1, 0)
        buffer.writeu8(raw, 2, 98) -- 'b'
        expect(hash.crc32(raw)).toBe(367556721)
        expect(hash.crc32("a\0b")).toBe(367556721)
    end)

    test("crc32c", function()
        expect(hash.crc32c("")).toBe(0)
        expect(hash.crc32c("123456789")).toBe(3808858755)
        local part = hash.crc32c("12345")
        expect(part).toBe(416359221)
        expect(hash.crc32c("6789", part)).toBe(3808858755)
        expect(hash.crc32c("123456789", 0)).toBe(3808858755)
        expect(hash.crc32c("a\0b")).toBe(1677306204)
    end)

    test("adler32", function()
        expect(hash.adler32("")).toBe(1)
        expect(hash.adler32("123456789")).toBe(152961502)
        expect(hash.adler32("123456789", 1)).toBe(152961502)
        local part = hash.adler32("12345")
        expect(part).toBe(49807616)
        expect(hash.adler32("6789", part)).toBe(152961502)
        expect(hash.adler32("a\0b")).toBe(25690308)
    end)

    test("fnv1a32", function()
        expect(hash.fnv1a32("")).toBe(2166136261)
        expect(hash.fnv1a32("123456789")).toBe(3146166556)
        expect(hash.fnv1a32("123456789", 2166136261)).toBe(3146166556)
        local part = hash.fnv1a32("12345")
        expect(part).toBe(1136836824)
        expect(hash.fnv1a32("6789", part)).toBe(3146166556)
    end)

    test("xxhash32", function()
        expect(hash.xxhash32("")).toBe(46947589)
        expect(hash.xxhash32("123456789")).toBe(2474356071)
        expect(hash.xxhash32("123456789", 0)).toBe(2474356071)
        expect(hash.xxhash32("123456789", 1)).toBe(4066480524)
    end)

    test("murmur32", function()
        expect(hash.murmur32("")).toBe(0)
        expect(hash.murmur32("a")).toBe(1009084850)
        expect(hash.murmur32("123456789")).toBe(3036607362)
        expect(hash.murmur32("123456789", 0)).toBe(3036607362)
        expect(hash.murmur32("123456789", 1)).toBe(1422972671)
    end)

    test("cityhash32", function()
        expect(hash.cityhash32("")).toBe(3696677242)
        expect(hash.cityhash32("a")).toBe(1016544589)
        expect(hash.cityhash32("123456789")).toBe(4170107472)
        expect(hash.cityhash32(buffer.fromstring("123456789"))).toBe(4170107472)
    end)

    test("range", function()
        expect(function()
            hash.fnv1a32("123456789", "0" :: any)
        end).toThrow("bad sum, argument #2 to 'fnv1a32' (number expected, got string)")
        expect(function()
            hash.murmur32(1 :: any, nil)
        end).toThrow("invalid argument #1 to 'murmur32' (string expected, got number)")
    end)
end)

return nil
