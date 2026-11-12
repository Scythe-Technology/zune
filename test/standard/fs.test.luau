--!strict
local TEMP_DIR = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")

local fs = zune.fs
if not fs then
    return
end
local luau = zune.luau
local platform = zune.platform

local cwd = zune.io.cwd()

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function statKind(dir: any, name: string): string
    local ok, result = pcall(dir.statFile, dir, name)
    if not ok then
        if result == "FileNotFound" then
            return "none"
        end
        error(result)
    end
    return result.kind
end

local function isDir(dir: any, name: string): boolean
    return statKind(dir, name) == "directory"
end

local function isFile(dir: any, name: string): boolean
    return statKind(dir, name) == "file"
end

local function writeAll(file: any, content: string | buffer)
    local len = if type(content) == "string" then #content else buffer.len(content :: buffer)
    local written = 0
    while written < len do
        local n = file:writePositional(written, content, written)
        if n == 0 then
            error("short write")
        end
        written += n
    end
end

local function readAll(file: any, len: number): string
    local buf = buffer.create(len)
    local read = 0
    while read < len do
        local n = file:readPositional(read, buf, read, len - read)
        if n == 0 then
            break
        end
        read += n
    end
    return buffer.readstring(buf, 0, read)
end

local function writeFile(dir: any, name: string, content: string | buffer)
    local file = dir:createFile(name, {
        read = true,
        truncate = true,
        nonblocking = true,
    })
    writeAll(file, content)
    file:close()
end

local function readFile(dir: any, name: string): string
    local file = dir:openFile(name, {
        mode = "r",
    })
    local text = readAll(file, file:size())
    file:close()
    return text
end

local function realPathOf(dir: any): string
    local buf = buffer.create(fs.path.max_path_bytes)
    local n = dir:realPath(buf)
    return buffer.readstring(buf, 0, n)
end

assert(isDir(cwd, TEMP_DIR), `TEMP_DIR is not a directory, {TEMP_DIR}`)

local root = cwd:openDir(TEMP_DIR, {
    iterate = true,
})

describe("cwd", function()
    test("does not iterate", function()
        local function check()
            expect(function()
                cwd:entries()
            end).toThrow("directory not opened for iteration")

            expect(function()
                cwd:close()
            end).toThrow("directory not owned")

            local plain = cwd:openDir(TEMP_DIR)
            expect(function()
                plain:entries()
            end).toThrow("directory not opened for iteration")
            plain:close()
        end
        check()
        luau.sync(check)
    end)
end)

describe("binary", function()
    local binaryData = buffer.fromstring("Some binary\n")
    local binaryDataLarge = buffer.fromstring(string.rep("ABC\n", 600))

    describe("writeFile", function()
        test("small write", function()
            local function write(name: string)
                writeFile(root, name, binaryData)

                expect(function()
                    writeFile(root, `unknown/{name}`, binaryData)
                end).toThrow("FileNotFound")
            end
            write("sample")
            luau.sync(function()
                write("sample-sync")
            end)
        end)
        test("large write", function()
            local function write(name: string)
                writeFile(root, name, binaryDataLarge)

                expect(function()
                    writeFile(root, `unknown/{name}`, binaryDataLarge)
                end).toThrow("FileNotFound")
            end
            write("sample2")
            luau.sync(function()
                write("sample2-sync")
            end)
        end)
    end)

    describe("readFile", function()
        test("small read", function()
            local function read(name: string)
                local file = root:openFile(name, {
                    mode = "r",
                })
                local result = buffer.fromstring(readAll(file, file:size()))
                file:close()
                expect(result).toBe(expect.any("buffer"))
                expect(buffer.tostring(result)).toBe(buffer.tostring(binaryData))
            end
            read("sample")
            luau.sync(function()
                read("sample-sync")
            end)
        end)
        test("large read", function()
            local function read(name: string)
                local file = root:openFile(name, {
                    mode = "r",
                })
                local result = buffer.fromstring(readAll(file, file:size()))
                file:close()
                expect(result).toBe(expect.any("buffer"))
                expect(buffer.tostring(result)).toBe(buffer.tostring(binaryDataLarge))
            end
            read("sample2")
            luau.sync(function()
                read("sample2-sync")
            end)
        end)
        test("unknown file", function()
            local function read(name: string)
                expect(function()
                    root:openFile(`unknown/{name}`, {
                        mode = "r",
                    })
                end).toThrow("FileNotFound")
            end
            read("sample")
            luau.sync(function()
                read("sample-sync")
            end)
        end)
    end)

    test("deleteFile", function()
        local function remove(name: string)
            root:deleteFile(name)
            expect(function()
                root:deleteFile(`unknown/{name}`)
            end).toThrow("FileNotFound")
        end
        remove("sample")
        remove("sample2")
        luau.sync(function()
            remove("sample-sync")
            remove("sample2-sync")
        end)
    end)
end)

assert(not isFile(root, "sample"), "File should be removed")
assert(not isFile(root, "sample.txt"), "File should not exist")

describe("text", function()
    local textData = "Some text\n"
    local textDataLarge = string.rep("ABC\n", 600)

    describe("writeFile", function()
        test("small write", function()
            local function write(name: string)
                writeFile(root, name, textData)

                expect(function()
                    writeFile(root, `unknown/{name}`, textData)
                end).toThrow("FileNotFound")
            end
            write("sample.txt")
            luau.sync(function()
                write("sample-sync.txt")
            end)
        end)
        test("large write", function()
            local function write(name: string)
                writeFile(root, name, textDataLarge)

                expect(function()
                    writeFile(root, `unknown/{name}`, textDataLarge)
                end).toThrow("FileNotFound")
            end
            write("sample2.txt")
            luau.sync(function()
                write("sample2-sync.txt")
            end)
        end)
    end)

    describe("readFile", function()
        test("small read", function()
            local function read(name: string)
                local result = readFile(root, name)
                expect(result).toBe(expect.any("string"))
                expect(result).toBe(textData)
            end
            read("sample.txt")
            luau.sync(function()
                read("sample-sync.txt")
            end)
        end)
        test("large read", function()
            local function read(name: string)
                local result = readFile(root, name)
                expect(result).toBe(expect.any("string"))
                expect(result).toBe(textDataLarge)
            end
            read("sample2.txt")
            luau.sync(function()
                read("sample2-sync.txt")
            end)
        end)
        test("unknown file", function()
            local function read(name: string)
                expect(function()
                    readFile(root, `unknown/{name}`)
                end).toThrow("FileNotFound")
            end
            read("sample.txt")
            luau.sync(function()
                read("sample-sync.txt")
            end)
        end)
    end)

    test("isFile", function()
        local function check(name: string)
            expect(isFile(root, name)).toBeTruthy()
            expect(isDir(root, name)).toBeFalsy()
            expect(isFile(root, `unknown/{name}`)).toBeFalsy()
        end
        check("sample.txt")
        check("sample2.txt")
        luau.sync(function()
            check("sample-sync.txt")
            check("sample2-sync.txt")
        end)
    end)

    test("deleteFile", function()
        local function remove(name: string)
            root:deleteFile(name)
            expect(function()
                root:deleteFile(`unknown/{name}`)
            end).toThrow("FileNotFound")
        end
        remove("sample.txt")
        remove("sample2.txt")
        luau.sync(function()
            remove("sample-sync.txt")
            remove("sample2-sync.txt")
        end)
    end)
end)

describe("dir", function()
    test("makeDir", function()
        local function make(name: string)
            root:createDir(name)
            root:createDirPath(`{name}/bar/luau`)

            expect(function()
                root:createDir(`unknown/{name}`)
            end).toThrow("FileNotFound")
        end
        make("foo")
        luau.sync(function()
            make("foo-sync")
        end)
    end)

    test("entries", function()
        local function list(name: string)
            local dir = root:openDir(name, {
                iterate = true,
            })
            local result = dir:entries()
            dir:close()
            expect(result).toBe(expect.any("table"))
            expect(result).toBe(expect.similar({ { name = "bar", kind = "directory" } }))

            local nested = root:openDir(`{name}/bar/luau`, {
                iterate = true,
            })
            local empty = nested:entries()
            nested:close()
            expect(empty).toBe(expect.any("table"))
            expect(empty).toBe(expect.similar({}))

            expect(function()
                root:openDir(`{name}/unknown`, {
                    iterate = true,
                })
            end).toThrow("FileNotFound")
        end
        list("foo")
        luau.sync(function()
            list("foo-sync")
        end)
    end)

    test("isDir", function()
        local function check(name: string)
            expect(isDir(root, name)).toBeTruthy()
            expect(isFile(root, name)).toBeFalsy()
            expect(isDir(root, `unknown/{name}`)).toBeFalsy()
        end
        check("foo")
        luau.sync(function()
            check("foo-sync")
        end)
    end)

    test("deleteDir", function()
        local function remove(name: string)
            root:deleteDir(`{name}/bar/luau`)
            expect(isDir(root, `{name}/bar/luau`)).toBeFalsy()

            expect(function()
                root:deleteDir(name)
            end).toThrow("DirNotEmpty")

            root:deleteTree(name)
            expect(isDir(root, name)).toBeFalsy()
        end
        remove("foo")
        luau.sync(function()
            remove("foo-sync")
        end)
    end)
end)

local function expectStat(stat: any, kind: string)
    expect(stat).toBe(expect.any("table"))
    expect(stat).toBe(expect.similar({
        changed_at = expect.any("number"),
        modified_at = expect.any("number"),
        accessed_at = expect.any("number"),
        block_size = expect.any("number"),
        size = expect.any("number"),
        mode = expect.any("number"),
        kind = kind,
    }))
end

test("stat", function()
    local function check(name: string)
        root:createDir(name)
        writeFile(root, `{name}/sample.txt`, "Some text sample\n")

        local dir = root:openDir(name)
        expectStat(dir:stat(), "directory")
        dir:close()

        expectStat(root:statFile(`{name}/sample.txt`), "file")

        expect(function()
            root:statFile(`{name}/unknown.txt`)
        end).toThrow("FileNotFound")

        root:deleteFile(`{name}/sample.txt`)
        root:deleteDir(name)
    end
    check("stat")
    luau.sync(function()
        check("stat-sync")
    end)
end)

test("move", function()
    local function move(name: string)
        root:createDir(name)
        writeFile(root, `{name}/sample.txt`, "Some text sample\n")
        writeFile(root, `{name}/sample2.txt`, "Some text sample number 2\n")

        root:renamePreserve(`{name}/sample.txt`, root, `{name}.txt`)
        expect(isFile(root, `{name}.txt`)).toBeTruthy()
        expect(isFile(root, `{name}/sample.txt`)).toBeFalsy()
        expect(readFile(root, `{name}.txt`)).toBe("Some text sample\n")

        expect(function()
            root:renamePreserve(`{name}/sample2.txt`, root, `{name}.txt`)
        end).toThrow("PathAlreadyExists")
        expect(isFile(root, `{name}.txt`)).toBeTruthy()

        root:rename(`{name}/sample2.txt`, root, `{name}.txt`)
        expect(isFile(root, `{name}.txt`)).toBeTruthy()
        expect(isFile(root, `{name}/sample2.txt`)).toBeFalsy()
        expect(readFile(root, `{name}.txt`)).toBe("Some text sample number 2\n")

        root:deleteFile(`{name}.txt`)
        root:deleteDir(name)

        expect(isFile(root, `{name}.txt`)).toBeFalsy()
        expect(isDir(root, name)).toBeFalsy()
    end
    move("metadata")
    luau.sync(function()
        move("metadata-sync")
    end)
end)

test("copy", function()
    local function copyTree(srcName: string, destName: string, replace: boolean)
        local src = root:openDir(srcName, {
            iterate = true,
        })
        if statKind(root, destName) ~= "directory" then
            root:createDir(destName)
        elseif not replace then
            src:close()
            error("PathAlreadyExists", 0)
        end
        local dest = root:openDir(destName)
        for _, entry in src:entries() do
            src:copyFile(entry.name, dest, entry.name, {
                replace = replace,
            })
        end
        src:close()
        dest:close()
    end

    local function copy(name: string)
        root:createDir(name)
        writeFile(root, `{name}/sample.txt`, "Some text sample\n")
        writeFile(root, `{name}/sample2.txt`, "Some text sample number 2\n")

        root:copyFile(`{name}/sample.txt`, root, `{name}.txt`, {
            replace = false,
        })
        expect(isFile(root, `{name}.txt`)).toBeTruthy()
        expect(isFile(root, `{name}/sample.txt`)).toBeTruthy()

        expect(function()
            root:copyFile(`{name}/sample3.txt`, root, `{name}-missing`, {
                replace = false,
            })
        end).toThrow("FileNotFound")
        expect(isFile(root, `{name}-missing`)).toBeFalsy()

        expect(function()
            root:copyFile(`{name}/sample.txt`, root, `{name}.txt`, {
                replace = false,
            })
        end).toThrow("PathAlreadyExists")

        root:copyFile(`{name}/sample2.txt`, root, `{name}.txt`, {
            replace = true,
        })
        expect(readFile(root, `{name}.txt`)).toBe("Some text sample number 2\n")

        copyTree(name, `{name}2`, false)
        expect(isDir(root, `{name}2`)).toBeTruthy()
        expect(isFile(root, `{name}2/sample.txt`)).toBeTruthy()
        expect(isFile(root, `{name}2/sample2.txt`)).toBeTruthy()

        expect(function()
            copyTree(name, `{name}2`, false)
        end).toThrow("PathAlreadyExists")

        copyTree(name, `{name}2`, true)
        expect(isDir(root, `{name}2`)).toBeTruthy()
        expect(isFile(root, `{name}2/sample.txt`)).toBeTruthy()
        expect(isFile(root, `{name}2/sample2.txt`)).toBeTruthy()

        root:deleteFile(`{name}.txt`)
        root:deleteTree(name)
        root:deleteTree(`{name}2`)

        expect(isFile(root, `{name}.txt`)).toBeFalsy()
        expect(isDir(root, name)).toBeFalsy()
        expect(isDir(root, `{name}2`)).toBeFalsy()
    end
    copy("copied")
    luau.sync(function()
        copy("copied-sync")
    end)
end)

test("symLink", function()
    if platform.os ~= "windows" then
        local function link(name: string)
            root:createDir(name)
            writeFile(root, `{name}/sample.txt`, "Some text sample\n")
            writeFile(root, `{name}/sample2.txt`, "Some text sample number 2\n")

            root:symLink(`{name}/sample.txt`, `{name}.txt`, {})
            expect(isFile(root, `{name}.txt`)).toBeTruthy()
            expect(isFile(root, `{name}/sample.txt`)).toBeTruthy()
            expect(root:statFile(`{name}.txt`, {
                follow_symlinks = false,
            }).kind).toBe("sym_link")

            root:symLink(`{name}/missing.txt`, `{name}-dangling`, {})
            expect(root:statFile(`{name}-dangling`, {
                follow_symlinks = false,
            }).kind).toBe("sym_link")
            expect(function()
                root:statFile(`{name}-dangling`)
            end).toThrow("FileNotFound")

            root:symLink(name, `{name}2`, {
                is_directory = true,
            })
            expect(isDir(root, `{name}2`)).toBeTruthy()
            expect(isFile(root, `{name}2/sample.txt`)).toBeTruthy()
            expect(isFile(root, `{name}2/sample2.txt`)).toBeTruthy()
            expect(root:statFile(`{name}2`, {
                follow_symlinks = false,
            }).kind).toBe("sym_link")

            expect(function()
                root:symLink(name, `{name}2`, {
                    is_directory = true,
                })
            end).toThrow("PathAlreadyExists")

            root:deleteFile(`{name}.txt`)
            root:deleteFile(`{name}-dangling`)
            root:deleteTree(name)
            root:deleteFile(`{name}2`)

            expect(isFile(root, `{name}.txt`)).toBeFalsy()
            expect(isDir(root, name)).toBeFalsy()
            expect(isDir(root, `{name}2`)).toBeFalsy()
        end
        link("linked")
        luau.sync(function()
            link("linked-sync")
        end)
    end
end)

describe("file object/handle", function()
    local textData = "Some text\n"

    test("open unknown file", function()
        local function open(name: string)
            expect(function()
                root:openFile(name)
            end).toThrow("FileNotFound")
        end
        open("sample.txt")
        luau.sync(function()
            open("sample-sync.txt")
        end)
    end)

    test("create file", function()
        local function create(name: string)
            local result = root:createFile(name, {
                read = true,
                nonblocking = true,
            })
            expect(result).toBe(expect.type("userdata"))

            local b = buffer.create(#textData)
            expect(result:readPositional(0, b)).toBe(0)

            expect(result:size()).toBe(0)

            result:writePositional(0, textData)

            expect(result:size()).toBe(#textData)
            expect(result:readPositional(0, b)).toBe(#textData)

            result:sync()
            result:close()

            expect(function()
                result:read(b)
            end).toThrow("file closed")
        end
        create("sample.txt")
        luau.sync(function()
            create("sample-sync.txt")
        end)
    end)

    test("create file exclusive", function()
        local function create(name: string)
            expect(function()
                local _ = root:createFile(name, {
                    exclusive = true,
                })
            end).toThrow("PathAlreadyExists")
        end
        create("sample.txt")
        luau.sync(function()
            create("sample-sync.txt")
        end)
    end)

    test("open file read mode", function()
        local function open(name: string)
            local result = root:openFile(name, {
                mode = "r",
            })
            expect(result).toBe(expect.type("userdata"))

            expect(result:size()).toBe(#textData)
            local b = buffer.create(#textData)
            expect(result:readPositional(0, b)).toBe(#textData)
            expect(b).toBe(expect.type("buffer"))
            expect(buffer.tostring(b)).toBe(textData)

            expect(function()
                result:write("Some text")
            end).toThrow("file not open for writing")

            result:close()
        end
        open("sample.txt")
        luau.sync(function()
            open("sample-sync.txt")
        end)
    end)

    test("open file write mode", function()
        local function open(name: string)
            local result = root:openFile(name, {
                mode = "w",
            })
            expect(result).toBe(expect.type("userdata"))

            local len = result:size()
            expect(len).toBe(#textData)
            result:writePositional(#textData, "Append text")
            expect(result:size()).toBe(len + #"Append text")

            expect(function()
                result:readPositional(len + #"Append text", buffer.create(1))
            end).toThrow("file not open for reading")

            result:close()
        end
        open("sample.txt")
        luau.sync(function()
            open("sample-sync.txt")
        end)
    end)

    test("open file both mode", function()
        local function open(name: string)
            local result = root:openFile(name, {
                mode = "rw",
            })
            expect(result).toBe(expect.type("userdata"))

            local len = #(textData .. "Append text")
            local b = buffer.create(len)
            expect(result:readPositional(0, b)).toBe(len)

            result:writePositional(len, "Some text")
            result:close()
        end
        open("sample.txt")
        luau.sync(function()
            open("sample-sync.txt")
        end)
    end)

    root:deleteFile("sample.txt")
    root:deleteFile("sample-sync.txt")
end)

describe("tempDir", function()
    local function pathOfClosed(cleanup: boolean): string
        local temp = fs.createTempDir({
            cleanup = cleanup,
            iterate = true,
        })
        expect(temp).toBe(expect.type("userdata"))

        local file = temp:createFile("inside.txt", {
            read = true,
            truncate = true,
            nonblocking = true,
        })
        writeAll(file, "temp")
        file:close()

        local entries = temp:entries()
        expect(entries).toBe(expect.similar({ { name = "inside.txt", kind = "file" } }))

        local path = realPathOf(temp)
        if cleanup then
            return path
        end
        temp:close()
        return path
    end

    test("keeps the directory without cleanup", function()
        local function check()
            local path = pathOfClosed(false)
            expect(cwd:statFile(path).kind).toBe("directory")
            cwd:deleteTree(path)
            expect(function()
                cwd:statFile(path)
            end).toThrow("FileNotFound")
        end
        check()
        luau.sync(check)
    end)

    test("deletes the directory on close", function()
        local function check()
            local temp = fs.createTempDir({
                cleanup = true,
                iterate = true,
            })
            local file = temp:createFile("inside.txt", {
                read = true,
                truncate = true,
            })
            file:close()
            local path = realPathOf(temp)
            temp:close()
            expect(function()
                cwd:statFile(path)
            end).toThrow("FileNotFound")
        end
        check()
        luau.sync(check)
    end)

    test("deletes the directory on collect", function()
        local path = pathOfClosed(true)
        luau.garbagecollect()
        expect(function()
            cwd:statFile(path)
        end).toThrow("FileNotFound")
    end)
end)

root:close()
