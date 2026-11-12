--!strict
local regex = zune.regex

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("regex", function()
    test("match", function()
        local re = regex.create("a(b+)c")

        expect(re:match("abbc")).toBe(expect.similar({
            { string = "abbc", index = 1 },
            { string = "bb", index = 2 },
        }))

        expect(re:match("  abbc")).toBeNil()
    end)

    test("search", function()
        local re = regex.create("a(b+)c")

        expect(re:search("abbc")).toBe(expect.similar({
            { string = "abbc", index = 1 },
            { string = "bb", index = 2 },
        }))

        expect(re:search("  abbc")).toBe(expect.similar({
            { string = "abbc", index = 3 },
            { string = "bb", index = 4 },
        }))
    end)

    describe("captures", function()
        test("basic", function()
            local re = regex.create("a(b+)c")

            expect(re:captures("abbc")).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("abbc abbbc")).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))
        end)
        test("global flag", function()
            local re = regex.create("a(b+)c")

            expect(re:captures("abbc", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("abbc abbbc", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
                {
                    { string = "abbbc", index = 6 },
                    { string = "bbb", index = 7 },
                },
            }))
        end)
        test("multiline flag", function()
            local re = regex.create("a(b+)c", "m")

            expect(re:captures("abbc")).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("abbc abbbc\nabbc abbbc\n")).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))
        end)
        test("caseInsensitive flag", function()
            local re = regex.create("a(b+)c", "i")

            expect(re:captures("abbc")).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("ABBC")).toBe(expect.similar({
                {
                    { string = "ABBC", index = 1 },
                    { string = "BB", index = 2 },
                },
            }))
        end)
        test("unicode flag", function()
            local re = regex.create("a(🍕+)c", "u")

            expect(re:captures("a🍕🍕c")).toBe(expect.similar({
                {
                    { string = "a🍕🍕c", index = 1 },
                    { string = "🍕🍕", index = 2 },
                },
            }))

            expect(re:captures("a🍕🍕c a🍕🍕🍕c\na🍕🍕c a🍕🍕🍕c\n")).toBe(expect.similar({
                {
                    { string = "a🍕🍕c", index = 1 },
                    { string = "🍕🍕", index = 2 },
                },
            }))
        end)
        test("global/caseInsensitive flag", function()
            local re = regex.create("a(b+)c", "i")

            expect(re:captures("abbc", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("abbc abbbc", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
                {
                    { string = "abbbc", index = 6 },
                    { string = "bbb", index = 7 },
                },
            }))

            expect(re:captures("ABBC ABBBC", true)).toBe(expect.similar({
                {
                    { string = "ABBC", index = 1 },
                    { string = "BB", index = 2 },
                },
                {
                    { string = "ABBBC", index = 6 },
                    { string = "BBB", index = 7 },
                },
            }))
        end)
        test("global/multiline flag", function()
            local re = regex.create("a(b+)c", "m")

            expect(re:captures("abbc", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("abbc abbbc\nabbc abbbc\n", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
                {
                    { string = "abbbc", index = 6 },
                    { string = "bbb", index = 7 },
                },
                {
                    { string = "abbc", index = 12 },
                    { string = "bb", index = 13 },
                },
                {
                    { string = "abbbc", index = 17 },
                    { string = "bbb", index = 18 },
                },
            }))
        end)
        test("global/multiline/caseInsensitive flag", function()
            local re = regex.create("a(b+)c", "mi")

            expect(re:captures("abbc", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
            }))

            expect(re:captures("abbc abbbc\nabbc abbbc\n", true)).toBe(expect.similar({
                {
                    { string = "abbc", index = 1 },
                    { string = "bb", index = 2 },
                },
                {
                    { string = "abbbc", index = 6 },
                    { string = "bbb", index = 7 },
                },
                {
                    { string = "abbc", index = 12 },
                    { string = "bb", index = 13 },
                },
                {
                    { string = "abbbc", index = 17 },
                    { string = "bbb", index = 18 },
                },
            }))

            expect(re:captures("ABBC ABBBC\nABBC ABBBC\n", true)).toBe(expect.similar({
                {
                    { string = "ABBC", index = 1 },
                    { string = "BB", index = 2 },
                },
                {
                    { string = "ABBBC", index = 6 },
                    { string = "BBB", index = 7 },
                },
                {
                    { string = "ABBC", index = 12 },
                    { string = "BB", index = 13 },
                },
                {
                    { string = "ABBBC", index = 17 },
                    { string = "BBB", index = 18 },
                },
            }))
        end)
    end)

    test("split", function()
        local re = regex.create("b+")

        expect(re:split("abbc")).toBe(expect.similar({
            "a",
            "c",
        }))

        expect(re:split("abbccabcacbc")).toBe(expect.similar({
            "a",
            "ccabcacbc",
        }))

        expect(re:split("abbccabcacbc", true)).toBe(expect.similar({
            "a",
            "cca",
            "cac",
            "c",
        }))
    end)

    test("isMatch", function()
        local re = regex.create("a(b+)c")

        expect(re:isMatch("abbc")).toBe(true)
        expect(re:isMatch("  abbc")).toBe(false)
        expect(re:isMatch("abc")).toBe(true)
    end)

    test("format", function()
        local re = regex.create("(b+)")

        expect(re:format("abbc", "1=$1")).toBe("1=bb")
    end)

    test("format extended", function()
        local re = regex.create("(B+)")

        expect(re:format("aBBc", "1=\\L$1")).toBe("1=bb")
    end)

    test("replace", function()
        local re = regex.create("b+")

        expect(re:replace("abbc", "")).toBe("ac")
        expect(re:replace("  abbc", "")).toBe("  ac")
        expect(re:replace("abc", "bb")).toBe("abbc")
        expect(re:replace("abc abc", "bb")).toBe("abbc abc")
    end)

    test("replaceAll", function()
        local re = regex.create("b+")

        expect(re:replaceAll("abbc", "")).toBe("ac")
        expect(re:replaceAll("  abbc", "")).toBe("  ac")
        expect(re:replaceAll("abc", "bb")).toBe("abbc")
        expect(re:replaceAll("abc abc", "bb")).toBe("abbc abbc")
    end)

    test("replace caseInsensitive", function()
        local re = regex.create("b+", "i")

        expect(re:replace("ABBC", "")).toBe("AC")
        expect(re:replace("  ABBC", "")).toBe("  AC")
        expect(re:replace("ABC", "bb")).toBe("AbbC")
        expect(re:replace("ABC ABC", "bb")).toBe("AbbC ABC")
    end)

    test("replaceAll caseInsensitive", function()
        local re = regex.create("b+", "i")

        expect(re:replaceAll("ABBC", "")).toBe("AC")
        expect(re:replaceAll("  ABBC", "")).toBe("  AC")
        expect(re:replaceAll("ABC", "bb")).toBe("AbbC")
        expect(re:replaceAll("ABC ABC", "bb")).toBe("AbbC AbbC")
    end)
end)
