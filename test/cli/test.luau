local testing = require("@zune/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("cli", function()
    test("basic", function()
        expect(1).toBe(1);
    end)
end)
