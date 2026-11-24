--!strict
local debug = zune.debug

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

assert(type(describe) == "function", `Should be function, got {type(describe)}`)
assert(type(expect) == "table", `Should be table, got {type(expect)}`)
assert(type(test) == "function", `Should be function, got {type(test)}`)

describe("debug", function()
    test("root", function()
        local res = debug.dumpStacktrace(1, 1)
        expect(#res:split("\n")).toBe(4)
    end)
    test("source", function()
        local full = debug.source(1)
        expect(type(full)).toBe("string")
        expect(string.find(full :: string, "debug.test.luau", 1, true)).toBeTruthy()
        expect(string.sub(full :: string, 1, 1)).never.toBe("@")
        expect(debug.source(80)).toBeNil()
        expect(function()
            debug.source(-1)
        end).toThrow("invalid stack level")

        local long = `{string.rep("segment/", 40)}leaf.luau`
        local fn = zune.luau.load(
            zune.luau.compile('return zune.debug.source(1), debug.info(1, "s")', {
                debug_level = 2,
            }),
            {
                chunk_name = `@{long}`,
            }
        )
        local got, shown = fn()
        expect(got).toBe(long)
        expect(shown).never.toBe(long)

        local named = zune.luau.load(
            zune.luau.compile("return zune.debug.source(1)", {
                debug_level = 2,
            }),
            {
                chunk_name = "=chunk",
            }
        )
        expect(named()).toBeNil()
    end)
    test("stacktrace", function()
        local function test()
            local function test2()
                local function test3()
                    debug.dumpStacktrace(1)
                end
                test3()
            end
            test2()
        end
        test()
    end)
end)
