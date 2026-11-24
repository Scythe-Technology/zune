--!strict
local testing = require("@zune/testing")

local describe = testing.describe

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)")
assert(version and #version > 0, "No version")

describe("fs", function()
    require("@self/fs.test")
end)

describe("text", function()
    require("@self/text.test")
end)

describe("spec", function()
    require("@self/spec.test")
end)

describe("script", function()
    require("@self/script.test")
end)

describe("SemanticVersion", function()
    require("@self/SemanticVersion.test")
end)

describe("archive", function()
    require("@self/archive")
end)

describe("git", function()
    require("@self/git")
end)

describe("io", function()
    require("@self/io.test")
end)

describe("package", function()
    require("@self/package")
end)

describe("net", function()
    require("@self/net")
end)
