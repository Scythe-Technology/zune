--!strict

local git = require("@zune/package/git")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local OID40 = "0123456789abcdef0123456789abcdef01234567"
local OID64 = `{OID40}89abcdef0123456789abcdef`

describe("parse", function()
    test("pin", function()
        local base, oid = git.parse(`git+https://example.com/repo.git#{OID40}`)
        expect(base).toBe("https://example.com/repo.git")
        expect(oid).toBe(OID40)

        base, oid = git.parse(`git+https://example.com/repo#{string.upper(OID40)}`)
        expect(base).toBe("https://example.com/repo.git")
        expect(oid).toBe(OID40)

        base, oid = git.parse(`git+ssh://git@example.com/repo#{OID64}`)
        expect(base).toBe("ssh://git@example.com/repo.git")
        expect(oid).toBe(OID64)

        base, oid = git.parse(`git+https://example.com/repo.git#{string.upper(OID64)}`)
        expect(base).toBe("https://example.com/repo.git")
        expect(oid).toBe(OID64)
    end)

    test("reject", function()
        expect(function()
            git.parse(`https://example.com/repo.git#{OID40}`)
        end).toThrow("not a git url")

        local bad = {
            "git+https://example.com/repo.git",
            `git+https://example.com/repo.git#`,
            "git+https://example.com/repo.git#abc",
            `git+https://example.com/repo.git#{string.rep("z", 40)}`,
            `git+https://example.com/repo.git#{string.rep("a", 39)}`,
            `git+https://example.com/repo.git#{string.rep("a", 41)}`,
            `git+https://example.com/repo.git#{string.rep("a", 63)}`,
            `git+https://example.com/repo.git#{string.rep("a", 65)}`,
        }
        for _, url in bad do
            expect(function()
                git.parse(url)
            end).toThrow("git pin must be a commit")
        end
    end)
end)

return nil
