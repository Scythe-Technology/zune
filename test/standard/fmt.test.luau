--!strict
local fmt = zune.fmt

local testing = require("@zune/testing")

local test = testing.test
local expect = testing.expect
local describe = testing.describe

describe("fmt", function()
    test("format", function()
        local use_colors = fmt.useColors()
        expect(fmt.format("test")).toBe("test")
        expect(fmt.format(123)).toBe(if use_colors then "\x1B[96m123\x1B[0m" else "123")
        local res: string = fmt.format({ [" "] = 1 })
        local start: number = (res:find(">")) or error("Bad format")
        start += 1
        expect(res:sub(start)).toBe(
            if use_colors
                then ' {\x1B[0m\n    \x1B[2m[\x1B[0;32m" "\x1B[0;2m]\x1B[0m\x1B[2m = \x1B[0m\x1B[96m1\x1B[0m\x1B[2m,\x1B[0m \n\x1B[2m}\x1B[0m'
                else ' {\n    [" "] = 1, \n}'
        )
        expect(((res:sub(1, start)):find(if use_colors then "\x1B%[2m<table: 0x.+>" else "<table: 0x.+>"))).never.toBeNil()
    end)
end)
