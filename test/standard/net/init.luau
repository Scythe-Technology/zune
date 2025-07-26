--!strict
local testing = zune.testing;

local describe = testing.describe;

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

describe("Socket", function()
    require("@self/socket.test");
end)

describe("Http", function()
    describe("Server", function()
        require("@self/http/server.test");
    end)

    describe("Requests", function()
        require("@self/http/request.test");
    end)

    describe("WebSockets", function()
        require("@self/http/websocket.test");
    end)
end)
