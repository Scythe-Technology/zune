local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Require", function()
    describe("Good", function()
        test("Known File", function()
            local ok, res = pcall(require, "./samples/simpleLib");
            expect(ok).toBeTruthy();
            expect(res).toBe(expect.any("table"));
            expect(res.size).toBe(32);
            expect(res.buffer).toBe(expect.any("buffer"));
        end)
        test("Known File", function()
            local ok, res = pcall(require, ".\\samples\\simpleLib");
            expect(ok).toBeTruthy();
            expect(res).toBe(expect.any("table"));
            expect(res.size).toBe(32);
            expect(res.buffer).toBe(expect.any("buffer"));
        end)
    end)

    describe("Bad", function()
        test("Bad Syntax", function()
            local ok, res = pcall(require, "samples/simpleLib2");
            expect(ok).toBeFalsy();
            expect(res).toBe(`must have either "@", "./", or "../" prefix`);
        end)

        test("Bad Syntax #2", function()
            local ok, res = pcall(require, "./samples/simpleLib2.luau");
            expect(ok).toBeFalsy();
            expect(res).toBe(`redundant file extension, remove '.luau'`);
        end)

        test("Bad Syntax #3", function()
            local ok, res = pcall(require, "./samples/simpleLib2.lua");
            expect(ok).toBeFalsy();
            expect(res).toBe(`redundant file extension, remove '.lua'`);
        end)

        local SEP = if zune.platform.os == "windows" then "\\" else "/"
        test("Name Conflict", function()
            local ok, res = pcall(require, "./generated/duplicate");
            expect(ok).toBeFalsy();
            expect(res).toBe(`module name conflicted.\n├─ test{SEP}engine{SEP}generated{SEP}duplicate.luau\n└─ test{SEP}engine{SEP}generated{SEP}duplicate.lua`);
        end)

        test("Name Conflict #2", function()
            local ok, res = pcall(require, "./generated/duplicate2");
            expect(ok).toBeFalsy();
            expect(res).toBe(`module name conflicted.\n├─ test{SEP}engine{SEP}generated{SEP}duplicate2.luau\n├─ test{SEP}engine{SEP}generated{SEP}duplicate2.lua\n└─ test{SEP}engine{SEP}generated{SEP}duplicate2{SEP}init.luau`);
        end)

        test("Name Conflict #3", function()
            local ok, res = pcall(require, "./generated/duplicate3");
            expect(ok).toBeFalsy();
            expect(res).toBe(`module name conflicted.\n├─ test{SEP}engine{SEP}generated{SEP}duplicate3.luau\n└─ test{SEP}engine{SEP}generated{SEP}duplicate3{SEP}init.luau`);
        end)

        test("Unknown File", function()
            local ok, res = pcall(require, "./samples/simpleLib2");
            expect(ok).toBeFalsy();
            expect(res:match("%w+ %w+ %w+:")).toBe("module not found:");
        end)

        test("Unknown File #2", function()
            local ok, res = pcall(require, "./simpleLib");
            expect(ok).toBeFalsy();
            expect(res:match("%w+ %w+ %w+:")).toBe("module not found:");
        end)

        test("Unknown Alias", function()
            local ok, res = pcall(require, "@unknown/module");
            expect(ok).toBeFalsy();
            expect(res).toBe("@unknown is not a valid alias");
        end)
    end)
end)

describe("Require Many Value", function()
    test("Validating Require Context", function()
        expect(_FILE).never.toBeNil();
        expect(debug.info(1, "s"):find("require%.test%.luau")).never.toBeNil();
    end)
    
    test("Require Buffer", function()
        expect(require("./generated/v1")).toBe(expect.type("buffer"));
    end)
    
    test("Require Number", function()
        expect(require("./generated/v2")).toBe(1);
    end)
    
    test("Require String", function()
        expect(require("./generated/v3")).toBe("Hello, World!");
    end)
    
    test("Require Boolean", function()
        expect(require("./generated/v4")).toBe(true);
    end)

    test("Require Async", function()
        expect(require("./generated/v5")).toBe(true);
    end)

    test("Require Async Queue", function()
        local a, b, c;
        local start = os.clock();
        task.spawn(function()
            a = require("./generated/v6")
        end)
        task.spawn(function()
            b = require("./generated/v6")
        end)
        task.spawn(function()
            c = require("./generated/v6")
        end)
        local res = require("./generated/v6");
        expect(os.clock() - start).toBeCloseTo(1, 0);

        expect(a).toBe(res);
        expect(b).toBe(res);
        expect(c).toBe(res);
        task.wait(0.2);
    end)

    test("Require Async Error", function()
        local success, err = pcall(require, ("./generated/yielderror"));
        expect(success).toBe(false);
        expect(err).toBe("requested module failed to load");
        task.wait(0.2);
    end)
    
    test("Require Blank", function()
        local res = require(("./generated/blank"))::any;
        expect(res).toBe(nil);
    end)
    
    test("Require TooMany", function()
        local ok, err = pcall(require, ("./generated/toomany"));
        expect(ok).toBeFalsy();
        assert((string.find(err, "module must return one value")) ~= nil);
    end)

    test("Require Yield TooMany", function()
        local ok, err = pcall(require, ("./generated/yieldtoomany"));
        expect(ok).toBeFalsy();
        assert((string.find(err, "module must return one value")) ~= nil);
        task.wait(0.2);
    end)

    test("Require Cyclic Dependency", function()
        local ok, err = pcall(require, ("./samples/cyclic"));
        expect(ok).toBeFalsy();
        -- Cyclic dependency error message is printed in console.
        expect(err).toBe("requested module failed to load");
        task.wait(0.2);
    end)
end)

describe("Require .lua", function()
    test("Require Module", function()
        expect(require("./legacy")).toBe(expect.similar({
            "Legacy"
        }));
    end)
    test("Require A", function()
        expect(require("./legacy/A")).toBe("A-Legacy");
    end)
end)

describe("Aliases", function()
    test("@Dev", function()
        local dev = require("@dev")::any;
        expect(dev).toBe(expect.similar({
            Boolean = true,
            Number = 1,
            String = "string",
        }));
    end)
    
    test("@Module", function()
        local module = require("@module")::any;
        expect(module).toBe(expect.type("string"));
        expect(module).toBe("FullModule");
    end)

    test("@Module/sub", function()
        local module = require("@module/sub")::any;
        expect(module).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }));
        expect(module.foo()).toBe("foo");
        expect(module.bar()).toBe("bar");
    end)

    test("@Sub/kool (overrides sub)", function()
        local module = require("@sub/kool")::any;
        expect(module).toBe("Sub library");
    end)

    test("@Sub/subdir/foo", function()
        local module = require("@sub/subdir/foo")::any;
        expect(module).toBe("The bar exam");
    end)

    test("@Subd/foo", function()
        local module = require("@subd/foo")::any;
        expect(module).toBe("The bar exam");
    end)

    test("@Alias_path, @alias path", function()
        local ok, err = pcall(require, "@alias_path");
        expect(ok).toBeFalsy();
        expect(err).toBe("alias \"@alias_path\" cannot point to an aliased path (\"@test\")");
    end)

    test("@Unknown_path, no prefix path", function()
        local ok, err = pcall(require, "@unknown_path");
        expect(ok).toBeFalsy();
        expect(err).toBe("could not jump to alias \"test\"");
    end)

    local HOME = zune.process.env.HOME
    test("@Home", function()
        local ok, err = pcall(require, "@home");
        expect(ok).toBeFalsy();
        expect(err).toBe(`module not found: "{HOME}"`);
    end)

     test("@Home_Sub", function()
        local ok, err = pcall(require, "@home_sub");
        expect(ok).toBeFalsy();
        expect(err).toBe(`module not found: "{zune.fs.path.join(HOME, "sub_path")}"`);
    end)
end)

describe("Require with Context", function()
    test("Require Module", function()
        local func = require("./generated/relative");
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe(expect.type("buffer"));
    end)
end)

describe("Amended Requires in Init Files", function()
    test("Require Child", function()
        local withinit = require("./module/withinit")
        expect(withinit.child.t).toBe("child")
    end)
    
    test("Require Sibling", function()
        local withinit = require("./module/withinit")
        expect(withinit.sibling).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }))
    end)
    
    test("Require Parent Sibling", function()
        local desc = require("./module/withinit/descendant")
        expect(desc.parent_sibling).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }))
    end)
    
    test("Bad Require", function()
        local ok, err = pcall(require, "./module/withinit_bad")
        expect(ok).toBeFalsy();
        -- No alias error message will be printed in console
        expect(err).toBe("requested module failed to load")
    end)
end)