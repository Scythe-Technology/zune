--!strict
local luau = zune.luau;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function makeLine(line : number)
    return string.rep("\n", line - 1);
end

describe("Compile", function()
    test("Basic", function()
        local bytecode = luau.compile("print('Hello, World!')");
        expect(buffer.tostring(bytecode)).toBe("\x06\x03\x02\x05print\rHello, World!\x00\x01\x02\x00\x00\x01\x02\x00\x06A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x05\x01\x02\x00\x15\x00\x02\x01\x16\x00\x01\x00\x03\x03\x01\x04\x00\x00\x00@\x03\x02\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
    end)

    test("Options", function()
        local bytecode = luau.compile("print('Hello!')", {
            optimization_level = 0,
            debug_level = 0,
            coverage_level = 2,
        });
        local bytecode2 = luau.compile("print('Hello!')", {
            optimization_level = 1,
            debug_level = 1,
            coverage_level = 0,
        });
        expect(buffer.tostring(bytecode)).toBe("\x06\x03\x02\x05print\x06Hello!\x00\x01\x02\x00\x00\x01\x02\x00\tA\x00\x00\x00E\x00\x00\x00E\x00\x00\x00\a\x00\x00F\x00\x00\x00\x00E\x00\x00\x00\x05\x01\x01\x00\x15\x00\x02\x01\x16\x00\x01\x00\x02\x03\x01\x03\x02\x00\x01\x00\x00\x00\x00");
        expect(buffer.tostring(bytecode2)).toBe("\x06\x03\x02\x05print\x06Hello!\x00\x01\x02\x00\x00\x01\x02\x00\x06A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x05\x01\x02\x00\x15\x00\x02\x01\x16\x00\x01\x00\x03\x03\x01\x04\x00\x00\x00@\x03\x02\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        expect(buffer.tostring(bytecode)).never.toBe(buffer.tostring(bytecode2));
    end)

    test("Error Basic", function()
        expect(function()
            local _ = luau.compile(makeLine(1).."a");
        end).toThrow(":1: Incomplete statement: expected assignment or a function call");
    end)

    test("Error Basic (Line)", function()
        expect(function()
            luau.compile(makeLine(1234).."a");
        end).toThrow(":1234: Incomplete statement: expected assignment or a function call");
    end)
end)

local function returnStringBytecode(str : string)
    return `\x06\x03\x01{string.char(#str)}{str}\x00\x01\x01\x00\x00\x01\x02\x00\x03A\x00\x00\x00\x05\x00\x00\x00\x16\x00\x02\x00\x01\x03\x01\x00\x01\x00\x01\x18\x00\x00\x00\x01\x00\x00\x00\x00\x00`
end

local function timeFunction(f: (...any) -> (...any))
    local start = os.clock();
    f();
    return os.clock() - start;
end

describe("Load", function()
    local bytecode = luau.compile("return 'Hello, World!'");
    expect(buffer.tostring(bytecode)).toBe(returnStringBytecode "Hello, World!");
    
    test("Basic", function()
        local func = luau.load(bytecode);
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Hello, World!");
    end)

    test("Basic", function()
        local func = luau.load(bytecode);
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Hello, World!");
    end)

    test("Options", function()
        local bCode = luau.compile("return a");
        expect(buffer.tostring(bCode)).toBe("\x06\x03\x01\x01a\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local func = luau.load(bCode, {
            env = {
                a = "Foo",
            }
        });
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Foo");
    end)

    test("Options (2)", function()
        local bCode = luau.compile("return a()");
        expect(buffer.tostring(bCode)).toBe("\x06\x03\x01\x01a\x00\x01\x01\x00\x00\x01\x02\x00\x05A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x15\x00\x01\x00\x16\x00\x00\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local func = luau.load(bCode, {
            chunk_name = "test",
        });
        expect(func).toBe(expect.type("function"));
        expect(func).toThrow(`attempt to call a nil value`);
    end)

    describe("CodeGen", function()
        local function native()
            local size = 2e5;
            local buf = buffer.create(size);
            for i = 1, size do
                buffer.writeu8(buf, i - 1, i);
            end
        end
        local bCode = luau.compile([[
            local size = 2e5;
            local buf = buffer.create(size);
            for i = 1, size do
                buffer.writeu8(buf, i - 1, i);
            end
        ]]);
        local safeNativeTime = timeFunction(native);
        test("Basic (NCG Enabled)", function()
            local func = luau.load(bCode, {
                native_code_gen = true;
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(safeNativeTime, 0.5);
        end)

        test("New Environment (NCG Enabled)", function()
            local func = luau.load(bCode, {
                native_code_gen = true;
                env = {
                    buffer = buffer,
                };
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(safeNativeTime, 0.5);
        end)

        getfenv(); -- Force unsafe environment

        local UnsafeNativeTime = timeFunction(native);

        test("Basic (NCG Disabled)", function()
            local func = luau.load(bCode, {
                native_code_gen = false;
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(UnsafeNativeTime, -0.25);
        end)

        test("New Environment (NCG Disabled)", function()
            local func = luau.load(bCode, {
                native_code_gen = false;
                env = {
                    buffer = buffer,
                };
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(UnsafeNativeTime, -0.5); -- could be much faster, since it is a stripped environment
        end)

        test("Basic (NCG Enabled, Unsafe)", function()
            local func = luau.load(bCode, {
                native_code_gen = true;
            });
            expect(func).toBe(expect.type("function"));
            -- Should be slower than the safe native time, because the global environment is unsafe
            expect(timeFunction(func)).toBeCloseTo(UnsafeNativeTime, -1);
        end)

        test("New Environment (NCG Enabled, Unsafe)", function()
            local func = luau.load(bCode, {
                native_code_gen = true;
                env = {
                    buffer = buffer,
                };
            });
            expect(func).toBe(expect.type("function"));
            -- Should be faster than the unsafe native time, because the environment is safe (custom table)
            expect(timeFunction(func)).toBeCloseTo(safeNativeTime, 0.5);
        end)
    end)

    test("Environment", function()
        local bCode = luau.compile("return require");
        expect(buffer.tostring(bCode)).toBe("\x06\x03\x01\arequire\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local func = luau.load(bCode, {
            chunk_name = "test",
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv(func)).toBe(getfenv());
        expect(func()).toBe(require);
    end)

    test("Environment (2)", function()
        local bCode = luau.compile("return require");
        expect(buffer.tostring(bCode)).toBe("\x06\x03\x01\arequire\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local env = {};
        local func = luau.load(bCode, {
            chunk_name = "test",
            env = env,
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv()).never.toBe(env); -- make sure load didn't change the environment
        expect(getfenv(func)).toBe(env); -- make sure the environment is the one we passed
        expect(func()).toBe(nil);
    end)

    test("Environment (3)", function()
        local bCode = luau.compile("return require");
        expect(buffer.tostring(bCode)).toBe("\x06\x03\x01\arequire\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local env = setmetatable({}, {});
        local func = luau.load(bCode, {
            chunk_name = "test",
            env = env,
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv()).never.toBe(env); -- make sure load didn't change the environment
        expect(getfenv(func)).toBe(env); -- make sure the environment is the one we passed
        expect(func()).toBe(nil);
    end)

    test("Environment (4)", function()
        local bCode = luau.compile("return function() return require end");
        expect(buffer.tostring(bCode)).toBe("\x06\x03\x01\arequire\x00\x02\x01\x00\x00\x00\x00\x00\x03\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x01\x00\x00\x00\x00\x01\x00\x00\x01\x02\x00\x03A\x00\x00\x00@\x00\x00\x00\x16\x00\x02\x00\x01\x06\x00\x01\x00\x01\x00\x01\x18\x00\x00\x00\x01\x00\x00\x00\x00\x01");
        local indexed = nil
        local env = setmetatable(
            {},
            {
                __index = function(_, key)
                    indexed = key
                    return nil
                end
            }
        );
        local func = luau.load(bCode, {
            chunk_name = "test",
            env = env,
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv()).never.toBe(env); -- make sure load didn't change the environment
        expect(getfenv(func)).toBe(env); -- make sure the environment is the one we passed
        expect(func()()).toBe(nil);
        expect(indexed).toBe("require");
    end)

    test("Literal", function()
        local func = luau.load(returnStringBytecode "Hello!");
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Hello!");
    end)
end)

test("Coverage", function()
    local bytecode = luau.compile([[
        local function nothing() --*hit* (main)
            local a = 0        --_____ (nothing)
            a += 1             --_____ (nothing)
        end
        local function bar()     --*hit* (main)
            local a = 0        --*hit* (bar)
            a += 1             --*hit* (bar)
        end
        local function foo()     --*hit* (main)
            bar()              --*hit* (foo)
        end
        foo()                    --*hit* (main)
    ]], {coverage_level = 2});

    local load = luau.load(bytecode, {
        chunk_name = "test",
    });

    load();

    local coverage = luau.coverage(load);

    expect(coverage).toBe(expect.similar({
        [1] = { -- main
            line = 1,
            depth = 0,
            [1] = 1,
            [5] = 1,
            [9] = 1,
            [12] = 1,
        },
        [2] = { -- nothing
            name = "nothing",
            line = 1,
            depth = 1,
            [2] = 0, -- no hits
            [3] = 0,
        },
        [3] = { -- bar
            name = "bar",
            line = 5,
            depth = 1,
            [6] = 1,
            [7] = 1,
        },
        [4] = { -- foo
            name = "foo",
            line = 9,
            depth = 1,
            [10] = 1,
        },
    }));
end)

describe("Parse", function()
    local path = zune.require.navigate("./test/parse")
    for _, file in zune.fs.entries(path) do
        if (file.kind ~= "file") then
            continue;
        end
        local content = zune.fs.readFile(zune.fs.path.join(path, file.name));

        local lines = content:gsub("\r\n", "\n"):gsub("\r", "\n"):split("\n");
        local result_content
        local test_content
        for i = #lines, 1, -1 do
            local line = lines[i];
            local start_pos, end_pos = line:find("^%s*%-%-%[%[%s*@result%s*");
            if (start_pos and end_pos) then
                lines[i] = line:sub(end_pos + 1, -1);
                for i = #lines, i, -1 do
                    local close_start_pos, close_end_pos = lines[i]:find("%]%]%s*$");
                    if (close_start_pos and close_end_pos) then
                        lines[i] = lines[i]:sub(1, close_start_pos - 1);
                        break;
                    end
                end
                result_content = table.concat(lines, "\n", i);
                test_content = table.concat(lines, "\n", 1, i - 1);
                break;
            end
        end
        if (not test_content or not result_content) then
            error(`could not find @result in {file.name}`);
        end
        local result, fflags = luau.load(luau.compile(`return {result_content}`))();

        local old_fflags = {};
        if (fflags) then
            for name, value in fflags do
                old_fflags[name] = luau.fflag.get(name);
                luau.fflag.set(name, value);
            end
        end

        test(`Parse Test ({file.name})`, function()
            local res = luau.parse(test_content);
            expect(res).toBe(expect.similar(result));
        end)

        if (fflags) then
            for name, value in old_fflags do
                luau.fflag.set(name, value.value);
            end
        end
    end

    test("Error", function()
        local input = [[
            `interp`
        ]];
        local result = luau.parse(input);
        expect(result).toBe(expect.similar({
            errors = {
                {
                    message = "Expected identifier when parsing expression, got `interp`",
                    span_start = vector.create(12, 0),
                    span_stop = vector.create(20, 0),
                }
            },
            root = {},
            lines = 0,
            line_offsets = {},
            eof = {
                tag = "eof",
                text = "",
                position = vector.zero,
                trailing_trivia = {},
                leading_trivia = {},
            },
            hotcomments = {},
        }));
    end)

    test("Source Any", function()
        local function tryDir(dir: string)
            for _, entry in zune.fs.entries(dir) do
                if (entry.kind == "file") then
                    if (string.find(entry.name, ".luau$")) then
                        local input = zune.fs.readFile(zune.fs.path.join(dir, entry.name));
                        local result = luau.parse(input);
                        expect(result).toBe(expect.similar({
                            root = expect.type("table"),
                            eof = expect.type("table"),
                            lines = expect.any("number"),
                            line_offsets = expect.any("table"),
                            hotcomments = expect.any("table"),
                        }));
                    end
                elseif (entry.kind == "directory" and entry.name ~= "test") then
                    tryDir(zune.fs.path.join(dir, entry.name));
                    continue;
                end
            end
        end
        tryDir("test/standard");
    end)
end)

describe("ParseExpr", function()
    test("Basic", function()
        local input = [[`interp`]];
        local result = luau.parseExpr(input);
        expect(result).toBe(expect.similar({
            tag = "string",
            text = "interp",
            quote_style = "interp",
            block_depth = 0,
            position = vector.zero,
            span_start = vector.zero,
            span_stop = vector.create(8, 0),
            trailing_trivia = {},
            leading_trivia = {},
        }));
    end)

    test("ExprBinary", function()
        local input = [[1 * 2]];
        local result = luau.parseExpr(input);
        expect(result).toBe(expect.similar({
            tag = "binary",
            lhsoperand = {
                tag = "number",
                value = 1,
                text = "1",
                position = vector.zero,
                span_start = vector.zero,
                span_stop = vector.create(1, 0),
                trailing_trivia = {},
                leading_trivia = {},
            },
            rhsoperand = {
                tag = "number",
                value = 2,
                text = "2",
                position = vector.create(4, 0),
                span_start = vector.create(4, 0),
                span_stop = vector.create(5, 0),
                trailing_trivia = {},
                leading_trivia = {
                    [1] = {
                        span_start = vector.create(3, 0),
                        span_stop = vector.create(4, 0),
                        text = " ",
                        tag = "whitespace",
                    },
                },
            },
            operator = {
                text = "*",
                position = vector.create(2, 0),
                trailing_trivia = {},
                leading_trivia = {
                    [1] = {
                        span_start = vector.create(1, 0),
                        span_stop = vector.create(2, 0),
                        text = " ",
                        tag = "whitespace",
                    },
                },
            },
            span_start = vector.zero,
            span_stop = vector.create(5, 0),
        }));
    end)

    test("Error", function()
        local input = [[local a = 0]];
        local result = luau.parseExpr(input);
        expect(result).toBe(expect.similar({
            errors = {
                {
                    message = "Expected identifier when parsing expression, got 'local'",
                    span_start = vector.zero,
                    span_stop = vector.create(5, 0),
                }
            },
            root = {},
            lines = 0,
            line_offsets = {},
            eof = {
                tag = "eof",
                text = "",
                position = vector.zero,
                trailing_trivia = {},
                leading_trivia = {},
            },
            hotcomments = {},
        }));
    end)
end)

describe("GarbageCollect", function()
    test("Basic", function()
        local value: any? = {};
        local weak = setmetatable({value}, {__mode = "v"});
        value = nil;
        luau.garbagecollect();
        expect(weak[1]).toBeNil();
    end)
    
    test("Step", function()
        local value: any? = {};
        local weak = setmetatable({value}, {__mode = "v"});
        value = nil;
        luau.garbagecollect(true);
        expect(weak[1]).never.toBeNil();
        luau.garbagecollect();
        expect(weak[1]).toBeNil();
    end)
end)


describe("FastFlags", function()
    test("Basic", function()
        for _, fflag in luau.fflag.list() do
            if (fflag.type == "boolean") then
                local current = fflag.value;
                luau.fflag.set(fflag.name, not current);
                expect(luau.fflag.get(fflag.name).value).toBe(not current);
                luau.fflag.set(fflag.name, current);
                expect(luau.fflag.get(fflag.name).value).toBe(current);
            elseif (fflag.type == "integer") then
                local current = fflag.value;
                luau.fflag.set(fflag.name, current + 1);
                expect(luau.fflag.get(fflag.name).value).toBe(current + 1);
                luau.fflag.set(fflag.name, current);
                expect(luau.fflag.get(fflag.name).value).toBe(current);
            else
                error("unsupported fast flag value, outdated");
            end
        end
        expect(#luau.fflag.list()).toBeGreaterThan(0);
    end)
end)
