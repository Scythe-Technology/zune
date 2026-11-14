local utilA = require("./Utils/utilA");
local constant = require("./anyvalue");

local testing = require("@zune/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("utilA", function()
	test("validating", function()
		expect(utilA).toBe(expect.any("table"));
		local i, v = next(utilA);
		expect(i).toBeNil();
		expect(v).toBeNil();
	end)
end)

test("constant", function()
	expect(constant).toBe(expect.type("string"));
	expect(constant).toBe("Zune");
end)

describe("simpleLib", function()
	test("validating context", function()
		expect(_FILE).never.toBeNil();
		expect(debug.info(1, "s"):find("simpleLib%.luau")).never.toBeNil();
	end)
end)

local simple = {};

simple.size = 32;
simple.buffer = buffer.create(simple.size);

function simple:emit()
	return "Hello, World!";
end

return simple;