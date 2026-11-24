--!strict
local testing = require("@zune/testing")

local describe = testing.describe

describe("tar", function()
    require("@self/tar.test")
end)

describe("zip", function()
    require("@self/zip.test")
end)

return nil
