--!strict
--!native
--!optimize 2
local mem = zune.mem;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

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
    test("find", function()
        local a = buffer.fromstring("test");
        expect(mem.find(a, "te")).toBe(0);
        expect(mem.find(a, "t")).toBe(0);
        expect(mem.find(a, "test")).toBe(0);
        expect(mem.find(a, "es")).toBe(1);
        expect(mem.find(a, "st")).toBe(2);
        expect(mem.find(a, "e")).toBe(1);
        expect(mem.find(a, "x")).toBeNil();
        expect(mem.find(a, "")).toBe(0);
    end)
    test("findPos", function()
        local a = buffer.fromstring("test");
        expect(mem.findPos(a, 0, "te")).toBe(0);
        expect(mem.findPos(a, 1, "te")).toBeNil();
        expect(mem.findPos(a, 0, "t")).toBe(0);
        expect(mem.findPos(a, 1, "t")).toBe(3);
        expect(mem.findPos(a, 4, "t")).toBeNil();
        expect(mem.findPos(a, 0, "test")).toBe(0);
        expect(mem.findPos(a, 1, "test")).toBeNil();
        expect(mem.findPos(a, 0, "es")).toBe(1);
    end)
    test("findLast", function()
        local a = buffer.fromstring("test");
        expect(mem.findLast(a, "te")).toBe(0);
        expect(mem.findLast(a, "t")).toBe(3);
        expect(mem.findLast(a, "test")).toBe(0);
        expect(mem.findLast(a, "es")).toBe(1);
        expect(mem.findLast(a, "st")).toBe(2);
        expect(mem.findLast(a, "e")).toBe(1);
        expect(mem.findLast(a, "x")).toBeNil();
        expect(mem.findLast(a, "")).toBe(4);
    end)
    test("findScalar", function()
        local a = buffer.fromstring("test");
        expect(mem.findScalar(a, string.byte('t'))).toBe(0);
        expect(mem.findScalar(a, string.byte('e'))).toBe(1);
        expect(mem.findScalar(a, string.byte('s'))).toBe(2);
        expect(mem.findScalar(a, string.byte('x'))).toBeNil();
        expect(mem.findScalar(a, 0)).toBeNil();
    end)
    test("findScalarPos", function()
        local a = buffer.fromstring("test");
        expect(mem.findScalarPos(a, 0, string.byte('t'))).toBe(0);
        expect(mem.findScalarPos(a, 1, string.byte('t'))).toBe(3);
        expect(mem.findScalarPos(a, 4, string.byte('t'))).toBeNil();
        expect(mem.findScalarPos(a, 0, string.byte('e'))).toBe(1);
        expect(mem.findScalarPos(a, 2, string.byte('e'))).toBeNil();
        expect(mem.findScalarPos(a, 0, string.byte('s'))).toBe(2);
        expect(mem.findScalarPos(a, 1, string.byte('s'))).toBe(2);
        expect(mem.findScalarPos(a, 0, string.byte('x'))).toBeNil();
        expect(mem.findScalarPos(a, 0, 0)).toBeNil();
    end)
    test("findScalarLast", function()
        local a = buffer.fromstring("test");
        expect(mem.findScalarLast(a, string.byte('t'))).toBe(3);
        expect(mem.findScalarLast(a, string.byte('e'))).toBe(1);
        expect(mem.findScalarLast(a, string.byte('s'))).toBe(2);
        expect(mem.findScalarLast(a, string.byte('x'))).toBeNil();
        expect(mem.findScalarLast(a, 0)).toBeNil();
    end)
    test("findAny", function()
        local a = buffer.fromstring("test");
        expect(mem.findAny(a, "te")).toBe(0);
        expect(mem.findAny(a, "t")).toBe(0);
        expect(mem.findAny(a, "test")).toBe(0);
        expect(mem.findAny(a, "es")).toBe(1);
        expect(mem.findAny(a, "st")).toBe(0);
        expect(mem.findAny(a, "e")).toBe(1);
        expect(mem.findAny(a, "x")).toBeNil();
        expect(mem.findAny(a, "")).toBeNil();
    end)
    test("findAnyPos", function()
        local a = buffer.fromstring("test");
        expect(mem.findAnyPos(a, 0, "te")).toBe(0);
        expect(mem.findAnyPos(a, 1, "te")).toBe(1);
        expect(mem.findAnyPos(a, 0, "t")).toBe(0);
        expect(mem.findAnyPos(a, 1, "t")).toBe(3);
        expect(mem.findAnyPos(a, 4, "t")).toBeNil();
        expect(mem.findAnyPos(a, 0, "test")).toBe(0);
        expect(mem.findAnyPos(a, 1, "test")).toBe(1);
        expect(mem.findAnyPos(a, 0, "es")).toBe(1);
        expect(mem.findAnyPos(a, 1, "es")).toBe(1);
        expect(mem.findAnyPos(a, 0, "st")).toBe(0);
        expect(mem.findAnyPos(a, 1, "st")).toBe(2);
        expect(mem.findAnyPos(a, 0, "e")).toBe(1);
        expect(mem.findAnyPos(a, 2, "e")).toBeNil();
        expect(mem.findAnyPos(a, 0, "x")).toBeNil();
        expect(mem.findAnyPos(a, 0, "")).toBeNil();
    end)
    test("findAnyLast", function()
        local a = buffer.fromstring("test");
        expect(mem.findAnyLast(a, "te")).toBe(3);
        expect(mem.findAnyLast(a, "t")).toBe(3);
        expect(mem.findAnyLast(a, "test")).toBe(3);
        expect(mem.findAnyLast(a, "es")).toBe(2);
        expect(mem.findAnyLast(a, "st")).toBe(3);
        expect(mem.findAnyLast(a, "e")).toBe(1);
        expect(mem.findAnyLast(a, "x")).toBeNil();
        expect(mem.findAnyLast(a, "")).toBeNil();
    end)
    test("findNone", function()
        local a = buffer.fromstring("test");
        expect(mem.findNone(a, "te")).toBe(2);
        expect(mem.findNone(a, "t")).toBe(1);
        expect(mem.findNone(a, "test")).toBeNil();
        expect(mem.findNone(a, "es")).toBe(0);
        expect(mem.findNone(a, "st")).toBe(1);
        expect(mem.findNone(a, "e")).toBe(0);
        expect(mem.findNone(a, "x")).toBe(0);
        expect(mem.findNone(a, "")).toBe(0);
    end)
    test("findNonePos", function()
        local a = buffer.fromstring("test");
        expect(mem.findNonePos(a, 0, "te")).toBe(2);
        expect(mem.findNonePos(a, 1, "te")).toBe(2);
        expect(mem.findNonePos(a, 0, "t")).toBe(1);
        expect(mem.findNonePos(a, 1, "t")).toBe(1);
        expect(mem.findNonePos(a, 4, "t")).toBeNil();
        expect(mem.findNonePos(a, 0, "test")).toBeNil();
        expect(mem.findNonePos(a, 1, "test")).toBeNil();
        expect(mem.findNonePos(a, 0, "es")).toBe(0);
        expect(mem.findNonePos(a, 1, "es")).toBe(3);
        expect(mem.findNonePos(a, 0, "st")).toBe(1);
        expect(mem.findNonePos(a, 1, "st")).toBe(1);
        expect(mem.findNonePos(a, 0, "e")).toBe(0);
        expect(mem.findNonePos(a, 1, "e")).toBe(2);
        expect(mem.findNonePos(a, 0, "x")).toBe(0);
        expect(mem.findNonePos(a, 0, "")).toBe(0);
    end)
    test("findNoneLast", function()
        local a = buffer.fromstring("test");
        expect(mem.findNoneLast(a, "te")).toBe(2);
        expect(mem.findNoneLast(a, "t")).toBe(2);
        expect(mem.findNoneLast(a, "test")).toBeNil();
        expect(mem.findNoneLast(a, "es")).toBe(3);
        expect(mem.findNoneLast(a, "st")).toBe(1);
        expect(mem.findNoneLast(a, "e")).toBe(3);
        expect(mem.findNoneLast(a, "x")).toBe(3);
        expect(mem.findNoneLast(a, "")).toBe(3);
    end)
    test("findDiff", function()
        local a = buffer.fromstring("test");
        expect(mem.findDiff(a, "te")).toBe(2);
        expect(mem.findDiff(a, "t")).toBe(1);
        expect(mem.findDiff(a, "test")).toBeNil();
        expect(mem.findDiff(a, "es")).toBe(0);
        expect(mem.findDiff(a, "st")).toBe(0);
        expect(mem.findDiff(a, "e")).toBe(0);
        expect(mem.findDiff(a, "x")).toBe(0);
        expect(mem.findDiff(a, "")).toBe(0);
    end)
    test("findDiffPos", function()
        local a = buffer.fromstring("test");
        expect(mem.findDiffPos(a, 0, "te")).toBe(2);
        expect(mem.findDiffPos(a, 1, "te")).toBe(1);
        expect(mem.findDiffPos(a, 0, "t")).toBe(1);
        expect(mem.findDiffPos(a, 1, "t")).toBe(1);
        expect(mem.findDiffPos(a, 4, "t")).toBe(4);
        expect(mem.findDiffPos(a, 0, "test")).toBeNil();
        expect(mem.findDiffPos(a, 1, "test")).toBe(1);
        expect(mem.findDiffPos(a, 0, "es")).toBe(0);
        expect(mem.findDiffPos(a, 1, "es")).toBe(3);
        expect(mem.findDiffPos(a, 0, "st")).toBe(0);
        expect(mem.findDiffPos(a, 1, "st")).toBe(1);
        expect(mem.findDiffPos(a, 0, "e")).toBe(0);
        expect(mem.findDiffPos(a, 1, "e")).toBe(2);
        expect(mem.findDiffPos(a, 0, "x")).toBe(0);
        expect(mem.findDiffPos(a, 0, "")).toBe(0);
    end)
    test("findMax", function()
        local a = buffer.fromstring("test");
        expect(mem.findMax(a)).toBe(0);
        expect(mem.findMax("1234")).toBe(3);
        expect(function()
            mem.findMax(buffer.fromstring(""))
        end).toThrow("cannot find max of empty slice");
    end)
    test("findMin", function()
        local a = buffer.fromstring("test");
        expect(mem.findMin(a)).toBe(1);
        expect(mem.findMin("1234")).toBe(0);
        expect(function()
            mem.findMin(buffer.fromstring(""))
        end).toThrow("cannot find min of empty slice");
    end)
    test("findMinMax", function()
        local a = buffer.fromstring("test");
        expect({mem.findMinMax(a)}).toBe(expect.similar({1, 0}));
        expect({mem.findMinMax("1234")}).toBe(expect.similar({0, 3}));
        expect(function()
            mem.findMinMax(buffer.fromstring(""))
        end).toThrow("cannot find min/max of empty slice");
    end)
    test("cutPrefix", function()
        local a = buffer.fromstring("test");
        local b = mem.cutPrefix(a, "te");
        expect(mem.eql(b :: buffer, "st")).toBeTruthy();
        expect(mem.eql(mem.cutPrefix(a, "t") :: buffer, "est")).toBeTruthy();
        expect(mem.eql(mem.cutPrefix(a, "test") :: buffer, "")).toBeTruthy();
        expect(mem.cutPrefix(a, "x")).toBeNil();
        expect(mem.eql(mem.cutPrefix(a, "") :: buffer, a)).toBeTruthy();
    end)
    test("cutSuffix", function()
        local a = buffer.fromstring("test");
        local b = mem.cutSuffix(a, "st");
        expect(mem.eql(b :: buffer, "te")).toBeTruthy();
        expect(mem.eql(mem.cutSuffix(a, "t") :: buffer, "tes")).toBeTruthy();
        expect(mem.eql(mem.cutSuffix(a, "test") :: buffer, "")).toBeTruthy();
        expect(mem.cutSuffix(a, "x")).toBeNil();
        expect(mem.eql(mem.cutSuffix(a, "") :: buffer, a)).toBeTruthy();
    end)
    test("cut", function()
        local a = buffer.fromstring("test");
        local left, right = mem.cut(a, "es");
        assert(left);
        assert(right);
        expect(mem.eql(left, "t")).toBeTruthy();
        expect(mem.eql(right, "t")).toBeTruthy();
        expect((mem.cut(a, "x"))).toBeNil();
        left, right = mem.cut(a, "t");
        assert(left);
        assert(right);
        expect(mem.eql(left, "")).toBeTruthy();
        expect(mem.eql(right, "est")).toBeTruthy();
    end)
    test("cutLast", function()
        local a = buffer.fromstring("testest");
        local left, right = mem.cutLast(a, "es");
        assert(left);
        assert(right);
        expect(mem.eql(left, "test")).toBeTruthy();
        expect(mem.eql(right, "t")).toBeTruthy();
        expect((mem.cutLast(a, "x"))).toBeNil();
        left, right = mem.cutLast(a, "t");
        assert(left);
        assert(right);
        expect(mem.eql(left, "testes")).toBeTruthy();
        expect(mem.eql(right, "")).toBeTruthy();
    end)
    test("cutScalar", function()
        local a = buffer.fromstring("test");
        local left, right = mem.cutScalar(a, string.byte('e'));
        assert(left);
        assert(right);
        expect(mem.eql(left, "t")).toBeTruthy();
        expect(mem.eql(right, "st")).toBeTruthy();
        expect((mem.cutScalar(a, string.byte('x')))).toBeNil();
        left, right = mem.cutScalar(a, string.byte('t'));
        assert(left);
        assert(right);
        expect(mem.eql(left, "")).toBeTruthy();
        expect(mem.eql(right, "est")).toBeTruthy();
    end)
    test("cutScalarLast", function()
        local a = buffer.fromstring("testest");
        local left, right = mem.cutScalarLast(a, string.byte('e'));
        assert(left);
        assert(right);
        expect(mem.eql(left, "test")).toBeTruthy();
        expect(mem.eql(right, "st")).toBeTruthy();
        expect((mem.cutScalarLast(a, string.byte('x')))).toBeNil();
        left, right = mem.cutScalarLast(a, string.byte('t'));
        assert(left);
        assert(right);
        expect(mem.eql(left, "testes")).toBeTruthy();
        expect(mem.eql(right, "")).toBeTruthy();
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
    test("toVector2", function()
        local buf = buffer.create(8);
        buffer.writef32(buf, 0, 1.0);
        buffer.writef32(buf, 4, 2.0);
        local vec = mem.toVector2(buf);
        expect(vec.x).toBe(1);
        expect(vec.y).toBe(2);
        expect(function()
            mem.toVector2(buffer.create(2));
        end).toThrow("access out of bounds");
    end)
    test("toVector3", function()
        local buf = buffer.create(12);
        buffer.writef32(buf, 0, 1.0);
        buffer.writef32(buf, 4, 2.0);
        buffer.writef32(buf, 8, 3.0);
        local vec = mem.toVector3(buf);
        expect(vec.x).toBe(1);
        expect(vec.y).toBe(2);
        expect(vec.z).toBe(3);
        expect(function()
            mem.toVector3(buffer.create(2));
        end).toThrow("access out of bounds");
    end)
    test("writeVector2", function()
        local buf = buffer.create(8);
        mem.writeVector2(buf, 0, vector.create(1.0, 2.0));
        expect(buffer.readf32(buf, 0)).toBe(1.0);
        expect(buffer.readf32(buf, 4)).toBe(2.0);
        expect(function()
            mem.writeVector2(buffer.create(2), 0, vector.create(1.0, 2.0));
        end).toThrow("access out of bounds");
        expect(function()
            mem.writeVector2(buf, 5, vector.create(1.0, 2.0));
        end).toThrow("access out of bounds");
    end)
    test("writeVector3", function()
        local buf = buffer.create(12);
        mem.writeVector3(buf, 0, vector.create(1.0, 2.0, 3.0));
        expect(buffer.readf32(buf, 0)).toBe(1.0);
        expect(buffer.readf32(buf, 4)).toBe(2.0);
        expect(buffer.readf32(buf, 8)).toBe(3.0);
        expect(function()
            mem.writeVector3(buffer.create(2), 0, vector.create(1.0, 2.0, 3.0));
        end).toThrow("access out of bounds");
        expect(function()
            mem.writeVector3(buf, 5, vector.create(1.0, 2.0, 3.0));
        end).toThrow("access out of bounds");
    end)
end)