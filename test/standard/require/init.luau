local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local foo = require("@self/module/foo");

local this_path = debug.info(1, "s");

local _7 = if zune.platform.os == "windows" then "\\" else "/";

describe("require", function()
    local RelativeAlias = [[{
        "aliases": {
            "test": "./"
        }
    }]];

    test("current context", function()
        local path = zune.require.navigate("@self/module/foo");
        expect(path).toBe(`test{_7}standard{_7}require{_7}module{_7}foo`);
        expect(zune.require.getCached(path)).toBe(expect.similar({"foo"}));
    end)
    test("navigated require", function()
        local path = zune.require.navigate("@self/module/bar");
        local relative = zune.fs.path.relative(zune.fs.path.dirname(this_path) or "./", path);
        expect(relative).toBe(`module{_7}bar`);
        expect(zune.require.getCached(relative)).toBeNil();
        local bar = require(`./require/{relative}`);
        expect(bar).toBe(expect.similar({"bar"}));
        expect(zune.require.getCached(path)).toBe(bar);
    end)
    test("custom config", function()
        local path = zune.require.navigate("@test/foo", this_path, RelativeAlias);
        expect(path).toBe(`test{_7}standard{_7}foo`);
    end)
    test("custom config and context", function()
        do
            local path = zune.require.navigate("@test/foo", "", RelativeAlias);
            expect(path).toBe(`foo`);
        end
        do
            local path = zune.require.navigate("@test/foo", "src/main", RelativeAlias);
            expect(path).toBe(`src{_7}foo`);
        end
    end)
end)

