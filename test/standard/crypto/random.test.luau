--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Random", function()
    test("NextInteger", function()
        expect(crypto.random.nextInteger()).toBe(expect.type("number"));
        expect(crypto.random.nextInteger(-10, 10)).toBe(expect.type("number"));
        expect(function()
            crypto.random.nextInteger(-10);
        end).toThrow("missing argument #2 to 'nextInteger' (number expected)");
        expect(function()
            crypto.random.nextInteger(100, -100);
        end).toThrow("invalid range (min > max)");
        expect(crypto.random.nextInteger(0, 0)).toBe(0);
    end)

    test("NextNumber", function()
        expect(crypto.random.nextNumber()).toBe(expect.type("number"));
        expect(crypto.random.nextNumber(-0.5, 0.5)).toBe(expect.type("number"));
        expect(function()
            crypto.random.nextNumber(-10);
        end).toThrow("missing argument #2 to 'nextNumber' (number expected)");
        expect(function()
            crypto.random.nextNumber(100, -100);
        end).toThrow("invalid range (min > max)");
        expect(crypto.random.nextNumber(0, 0)).toBe(0);
    end)

    test("NextBoolean", function()
        expect(crypto.random.nextBoolean()).toBe(expect.type("boolean"));
    end)

    test("Fill", function()
        local buf = buffer.create(16);

        crypto.random.fill(buf, 8, 8);

        expect(buffer.readstring(buf, 0, 8)).toBe("\0\0\0\0\0\0\0\0");
        expect(buffer.readstring(buf, 8, 8)).never.toBe("\0\0\0\0\0\0\0\0");

        expect(function()
            crypto.random.fill(buf, 0, 17);
        end).toThrow("invalid length (offset + length > buffer size)");
        expect(function()
            crypto.random.fill(buf, 8, 9);
        end).toThrow("invalid length (offset + length > buffer size)");
        expect(function()
            crypto.random.fill(buf, -1, 1);
        end).toThrow("invalid offset (offset < 0)");
        expect(function()
            crypto.random.fill(buf, 0, -1);
        end).toThrow("invalid length (length < 0)");
    end)
end)

return nil;