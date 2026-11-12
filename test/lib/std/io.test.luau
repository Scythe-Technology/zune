--!strict
local testing = require("@zune/testing")
local io = require("@zune/io")

local test = testing.test
local expect = testing.expect
local describe = testing.describe

local function contents(array: any): string
    if array.len == 0 then
        return ""
    end

    local buf = buffer.create(array.len)
    local n, err = array:readPositional(0, buf)

    expect(n).toBe(array.len)
    expect(err).toBeNil()
    return buffer.tostring(buf)
end

describe("writer", function()
    test("streams into a buffer array", function()
        local array = zune.io.createBufferArray({ limit = 32 })
        local writer = io.createWriter(array)

        expect(writer:writeAll("hello", 1, 3)).toBeNil()
        expect(writer:writeAll("!")).toBeNil()

        expect(array.len).toBe(4)
        expect(array.offset).toBe(4)
        expect(contents(array)).toBe("ell!")
    end)

    test("positional writer does not move the cursor", function()
        local array = zune.io.createBufferArray({ limit = 32 })
        local writer = io.createWriter(array, { positional = true })

        expect(writer:writeAll("hello")).toBeNil()
        expect(writer:writeAll("!")).toBeNil()

        expect(array.len).toBe(6)
        expect(array.offset).toBe(0)
        expect(contents(array)).toBe("hello!")
    end)

    test("forwards a limit error", function()
        local array = zune.io.createBufferArray({ limit = 4 })
        local writer = io.createWriter(array)

        expect(writer:writeAll("abcd")).toBeNil()

        local err = writer:writeAll("e")
        expect(err).toBe("limit exceeded")
        expect(array.len).toBe(4)
        expect(contents(array)).toBe("abcd")
    end)

    test("requires a write method", function()
        expect(function()
            io.createWriter({})
        end).toThrow("must have a write method")
    end)
end)

describe("reader", function()
    test("streams from a buffer array", function()
        local array = zune.io.createBufferArray({ limit = 32 })
        expect(array:write("hello")).toBe(5)
        array:seekTo(0)

        local reader = io.createReader(array)
        local dest = buffer.create(8)
        local n, err = reader:read(dest, 0, 5)

        expect(n).toBe(5)
        expect(err).toBeNil()
        expect(buffer.readstring(dest, 0, 5)).toBe("hello")
        expect(array.offset).toBe(5)
    end)

    test("positional reader keeps the array cursor", function()
        local array = zune.io.createBufferArray({ limit = 32 })
        expect(array:write("hello")).toBe(5)

        local reader = io.createReader(array, { positional = true })
        local dest = buffer.create(5)
        local n, err = reader:read(dest)

        expect(n).toBe(5)
        expect(err).toBeNil()
        expect(buffer.tostring(dest)).toBe("hello")
        expect(array.offset).toBe(5)
    end)

    test("readAll raises EOF", function()
        local array = zune.io.createBufferArray({ limit = 32 })
        expect(array:append("hi")).toBe(2)

        local reader = io.createReader(array, { positional = true })
        local dest = buffer.create(4)

        expect(function()
            reader:readAll(dest)
        end).toThrow("EOF")
    end)

    test("readAll raises a bounds error", function()
        local array = zune.io.createBufferArray({ limit = 8 })
        expect(array:append("ab")).toBe(2)

        local reader = io.createReader(array, { positional = true })
        reader.offset = 3

        expect(function()
            reader:readAll(buffer.create(1))
        end).toThrow("out of bounds")
    end)

    test("requires a read method", function()
        expect(function()
            io.createReader({})
        end).toThrow("must have a read method")
    end)
end)

describe("file", function()
    local temp = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")
    local cwd = zune.io.cwd()
    local path = `{temp}/io-roundtrip.txt`

    test("positional round trip", function()
        local file = cwd:createFile(path, {
            read = true,
            truncate = true,
            nonblocking = true,
        })
        local writer = io.createWriter(file, { positional = true })

        expect(writer:writeAll("hello")).toBeNil()

        local reader = io.createReader(file, { positional = true })
        local dest = buffer.create(8)
        local n, err = reader:read(dest, 0, 5)

        expect(n).toBe(5)
        expect(err).toBeNil()
        expect(buffer.readstring(dest, 0, 5)).toBe("hello")

        file:close()
        cwd:deleteFile(path)
    end)

    test("streaming is rejected", function()
        local file = cwd:createFile(path, {
            read = true,
            truncate = true,
        })

        expect(function()
            file:write("hello")
        end).toThrow("file does not support streaming (use positional)")
        expect(function()
            file:read(buffer.create(1))
        end).toThrow("file does not support streaming (use positional)")

        file:close()
        cwd:deleteFile(path)
    end)

    test("streaming is rejected off the loop", function()
        zune.luau.sync(function()
            local file = cwd:createFile(path, {
                read = true,
                truncate = true,
            })

            expect(function()
                file:write("hello")
            end).toThrow("file does not support streaming (use positional)")
            expect(function()
                file:read(buffer.create(1))
            end).toThrow("file does not support streaming (use positional)")

            expect(file:writePositional(0, "hello")).toBe(5)
            local dest = buffer.create(5)
            expect(file:readPositional(0, dest)).toBe(5)
            expect(buffer.tostring(dest)).toBe("hello")

            file:close()
            cwd:deleteFile(path)
        end)
    end)
end)

return nil
