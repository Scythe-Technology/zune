--!strict
--!optimize 2

local spec = require("@zune/spec")
local trace = require("@zune/package/trace")

local Node = require("@zune/package/Node")

trace.mask(getfenv())

export type Impl = {
    __index: Impl,
    __tostring: (self: Dependency) -> string,

    --- Returns the value exported by this dependency with `name`.
    ---
    --- Throws an error if no export with `name` exists.
    ---
    --- ```lua
    --- local bin = lib:get("bin")
    --- b.install(bin, { name = "libsample.so" })
    --- ```
    ---
    --- @param name - Export name.
    --- @return The exported value.
    get: (self: Dependency, name: string) -> any,
}

export type Dependency = setmetatable<Node.Fields, Impl> & Node.Node

local Dependency = {} :: Impl
Dependency.__index = Dependency
Dependency.__tostring = Node.__tostring

setmetatable(Dependency, Node)

local exportNameSpec = spec.intersection(spec.string, spec.minLength(1))
function Dependency.get(self: Dependency, name: string): any
    if not exportNameSpec(name) then
        error("export name is required", 0)
    end
    local owner = self.info.owner
    local child = self.state.child
    if owner.state.phase ~= "build" or not child or child.state.phase ~= "done" then
        if owner.state.phase ~= "build" then
            return self.ctx:createNode(owner, "export", "export")
        end
        error(`unknown export {name}`, 0)
    end
    local entry = child.state.exported[name]
    if entry == nil then
        error(`unknown export {name}`, 0)
    end
    return entry.value
end

return Dependency
