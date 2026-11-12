--!strict
local testing = require("@zune/testing")

if not zune.net then
    return
end

local describe = testing.describe

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)")
assert(version and #version > 0, "No version")

describe("socket", function()
    require("@self/socket.test")
end)
