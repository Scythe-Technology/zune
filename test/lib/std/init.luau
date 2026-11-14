--!strict
local testing = require("@zune/testing")

local describe = testing.describe

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)")
assert(version and #version > 0, "No version")

describe("fs", function()
    require("@self/fs.test")
end)

describe("io", function()
    require("@self/io.test")
end)

describe("net", function()
    require("@self/net")
end)
