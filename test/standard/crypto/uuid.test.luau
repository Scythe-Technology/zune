--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("UUID", function()
    test("v4", function()
        local uuid = crypto.uuid.v4();
        expect(uuid).toBe(expect.type("string"));
        expect(#uuid).toBe(36);
        local split = string.split(uuid, "-");
        expect(#split).toBe(5);
        expect(#split[1]).toBe(8);
        expect(#split[2]).toBe(4);
        expect(#split[3]).toBe(4);
        expect(#split[4]).toBe(4);
        expect(#split[5]).toBe(12);
    end)

    test("v7", function()
        local uuid = crypto.uuid.v7();
        expect(uuid).toBe(expect.type("string"));
        expect(#uuid).toBe(36);
        local split = string.split(uuid, "-");
        expect(#split).toBe(5);
        expect(#split[1]).toBe(8);
        expect(#split[2]).toBe(4);
        expect(#split[3]).toBe(4);
        expect(#split[4]).toBe(4);
        expect(#split[5]).toBe(12);
    end)
end)

return nil;