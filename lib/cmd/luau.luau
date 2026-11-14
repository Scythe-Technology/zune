--!strict
--- @description Display info from luau.

local process = zune.process

local ansi = require("@zune/ansi").auto()

local function fail(label: string, msg: string): never
    print(`{ansi.paint(ansi.red, label)}: {msg}`)
    return process.exit(1)
end

local command = process.args[2]
if not command or process.args[3] then
    fail("usage", "luau <list-fflags | version>")
    return
end

if command == "version" then
    local major, minor = _LUAU.version.major, _LUAU.version.minor
    print(`{major}.{minor}`)
    return
end

if command ~= "list-fflags" then
    fail("usage", "luau <list-fflags | version>")
    return
end

local flags = zune.luau.fflag.list()
local longest = 0
for _, flag in flags do
    if #flag.name > longest then
        longest = #flag.name
    end
end

local function writeFlag(flag: LuauFFlag)
    local pad = string.rep(".", longest - #flag.name + 2)
    local name = `{ansi.bold}{flag.name} {ansi.dim}{pad}{ansi.reset}`
    if flag.type == "integer" then
        print(
            `{name} = ({ansi.bold}{ansi.bright_cyan}int{ansi.reset})  {ansi.bold}{ansi.yellow}{flag.value}{ansi.reset}`
        )
    else
        local tone = if flag.value then ansi.green else ansi.red
        print(`{name} = ({ansi.bold}{ansi.yellow}bool{ansi.reset}) {ansi.bold}{tone}{flag.value}{ansi.reset}`)
    end
end

for _, flag in flags do
    if flag.type == "integer" then
        writeFlag(flag)
    end
end
for _, flag in flags do
    if flag.type == "boolean" then
        writeFlag(flag)
    end
end
