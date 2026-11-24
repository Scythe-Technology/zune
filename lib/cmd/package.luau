--!strict
--- @description Install, fetch, and build from package.luau.
--- @description
--- @description   package install [--yes] [--target <arch>-<os>[-<abi>]] [<options>]
--- @description   package add <url>
--- @description   package why [hash]
--- @description   package build [--yes] [--target <arch>-<os>[-<abi>]] [--zune-bin <file>] [--out <file>] [--debug] [<options>]
--- @description   package clean [--unused] [--cache] [--cache-system] [--env] [--reset]
--- @description

local mem = zune.mem
local process = zune.process

local pkg = require("@zune/package")
local pkg_tui = require("@zune/package/tui")

local ansi = require("@zune/ansi").auto()

local USAGE = table.concat({
    `{ansi.red}usage{ansi.reset}: package install [--yes] [--target <arch>-<os>[-<abi>]] [<options>]`,
    "       package add <url>",
    "       package why [hash]",
    "       package build [--yes] [--target <arch>-<os>[-<abi>]] [--zune-bin <file>] [--out <file>] [--debug] [<options>]",
    "       package clean [--unused] [--cache] [--cache-system] [--env] [--reset]",
}, "\n")

local function parseNumber(text: string): number?
    if
        string.match(text, "^[%+%-]?%d+$")
        or string.match(text, "^[%+%-]?%d+%.%d+$")
        or string.match(text, "^[%+%-]?%d+[eE][%+%-]?%d+$")
        or string.match(text, "^[%+%-]?%d+%.%d+[eE][%+%-]?%d+$")
    then
        return tonumber(text)
    end
    return nil
end

local function parseVector(text: string): vector?
    local parts = string.split(text, ",")
    if #parts ~= 3 then
        return nil
    end
    local x = parseNumber(string.match(parts[1], "^%s*(.-)%s*$") or "")
    local y = parseNumber(string.match(parts[2], "^%s*(.-)%s*$") or "")
    local z = parseNumber(string.match(parts[3], "^%s*(.-)%s*$") or "")
    if x == nil or y == nil or z == nil then
        return nil
    end
    return vector.create(x, y, z)
end

local function parseUserOption(arg: string): (string, any)
    local kind = string.sub(arg, 2, 2)
    local body = string.sub(arg, 3)
    local eq = mem.findScalar(body, 61) -- '='
    local name = if eq then string.sub(body, 1, eq) else body
    local value = if eq then string.sub(body, eq + 2) else nil
    if name == "" then
        error(`{ansi.red}usage{ansi.reset}: -{kind}<name>=<value>`, 0)
    end
    if kind == "S" then
        if value == nil then
            error(`{ansi.red}usage{ansi.reset}: -S<name>=<value>`, 0)
        end
        return name, value
    elseif kind == "N" then
        local number = if value then parseNumber(value) else nil
        if number == nil then
            error(`{ansi.red}usage{ansi.reset}: -N<name>=<number>`, 0)
        end
        return name, number
    elseif kind == "V" then
        local point = if value then parseVector(value) else nil
        if point == nil then
            error(`{ansi.red}usage{ansi.reset}: -V<name>=<x>,<y>,<z>`, 0)
        end
        return name, point
    elseif value == nil then
        return name, true
    elseif value ~= "true" and value ~= "false" then
        error(`{ansi.red}usage{ansi.reset}: -B<name>=<bool>`, 0)
    end
    return name, value == "true"
end

local function main()
    local args = process.args
    local sub = args[2]
    if not sub or sub == "-h" or sub == "--help" then
        print(USAGE)
        if not sub then
            process.exit(1)
        end
        return
    end

    local reporter = pkg_tui.reporter()

    local options: pkg.Options = {
        yes = false,
        target = nil,
        zune_bin = nil,
        out = nil,
        debug = false,
        reporter = reporter,
        unused = false,
        cache = 0,
        env = false,
        reset = false,
        options = nil,
    }
    local positionals: { string } = {}
    local i = 3
    while i <= #args do
        local arg = args[i]
        if arg == "--yes" then
            options.yes = true
        elseif arg == "--target" then
            i += 1
            options.target = args[i]
            if not options.target or options.target == "" then
                error(`{ansi.red}usage{ansi.reset}: --target <arch>-<os>[-<abi>]`, 0)
            end
        elseif arg == "--zune-bin" and sub == "build" then
            i += 1
            options.zune_bin = args[i]
            if not options.zune_bin or options.zune_bin == "" then
                error(`{ansi.red}usage{ansi.reset}: --zune-bin <file>`, 0)
            end
        elseif arg == "--out" then
            i += 1
            options.out = args[i]
            if not options.out or options.out == "" then
                error(`{ansi.red}usage{ansi.reset}: --out <file>`, 0)
            end
        elseif arg == "--debug" and sub == "build" then
            options.debug = true
        elseif arg == "--unused" and sub == "clean" then
            options.unused = true
        elseif arg == "--cache" and sub == "clean" then
            options.cache = math.max(options.cache or 0, 1)
        elseif arg == "--cache-system" and sub == "clean" then
            options.cache = math.max(options.cache or 0, 2)
        elseif arg == "--env" and sub == "clean" then
            options.env = true
        elseif arg == "--reset" and sub == "clean" then
            options.reset = true
        elseif
            mem.startsWith(arg, "-S")
            or mem.startsWith(arg, "-N")
            or mem.startsWith(arg, "-B")
            or mem.startsWith(arg, "-V")
        then
            local name, value = parseUserOption(arg)
            if options.options == nil then
                options.options = {}
            end
            (options.options :: any)[name] = value
        elseif mem.startsWith(arg, "-") then
            error(`{ansi.red}unknown flag{ansi.reset}: '{arg}'`, 0)
        else
            table.insert(positionals, arg)
        end
        i += 1
    end

    if sub == "install" then
        if #positionals ~= 0 then
            error(USAGE, 0)
        end
        pkg.install(options)
        return
    end
    if sub == "add" then
        if #positionals ~= 1 then
            error(USAGE, 0)
        end
        local result = pkg.add(positionals[1], options)
        if result.wrote then
            print(`wrote {result.file}`)
        end
        print(`paste into {ansi.bold}{ansi.underline}{result.file}{ansi.reset} inside build:`)
        print("")
        print(`    {result.line}`)
        return
    end
    if sub == "why" then
        if #positionals > 1 then
            error(USAGE, 0)
        end
        for _, line in pkg.why(positionals[1], options) do
            print(line)
        end
        return
    end
    if sub == "build" then
        if #positionals ~= 0 then
            error(USAGE, 0)
        end
        pkg.build(options)
        return
    end
    if sub == "clean" then
        if #positionals ~= 0 then
            error(USAGE, 0)
        end
        pkg.clean(options)
        return
    end
    error(USAGE, 0)
end

local ok, err = pcall(main)
if not ok then
    print(tostring(err))
    process.exit(1)
end
