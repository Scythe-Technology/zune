local sibling = require("./sub")
local child = require("@self/child")

return {
    sibling = sibling,
    child = child,
}
