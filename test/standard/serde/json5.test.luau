--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Json5", function()
    -- Encoding tests are the similar to json, so we test some edge cases
    describe("Encoding", function()
        test("Number", function()
            expect(serde.json5.encode(1)).toBe("1");
            expect(serde.json5.encode(math.huge)).toBe("Infinity");
            expect(serde.json5.encode(-math.huge)).toBe("-Infinity");
            expect(serde.json5.encode(0/0)).toBe("NaN");
        end)
    end)

    describe("Decoding", function()
        test("Number", function()
            expect(serde.json5.decode("+1")).toBe(1);
            expect(serde.json5.decode("+1.123")).toBe(1.123);
            expect(serde.json5.decode("+.123")).toBe(0.123);
            expect(serde.json5.decode(".123")).toBe(0.123);
            expect(serde.json5.decode("-.123")).toBe(-0.123);
            expect(serde.json5.decode("123.")).toBe(123);
            expect(serde.json5.decode("+123.")).toBe(123);
            expect(serde.json5.decode("-123.")).toBe(-123);
            expect(serde.json5.decode("+1.123e2")).toBe(1.123e2);
            expect(serde.json5.decode("+1.123e-2")).toBe(1.123e-2);
            expect(serde.json5.decode("+1.123e+2")).toBe(1.123e+2);
            expect(serde.json5.decode("-1.123e2")).toBe(-1.123e2);
            expect(serde.json5.decode("-1.123e-2")).toBe(-1.123e-2);
            expect(serde.json5.decode("-1.123e+2")).toBe(-1.123e+2);
            expect(serde.json5.decode("+0")).toBe(0);
            expect(serde.json5.decode("+0.0")).toBe(0);
            expect(serde.json5.decode("+0.000")).toBe(0);
            expect(serde.json5.decode("+0.000e2")).toBe(0);
            expect(serde.json5.decode("+0.000e-2")).toBe(0);
            expect(serde.json5.decode("+0.000e+2")).toBe(0);
            expect(serde.json5.decode("+NaN")).toBeNan();
            expect(serde.json5.decode("+Infinity")).toBe(math.huge);
            expect(serde.json5.decode("-Infinity")).toBe(-math.huge);
        end)
        test("Boolean", function()
            expect(serde.json5.decode("true")).toBe(true);
            expect(serde.json5.decode("false")).toBe(false);
        end)
        test("String", function()
            expect(serde.json5.decode(`""`)).toBe("");
            expect(serde.json5.decode(`"t"`)).toBe("t");
            expect(serde.json5.decode(`"te"`)).toBe("te");
            expect(serde.json5.decode(`"te\\u0020"`)).toBe("te ");
            expect(serde.json5.decode(`"te\\r"    `)).toBe("te\r");
            expect(serde.json5.decode(`"test"`)).toBe("test");
            expect(serde.json5.decode(`"\\u0000 \\u0000"`)).toBe("\0\32\0");
        end)
        test("Null", function()
            expect(serde.json5.decode("null")).toBe(nil);
            expect(serde.json5.decode("[null]")).toBe(expect.similar({}));
            expect(serde.json5.decode("null", {
                preserve_null = true
            })).toBe(serde.json5.values.null);
            expect(serde.json5.decode("[null]", {
                preserve_null = true
            })).toBe(expect.similar({serde.json5.values.null}));
        end)
        test("Object/Array", function()
            expect(serde.json5.decode(`\{\}`)).toBe(expect.similar({}));
            expect(serde.json5.decode(`\{"a":1,"b":2,"c":3\}`)).toBe(expect.similar({a = 1, b = 2, c = 3}));
            expect(serde.json5.decode(`\{a:1,b:2,c:3\}`)).toBe(expect.similar({a = 1, b = 2, c = 3}));
            expect(serde.json5.decode(`[]`)).toBe(expect.similar({}));
            expect(serde.json5.decode(`[1, 2, 3]`)).toBe(expect.similar({1,2,3}));
            expect(serde.json5.decode(`\{// comments \n "a" :1 /*multi\nline\ncomment*/, "b"   : 2,    /*  multi  \n  line  \n  comment */   "c"   :    3       \}`)).toBe(expect.similar({a = 1, b = 2, c = 3}));
        end)
        test("Fail", function()
            expect(function() serde.json5.decode("test"); end).toThrow(`ParseValueError`);
            expect(function() serde.json5.decode(`"test\\`); end).toThrow(`ParseStringError`);
            expect(function() serde.json5.decode(`"test\\"`); end).toThrow(`ParseStringError`);
            expect(function() serde.json5.decode("tru"); end).toThrow(`ParseValueError`);
            expect(function() serde.json5.decode("fals"); end).toThrow(`ParseValueError`);
            expect(function() serde.json5.decode("nul"); end).toThrow(`ParseValueError`);
            expect(function() serde.json5.decode("truex"); end).toThrow(`ParseValueError`);
            expect(function() serde.json5.decode("falsx"); end).toThrow(`ParseValueError`);
            expect(function() serde.json5.decode(`\{`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1,`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1,"b":2`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1,"b":2,`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1,"b":2,"c":3`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1,"b":2,"c":3,`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{"a":1,"b":2"c":3}`); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.decode(`\{ "a" :1 , "b"   : 2,       "c"   :    3       `); end).toThrow(`UnexpectedTokenError`);
            expect(function() serde.json5.values.null.a = 2 end).toThrow(`attempt to modify a readonly table`);
        end)
    end)

    describe("Full", function()
        local full_table = {};
        full_table["a"] = "a";
        full_table["b"] = 100.20;
        full_table["c"] = true;
        full_table["d"] = serde.json5.values.null;
        full_table["e"] = {1, 2, 3};
        full_table["f"] = {a = "a", b = 100.20, c = true, d = serde.json5.values.null};
        full_table["some encoded\0name"] = "someencoded\0value\1\n\n";
        full_table["g"] = table.clone(full_table);
        full_table["g"]["__sub"] = table.clone(full_table);
        full_table["h"] = table.clone(full_table);

        -- fixes
        full_table["g"]["__sub"]["g"] = nil :: any; -- circular reference
        full_table["h"]["__sub"] = nil :: any; -- circular reference
        full_table["h"]["g"] = nil :: any; -- circular reference

        test("Encode/Decode", function()
            expect(serde.json5.decode(serde.json5.encode(full_table), {preserve_null = true})).toBe(expect.similar(full_table));
        end)
    end)
end)

return nil;
