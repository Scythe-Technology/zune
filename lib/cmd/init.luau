--!strict
--- @description Create initial files & configs for zune.

local process = zune.process

local fs = require("@zune/fs")
local io = require("@zune/io")
local tui = require("@zune/tui")
local pkg = require("@zune/package")
local runtime = require("@zune/runtime")

local ansi = require("@zune/ansi").auto()

local CONFIG = [[
# Zune Configuration

# Debug settings
#  This affects the way Zune handles errors and debug information.
[runtime]
use_detailed_error = true

# Compiling settings
#  This affects all required files and the main file.
[runtime.luau]
debug_level = 2
optimization_level = 1
default_ncg = true

# Formatter settings
#  This affects the output of the formatter while printing.
[format]
max_depth = 4
use_color = true
table_address = true
recursive_table = false
sorted = false
buffer_max_display = 48

# FFlag settings for Luau
#  You can use `zune luau list-fflags` to list all available FFlags.
#[runtime.luau.fflags]
#DebugCodegenOptSize = false

# Features settings
#  This affects the features that are enabled in Zune.
#  mainly builtin libraries and features.
#[runtime.features]
#io = true
#mem = true
#fmt = true
#luau = true
#task = true
#debug = true
#ascii = true
#serde = true
#regex = true
#config = true
#crypto = true
#random = true
#require = true
#testing = true
#process = true
#platform = true
#fs = true
#c = true
#gpio = true
#net = true
#time = true
#thread = true
#hash = true
]]

local MODULE = [[local io = zune.io

local module = {}

function module.hello()
    io.stdout:write("Hello, World!\n")
end

return module
]]

local MODULE_IO = [[local io = require("@zune/io")

local module = {}

function module.hello()
    local writer = io.createWriter(io.stdout)
    writer:writeAll("Hello, World!\n")
end

return module
]]

local TEST = [[local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local module = require("./src")

describe("module", function()
    test("hello", function()
        expect(module.hello).toBe(expect.type("function"))
        module.hello()
    end)
end)
]]

local MAIN = [[local io = zune.io

local function main()
    io.stdout:write("Hello, World!")
end

main()
]]

local MAIN_IO = [[local io = require("@zune/io")

local function main()
    local writer = io.createWriter(io.stdout)
    writer:writeAll("Hello, World!")
end

main()
]]

local function writeNew(cwd: Dir, path: string, contents: string): boolean
    local ok, file = pcall(function()
        return cwd:createFile(path, {
            exclusive = true,
            nonblocking = true,
        })
    end)
    if not ok then
        if (file :: any) == "PathAlreadyExists" then
            return false
        end
        error(tostring(file), 0)
    end

    local writer = io.createPosWriter(file)

    writer:writeAll(contents)

    file:close()

    print(`init created file: {path}`)

    return true
end

local function main()
    local cwd = io.cwd()

    local root = fs.realPathAlloc(cwd)

    local wrote_package = false
    local loaded = nil

    local std_path = runtime.getStd()

    if not std_path then
        local exe_dir = fs.path.dirname(process.getExePath())
        print(`{ansi.yellow}Could not find the standard library. Some features may not work correctly.`)
        print(`  Reinstall the standard library ({exe_dir}){ansi.reset}`)
        print()
    end

    if std_path then
        if fs.stat("package.luau").kind ~= "file" then
            if fs.stat(".config.luau").kind == "file" then
                local allow = tui.ask("aliases in .config.luau would be managed by the package", { "Y", "n" })
                if allow == "Y" then
                    print("loading .config.luau and writing bare package...")
                    loaded = pkg.loadConfig(fs.path.join(root, ".config.luau"))
                    wrote_package = pkg.writeBare(root, loaded)
                    print("init created file: package.luau")
                end
            else
                wrote_package = pkg.writeBare(root)
                print("init created file: package.luau")
            end
        end

        if wrote_package and fs.stat(".zune").kind == "none" then
            pkg.seedConfig(root, loaded)
        end
    end

    if not writeNew(cwd, "zune.toml", CONFIG) then
        print("zune configuration file, 'zune.toml' already exists.")
        print("skipping template creation.")
        return
    end

    local kind = process.args[2]
    if kind == "bare" then
        return
    end

    cwd:createDirPath("src")

    if kind == "module" then
        cwd:createDirPath("tests")
        writeNew(cwd, "src/init.luau", if std_path then MODULE_IO else MODULE)
        if std_path then
            writeNew(cwd, "tests/init.luau", TEST)
        else
            writeNew(cwd, "tests/init.luau", "-- could not create demo test file, missing library.\n")
        end
        return
    end

    writeNew(cwd, "src/main.luau", if std_path then MAIN_IO else MAIN)
end

main()
print("init complete!")
