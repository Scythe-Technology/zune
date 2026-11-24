--!strict

local crypto = zune.crypto
local mem = zune.mem

local tar = require("@zune/archive/tar")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("entries", function()
    test("read basic", function()
        -- 493 = 0755
        local archive = tar.write({
            { path = "src/a.txt", mode = 420, data = buffer.fromstring("hello") },
            { path = "bin/tool", mode = 493, data = buffer.fromstring("#!/bin/sh\n") },
        })
        local cursor = tar.iterate(archive)

        local tool = assert(cursor:next())
        expect(tool.path).toBe("bin/tool")
        expect(tool.kind).toBe("file")
        expect(tool.mode).toBe(493)
        expect(tool.size).toBe(10)
        expect(buffer.tostring(tool:bytes())).toBe("#!/bin/sh\n")

        local source = assert(cursor:next())
        expect(source.path).toBe("src/a.txt")
        expect(source.mode).toBe(420)
        expect(buffer.tostring(source:bytes())).toBe("hello")
        expect(cursor:next()).toBeNil()
    end)

    test("prefix", function()
        local path = `{string.rep("a", 10)}/{string.rep("b", 95)}`
        local archive = tar.write({
            { path = path, mode = 420, data = buffer.fromstring("split") },
        })
        local entry = assert(tar.iterate(archive):next())
        expect(entry.path).toBe(path)
        expect(buffer.tostring(entry:bytes())).toBe("split")
    end)

    test("pax", function()
        local path = string.rep("c", 120)
        local archive = tar.write({
            { path = path, mode = 420, data = buffer.fromstring("long") },
            { path = "short.txt", mode = 420, data = buffer.fromstring("ok") },
        })
        local cursor = tar.iterate(archive)
        local long = assert(cursor:next())
        expect(long.path).toBe(path)
        expect(buffer.tostring(long:bytes())).toBe("long")
        local short = assert(cursor:next())
        expect(short.path).toBe("short.txt")
        expect(buffer.tostring(short:bytes())).toBe("ok")
        expect(cursor:next()).toBeNil()
    end)

    test("parent", function()
        local archive = tar.write({
            { path = "../evil.txt", mode = 420, data = buffer.fromstring("x") },
        })
        local entry = assert(tar.iterate(archive):next())
        expect(entry.path).toBe("../evil.txt")
        expect(buffer.tostring(entry:bytes())).toBe("x")
    end)

    test("dir", function()
        local archive = tar.write({
            { path = "src/a.txt", mode = 420, data = buffer.fromstring("hello") },
            { path = "src/", mode = 493, data = buffer.create(0), kind = "dir" },
        })
        local cursor = tar.iterate(archive)
        local directory = assert(cursor:next())
        expect(directory.path).toBe("src/")
        expect(directory.kind).toBe("dir")
        expect(directory.mode).toBe(493)
        expect(buffer.len(directory:bytes())).toBe(0)
        expect(assert(cursor:next()).path).toBe("src/a.txt")
    end)

    test("truncated", function()
        local archive = tar.write({
            { path = "a.txt", mode = 420, data = buffer.fromstring("hello") },
        })
        local cut = mem.slice(archive, 0, 512)
        expect(function()
            tar.iterate(cut)
        end).toThrow("truncated tar")
    end)

    test("write", function()
        local archive = tar.write({
            { path = "b.txt", mode = 420, data = buffer.fromstring("b") },
            { path = "a.txt", mode = 493, data = buffer.fromstring("a") },
            { path = string.rep("c", 120), mode = 420, data = buffer.fromstring("long") },
            {
                path = `{string.rep("p", 10)}/{string.rep("n", 95)}`,
                mode = 420,
                data = buffer.fromstring("split"),
            },
        })
        local hasher = crypto.createHash("blake3")
        hasher:update(archive)
        expect(hasher:digest("hex")).toBe("2f44279d9d6282b7c8da80d53d41797c585f61bc5c4b1989573e6e57f6d6bd1d")
    end)
end)

return nil
