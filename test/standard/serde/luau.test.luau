--!strict
local serde = zune.serde

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("luau", function()
    describe("encoding", function()
        test("single", function()
            expect(serde.luau.encode(nil)).toBe("nil")
            expect(serde.luau.encode(true)).toBe("true")
            expect(serde.luau.encode(false)).toBe("false")
            expect(serde.luau.encode(1)).toBe("1")
            expect(serde.luau.encode(1.5)).toBe("1.5")
            expect(function()
                serde.luau.encode(0 / 0)
            end).toThrow("invalid number value (cannot be inf or nan)")
            expect(function()
                serde.luau.encode(math.huge)
            end).toThrow("invalid number value (cannot be inf or nan)")
        end)

        test("string", function()
            expect(serde.luau.encode("test")).toBe(`"test"`)
            expect(serde.luau.encode('te"st')).toBe(`"te\\"st"`)
            expect(serde.luau.encode("te\\st")).toBe(`"te\\\\st"`)
            expect(serde.luau.encode("te\nst")).toBe(`"te\\nst"`)
            expect(serde.luau.encode("a\tb")).toBe(`"a\\tb"`)
            expect(serde.luau.encode(string.char(1))).toBe(`"\\x01"`)
            expect(serde.luau.encode(string.char(127))).toBe(`"\\x7f"`)
        end)

        test("table", function()
            expect(serde.luau.encode({})).toBe("{}")
            expect(serde.luau.encode({ "b", "a" }, { pretty_indent = 0 })).toBe(`\{"b", "a"\}`)
            expect(serde.luau.encode({ b = 1, a = 2 }, { pretty_indent = 0 })).toBe("{a = 2, b = 1}")
            expect(serde.luau.encode({ b = 1, [2] = 3, a = 4 }, { pretty_indent = 0 })).toBe("{a = 4, [2] = 3, b = 1}")
            expect(serde.luau.encode({ ["a-b"] = 1, [""] = 2 }, { pretty_indent = 0 })).toBe(
                `\{["a-b"] = 1, [""] = 2\}`
            )
            expect(serde.luau.encode({ a = 1 })).toBe("{\n    a = 1,\n}")
            expect(serde.luau.encode({ a = 1 }, { pretty_indent = 1 })).toBe("{\n  a = 1,\n}")
            expect(serde.luau.encode({ a = 1 }, { pretty_indent = 3 })).toBe("{\n\ta = 1,\n}")
            expect(serde.luau.encode({ a = { b = 1 } }, { pretty_indent = 1 })).toBe("{\n  a = {\n    b = 1,\n  },\n}")
            expect(serde.luau.encode({ 1, 2 }, { pretty_indent = 1 })).toBe("{\n  1,\n  2,\n}")
            expect(serde.luau.encode({ [1] = "a", [3] = "c" }, { pretty_indent = 0 })).toBe(`\{[1] = "a", [3] = "c"\}`)
        end)

        test("sort", function()
            local value = { a = 1, b = 2, c = 3 }
            expect(serde.luau.encode(value, { pretty_indent = 0, sort = false })).toBe(
                serde.luau.encode(value, { pretty_indent = 0 })
            )
            expect(serde.luau.encode(value, { pretty_indent = 0 })).toBe("{a = 1, c = 3, b = 2}")
            expect(serde.luau.encode(value, { pretty_indent = 0, sort = true })).toBe("{a = 1, b = 2, c = 3}")
            expect(serde.luau.encode(value, { pretty_indent = 1, sort = false })).toBe(
                "{\n  a = 1,\n  c = 3,\n  b = 2,\n}"
            )
            expect(
                serde.luau.encode({ a = 1, b = 2, c = { a = 1, b = 2, c = 3 } }, { pretty_indent = 0, sort = false })
            ).toBe("{a = 1, c = {a = 1, c = 3, b = 2}, b = 2}")
            expect(serde.luau.encode({ z = { b = 1, a = 2 }, a = 1 }, { pretty_indent = 0, sort = true })).toBe(
                "{a = 1, z = {a = 2, b = 1}}"
            )
            expect(serde.luau.encode({ b = 1, [2] = 3, a = 4 }, { pretty_indent = 0, sort = true })).toBe(
                "{a = 4, b = 1, [2] = 3}"
            )
            expect(serde.luau.encode({ ["a-b"] = 1, [""] = 2 }, { pretty_indent = 0, sort = true })).toBe(
                `\{[""] = 2, ["a-b"] = 1\}`
            )
            expect(serde.luau.encode({ { b = 1, a = 2 } }, { pretty_indent = 0, sort = true })).toBe(
                `\{\{a = 2, b = 1\}\}`
            )
            expect(serde.luau.encode({ "b", "a" }, { pretty_indent = 0, sort = true })).toBe(`\{"b", "a"\}`)
            expect(serde.luau.encode({}, { sort = false })).toBe("{}")
            expect(function()
                serde.luau.encode({ [true] = 1 }, { sort = false })
            end).toThrow("invalid key type (expected string or number, got boolean)")
            expect(function()
                serde.luau.encode({}, { sort = "zune" :: any })
            end).toThrow("invalid value (boolean expected, got string)")
        end)

        test("base_indent", function()
            expect(serde.luau.encode({ a = 1 }, { pretty_indent = 0, base_indent = 2 })).toBe("{a = 1}")
            expect(serde.luau.encode({ a = 1 }, { pretty_indent = 2, base_indent = 1 })).toBe(
                "{\n        a = 1,\n    }"
            )
            expect(function()
                serde.luau.encode({}, { base_indent = -1 })
            end).toThrow("unsupported base indent -1")
        end)

        test("vector", function()
            expect(serde.luau.encode(vector.create(1, 2, 3))).toBe("vector.create(1, 2, 3)")
            expect(serde.luau.encode({ scale = vector.create(1, 0, 0) }, { pretty_indent = 0, sort = true })).toBe(
                "{scale = vector.create(1, 0, 0)}"
            )
            expect(function()
                serde.luau.encode(vector.create(0 / 0, 0, 0))
            end).toThrow("invalid number value (cannot be inf or nan)")
        end)

        test("buffer", function()
            expect(serde.luau.encode(buffer.fromstring("test"))).toBe(`buffer.fromstring("test")`)
            expect(serde.luau.encode(buffer.fromstring("te\nst"))).toBe(`buffer.fromstring("te\\nst")`)
            expect(serde.luau.encode(buffer.fromstring(""))).toBe(`buffer.fromstring("")`)
            expect(serde.luau.encode(buffer.fromstring(string.char(1)))).toBe(`buffer.fromstring("\\x01")`)
        end)

        test("fail", function()
            expect(function()
                serde.luau.encode(function() end)
            end).toThrow("unsupported value type (got function)")
            expect(function()
                serde.luau.encode({ [true] = 1 })
            end).toThrow("invalid key type (expected string or number, got boolean)")
            local cycle = {}
            cycle.self = cycle
            expect(function()
                serde.luau.encode(cycle)
            end).toThrow("table circular reference")
            expect(function()
                serde.luau.encode({}, { pretty_indent = 4 })
            end).toThrow("unsupported indent kind 4")
        end)
    end)
end)

return nil
