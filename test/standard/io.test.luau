--!strict
local io = zune.io

local fs = require("@zune/fs")
local wrapped = require("@zune/io")
local testing = require("@zune/testing")

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

describe("io", function()
    test("cwd", function()
        local cwd = fs.realPathAlloc(io.cwd())

        expect(cwd).toBe(expect.any("string"))
        expect(#cwd).toBeGreaterThan(0)
        if zune.platform.os == "windows" then
            expect(cwd:sub(2, 3) == ":\\").toBeTruthy()
        else
            expect(cwd:sub(1, 1) == "/").toBeTruthy()
        end
    end)

    describe("createBufferArray", function()
        test("write grows", function()
            local array = io.createBufferArray({ limit = 8 })

            expect(array:write("ab")).toBe(2)
            expect(array.offset).toBe(2)

            expect(array:write("cd")).toBe(2)
            expect(array.len).toBe(4)
            expect(array.offset).toBe(4)
            expect(contents(array)).toBe("abcd")

            array:seekTo(1)
            expect(array:write("XY")).toBe(2)
            expect(array.len).toBe(4)
            expect(contents(array)).toBe("aXYd")
        end)

        test("writePositional grows and zero-fills a gap", function()
            local array = io.createBufferArray({ limit = 8 })

            expect(array:writePositional(0, "go")).toBe(2)
            expect(array:writePositional(array.len, "od")).toBe(2)
            expect(array.len).toBe(4)
            expect(array.offset).toBe(0)
            expect(contents(array)).toBe("good")

            expect(array:writePositional(6, "z")).toBe(1)
            expect(array.len).toBe(7)
            expect(contents(array)).toBe("good\0\0z")
        end)

        test("limit returns an error and keeps the bytes", function()
            local array = io.createBufferArray({ limit = 4 })

            expect(array:write("abcd")).toBe(4)

            local n, err = array:write("e")
            expect(n).toBe(0)
            expect(err).toBe("limit exceeded")
            expect(array.len).toBe(4)
            expect(contents(array)).toBe("abcd")

            array:seekTo(0)
            expect(array:write("wxyz")).toBe(4)
            expect(array.len).toBe(4)
            expect(contents(array)).toBe("wxyz")

            local positional_n, positional_err = array:writePositional(2, "abcd")
            expect(positional_n).toBe(0)
            expect(positional_err).toBe("limit exceeded")
            expect(array.len).toBe(4)
            expect(contents(array)).toBe("wxyz")
        end)

        test("append and grow stop at the limit", function()
            local array = io.createBufferArray({ limit = 4 })

            expect(array:append("ab")).toBe(2)
            expect(array.len).toBe(2)
            expect(array.offset).toBe(0)

            local append_n, append_err = array:append("cdef")
            expect(append_n).toBe(0)
            expect(append_err).toBe("limit exceeded")
            expect(array.len).toBe(2)

            array:grow(2)
            expect(array.len).toBe(4)
            expect(contents(array)).toBe("ab\0\0")

            expect(function()
                array:grow(1)
            end).toThrow("limit exceeded")
            expect(array.len).toBe(4)
        end)

        test("empty input returns zero", function()
            local array = io.createBufferArray({ limit = 8 })
            local empty = buffer.create(0)

            local write_n, write_err = array:write(empty)
            expect(write_n).toBe(0)
            expect(write_err).toBeNil()

            local append_n, append_err = array:append(empty)
            expect(append_n).toBe(0)
            expect(append_err).toBeNil()
            expect(array.len).toBe(0)

            local read_n, read_err = array:read(empty)
            expect(read_n).toBe(0)
            expect(read_err).toBeNil()
        end)

        test("read follows the cursor", function()
            local array = io.createBufferArray({ limit = 8 })
            expect(array:write("abcd")).toBe(4)

            array:seekTo(0)
            local buf = buffer.create(2)

            expect(array:read(buf)).toBe(2)
            expect(array.offset).toBe(2)
            expect(buffer.readstring(buf, 0, 2)).toBe("ab")

            expect(array:read(buf)).toBe(2)
            expect(buffer.readstring(buf, 0, 2)).toBe("cd")

            local n, err = array:read(buf)
            expect(n).toBe(0)
            expect(err).toBeNil()
            expect(array.offset).toBe(4)
        end)

        test("readPositional reports an offset past the end", function()
            local array = io.createBufferArray({ limit = 8 })
            expect(array:append("ab")).toBe(2)

            local buf = buffer.create(2)
            local at_end, at_end_err = array:readPositional(2, buf)
            expect(at_end).toBe(0)
            expect(at_end_err).toBeNil()

            local n, err = array:readPositional(3, buf)
            expect(n).toBe(0)
            expect(err).toBe("out of bounds")
            expect(array.len).toBe(2)
        end)

        test("seekTo clamps and clear resets", function()
            local array = io.createBufferArray({ limit = 8 })
            expect(array:write("abcd")).toBe(4)

            array:seekTo(100)
            expect(array.offset).toBe(4)

            array:clear()
            expect(array.len).toBe(0)
            expect(array.offset).toBe(0)

            local n, err = array:read(buffer.create(1))
            expect(n).toBe(0)
            expect(err).toBeNil()
        end)

        test("size cannot exceed the limit", function()
            expect(function()
                io.createBufferArray({
                    limit = 4,
                    size = 5,
                })
            end).toThrow("size cannot be larger than limit")
        end)

        test("positional writer grows", function()
            local array = io.createBufferArray({ limit = 16 })
            local writer = wrapped.createWriter(array, { positional = true })

            expect(writer:writeAll("hello")).toBeNil()
            expect(writer:writeAll("!")).toBeNil()

            expect(array.len).toBe(6)
            expect(array.offset).toBe(0)
            expect(contents(array)).toBe("hello!")
        end)
    end)
end)
