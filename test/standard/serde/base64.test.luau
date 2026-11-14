--!strict
local serde = zune.serde

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local TEXT = "Hello, World!"
local ENCODED = "SGVsbG8sIFdvcmxkIQ=="

describe("base64", function()
    test("calcSize", function()
        expect(serde.base64.calcSize(#TEXT)).toBe(#ENCODED)
        expect(serde.base64.calcSize(0)).toBe(0)
    end)

    test("encoding", function()
        local out = buffer.create(serde.base64.calcSize(#TEXT))
        expect(serde.base64.encode(out, 0, TEXT, 0)).toBe(#ENCODED)
        expect(buffer.tostring(out)).toBe(ENCODED)

        local src = buffer.fromstring(">>" .. TEXT)
        local from_buffer = buffer.create(#ENCODED)
        expect(serde.base64.encode(from_buffer, 0, src, 2)).toBe(#ENCODED)
        expect(buffer.tostring(from_buffer)).toBe(ENCODED)

        local placed = buffer.create(#ENCODED + 4)
        expect(serde.base64.encode(placed, 2, TEXT, 0, #TEXT)).toBe(#ENCODED)
        expect(buffer.readstring(placed, 2, #ENCODED)).toBe(ENCODED)

        local empty = buffer.create(0)
        expect(serde.base64.encode(empty, 0, "", 0)).toBe(0)
    end)

    test("decoding", function()
        local out = buffer.create(#TEXT)
        expect(serde.base64.decode(out, 0, ENCODED, 0)).toBe(#TEXT)
        expect(buffer.tostring(out)).toBe(TEXT)

        local src = buffer.fromstring(".." .. ENCODED)
        local placed = buffer.create(#TEXT + 3)
        expect(serde.base64.decode(placed, 1, src, 2, #ENCODED)).toBe(#TEXT)
        expect(buffer.readstring(placed, 1, #TEXT)).toBe(TEXT)

        local empty = buffer.create(0)
        expect(serde.base64.decode(empty, 0, "", 0)).toBe(0)
    end)

    test("error", function()
        expect(function()
            serde.base64.decode(buffer.create(16), 0, "InvalidBase64String", 0)
        end).toThrow("InvalidPadding")
        expect(function()
            serde.base64.decode(buffer.create(3), 0, "!!!!", 0)
        end).toThrow("InvalidCharacter")
        expect(function()
            serde.base64.encode(buffer.create(1), 0, TEXT, 0)
        end).toThrow("no space")
        expect(function()
            serde.base64.encode(buffer.create(#ENCODED), 0, TEXT, 10, 10)
        end).toThrow("access out of bounds")
        expect(function()
            serde.base64.encode(buffer.create(#ENCODED), #ENCODED + 1, TEXT, 0)
        end).toThrow("access out of bounds")
    end)
end)

return nil
