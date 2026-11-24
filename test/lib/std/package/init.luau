--!strict
local testing = require("@zune/testing")

local describe = testing.describe

describe("resolve", function()
    require("@self/resolve.test")
end)

describe("git", function()
    require("@self/git.test")
end)

describe("archive", function()
    require("@self/archive.test")
end)

describe("clean", function()
    require("@self/clean.test")
end)

return nil
