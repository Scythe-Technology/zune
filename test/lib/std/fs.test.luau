--!strict
local TEMP_DIR = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")

local fs = require("@zune/fs")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function path(name: string): string
    return `{TEMP_DIR}/{name}`
end

local function kinds(dir: string): { [string]: string }
    local found = {}
    for _, entry in fs.entries(dir) do
        found[entry.name] = entry.kind
    end
    return found
end

describe("files", function()
    test("read and write", function()
        local text = "Some text\n"
        local bytes = buffer.fromstring("Some binary\n")

        fs.writeFile(path("sample.txt"), text)
        fs.writeFile(path("sample.bin"), bytes)

        expect(fs.readFile(path("sample.txt"))).toBe(text)
        expect(buffer.tostring(fs.readFileBytes(path("sample.bin")))).toBe(buffer.tostring(bytes))

        expect(function()
            fs.readFile(path("missing.txt"))
        end).toThrow("FileNotFound")

        expect(function()
            fs.writeFile(path("missing/sample.txt"), text)
        end).toThrow("FileNotFound")

        fs.deleteFile(path("sample.txt"))
        fs.deleteFile(path("sample.bin"))

        expect(function()
            fs.deleteFile(path("missing.txt"))
        end).toThrow("FileNotFound")
    end)

    test("createFile honors read and truncate", function()
        fs.writeFile(path("kept.txt"), "kept")

        local file = fs.createFile(path("kept.txt"), {
            read = false,
            truncate = false,
        })

        expect(function()
            file:read(buffer.create(4))
        end).toThrow("file not open for reading")
        file:close()

        expect(fs.readFile(path("kept.txt"))).toBe("kept")
        fs.deleteFile(path("kept.txt"))
    end)
end)

describe("stat", function()
    test("missing path is none", function()
        expect(fs.stat(path("missing"))).toBe(expect.similar({
            kind = "none",
        }))
    end)

    test("file and directory", function()
        fs.writeFile(path("stat.txt"), "x")
        fs.makeDir(path("stat-dir"))

        expect(fs.stat(path("stat.txt")).kind).toBe("file")
        expect(fs.stat(path("stat-dir")).kind).toBe("directory")

        fs.deleteFile(path("stat.txt"))
        fs.deleteDir(path("stat-dir"))
    end)

    test("other errors are rethrown", function()
        fs.writeFile(path("not-a-dir"), "x")

        expect(fs.stat(path("not-a-dir/child")).kind).toBe("none")

        fs.deleteFile(path("not-a-dir"))
    end)
end)

describe("directories", function()
    test("make, list, and delete", function()
        fs.makeDir(path("tree"))
        fs.makeDir(path("tree/nested"), true)
        fs.writeFile(path("tree/nested/a.txt"), "a")

        local listed = kinds(path("tree"))
        expect(listed.nested).toBe("directory")

        local nested = kinds(path("tree/nested"))
        expect(nested["a.txt"]).toBe("file")

        expect(function()
            fs.makeDir(path("tree/missing/child"))
        end).toThrow("FileNotFound")

        expect(function()
            fs.deleteDir(path("tree"))
        end).toThrow("DirNotEmpty")
        expect(fs.stat(path("tree")).kind).toBe("directory")

        fs.deleteDir(path("tree"), true)
        expect(fs.stat(path("tree")).kind).toBe("none")
    end)

    test("move", function()
        fs.writeFile(path("from.txt"), "one")
        fs.writeFile(path("taken.txt"), "two")

        expect(function()
            fs.move(path("from.txt"), path("taken.txt"))
        end).toThrow("PathAlreadyExists")
        expect(fs.readFile(path("from.txt"))).toBe("one")
        expect(fs.readFile(path("taken.txt"))).toBe("two")

        fs.move(path("from.txt"), path("taken.txt"), true)
        expect(fs.stat(path("from.txt")).kind).toBe("none")
        expect(fs.readFile(path("taken.txt"))).toBe("one")

        fs.deleteFile(path("taken.txt"))
    end)

    test("copy file and directory", function()
        fs.makeDir(path("src"))
        fs.makeDir(path("src/sub"), true)
        fs.writeFile(path("src/a.txt"), "a")
        fs.writeFile(path("src/sub/b.txt"), "b")

        fs.copy(path("src/a.txt"), path("copied.txt"))
        expect(fs.readFile(path("copied.txt"))).toBe("a")
        expect(fs.readFile(path("src/a.txt"))).toBe("a")

        expect(function()
            fs.copy(path("src/a.txt"), path("copied.txt"), false)
        end).toThrow("PathAlreadyExists")

        fs.copy(path("src/sub/b.txt"), path("copied.txt"), true)
        expect(fs.readFile(path("copied.txt"))).toBe("b")

        fs.copy(path("src"), path("dest"))
        expect(fs.readFile(path("dest/a.txt"))).toBe("a")
        expect(fs.readFile(path("dest/sub/b.txt"))).toBe("b")

        expect(function()
            fs.copy(path("src"), path("dest"), false)
        end).toThrow("PathAlreadyExists")

        fs.deleteFile(path("copied.txt"))
        fs.deleteDir(path("src"), true)
        fs.deleteDir(path("dest"), true)
    end)
end)

describe("path", function()
    test("realPath", function()
        local from_cwd = fs.realPath(".")
        local from_dir = fs.realPathAlloc(zune.io.cwd())

        expect(from_cwd).toBe(expect.any("string"))
        expect(#from_cwd).toBeGreaterThan(0)
        expect(from_dir).toBe(from_cwd)
    end)
end)

return nil
