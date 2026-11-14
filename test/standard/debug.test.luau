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
