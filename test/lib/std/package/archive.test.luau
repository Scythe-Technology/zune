--!strict

local fs = require("@zune/fs")
local tar = require("@zune/archive/tar")
local zip = require("@zune/archive/zip")
local archive = require("@zune/package/archive")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local TEMP_DIR = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")

local function file(path: string, data: string): tar.File
    return {
        path = path,
        mode = 420,
        data = buffer.fromstring(data),
    }
end

local function read(dir: string, name: string): string?
    local path = fs.path.join(dir, name)
    if fs.stat(path).kind ~= "file" then
        return nil
    end
    return fs.readFile(path)
end

describe("unpack", function()
    test("file", function()
        local dest = `{TEMP_DIR}/pkg-archive-file`
        local packed = `{TEMP_DIR}/pkg-archive-file.tar`
        fs.writeFile(
            packed,
            tar.write({
                file("pkg/a.txt", "A"),
                file("pkg/b.txt", "B"),
            })
        )
        local count = archive.unpackFile(packed, dest)
        expect(count).toBe(2)
        expect(read(dest, "a.txt")).toBe("A")
        expect(read(dest, "b.txt")).toBe("B")
        expect(read(dest, "pkg/a.txt")).toBeNil()
    end)

    test("empty", function()
        local dest = `{TEMP_DIR}/pkg-archive-empty`
        local packed = `{TEMP_DIR}/pkg-archive-empty.tar`
        fs.writeFile(packed, tar.write({ file("pkg/a.txt", "") }))
        expect(archive.unpackFile(packed, dest)).toBe(1)
        expect(read(dest, "a.txt")).toBe("")
    end)

    test("truncated", function()
        local packed = `{TEMP_DIR}/pkg-archive-cut.tar`
        local blob = tar.write({ file("pkg/a.txt", "hello") })
        local cut = buffer.create(512)
        buffer.copy(cut, 0, blob, 0, 512)
        fs.writeFile(packed, cut)
        expect(function()
            archive.unpackFile(packed, `{TEMP_DIR}/pkg-archive-cut`)
        end).toThrow("truncated tar")
    end)

    test("strip", function()
        local dest = `{TEMP_DIR}/pkg-archive-strip`
        local count = archive.unpack(
            tar.write({
                file("pkg/a.txt", "A"),
                file("pkg/./nested/../b.txt", "B"),
            }),
            dest
        )
        expect(count).toBe(2)
        expect(read(dest, "a.txt")).toBe("A")
        expect(read(dest, "b.txt")).toBe("B")
        expect(read(dest, "pkg/a.txt")).toBeNil()
    end)

    test("filter", function()
        local blob = tar.write({
            file("pkg/a.txt", "A"),
            file("pkg/b.txt", "B"),
            file("pkg/lib/c.txt", "C"),
        })

        local picked = `{TEMP_DIR}/pkg-archive-filter`
        expect(archive.unpack(blob, picked, { paths = { "a.txt", "lib/*.txt" } })).toBe(2)
        expect(read(picked, "a.txt")).toBe("A")
        expect(read(picked, "b.txt")).toBeNil()
        expect(read(picked, "lib/c.txt")).toBe("C")

        local prefix = `{TEMP_DIR}/pkg-archive-prefix`
        expect(archive.unpack(blob, prefix, { paths = { "lib" } })).toBe(1)
        expect(read(prefix, "lib/c.txt")).toBe("C")
        expect(read(prefix, "a.txt")).toBeNil()

        expect(function()
            archive.unpack(blob, `{TEMP_DIR}/pkg-archive-none`, { paths = { "missing.txt" } })
        end).toThrow("paths matched nothing")
    end)

    test("roots", function()
        local dest = `{TEMP_DIR}/pkg-archive-roots`
        local count = archive.unpack(
            tar.write({
                file("a/x.txt", "X"),
                file("b/y.txt", "Y"),
            }),
            dest
        )
        expect(count).toBe(2)
        expect(read(dest, "a/x.txt")).toBe("X")
        expect(read(dest, "b/y.txt")).toBe("Y")
    end)

    test("escape", function()
        local bad = {
            "../evil.txt",
            "/evil.txt",
            "foo/../../evil.txt",
        }
        for _, path in bad do
            expect(function()
                archive.unpack(tar.write({ file(path, "no") }), `{TEMP_DIR}/pkg-archive-escape`)
            end).toThrow("archive path escapes")
        end
        expect(read(`{TEMP_DIR}/pkg-archive-escape`, "evil.txt")).toBeNil()
    end)

    test("zip", function()
        local dest = `{TEMP_DIR}/pkg-archive-zip`
        local packed = `{TEMP_DIR}/pkg-archive-zip.zip`
        local text = string.rep("hello zip stream\n", 4000)
        local blob = string.rep("0123456789abcdef", 8192)
        fs.writeFile(
            packed,
            zip.write({
                { path = "pkg/a.txt", data = buffer.fromstring(text), method = "deflate" },
                { path = "pkg/b.txt", data = buffer.fromstring(blob) },
                { path = "pkg/skip.txt", data = buffer.fromstring("no") },
            })
        )
        expect(archive.unpackFile(packed, dest, { paths = { "a.txt", "b.txt" } })).toBe(2)
        expect(read(dest, "a.txt")).toBe(text)
        expect(read(dest, "b.txt")).toBe(blob)
        expect(read(dest, "skip.txt")).toBeNil()
        expect(read(dest, "pkg/a.txt")).toBeNil()
    end)

    test("zip missing", function()
        local packed = `{TEMP_DIR}/pkg-archive-zip-bad`
        fs.writeFile(packed, buffer.fromstring("PK\x03\x04no directory"))
        expect(function()
            archive.unpackFile(packed, `{TEMP_DIR}/pkg-archive-zip-bad-out`)
        end).toThrow("zip directory missing")
    end)

    test("zip escape", function()
        local packed = `{TEMP_DIR}/pkg-archive-zip-escape.zip`
        fs.writeFile(
            packed,
            zip.write({
                { path = "../evil.txt", data = buffer.fromstring("no") },
            })
        )
        expect(function()
            archive.unpackFile(packed, `{TEMP_DIR}/pkg-archive-zip-escape`)
        end).toThrow("archive path escapes")
    end)

    test("max size", function()
        local blob = tar.write({
            file("pkg/a.txt", "AAAA"),
            file("pkg/b.txt", "BB"),
        })
        local over = `{TEMP_DIR}/pkg-archive-max`
        expect(function()
            archive.unpack(blob, over, { max_size = 5 })
        end).toThrow("archive exceeds max_size")
        expect(read(over, "a.txt")).toBeNil()
        expect(read(over, "b.txt")).toBeNil()

        local filtered = `{TEMP_DIR}/pkg-archive-max-filter`
        expect(function()
            archive.unpack(blob, filtered, { paths = { "b.txt" }, max_size = 3 })
        end).toThrow("archive exceeds max_size")
        expect(read(filtered, "b.txt")).toBeNil()

        local under = `{TEMP_DIR}/pkg-archive-max-ok`
        expect(archive.unpack(blob, under, { max_size = 6 })).toBe(2)
        expect(read(under, "a.txt")).toBe("AAAA")
        expect(read(under, "b.txt")).toBe("BB")

        local packed = `{TEMP_DIR}/pkg-archive-max-file.tar`
        fs.writeFile(packed, tar.write({ file("pkg/a.txt", "hello") }))
        local file_dest = `{TEMP_DIR}/pkg-archive-max-file`
        expect(function()
            archive.unpackFile(packed, file_dest, { max_size = 4 })
        end).toThrow("archive exceeds max_size")
        expect(read(file_dest, "a.txt")).toBeNil()
        expect(archive.unpackFile(packed, file_dest, { max_size = 5 })).toBe(1)
        expect(read(file_dest, "a.txt")).toBe("hello")

        local zip_dest = `{TEMP_DIR}/pkg-archive-zip-max`
        local zip_packed = `{TEMP_DIR}/pkg-archive-zip-max.zip`
        local text = string.rep("z", 1000)
        fs.writeFile(
            zip_packed,
            zip.write({
                { path = "pkg/a.txt", data = buffer.fromstring(text), method = "deflate" },
            })
        )
        expect(function()
            archive.unpackFile(zip_packed, zip_dest, { max_size = 999 })
        end).toThrow("archive exceeds max_size")
        expect(read(zip_dest, "a.txt")).toBeNil()
        expect(archive.unpackFile(zip_packed, zip_dest, { max_size = 1000 })).toBe(1)
        expect(read(zip_dest, "a.txt")).toBe(text)
    end)
end)

return nil
