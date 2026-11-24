--!strict

local fs = require("@zune/fs")
local script = require("@zune/script")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function load(name: string, source: string): () -> ...any
    return zune.luau.load(
        zune.luau.compile(source, {
            debug_level = 2,
        }),
        {
            chunk_name = name,
            env = {
                script = script,
            },
        }
    )
end

describe("script", function()
    test("relative", function()
        expect(load("@src/main.luau", 'return script.relative("assets/icon.png")\n')()).toBe(
            fs.path.resolve(fs.path.join("src", "assets/icon.png"))
        )

        expect(load("@src/main.luau", 'return script.relative("../note.txt")\n')()).toBe("note.txt")
        expect(load("@src/init.luau", 'return script.relative("../note.txt")\n')()).toBe("note.txt")

        expect(load("@/absolute/main.luau", 'return script.relative("note.txt")\n')()).toBe("/absolute/note.txt")

        expect(script.relative("")).never.toBeNil()

        expect(function()
            script.relative("/tmp/note.txt")
        end).toThrow("path must be relative")

        local missing = load("=chunk", 'return script.relative("note.txt")\n')
        expect(missing).toThrow("script source is missing")
    end)
end)

return nil
