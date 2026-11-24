--!strict
--- @description Evaluate lua/luau code snippet.

local mem = zune.mem
local process = zune.process

local ansi = require("@zune/ansi").auto()

local function fail(label: string, msg: string): never
    print(`{ansi.paint(ansi.red, label)}: {msg}`)
    return process.exit(1)
end

local source = process.args[2]
if not source then
    fail("usage", "eval <luau>")
    return
end

if mem.startsWith(source, "#!") then
    local newline = mem.findScalar(source, 10) -- '\n'
    source = if newline then string.sub(source, newline + 1) else ""
end

_G._FILE = { main = true }

local function syntax(message: unknown): never
    local text = tostring(message)
    if mem.startsWith(text, ":") then
        text = `///EVAL{text}`
    end
    return fail("syntax error", text)
end

local compiled, bytecode = pcall(zune.luau.compile, source, nil)
if not compiled then
    syntax(bytecode)
    return
end

local loaded, chunk = pcall(
    zune.luau.load,
    bytecode :: buffer,
    {
        chunk_name = "=///EVAL",
    } :: any
)
if not loaded then
    syntax(chunk)
end

zune.task.spawn(function()
    chunk()
end)
