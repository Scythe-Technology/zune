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
end)
