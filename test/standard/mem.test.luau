--!strict
--!native
--!optimize 2
local mem = zune.mem;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

type WritableSlice = buffer | FFIPointer;
type ReadableSlice = string | buffer | FFIPointer;

type MemLib = {
    len: (src: ReadableSlice) -> number?,
    copy: (dest: WritableSlice, destOffset: number, src: ReadableSlice, srcOffset: number, count: number?) -> (),
    slice: (src: ReadableSlice, offset: number, count: number?) -> buffer,
    eqlSlice: (a: ReadableSlice, aOffset: number, b: ReadableSlice, bOffset: number, count: number?) -> boolean,
    eql: (a: ReadableSlice, b: ReadableSlice) -> boolean,
    startsWith: (slice: ReadableSlice, needle: ReadableSlice) -> boolean,
    endsWith: (slice: ReadableSlice, needle: ReadableSlice) -> boolean,
    trim: (src: ReadableSlice, values_to_strip: ReadableSlice) -> buffer,
    trimLeft: (src: ReadableSlice, values_to_strip: ReadableSlice) -> buffer,
    trimRight: (src: ReadableSlice, values_to_strip: ReadableSlice) -> buffer,
    indexOf: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfPos: (src: ReadableSlice, offset: number, needle: ReadableSlice) -> number?,
    lastIndexOf: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfAny: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfAnyPos: (src: ReadableSlice, offset: number, needle: ReadableSlice) -> number?,
    lastIndexOfAny: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfNone: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfNonePos: (src: ReadableSlice, offset: number, needle: ReadableSlice) -> number?,
    lastIndexOfNone: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfDiff: (src: ReadableSlice, needle: ReadableSlice) -> number?,
    indexOfMax: (src: ReadableSlice) -> number,
    indexOfMin: (src: ReadableSlice) -> number,
    indexOfMinMax: (src: ReadableSlice) -> (number, number),replaceScalar: (src: WritableSlice, char: number, replacement: number) -> (),
    max: (src: ReadableSlice) -> number,
    min: (src: ReadableSlice) -> number,
    reverse: (src: WritableSlice) -> (),
    rotate: (src: WritableSlice, amount: number) -> (),
    set: (dest: WritableSlice, value: number, offset: number?, count: number?) -> (),
}
describe("Mem", function()
    test("len", function()
        expect(mem.len(buffer.fromstring("test"))).toBe(4);
        expect(mem.len(buffer.fromstring(""))).toBe(0);
        expect(mem.len("test")).toBe(4);
        expect(mem.len("")).toBe(0);
    end)
    test("copy", function()
        do
            local a = buffer.fromstring("test");
            local b = buffer.fromstring("subtest");
            mem.copy(b, 3, a, 0, 4);
            expect(mem.eql(b, "subtest")).toBeTruthy();
            expect(mem.eql(b, "subtes")).toBeFalsy();
            expect(function()
                mem.copy(b, 3, a, 0, 5);
            end).toThrow("access out of bounds");
        end
        do
            local b = buffer.fromstring("subtest");
            mem.copy(b, 3, "test", 0, 4);
            expect(mem.eql(b, "subtest")).toBeTruthy();
            expect(mem.eql(b, "subtes")).toBeFalsy();
            expect(function()
                mem.copy(b, 3, "test", 0, 5);
            end).toThrow("access out of bounds");
        end
    end)
    test("slice", function()
        local a = buffer.fromstring("test");
        local b = mem.slice(a, 1, 2);
        expect(mem.eql(b, "es")).toBeTruthy();
        expect(mem.eql(mem.slice(a, 0, 4), a)).toBeTruthy();
        expect(function()
            mem.slice(a, 0, 5);
        end).toThrow("access out of bounds");
        expect(mem.eql(mem.slice(a, 1, 3), "est")).toBeTruthy();
    end)
    test("eqlSlice", function()
        local a = buffer.fromstring("test");
        local b = buffer.fromstring("subtest");
        expect(mem.eqlSlice(a, 0, b, 3)).toBeTruthy();
        for i = 1, 4 do
            expect(mem.eqlSlice(a, 0, b, 3, i)).toBeTruthy();
        end
        expect(mem.eqlSlice(a, 0, b, 0)).toBeFalsy();
        expect(mem.eqlSlice(a, 0, b, 1)).toBeFalsy();
        expect(mem.eqlSlice(a, 0, b, 2)).toBeFalsy();
        expect(mem.eqlSlice(a, 2, b, 0, 2)).toBeFalsy();
    end)
    test("eql", function()
        local a = buffer.fromstring("test");
        local b = buffer.fromstring("test");
        expect(mem.eql(a, b)).toBeTruthy();
        expect(mem.eql(a, "test")).toBeTruthy();
        expect(mem.eql(a, buffer.fromstring("test2"))).toBeFalsy();
    end)
    test("startsWith", function()
        local a = buffer.fromstring("test");
        expect(mem.startsWith(a, "te")).toBeTruthy();
        expect(mem.startsWith(a, "t")).toBeTruthy();
        expect(mem.startsWith(a, "test")).toBeTruthy();
        expect(mem.startsWith(a, "tes")).toBeTruthy();
        expect(mem.startsWith(a, "est")).toBeFalsy();
        expect(mem.startsWith(a, "")).toBeTruthy();
    end)
    test("endsWith", function()
        local a = buffer.fromstring("test");
        expect(mem.endsWith(a, "st")).toBeTruthy();
        expect(mem.endsWith(a, "t")).toBeTruthy();
        expect(mem.endsWith(a, "test")).toBeTruthy();
        expect(mem.endsWith(a, "tes")).toBeFalsy();
        expect(mem.endsWith(a, "te")).toBeFalsy();
        expect(mem.endsWith(a, "")).toBeTruthy();
    end)
    test("trim", function()
        local a = buffer.fromstring("  test  ");
        local b = mem.trim(a, " ");
        expect(mem.eql(b, "test")).toBeTruthy();
        expect(mem.eql(mem.trim(a, "t"), "  test  ")).toBeTruthy();
        expect(mem.eql(mem.trim(a, "t "), "es")).toBeTruthy();
        expect(mem.eql(mem.trim(a, ""), a)).toBeTruthy();
        expect(mem.eql(mem.trim(a, " "), "test")).toBeTruthy();
    end)
    test("trimLeft", function()
        local a = buffer.fromstring("  test  ");
        local b = mem.trimLeft(a, " ");
        expect(mem.eql(b, "test  ")).toBeTruthy();
        expect(mem.eql(mem.trimLeft(a, "t"), "  test  ")).toBeTruthy();
        expect(mem.eql(mem.trimLeft(a, "t "), "est  ")).toBeTruthy();
        expect(mem.eql(mem.trimLeft(a, ""), a)).toBeTruthy();
        expect(mem.eql(mem.trimLeft(a, " "), "test  ")).toBeTruthy();
    end)
    test("trimRight", function()
        local a = buffer.fromstring("  test  ");
        local b = mem.trimRight(a, " ");
        expect(mem.eql(b, "  test")).toBeTruthy();
        expect(mem.eql(mem.trimRight(a, "t"), "  test  ")).toBeTruthy();
        expect(mem.eql(mem.trimRight(a, "t "), "  tes")).toBeTruthy();
        expect(mem.eql(mem.trimRight(a, ""), a)).toBeTruthy();
        expect(mem.eql(mem.trimRight(a, " "), "  test")).toBeTruthy();
    end)
    test("indexOf", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOf(a, "te")).toBe(0);
        expect(mem.indexOf(a, "t")).toBe(0);
        expect(mem.indexOf(a, "test")).toBe(0);
        expect(mem.indexOf(a, "es")).toBe(1);
        expect(mem.indexOf(a, "st")).toBe(2);
        expect(mem.indexOf(a, "e")).toBe(1);
        expect(mem.indexOf(a, "x")).toBeNil();
        expect(mem.indexOf(a, "")).toBe(0);
    end)
    test("indexOfPos", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfPos(a, 0, "te")).toBe(0);
        expect(mem.indexOfPos(a, 1, "te")).toBeNil();
        expect(mem.indexOfPos(a, 0, "t")).toBe(0);
        expect(mem.indexOfPos(a, 1, "t")).toBe(3);
        expect(mem.indexOfPos(a, 0, "test")).toBe(0);
        expect(mem.indexOfPos(a, 1, "test")).toBeNil();
        expect(mem.indexOfPos(a, 0, "es")).toBe(1);
    end)
    test("lastIndexOf", function()
        local a = buffer.fromstring("test");
        expect(mem.lastIndexOf(a, "te")).toBe(0);
        expect(mem.lastIndexOf(a, "t")).toBe(3);
        expect(mem.lastIndexOf(a, "test")).toBe(0);
        expect(mem.lastIndexOf(a, "es")).toBe(1);
        expect(mem.lastIndexOf(a, "st")).toBe(2);
        expect(mem.lastIndexOf(a, "e")).toBe(1);
        expect(mem.lastIndexOf(a, "x")).toBeNil();
        expect(mem.lastIndexOf(a, "")).toBe(4);
    end)
    test("indexOfAny", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfAny(a, "te")).toBe(0);
        expect(mem.indexOfAny(a, "t")).toBe(0);
        expect(mem.indexOfAny(a, "test")).toBe(0);
        expect(mem.indexOfAny(a, "es")).toBe(1);
        expect(mem.indexOfAny(a, "st")).toBe(0);
        expect(mem.indexOfAny(a, "e")).toBe(1);
        expect(mem.indexOfAny(a, "x")).toBeNil();
        expect(mem.indexOfAny(a, "")).toBeNil();
    end)
    test("indexOfAnyPos", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfAnyPos(a, 0, "te")).toBe(0);
        expect(mem.indexOfAnyPos(a, 1, "te")).toBe(1);
        expect(mem.indexOfAnyPos(a, 0, "t")).toBe(0);
        expect(mem.indexOfAnyPos(a, 1, "t")).toBe(3);
        expect(mem.indexOfAnyPos(a, 0, "test")).toBe(0);
        expect(mem.indexOfAnyPos(a, 1, "test")).toBe(1);
        expect(mem.indexOfAnyPos(a, 0, "es")).toBe(1);
        expect(mem.indexOfAnyPos(a, 1, "es")).toBe(1);
        expect(mem.indexOfAnyPos(a, 0, "st")).toBe(0);
        expect(mem.indexOfAnyPos(a, 1, "st")).toBe(2);
        expect(mem.indexOfAnyPos(a, 0, "e")).toBe(1);
        expect(mem.indexOfAnyPos(a, 2, "e")).toBeNil();
        expect(mem.indexOfAnyPos(a, 0, "x")).toBeNil();
        expect(mem.indexOfAnyPos(a, 0, "")).toBeNil();
    end)
    test("lastIndexOfAny", function()
        local a = buffer.fromstring("test");
        expect(mem.lastIndexOfAny(a, "te")).toBe(3);
        expect(mem.lastIndexOfAny(a, "t")).toBe(3);
        expect(mem.lastIndexOfAny(a, "test")).toBe(3);
        expect(mem.lastIndexOfAny(a, "es")).toBe(2);
        expect(mem.lastIndexOfAny(a, "st")).toBe(3);
        expect(mem.lastIndexOfAny(a, "e")).toBe(1);
        expect(mem.lastIndexOfAny(a, "x")).toBeNil();
        expect(mem.lastIndexOfAny(a, "")).toBeNil();
    end)
    test("indexOfNone", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfNone(a, "te")).toBe(2);
        expect(mem.indexOfNone(a, "t")).toBe(1);
        expect(mem.indexOfNone(a, "test")).toBeNil();
        expect(mem.indexOfNone(a, "es")).toBe(0);
        expect(mem.indexOfNone(a, "st")).toBe(1);
        expect(mem.indexOfNone(a, "e")).toBe(0);
        expect(mem.indexOfNone(a, "x")).toBe(0);
        expect(mem.indexOfNone(a, "")).toBe(0);
    end)
    test("indexOfNonePos", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfNonePos(a, 0, "te")).toBe(2);
        expect(mem.indexOfNonePos(a, 1, "te")).toBe(2);
        expect(mem.indexOfNonePos(a, 0, "t")).toBe(1);
        expect(mem.indexOfNonePos(a, 1, "t")).toBe(1);
        expect(mem.indexOfNonePos(a, 0, "test")).toBeNil();
        expect(mem.indexOfNonePos(a, 1, "test")).toBeNil();
        expect(mem.indexOfNonePos(a, 0, "es")).toBe(0);
        expect(mem.indexOfNonePos(a, 1, "es")).toBe(3);
        expect(mem.indexOfNonePos(a, 0, "st")).toBe(1);
        expect(mem.indexOfNonePos(a, 1, "st")).toBe(1);
        expect(mem.indexOfNonePos(a, 0, "e")).toBe(0);
        expect(mem.indexOfNonePos(a, 1, "e")).toBe(2);
        expect(mem.indexOfNonePos(a, 0, "x")).toBe(0);
        expect(mem.indexOfNonePos(a, 0, "")).toBe(0);
    end)
    test("lastIndexOfNone", function()
        local a = buffer.fromstring("test");
        expect(mem.lastIndexOfNone(a, "te")).toBe(2);
        expect(mem.lastIndexOfNone(a, "t")).toBe(2);
        expect(mem.lastIndexOfNone(a, "test")).toBeNil();
        expect(mem.lastIndexOfNone(a, "es")).toBe(3);
        expect(mem.lastIndexOfNone(a, "st")).toBe(1);
        expect(mem.lastIndexOfNone(a, "e")).toBe(3);
        expect(mem.lastIndexOfNone(a, "x")).toBe(3);
        expect(mem.lastIndexOfNone(a, "")).toBe(3);
    end)
    test("indexOfDiff", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfDiff(a, "te")).toBe(2);
        expect(mem.indexOfDiff(a, "t")).toBe(1);
        expect(mem.indexOfDiff(a, "test")).toBeNil();
        expect(mem.indexOfDiff(a, "es")).toBe(0);
        expect(mem.indexOfDiff(a, "st")).toBe(0);
        expect(mem.indexOfDiff(a, "e")).toBe(0);
        expect(mem.indexOfDiff(a, "x")).toBe(0);
        expect(mem.indexOfDiff(a, "")).toBe(0);
    end)
    test("indexOfMax", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfMax(a)).toBe(0);
        expect(mem.indexOfMax("1234")).toBe(3);
        expect(function()
            mem.indexOfMax(buffer.fromstring(""))
        end).toThrow("cannot find max of empty slice");
    end)
    test("indexOfMin", function()
        local a = buffer.fromstring("test");
        expect(mem.indexOfMin(a)).toBe(1);
        expect(mem.indexOfMin("1234")).toBe(0);
        expect(function()
            mem.indexOfMin(buffer.fromstring(""))
        end).toThrow("cannot find min of empty slice");
    end)
    test("indexOfMinMax", function()
        local a = buffer.fromstring("test");
        expect({mem.indexOfMinMax(a)}).toBe(expect.similar({1, 0}));
        expect({mem.indexOfMinMax("1234")}).toBe(expect.similar({0, 3}));
        expect(function()
            mem.indexOfMinMax(buffer.fromstring(""))
        end).toThrow("cannot find min/max of empty slice");
    end)
    test("replaceScalar", function()
        local a = buffer.fromstring("test");
        mem.replaceScalar(a, string.byte('t'), string.byte('x'));
        expect(mem.eql(a, "xesx")).toBeTruthy();
        mem.replaceScalar(a, string.byte('x'), string.byte('t'));
        expect(mem.eql(a, "test")).toBeTruthy();
    end)
    test("max", function()
        local a = buffer.fromstring("test");
        expect(mem.max(a)).toBe(string.byte('t'));
        expect(mem.max("1234")).toBe(string.byte('4'));
        expect(function()
            mem.max(buffer.fromstring(""))
        end).toThrow("cannot find max of empty slice");
    end)
    test("min", function()
        local a = buffer.fromstring("test");
        expect(mem.min(a)).toBe(string.byte('e'));
        expect(mem.min("1234")).toBe(string.byte('1'));
        expect(function()
            mem.min(buffer.fromstring(""))
        end).toThrow("cannot find min of empty slice");
    end)
    test("reverse", function()
        local a = buffer.fromstring("test");
        mem.reverse(a);
        expect(mem.eql(a, "tset")).toBeTruthy();
        mem.reverse(a);
        expect(mem.eql(a, "test")).toBeTruthy();
    end)
    test("rotate", function()
        local a = buffer.fromstring("test");
        mem.rotate(a, 2);
        expect(mem.eql(a, "stte")).toBeTruthy();
        mem.rotate(a, 2);
        expect(mem.eql(a, "test")).toBeTruthy();
        mem.rotate(a, 4);
        expect(mem.eql(a, "test")).toBeTruthy();
        mem.rotate(a, 4);
        expect(mem.eql(a, "test")).toBeTruthy();
    end)
    test("set", function()
        local a = buffer.fromstring("test");
        mem.set(a, string.byte('x'));
        expect(mem.eql(a, "xxxx")).toBeTruthy();
        mem.set(a, string.byte('t'), 0, 2);
        expect(mem.eql(a, "ttxx")).toBeTruthy();
        mem.set(a, string.byte('e'), 2, 2);
        expect(mem.eql(a, "ttee")).toBeTruthy();
        mem.set(a, string.byte('s'), 1, 3);
        expect(mem.eql(a, "tsss")).toBeTruthy();
    end)
end)