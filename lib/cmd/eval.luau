--!strict
--- @description Evaluate lua/luau code snippet.

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

if string.sub(source, 1, 2) == "#!" then
    local newline = string.find(source, "\n", 1, true)
    source = if newline then string.sub(source, newline) else ""
end

_G._FILE = { main = true }

local function syntax(message: unknown): never
    local text = tostring(message)
    if string.sub(text, 1, 1) == ":" then
        text = `///EVAL{text}`
    end
    return fail("syntax error", text)
end

local compiled, bytecode = pcall(function()
    return zune.luau.compile(source)
end)
if not compiled then
    syntax(bytecode)
    return
end

local loaded, chunk = pcall(function()
    return zune.luau.load(bytecode :: buffer, {
        chunk_name = "=///EVAL",
    })
end)
if not loaded or type(chunk) ~= "function" then
    syntax(chunk)
end

zune.task.spawn(function()
    chunk()
end)
