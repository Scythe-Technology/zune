--!strict
local testing = require("@zune/testing")

local describe = testing.describe

describe("pack", function()
    require("@self/pack.test")
end)

return nil
