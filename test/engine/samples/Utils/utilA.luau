local utilB = require("./utilB");

local testing = require("@zune/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("utilB", function()
	test("validating", function()
		expect(utilB).toBeNil();
	end)
end)

describe("utilA", function()
	test("validating context", function()
		expect(_FILE).never.toBeNil();
		expect(debug.info(1, "s"):find("utilA%.luau")).never.toBeNil();
	end)
end)

local util = {};

return util;