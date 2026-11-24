--!strict
--!optimize 2

local fs = require("@zune/fs")
local spec = require("@zune/spec")
local trace = require("@zune/package/trace")
local slot = require("@zune/package/slot")

local ansi = require("@zune/ansi").auto()

trace.mask(getfenv())

export type Kind =
    "runtime"
    | "path"
    | "glob"
    | "export"
    | "self"
    | "command"
    | "execute"
    | "std"
    | "dependency"
    | "library"

export type Info = {
    line: number,
    trace: string,
    owner: any, -- Package
    url: string?,
    hash: string?,
    paths: { string }?,
    artifact: boolean,
    max_size: number?,
    options: any?,
    place: string?,
    base: Node?,
    sub: string?,
    run: string?,
    script: string?,
    inputs: { Node }?,
    cache: boolean?,
}

export type State = {
    dir: string?,
    child: any?, -- Package
}

export type Impl = {
    __index: Impl,
    __tostring: (self: Node) -> string,

    --- Returns a node for a relative path within this node.
    ---
    --- The path is constrained to this node's scope.
    ---
    --- ```lua
    --- local note = tree:path("docs"):path("note.txt")
    --- ```
    ---
    --- @param relative - Relative path to a file or directory.
    --- @return The resolved path node.
    path: (self: Node, relative: string) -> Node,

    --- Returns a glob node matching relative paths under this node.
    ---
    --- The pattern is not resolved immediately. It is stored and passed to the
    --- bundle at runtime.
    ---
    --- ```lua
    --- b.embedScript(tree:glob("**/*.luau"))
    --- b.embedFile(tree:glob("**/*.png"))
    --- ```
    ---
    --- @param pattern - Relative glob pattern (for example, `**/*.png`).
    --- @return The glob node.
    glob: (self: Node, pattern: string) -> Node,
}

export type Fields = {
    id: number,
    kind: Kind,
    name: string,
    ctx: any, -- Context
    info: Info,
    state: State,
}

export type Node = setmetatable<Fields, Impl>

local Node = {} :: Impl
Node.__index = Node

local pathSpec = spec.intersection(spec.string, spec.minLength(1))
function Node.path(self: Node, relative: string): Node
    if not pathSpec(relative) then
        error("path is required", 0)
    end
    if fs.path.isAbsolute(relative) or slot.rooted(relative) then
        error("path must be relative", 0)
    end
    local parent_sub = if self.kind == "path" then self.info.sub or "" else ""
    local resolved = if parent_sub == "" then fs.path.resolve(relative) else fs.path.resolve(parent_sub, relative)
    local created = self.ctx:createNode(self.info.owner, "path", self.name)
    created.info.base = self
    created.info.sub = slot.noEscapes(resolved, "path leaves the node")
    return created
end

local globSpec = spec.intersection(spec.string, spec.minLength(1))
function Node.glob(self: Node, pattern: string): Node
    if not globSpec(pattern) then
        error("glob is required", 0)
    end
    if fs.path.isAbsolute(pattern) or slot.rooted(pattern) then
        error("glob must be relative", 0)
    end
    local slashed = (string.gsub(pattern, "\\", "/"))
    for piece in string.gmatch(slashed, "[^/]+") do
        if piece == ".." then
            error("glob leaves the node", 0)
        end
    end
    local created = self.ctx:createNode(self.info.owner, "glob", self.name)
    created.info.base = self
    created.info.place = slashed
    return created
end

local function named(self: Node): string
    local current = self
    while current.info.base do
        current = current.info.base
    end
    if current.kind == "dependency" then
        local child = current.state.child
        if type(child) == "table" and type(child.name) == "string" and child.name ~= "" then
            if current == self and type(child.version) == "string" and child.version ~= "" then
                return `{child.name} {child.version}`
            end
            return child.name
        end
        local place = current.info.place
        if place and place ~= "" then
            return place
        end
        local url = current.info.url
        if url and url ~= "" then
            return url
        end
    end
    return current.name
end

function Node.__tostring(self: Node): string
    local kind = self.kind
    local title = named(self)
    local specifier: string = `{kind}({title})`
    if kind == "path" then
        local sub = self.info.sub
        if sub and #sub > 0 then
            specifier = `path({title} {sub})`
        end
    elseif kind == "glob" then
        local place = self.info.place
        if place and #place > 0 then
            specifier = `glob({title} {place})`
        end
    elseif kind == "command" then
        local run = self.info.run
        if run and #run > 0 then
            specifier = `command({title} {run})`
        end
    elseif kind == "execute" then
        local script = self.info.script
        if script and #script > 0 then
            specifier = `execute({title} {script})`
        end
    end
    if #title == 0 or title == kind then
        specifier = kind
    end
    return `{ansi.blue}<Node {specifier}>{ansi.reset}`
end

return Node
