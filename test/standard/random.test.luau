--!strict
local random = zune.random;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function randomTest(impl: any)
    do
        local rand: Random = impl.new();
        for i = 1, 20 do
            rand:nextInteger(0, 10);
        end
        for i = 1, 20 do
            rand:nextNumber(0, 10);
        end
    end
    
    local rand: Random = impl.new(0);
    for i = 1, 20 do
        local result = rand:nextInteger(0, 10);
        expect(result).toBeGreaterThanOrEqual(0);
        expect(result).toBeLessThanOrEqual(10);
        expect(result // 1).toBe(result);
    end
    for i = 1, 20 do
        local result = rand:nextNumber(0, 10);
        expect(result).toBeGreaterThanOrEqual(0);
        expect(result).toBeLessThanOrEqual(10);
        expect(result // 1).never.toBe(result);
    end

    expect(rand:nextNumber(0, math.huge)).toBe(math.huge);
    expect(rand:nextNumber(math.huge, 0)).toBe(math.huge);
    expect(rand:nextNumber(math.huge, math.huge)).toBe(math.huge);
    expect(rand:nextNumber(0, -math.huge)).toBe(-math.huge);
    expect(rand:nextNumber(-math.huge, 0)).toBe(-math.huge);
    expect(rand:nextNumber(-math.huge, -math.huge)).toBe(-math.huge);
    expect(tostring(rand:nextNumber(-math.huge, math.huge))).toBe(tostring(0/0));
    expect(tostring(rand:nextNumber(math.huge, -math.huge))).toBe(tostring(0/0));
    expect(tostring(rand:nextNumber(0/0, 0/0))).toBe(tostring(0/0));
    expect(tostring(rand:nextNumber(0, 0/0))).toBe(tostring(0/0));
    expect(tostring(rand:nextNumber(0/0, 0))).toBe(tostring(0/0));

    local copy = rand:clone();
    expect(copy:nextInteger(0, 10)).toBe(rand:nextInteger(0, 10));
    copy:nextInteger(0, 10);
    copy:nextInteger(0, 10);
    expect(copy:nextInteger(0, 10)).never.toBe(rand:nextInteger(0, 10));
end

describe("Random", function()
    test("Default", function()
        randomTest(random);
    end)
    test("LuauPcg32", function()
        randomTest(random.LuauPcg32);
    end)
    test("Isaac64", function()
        randomTest(random.Isaac64);
    end)
    test("Pcg32", function()
        randomTest(random.Pcg32);
    end)
    test("Xoroshiro128", function()
        randomTest(random.Xoroshiro128);
    end)
    test("Xoshiro256", function()
        randomTest(random.Xoshiro256);
    end)
    test("Sfc64", function()
        randomTest(random.Sfc64);
    end)
    test("RomuTrio", function()
        randomTest(random.RomuTrio);
    end)
end)
