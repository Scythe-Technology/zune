--!strict
local fmt = zune.fmt

local testing = require("@zune/testing")

local test = testing.test
local expect = testing.expect
local describe = testing.describe

describe("fmt", function()
    test("format", function()
        for i = 0, 1 do
            fmt.setEnabled(i == 0)

            local use_colors = fmt.useColors()
            local function coloredNumber(text: string): string
                return if use_colors then `\x1B[96m{text}\x1B[0m` else text
            end

            expect(fmt.format("test")).toBe("test")
            expect(fmt.format(123)).toBe(coloredNumber("123"))
            expect(fmt.format(0 / 0)).toBe(coloredNumber("nan"))
            expect(fmt.format(-(0 / 0))).toBe(coloredNumber("nan"))
            expect(fmt.format(0.000001)).toBe(coloredNumber("0.000001"))
            expect(fmt.format(1e-7)).toBe(coloredNumber("1e-7"))
            expect(fmt.format(-1e-7)).toBe(coloredNumber("-1e-7"))
            expect(fmt.format(1e21)).toBe(coloredNumber("1e21"))
            expect(fmt.format(10.0000001)).toBe(coloredNumber("10.0000001"))
            expect(fmt.format(math.huge)).toBe(coloredNumber("inf"))
            expect(fmt.format(-math.huge)).toBe(coloredNumber("-inf"))

            local vec_text = "<vector (nan, 1e-7, 1)>"
            expect(fmt.format(vector.create(0 / 0, 1e-7, 1))).toBe(
                if use_colors then `\x1B[95m{vec_text}\x1B[0m` else vec_text
            )
            local res: string = fmt.format({ [" "] = 1 })
            local start: number = (res:find(">")) or error("Bad format")
            start += 1
            expect(res:sub(start)).toBe(
                if use_colors
                    then ' {\x1B[0m\n    \x1B[2m[\x1B[0;32m" "\x1B[0;2m]\x1B[0m\x1B[2m = \x1B[0m\x1B[96m1\x1B[0m\x1B[2m,\x1B[0m \n\x1B[2m}\x1B[0m'
                    else ' {\n    [" "] = 1, \n}'
            )
            expect(((res:sub(1, start)):find(if use_colors then "\x1B%[2m<table: 0x.+>" else "<table: 0x.+>"))).never.toBeNil()
        end
    end)

    test("indent", function()
        fmt.setUseColor(false)
        fmt.setTableAddress(false)
        testing.defer(function()
            fmt.setIndent(1)
            fmt.setUseColor(true)
            fmt.setTableAddress(true)
        end)

        local function nested(unit: string): string
            return `\{\n{unit}a = \{\n{unit}{unit}b = 1, \n{unit}\}, \n\}`
        end

        fmt.setIndent(0)
        expect(fmt.format({ a = { b = 1 } })).toBe(nested("  "))
        fmt.setIndent(1)
        expect(fmt.format({ a = { b = 1 } })).toBe(nested("    "))
        fmt.setIndent(2)
        expect(fmt.format({ a = { b = 1 } })).toBe(nested("\t"))
    end)

    test("escape", function()
        fmt.setUseColor(false)
        fmt.setTableAddress(false)
        fmt.setIndent(1)
        testing.defer(function()
            fmt.setIndent(1)
            fmt.setUseColor(true)
            fmt.setTableAddress(true)
        end)

        expect(fmt.format({ a = 'te"st' })).toBe('{\n    a = "te\\"st", \n}')
        expect(fmt.format({ a = "te\\st" })).toBe('{\n    a = "te\\\\st", \n}')
        expect(fmt.format({ a = "te\nst" })).toBe('{\n    a = "te\\nst", \n}')
        expect(fmt.format({ a = "a\tb" })).toBe('{\n    a = "a\\tb", \n}')
        expect(fmt.format({ a = string.char(8) })).toBe('{\n    a = "\\b", \n}')
        expect(fmt.format({ a = string.char(11) })).toBe('{\n    a = "\\v", \n}')
        expect(fmt.format({ a = string.char(12) })).toBe('{\n    a = "\\f", \n}')
        expect(fmt.format({ a = string.char(7) })).toBe('{\n    a = "\\x07", \n}')
        expect(fmt.format({ a = string.char(1) })).toBe('{\n    a = "\\x01", \n}')
        expect(fmt.format({ a = string.char(127) })).toBe('{\n    a = "\\x7f", \n}')
        expect(fmt.format({ ["a-b"] = 1 })).toBe('{\n    ["a-b"] = 1, \n}')
        expect(fmt.format({ ["a_1"] = 1 })).toBe("{\n    a_1 = 1, \n}")
    end)

    test("sorted", function()
        fmt.setUseColor(false)
        fmt.setTableAddress(false)
        fmt.setIndent(1)
        fmt.setSorted(false)
        testing.defer(function()
            fmt.setIndent(1)
            fmt.setUseColor(true)
            fmt.setTableAddress(true)
            fmt.setSorted(false)
        end)

        local value = { a = 1, b = 2, c = 3 }
        expect(fmt.format(value)).toBe("{\n    a = 1, \n    c = 3, \n    b = 2, \n}")
        fmt.setSorted(true)
        expect(fmt.format(value)).toBe("{\n    a = 1, \n    b = 2, \n    c = 3, \n}")
        expect(fmt.format({ b = 1, [2] = 3, a = 4 })).toBe("{\n    a = 4, \n    b = 1, \n    [2] = 3, \n}")
        expect(fmt.format({ ["a-b"] = 1, [""] = 2 })).toBe('{\n    [""] = 2, \n    ["a-b"] = 1, \n}')
        expect(fmt.format({ z = { b = 1, a = 2 }, a = 1 })).toBe(
            "{\n    a = 1, \n    z = {\n        a = 2, \n        b = 1, \n    }, \n}"
        )
        expect(fmt.format({ [2] = "b", [1] = "a" })).toBe('{\n    [1] = "a", \n    [2] = "b", \n}')
    end)
end)
