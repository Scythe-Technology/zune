--!strict

local SemanticVersion = require("@zune/SemanticVersion")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function assertedVersion(text: string): SemanticVersion.Version
    return assert(SemanticVersion.parse(text), "failed to parse")
end

describe("parse", function()
    test("basic", function()
        local parsed = assertedVersion("1.2.3-alpha.1+001.build")
        expect(parsed.major).toBe(1)
        expect(parsed.minor).toBe(2)
        expect(parsed.patch).toBe(3)
        expect(parsed.prerelease[1]).toBe("alpha")
        expect(parsed.prerelease[2]).toBe("1")
        expect(#parsed.prerelease).toBe(2)
        expect(parsed.build[1]).toBe("001")
        expect(parsed.build[2]).toBe("build")
        expect(#parsed.build).toBe(2)
    end)

    test("valid", function()
        expect(SemanticVersion.parse("0.0.0")).toBeTruthy()
        expect(SemanticVersion.parse("1.2.3-0")).toBeTruthy()
        expect(SemanticVersion.parse("1.2.3-alpha-beta")).toBeTruthy()
        expect(SemanticVersion.parse("1.2.3+01")).toBeTruthy()
    end)

    test("invalid", function()
        expect(SemanticVersion.parse("")).toBeNil()
        expect(SemanticVersion.parse("1.2")).toBeNil()
        expect(SemanticVersion.parse("01.2.3")).toBeNil()
        expect(SemanticVersion.parse("1.02.3")).toBeNil()
        expect(SemanticVersion.parse("1.2.3-01")).toBeNil()
        expect(SemanticVersion.parse("1.2.3-")).toBeNil()
        expect(SemanticVersion.parse("1.2.3+")).toBeNil()
        expect(SemanticVersion.parse("1.2.3-alpha..1")).toBeNil()
        expect(SemanticVersion.parse("+1.2.3")).toBeNil()
    end)
end)

describe("compare", function()
    test("order", function()
        local chain = {
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
            "2.0.0",
            "2.1.0",
            "2.1.1",
        }
        for i = 1, #chain - 1 do
            local order = SemanticVersion.compare(assertedVersion(chain[i]), assertedVersion(chain[i + 1]))
            expect(order).toBe(-1)
        end
        expect(SemanticVersion.compare(assertedVersion("1.0.0"), assertedVersion("1.0.0"))).toBe(0)
    end)

    test("build", function()
        expect(SemanticVersion.compare(assertedVersion("1.0.0+aaa"), assertedVersion("1.0.0+zzz"))).toBe(0)
        expect(SemanticVersion.compare(assertedVersion("1.0.0-1"), assertedVersion("1.0.0-a"))).toBe(-1)
        expect(SemanticVersion.compare(assertedVersion("1.0.0"), assertedVersion("1.0.0-rc.1"))).toBe(1)
    end)
end)

return nil
