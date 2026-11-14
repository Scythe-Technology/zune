local task = zune.task

local testing = require("@zune/testing")
local fs = require("@zune/fs")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("require", function()
    describe("good", function()
        test("known file", function()
            local ok, res = pcall(require, "./samples/simpleLib")
            expect(ok).toBeTruthy()
            expect(res).toBe(expect.any("table"))
            expect(res.size).toBe(32)
            expect(res.buffer).toBe(expect.any("buffer"))
        end)
        test("known file", function()
            local ok, res = pcall(require, ".\\samples\\simpleLib")
            expect(ok).toBeTruthy()
            expect(res).toBe(expect.any("table"))
            expect(res.size).toBe(32)
            expect(res.buffer).toBe(expect.any("buffer"))
        end)
    end)

    describe("bad", function()
        test("bad syntax", function()
            local ok, res = pcall(require, "samples/simpleLib2")
            expect(ok).toBeFalsy()
            expect(res).toBe(`must have either "@", "./", or "../" prefix`)
        end)

        test("bad syntax #2", function()
            local ok, res = pcall(require, "./samples/simpleLib2.luau")
            expect(ok).toBeFalsy()
            expect(res).toBe(`redundant file extension, remove '.luau'`)
        end)

        test("bad syntax #3", function()
            local ok, res = pcall(require, "./samples/simpleLib2.lua")
            expect(ok).toBeFalsy()
            expect(res).toBe(`redundant file extension, remove '.lua'`)
        end)

        local SEP = if zune.platform.os == "windows" then "\\" else "/"
        test("name conflict", function()
            local ok, res = pcall(require, "./generated/duplicate")
            expect(ok).toBeFalsy()
            expect(res).toBe(
                `module name conflicted.\n├─ test{SEP}engine{SEP}generated{SEP}duplicate.luau\n└─ test{SEP}engine{SEP}generated{SEP}duplicate.lua`
            )
        end)

        test("name conflict #2", function()
            local ok, res = pcall(require, "./generated/duplicate2")
            expect(ok).toBeFalsy()
            expect(res).toBe(
                `module name conflicted.\n├─ test{SEP}engine{SEP}generated{SEP}duplicate2.luau\n├─ test{SEP}engine{SEP}generated{SEP}duplicate2.lua\n└─ test{SEP}engine{SEP}generated{SEP}duplicate2{SEP}init.luau`
            )
        end)

        test("name conflict #3", function()
            local ok, res = pcall(require, "./generated/duplicate3")
            expect(ok).toBeFalsy()
            expect(res).toBe(
                `module name conflicted.\n├─ test{SEP}engine{SEP}generated{SEP}duplicate3.luau\n└─ test{SEP}engine{SEP}generated{SEP}duplicate3{SEP}init.luau`
            )
        end)

        test("unknown file", function()
            local ok, res = pcall(require, "./samples/simpleLib2")
            expect(ok).toBeFalsy()
            expect(res:match("%w+ %w+ %w+:")).toBe("module not found:")
        end)

        test("unknown file #2", function()
            local ok, res = pcall(require, "./simpleLib")
            expect(ok).toBeFalsy()
            expect(res:match("%w+ %w+ %w+:")).toBe("module not found:")
        end)

        test("unknown alias", function()
            local ok, res = pcall(require, "@unknown/module")
            expect(ok).toBeFalsy()
            expect(res).toBe("@unknown is not a valid alias")
        end)

        test("config require", function()
            local ok, res = pcall(require, "./.config")
            expect(ok).toBeFalsy()
            expect(res).toBe("not allowed")
        end)
    end)
end)

describe("require many value", function()
    test("validating require context", function()
        expect(_FILE).never.toBeNil()
        expect(debug.info(1, "s"):find("require%.test%.luau")).never.toBeNil()
    end)

    test("require buffer", function()
        expect(require("./generated/v1")).toBe(expect.type("buffer"))
    end)

    test("require number", function()
        expect(require("./generated/v2")).toBe(1)
    end)

    test("require string", function()
        expect(require("./generated/v3")).toBe("Hello, World!")
    end)

    test("require boolean", function()
        expect(require("./generated/v4")).toBe(true)
    end)

    test("require async", function()
        expect(require("./generated/v5")).toBe(true)
    end)

    test("require async queue", function()
        local a, b, c
        local start = os.clock()
        task.spawn(function()
            a = require("./generated/v6")
        end)
        task.spawn(function()
            b = require("./generated/v6")
        end)
        task.spawn(function()
            c = require("./generated/v6")
        end)
        local res = require("./generated/v6")
        expect(os.clock() - start).toBeCloseTo(1, 0)

        expect(a).toBe(res)
        expect(b).toBe(res)
        expect(c).toBe(res)
        task.wait(0.2)
    end)

    test("require async error", function()
        local ok, err = pcall(require, "./generated/yielderror")
        expect(ok).toBe(false)
        expect(err).toBe("requested module failed to load")
        task.wait(0.2)
    end)

    test("require blank", function()
        local ok, err = pcall(require, "./generated/blank")
        expect(ok).toBe(false)
        expect(err).toBe("module did not exactly return one value")
    end)

    test("require tooMany", function()
        local ok, err = pcall(require, "./generated/toomany")
        expect(ok).toBeFalsy()
        assert((string.find(err, "module must return one value")) ~= nil)
    end)

    test("require yield tooMany", function()
        local ok, err = pcall(require, "./generated/yieldtoomany")
        expect(ok).toBeFalsy()
        assert((string.find(err, "module must return one value")) ~= nil)
        task.wait(0.2)
    end)

    test("require cyclic dependency", function()
        local ok, err = pcall(require, "./samples/cyclic")
        expect(ok).toBeFalsy()
        -- Cyclic dependency error message is printed in console.
        expect(err).toBe("requested module failed to load")
        task.wait(0.2)
    end)

    test("large require dependency", function()
        local DEPTH = 40
        local path = zune.require.navigate("./generated/.large")
        fs.makeDir(path, true)
        local function createModule(num: number, stops: boolean?)
            local src = if stops
                then `return \{n = {num}\}`
                else `local _ = require("./lr{num + 1}")\nreturn \{n = {num}\}`
            fs.writeFile(fs.path.join(path, `lr{num}.luau`), src)
        end
        fs.writeFile(fs.path.join(path, "entry.luau"), `require("./lr1") return nil`)
        for i = 1, DEPTH do
            createModule(i, i == DEPTH)
        end

        local ok, res = pcall(require, "./generated/.large/entry")
        expect(ok).toBeTruthy()
        expect(res).toBe(nil)
    end)

    test("large async require dependency", function()
        local DEPTH = 40
        local path = zune.require.navigate("./generated/.large-async")
        fs.makeDir(path, true)
        local function createModule(num: number, stops: boolean?)
            local src = if stops
                then `zune.task.wait()\nreturn \{n = {num}\}`
                else `local _ = require("./lr{num + 1}")\nzune.task.wait()\nreturn \{n = {num}\}`
            fs.writeFile(fs.path.join(path, `lr{num}.luau`), src)
        end
        fs.writeFile(fs.path.join(path, "entry.luau"), `require("./lr1") return nil`)
        for i = 1, DEPTH do
            createModule(i, i == DEPTH)
        end

        local ok, res = pcall(require, "./generated/.large-async/entry")
        expect(ok).toBeTruthy()
        expect(res).toBe(nil)
    end)

    test("require depth overflow", function()
        local DEPTH = 1000
        local path = zune.require.navigate("./generated/.large-overflow")
        fs.makeDir(path, true)
        local function createModule(num: number, stops: boolean?)
            local src = if stops
                then `return \{n = {num}\}`
                else `local _ = require("./lr{num + 1}")\nreturn \{n = {num}\}`
            fs.writeFile(fs.path.join(path, `lr{num}.luau`), src)
        end
        fs.writeFile(fs.path.join(path, "entry.luau"), `require("./lr1") return nil`)
        for i = 1, DEPTH do
            createModule(i, i == DEPTH)
        end

        local ok, err = pcall(require, "./generated/.large-overflow/entry")
        expect(ok).toBeFalsy()
        expect(err).toBe("requested module failed to load")
    end)

    test("require async depth overflow", function()
        local DEPTH = 1000
        local path = zune.require.navigate("./generated/.large-async-overflow")
        fs.makeDir(path, true)
        local function createModule(num: number, stops: boolean?)
            local src = if stops
                then `zune.task.wait()\nreturn \{n = {num}\}`
                else `local _ = require("./lr{num + 1}")\nzune.task.wait()\nreturn \{n = {num}\}`
            fs.writeFile(fs.path.join(path, `lr{num}.luau`), src)
        end
        fs.writeFile(fs.path.join(path, "entry.luau"), `require("./lr1") return nil`)
        for i = 1, DEPTH do
            createModule(i, i == DEPTH)
        end

        local ok, err = pcall(require, "./generated/.large-async-overflow/entry")
        expect(ok).toBeFalsy()
        expect(err).toBe("requested module failed to load")
    end)
end)

describe("require .lua", function()
    test("require module", function()
        expect(require("./legacy")).toBe(expect.similar({
            "Legacy",
        }))
    end)
    test("require a", function()
        expect(require("./legacy/A")).toBe("A-Legacy")
    end)
end)

describe("aliases", function()
    test("@dev", function()
        local dev = require("@dev") :: any
        expect(dev).toBe(expect.similar({
            Boolean = true,
            Number = 1,
            String = "string",
        }))
    end)

    test("@module", function()
        local module = require("@module") :: any
        expect(module).toBe(expect.type("string"))
        expect(module).toBe("FullModule")
    end)

    test("@module/sub", function()
        local module = require("@module/sub") :: any
        expect(module).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }))
        expect(module.foo()).toBe("foo")
        expect(module.bar()).toBe("bar")
    end)

    test("@sub/kool (overrides sub)", function()
        local module = require("@sub/kool") :: any
        expect(module).toBe("Sub library")
    end)

    test("@sub/subdir/foo", function()
        local module = require("@sub/subdir/foo") :: any
        expect(module).toBe("The bar exam")
    end)

    test("@subd/foo", function()
        local module = require("@subd/foo") :: any
        expect(module).toBe("The bar exam")
    end)

    test("@alias_path, @alias path", function()
        local ok, err = pcall(require, "@alias_path")
        expect(ok).toBeFalsy()
        expect(err).toBe('alias "@alias_path" cannot point to an aliased path ("@test")')
    end)

    test("@unknown_path, no prefix path", function()
        local ok, err = pcall(require, "@unknown_path")
        expect(ok).toBeFalsy()
        expect(err).toBe('could not jump to alias "test"')
    end)

    local HOME = zune.process.env.HOME or zune.process.env.USERPROFILE
    test("@home", function()
        local ok, err = pcall(require, "@home")
        expect(ok).toBeFalsy()
        expect(err).toBe(`module not found: "{HOME}"`)
    end)

    test("@home_sub", function()
        local ok, err = pcall(require, "@home_sub")
        expect(ok).toBeFalsy()
        expect(err).toBe(`module not found: "{zune.fs.path.join(HOME, "sub_path")}"`)
    end)
end)

describe("require with context", function()
    test("require module", function()
        local func = require("./generated/relative")
        expect(func).toBe(expect.type("function"))
        expect(func()).toBe(expect.type("buffer"))
    end)
end)

describe("amended requires in init files", function()
    test("require child", function()
        local withinit = require("./module/withinit")
        expect(withinit.child.t).toBe("child")
    end)

    test("require sibling", function()
        local withinit = require("./module/withinit")
        expect(withinit.sibling).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }))
    end)

    test("require parent sibling", function()
        local desc = require("./module/withinit/descendant")
        expect(desc.parent_sibling).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }))
    end)

    test("bad require", function()
        local ok, err = pcall(require, "./module/withinit_bad")
        expect(ok).toBeFalsy()
        -- No alias error message will be printed in console
        expect(err).toBe("requested module failed to load")
    end)
end)
