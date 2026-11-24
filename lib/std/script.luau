--!strict
--!optimize 2

local fs = zune.fs

local script = {}

--- Relative path to the script.
---
--- ```lua
--- local txt = script.relative("../notes.txt")
--- ```
---
--- @param path - Relative path from the script.
--- @return The relative path script.
function script.relative(path: string): string
    if fs.path.isAbsolute(path) then
        error("path must be relative", 0)
    end
    local source = zune.debug.source(2)
    if not source then
        error("script source is missing", 0)
    end
    local dir = fs.path.dirname(source)
    local base = if dir then dir else "."
    return fs.path.resolve(fs.path.join(base, path))
end

return script
