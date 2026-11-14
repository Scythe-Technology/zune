--!strict
local testing = require("@zune/testing")

local describe = testing.describe

describe("http", function()
    describe("server", function()
        require("@self/http/server.test")
    end)

    describe("client", function()
        require("@self/http/client.test")
    end)

    describe("websocket", function()
        require("@self/http/websocket.test")
    end)
end)

return nil
