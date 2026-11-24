local sibling = require("@self/sub")
local child = require("./child")

return {
    sibling = sibling,
    child = child,
}
