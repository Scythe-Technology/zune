--!strict

local mem = zune.mem
local zip = require("@zune/archive/zip")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("entries", function()
    test("stored", function()
        local archive = zip.write({
            { path = "src/a.txt", data = buffer.fromstring("hello") },
        })
        local entry = assert(zip.iterate(archive):next(), "missing entry")
        expect(entry.path).toBe("src/a.txt")
        expect(entry.kind).toBe("file")
        expect(entry.mode).toBe(420)
        expect(entry.method).toBe(0)
        expect(entry.size).toBe(5)
        expect(buffer.tostring(entry:bytes())).toBe("hello")
    end)

    test("dir", function()
        local archive = zip.write({
            { path = "dir/" },
            { path = "win\\" },
        })
        local cursor = zip.iterate(archive)
        local directory = assert(cursor:next(), "missing entry")
        expect(directory.path).toBe("dir/")
        expect(directory.kind).toBe("dir")
        expect(directory.mode).toBe(493)
        expect(buffer.len(directory:bytes())).toBe(0)
        local windows = assert(cursor:next(), "missing entry")
        expect(windows.path).toBe("win\\")
        expect(windows.kind).toBe("dir")
        expect(cursor:next()).toBeNil()
    end)

    test("deflate", function()
        local archive = zip.write({
            { path = "pack.txt", data = buffer.fromstring("123456789"), method = "deflate" },
            { path = "next.txt", data = buffer.fromstring("stored") },
        })
        local cursor = zip.iterate(archive)
        local packed = assert(cursor:next(), "missing entry")
        expect(packed.method).toBe(8)
        expect(packed.size).toBe(9)
        expect(buffer.tostring(packed:bytes())).toBe("123456789")
        local stored = assert(cursor:next(), "missing entry")
        expect(stored.method).toBe(0)
        expect(buffer.tostring(stored:bytes())).toBe("stored")
    end)

    test("parent", function()
        local archive = zip.write({
            { path = "../evil.txt", data = buffer.fromstring("x") },
        })
        local entry = assert(zip.iterate(archive):next(), "missing entry")
        expect(entry.path).toBe("../evil.txt")
        expect(buffer.tostring(entry:bytes())).toBe("x")
    end)

    test("crc", function()
        local archive = zip.write({
            { path = "a.txt", data = buffer.fromstring("123456789") },
        })
        expect(buffer.readu32(archive, 14)).toBe(0xCBF43926)
    end)

    test("missing", function()
        expect(function()
            zip.iterate(buffer.fromstring("nope"))
        end).toThrow("zip directory missing")
    end)

    test("empty", function()
        expect(zip.iterate(zip.write({})):next()).toBeNil()
    end)

    test("spans", function()
        local archive = zip.write({
            { path = "src/a.txt", data = buffer.fromstring("hello") },
        })
        local list = zip.spans(function(offset: number, dest: buffer, count: number)
            if count == 0 then
                return
            end
            buffer.copy(dest, 0, archive, offset, count)
        end, buffer.len(archive))
        expect(#list).toBe(1)
        expect(list[1].path).toBe("src/a.txt")
        expect(list[1].kind).toBe("file")
        expect(list[1].method).toBe(0)
        expect(list[1].size).toBe(5)
        expect(list[1].count).toBe(5)
        expect(buffer.readstring(archive, list[1].at, list[1].count)).toBe("hello")
    end)

    test("zip64", function()
        local name = "a.txt"
        local data = "hi"
        local local_len = 30 + #name
        local extra_len = 28
        local cd_len = 46 + #name + extra_len
        local cd_at = local_len + #data
        local z64_at = cd_at + cd_len
        local loc_at = z64_at + 56
        local eocd_at = loc_at + 20
        local archive = buffer.create(eocd_at + 22)

        buffer.writeu32(archive, 0, 0x04034b50) -- signature
        buffer.writeu16(archive, 26, #name)
        buffer.writestring(archive, 30, name)
        buffer.writestring(archive, local_len, data)

        buffer.writeu32(archive, cd_at, 0x02014b50) -- signature
        buffer.writeu32(archive, cd_at + 20, 0xFFFFFFFF) -- compressed
        buffer.writeu32(archive, cd_at + 24, 0xFFFFFFFF) -- uncompressed
        buffer.writeu16(archive, cd_at + 28, #name)
        buffer.writeu16(archive, cd_at + 30, extra_len)
        buffer.writeu32(archive, cd_at + 42, 0xFFFFFFFF) -- offset
        buffer.writestring(archive, cd_at + 46, name)
        local extra_at = cd_at + 46 + #name
        buffer.writeu16(archive, extra_at, 1)
        buffer.writeu16(archive, extra_at + 2, 24)
        mem.writeu64(archive, extra_at + 4, #data)
        mem.writeu64(archive, extra_at + 12, #data)
        mem.writeu64(archive, extra_at + 20, 0)

        buffer.writeu32(archive, z64_at, 0x06064b50) -- signature
        mem.writeu64(archive, z64_at + 4, 44)
        buffer.writeu16(archive, z64_at + 12, 45)
        buffer.writeu16(archive, z64_at + 14, 45)
        mem.writeu64(archive, z64_at + 24, 1)
        mem.writeu64(archive, z64_at + 32, 1)
        mem.writeu64(archive, z64_at + 40, cd_len)
        mem.writeu64(archive, z64_at + 48, cd_at)

        buffer.writeu32(archive, loc_at, 0x07064b50) -- signature
        mem.writeu64(archive, loc_at + 8, z64_at)
        buffer.writeu32(archive, loc_at + 16, 1)

        buffer.writeu32(archive, eocd_at, 0x06054b50) -- signature
        buffer.writeu16(archive, eocd_at + 10, 0xFFFF) -- count
        buffer.writeu32(archive, eocd_at + 12, 0xFFFFFFFF) -- size
        buffer.writeu32(archive, eocd_at + 16, 0xFFFFFFFF) -- offset

        local entry = assert(zip.iterate(archive):next(), "missing entry")
        expect(entry.path).toBe("a.txt")
        expect(entry.method).toBe(0)
        expect(entry.size).toBe(2)
        expect(buffer.tostring(entry:bytes())).toBe("hi")

        local bare = buffer.create(22)
        buffer.writeu32(bare, 0, 0x06054b50) -- signature
        buffer.writeu32(bare, 16, 0xFFFFFFFF) -- offset
        expect(function()
            zip.iterate(bare)
        end).toThrow("zip64 locator required")
    end)
end)

return nil
