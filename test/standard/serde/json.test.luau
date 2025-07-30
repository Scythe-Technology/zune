--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Json", function()
    describe("Encoding", function()
        test("Number", function()
            expect(serde.json.encode(1)).toBe("1");
            expect(serde.json.encode(1.123)).toBe("1.123");
            expect(function() serde.json.encode(0/0); end).toThrow(`invalid number value (cannot be inf or nan)`);
            expect(function() serde.json.encode(math.huge); end).toThrow(`invalid number value (cannot be inf or nan)`);
            expect(function() serde.json.encode(-math.huge); end).toThrow(`invalid number value (cannot be inf or nan)`);
        end)
        test("Boolean", function()
            expect(serde.json.encode(true)).toBe("true");
            expect(serde.json.encode(false)).toBe("false");
        end)
        test("String", function()
            expect(serde.json.encode("test")).toBe(`"test"`);
            expect(serde.json.encode("te\"st")).toBe(`"te\\"st"`);
            expect(serde.json.encode("te\\st")).toBe(`"te\\\\st"`);
            expect(serde.json.encode("te\nst")).toBe(`"te\\nst"`);
            expect(serde.json.encode("te\rst")).toBe(`"te\\rst"`);
            expect(serde.json.encode("te\tst")).toBe(`"te\\tst"`);
            expect(serde.json.encode("te\bst")).toBe(`"te\\bst"`);
            expect(serde.json.encode("te\fst")).toBe(`"te\\fst"`);
            expect(serde.json.encode("te\1st")).toBe(`"te\\u0001st"`);
            expect(serde.json.encode("\0\32\0")).toBe(`"\\u0000 \\u0000"`);
        end)
        test("Null", function()
            expect(serde.json.encode(nil)).toBe("null");
            expect(serde.json.encode(serde.json.values.null)).toBe("null");
        end)
        test("Object/Array", function()
            expect(serde.json.encode({})).toBe("[]");
            expect(serde.json.encode({a = 1, b = 2, c = 3})).toBe(`\{"a":1,"c":3,"b":2\}`);
            expect(serde.json.encode({a = 1, b = serde.json.values.null, c = 3})).toBe(`\{"a":1,"c":3,"b":null\}`);
            expect(serde.json.encode({1,2,3})).toBe(`[1,2,3]`);

            expect(serde.json.encode({1,2,3}, {
                pretty_indent = 0
            })).toBe(`[1,2,3]`);
            expect(serde.json.encode({1,2,3}, {
                pretty_indent = serde.json.indents.none
            })).toBe(`[1,2,3]`);

            expect(serde.json.encode({1,2,3}, {
                pretty_indent = serde.json.indents.two_spaces
            })).toBe(`[1, 2, 3]`);
            expect(serde.json.encode({a = 1, b = 2, c = 3}, {
                pretty_indent = serde.json.indents.two_spaces
            })).toBe(`\{\n  "a": 1,\n  "c": 3,\n  "b": 2\n\}`);
            expect(serde.json.encode({a = 1, b = 2, c = 3}, {
                pretty_indent = serde.json.indents.tabs
            })).toBe(`\{\n\t"a": 1,\n\t"c": 3,\n\t"b": 2\n\}`);
            expect(serde.json.encode({a = 1, b = 2, c = 3}, {
                pretty_indent = 1
            })).toBe(`\{\n  "a": 1,\n  "c": 3,\n  "b": 2\n\}`);
        end)
        test("Fail", function()
            expect(function() serde.json.encode(function() end); end).toThrow(`unsupported value type (got function)`);
            expect(function() serde.json.encode(coroutine.create(function() end)); end).toThrow(`unsupported value type (got thread)`);
            -- TODO: Remove this when buffer is supported
            expect(function() serde.json.encode(buffer.create(12)); end).toThrow(`unsupported value type (got buffer)`);

            expect(function() serde.json.encode({[function() end] = 1}); end).toThrow(`invalid key type (expected string, got function)`);
        end)
    end)

    describe("Decoding", function()
        test("Number", function()
            expect(serde.json.decode("1")).toBe(1);
            expect(serde.json.decode("1.123")).toBe(1.123);
            expect(serde.json.decode("1.123e2")).toBe(1.123e2);
            expect(serde.json.decode("1.123e-2")).toBe(1.123e-2);
            expect(serde.json.decode("1.123e+2")).toBe(1.123e+2);
            expect(serde.json.decode("-1.123e2")).toBe(-1.123e2);
            expect(serde.json.decode("-1.123e-2")).toBe(-1.123e-2);
            expect(serde.json.decode("-1.123e+2")).toBe(-1.123e+2);
            expect(serde.json.decode("0")).toBe(0);
            expect(serde.json.decode("0.0")).toBe(0);
            expect(serde.json.decode("0.000")).toBe(0);
            expect(serde.json.decode("0.000e2")).toBe(0);
            expect(serde.json.decode("0.000e-2")).toBe(0);
            expect(serde.json.decode("0.000e+2")).toBe(0);
        end)
        test("Boolean", function()
            expect(serde.json.decode("true")).toBe(true);
            expect(serde.json.decode("false")).toBe(false);
        end)
        test("String", function()
            expect(serde.json.decode(`""`)).toBe("");
            expect(serde.json.decode(`"t"`)).toBe("t");
            expect(serde.json.decode(`"te"`)).toBe("te");
            expect(serde.json.decode(`"te\\u0020"`)).toBe("te ");
            expect(serde.json.decode(`"te\\r"    `)).toBe("te\r");
            expect(serde.json.decode(`"test"`)).toBe("test");
            expect(serde.json.decode(`"\\u0000 \\u0000"`)).toBe("\0\32\0");
        end)
        test("Null", function()
            expect(serde.json.decode("null")).toBe(nil);
            expect(serde.json.decode("[null]")).toBe(expect.similar({}));
            expect(serde.json.decode("null", {
                preserve_null = true
            })).toBe(serde.json.values.null);
            expect(serde.json.decode("[null]", {
                preserve_null = true
            })).toBe(expect.similar({serde.json.values.null}));
        end)
        test("Object/Array", function()
            expect(serde.json.decode(`\{\}`)).toBe(expect.similar({}));
            expect(serde.json.decode(`\{"a":1,"b":2,"c":3\}`)).toBe(expect.similar({a = 1, b = 2, c = 3}));
            expect(serde.json.decode(`[]`)).toBe(expect.similar({}));
            expect(serde.json.decode(`[1, 2, 3]`)).toBe(expect.similar({1,2,3}));
            expect(serde.json.decode(`\{ "a" :1 , "b"   : 2,       "c"   :    3       \}`)).toBe(expect.similar({a = 1, b = 2, c = 3}));
        end)
        test("Fail", function()
            expect(function() serde.json.decode("test"); end).toThrow(`ParseValueError`);
            expect(function() serde.json.decode(`"test\\`); end).toThrow(`ParseStringError`);
            expect(function() serde.json.decode(`"test\\"`); end).toThrow(`ParseStringError`);
            expect(function() serde.json.decode("tru"); end).toThrow(`ParseValueError`);
            expect(function() serde.json.decode("fals"); end).toThrow(`ParseValueError`);
            expect(function() serde.json.decode("nul"); end).toThrow(`ParseValueError`);
            expect(function() serde.json.decode("truex"); end).toThrow(`ParseValueError`);
            expect(function() serde.json.decode("falsx"); end).toThrow(`ParseValueError`);
            expect(function() serde.json.decode(`\{`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1,`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1,"b":2`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1,"b":2,`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1,"b":2,"c":3`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1,"b":2,"c":3,`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{"a":1,"b":2"c":3}`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.decode(`\{ "a" :1 , "b"   : 2,       "c"   :    3       `); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json.values.null.a = 2 end).toThrow(`attempt to modify a readonly table`);
        end)
    end)
end)

return nil;
