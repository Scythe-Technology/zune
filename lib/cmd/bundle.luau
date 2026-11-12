--!strict
--- @description Bundle lua/luau scripts and files into a standalone executable.

local process = zune.process
local mem = zune.mem

local io = require("@zune/io")
local fs = require("@zune/fs")
local ansi = require("@zune/ansi").auto()

local cwd = io.cwd()

--- max 32
--- 8 = magic
--- 24 = zero bytes (no image)
local IMAGE_PATTERN = `[ZLBD01]{string.rep("\0", 24)}`

local function fail(label: string, msg: string): never
    print(`{ansi.paint(ansi.red, label)}: {msg}`)
    return process.exit(1)
end

local __verbose = false
local function verbose(color: string, label: string, msg: string)
    if not __verbose then
        return
    end
    print(`{ansi.paint(color, label)}: {msg}`)
end

local function readFile(path: string): buffer
    local ok, res = pcall(fs.readFileBytes, path)
    if not ok then
        if (res :: any) == "FileNotFound" then
            return fail("error", `'{path}' was not found`)
        end
        if (res :: any) == "IsDir" then
            return fail("error", `'{path}' is a directory`)
        end
        return fail("error", tostring(res))
    end
    return res
end

local state = {
    scripts = {} :: { string },
    files = {} :: { string },
    release = false,
    limbo = false,
    ncg = true,
    jit = true,
    optimization_level = 1,
    debug_level = 2,
    out_path = nil :: string?,
    exe_path = nil :: string?,
    home = process.env.HOME or process.env.USERPROFILE or "",
    format = {
        enabled = true,
        max_depth = 4,
        use_color = true,
        table_address = true,
        recursive_table = false,
        buffer_max_display = 48,
    },
}

local basket = state.scripts

local function level(arg: string, flag: string): number
    if #arg ~= 3 then
        return fail("error", `invalid {flag} level, usage: -{flag}<N>`)
    end
    local digit = tonumber(string.sub(arg, 3, 3))
    if digit and digit >= 0 and digit <= 2 then
        return digit
    end
    return fail("error", `invalid {flag} level, usage: -{flag}<N>`)
end

local function normalize(path: string): string
    if zune.platform.os ~= "windows" then
        return path
    end
    return (string.gsub(path, "\\", "/"))
end

local function findMeta(text: string): number?
    return (string.find(text, "[%*%?%[{]", 1))
end

local function splitSlash(path: string): { string }
    local parts: { string } = {}
    local start = 1
    for index = 1, #path do
        if string.sub(path, index, index) == "/" then
            table.insert(parts, string.sub(path, start, index - 1))
            start = index + 1
        end
    end
    table.insert(parts, string.sub(path, start))
    return parts
end

local function joinParts(parts: { string }): string
    if #parts == 0 then
        return "."
    end
    if parts[1] == "" then
        if #parts == 1 then
            return "/"
        end
        return `/{table.concat(parts, "/", 2)}`
    end
    return table.concat(parts, "/")
end

local function isLuauScript(name: string): boolean
    local ext = fs.path.extension(name)
    return ext == ".luau" or ext == ".lua"
end

local function openIter(parent: any, path: string): any
    local ok, res: any = pcall(function()
        return parent:openDir(path, { iterate = true })
    end)
    if not ok then
        if res == "FileNotFound" then
            return fail("error", `'{path}' was not found`)
        end
        if res == "NotDir" then
            return fail("error", `'{path}' is not a directory`)
        end
        return fail("error", tostring(res))
    end
    return res
end

local function childPath(dir: string, name: string): string
    if dir == "." then
        return name
    end
    return fs.path.join(dir, name)
end

local function expand(arg: string, into: { string }, scripts_only: boolean): { string }
    local pattern = normalize(arg)
    verbose(ansi.blue, "info", `expanding pattern '{pattern}'`)
    if not findMeta(pattern) then
        return { arg }
    end

    local parts = splitSlash(pattern)
    local static_count = 0
    for index, part in parts do
        if findMeta(part) ~= nil then
            break
        end
        static_count = index
    end

    local static: { string } = {}
    for index = 1, static_count do
        static[index] = parts[index]
    end
    local rest: { string } = {}
    for index = static_count + 1, #parts do
        table.insert(rest, parts[index])
    end

    local scan_dir = fs.path.resolve(joinParts(static))
    if scan_dir == "" then
        scan_dir = "."
    end
    local glob_part = table.concat(rest, "/")
    local match_pattern = if scan_dir == "."
        then glob_part
        elseif scan_dir == "/" then `/{glob_part}`
        else `{normalize(scan_dir)}/{glob_part}`

    local recursive = string.find(pattern, "**", 1, true) ~= nil
    if not recursive then
        for index = 1, #parts - 1 do
            if findMeta(parts[index]) ~= nil then
                recursive = true
                break
            end
        end
    end

    local taken: { [string]: boolean } = {}
    for _, existing in into do
        taken[fs.path.resolve(existing)] = true
    end

    local found: { string } = {}
    local matched = 0
    local root = openIter(cwd, scan_dir)

    local function scan(dir: Dir, dir_path: string)
        for _, entry in dir:entries() do
            local name = entry.name
            local path = childPath(dir_path, name)
            if entry.kind == "file" then
                verbose(ansi.green, "scan", `found file {ansi.green}'{path}'{ansi.reset}`)
                local listed = fs.path.globMatch(normalize(path), match_pattern)
                if listed and (not scripts_only or isLuauScript(name)) then
                    matched += 1
                    local resolved = fs.path.resolve(path)
                    if not taken[resolved] then
                        taken[resolved] = true
                        table.insert(found, path)
                    end
                end
            elseif entry.kind == "directory" and recursive then
                verbose(ansi.cyan, "scan", `found directory {ansi.green}'{path}'{ansi.reset}`)
                local child = openIter(dir, name)
                scan(child, path)
                child:close()
            end
        end
    end

    verbose(
        ansi.blue,
        "info",
        `starting scan in directory {ansi.green}'{scan_dir}'{ansi.reset} with pattern '{match_pattern}'`
    )
    scan(root, scan_dir)
    root:close()
    verbose(ansi.blue, "info", `finished scanning directory {ansi.green}'{scan_dir}'{ansi.reset}`)

    table.sort(found)
    return found
end

for _, arg in process.args do
    if arg == "--verbose" then
        __verbose = true
    end
end

local config = zune.config.getFromFile(cwd, "zune.toml")

state.debug_level = config.runtime.luau.debug_level
state.optimization_level = config.runtime.luau.optimization_level
state.jit = config.runtime.luau.jit_enabled
state.ncg = config.runtime.luau.default_ncg
state.format = config.format

local index = 2
while index <= #process.args do
    local arg = process.args[index]
    if arg == "--verbose" then
        index += 1
        continue
    end
    verbose(ansi.blue, "info", `processing argument '{arg}'`)
    if string.sub(arg, 1, 1) == "-" then
        if arg == "-f" or arg == "--files" then
            basket = state.files
        elseif arg == "-s" or arg == "--scripts" then
            basket = state.scripts
        elseif arg == "--release" then
            state.release = true
        elseif arg == "--debug" then
            state.release = false
        elseif arg == "--limbo" then
            state.limbo = true
        elseif arg == "--no-fmt" then
            state.fmt = false
        elseif arg == "--native" then
            state.ncg = true
        elseif arg == "--no-native" then
            state.ncg = false
        elseif arg == "--no-jit" then
            state.jit = false
        elseif arg == "--no_home" then
            state.home = ""
        elseif string.sub(arg, 1, 2) == "-O" then
            state.optimization_level = level(arg, "O")
        elseif string.sub(arg, 1, 2) == "-g" then
            state.debug_level = level(arg, "g")
        elseif string.sub(arg, 1, 6) == "--out=" then
            state.out_path = string.sub(arg, 7)
            if state.out_path == "" or state.out_path == "-" then
                fail("error", "usage: --out=<file>")
            end
        elseif string.sub(arg, 1, 6) == "--exe=" then
            state.exe_path = string.sub(arg, 7)
            if state.exe_path == "" then
                fail("error", "usage: --exe=<file>")
            end
        elseif string.sub(arg, 1, 7) == "--home=" then
            state.home = string.sub(arg, 8)
            if state.home == "" then
                fail("error", "usage: --home=<dir>")
            end
        elseif string.sub(arg, 1, 14) == "--compression=" then
            local kind = string.sub(arg, 15)
            if kind ~= "none" then
                fail("error", `compression '{kind}' is not supported`)
            end
        else
            fail("error", `unknown flag '{arg}'`)
        end
    else
        for _, script_path in expand(arg, basket, basket == state.scripts) do
            table.insert(basket, script_path)
        end
    end
    index += 1
end

if #state.scripts < 1 then
    fail("usage", "bundle [flags] <script> [scripts...] [-f <file>...]")
end

local function compile(source: string): buffer
    local body = source
    if string.sub(body, 1, 2) == "#!" then
        local newline = string.find(body, "\n", 1, true)
        body = if newline then string.sub(body, newline) else ""
    end
    local ok, bytecode = pcall(function()
        return zune.luau.compile(body, {
            debug_level = state.debug_level,
            optimization_level = state.optimization_level,
        })
    end)
    if not ok or type(bytecode) ~= "buffer" then
        return fail("compile error", tostring(bytecode))
    end
    return bytecode
end

local function fileSize(path: string): number
    local ok, res = pcall(function()
        return cwd:statFile(path, { follow_symlinks = true })
    end)
    if not ok then
        if (res :: any) == "FileNotFound" then
            return fail("error", `'{path}' was not found`)
        end
        return fail("error", tostring(res))
    end
    if res.kind == "directory" then
        return fail("error", `'{path}' is a directory`)
    end
    if res.kind ~= "file" then
        return fail("error", `'{path}' is not a file`)
    end
    return res.size
end

type Item = {
    kind: number,
    name: string,
    path: string,
    size: number,
    body: buffer?,
}

local items: { Item } = {}
local seen: { [string]: boolean } = {}

local function addItem(kind: number, path: string, size: number, body: buffer?)
    local name = fs.path.resolve(path)
    if seen[name] then
        fail("error", `'{name}' is already bundled`)
        return
    end
    if #name > 32767 or size > 137438953471 then
        fail("error", `'{name}' is too long to bundle`)
        return
    end
    seen[name] = true
    table.insert(items, {
        kind = kind,
        name = name,
        path = path,
        size = size,
        body = body,
    })
end

for _, path in state.scripts do
    if state.release then
        local body = compile(buffer.tostring(readFile(path)))
        verbose(ansi.blue, "info", `adding compiled script {ansi.green}'{path}'{ansi.reset}`)
        addItem(0, path, buffer.len(body), body)
    else
        verbose(ansi.blue, "info", `adding script {ansi.green}'{path}'{ansi.reset}`)
        addItem(0, path, fileSize(path), nil)
    end
end

for _, path in state.files do
    verbose(ansi.blue, "info", `adding file {ansi.green}'{path}'{ansi.reset}`)
    addItem(1, path, fileSize(path), nil)
end

local home_relative = if #state.home == 0 then "" else fs.path.relative(fs.realPathAlloc(cwd), state.home)
verbose(ansi.blue, "info", `checking home relative path '{home_relative}'`)
if mem.findAny(home_relative, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") then
    print(
        `{ansi.yellow}warning{ansi.reset}: resolved home directory relative path '{home_relative}' contains normal characters`
    )
    print("The bundled application may contain unwanted path names")
end

state.home = home_relative

if #state.home > 65535 then
    fail("error", "home directory is too long")
end

local payload_len = 11 + #state.home
for _, item in items do
    payload_len += 8 + #item.name + item.size
end

local payload = zune.io.createBufferArray({
    limit = payload_len,
})
local into = io.createWriter(payload, { positional = true })

local function writeBits(buf: buffer, bit_at: number, value: number, count: number): number
    buffer.writebits(buf, bit_at, count, value)
    return bit_at + count
end

do
    local buf = buffer.create(11 + #state.home)
    local bit_at = 0
    verbose(ansi.blue, "info", `writing bundle header`)

    verbose(
        ansi.blue,
        "info",
        table.concat({
            `bundle runtime configuration header:`,
            `  release: {ansi.cyan}{if state.release then 1 else 0}{ansi.reset}`,
            `  limbo: {ansi.cyan}{if state.limbo then 1 else 0}{ansi.reset}`,
            `  debug_level: {ansi.cyan}{state.debug_level}{ansi.reset}`,
            `  optimization_level: {ansi.cyan}{state.optimization_level}{ansi.reset}`,
            `  default_ncg: {ansi.cyan}{if state.ncg then 1 else 0}{ansi.reset}`,
            `  jit_enabled: {ansi.cyan}{if state.jit then 1 else 0}{ansi.reset}`,
            `  format:`,
            `    enabled: {ansi.cyan}{if state.format.enabled then 1 else 0}{ansi.reset}`,
            `    use_color: {ansi.cyan}{if state.format.use_color then 1 else 0}{ansi.reset}`,
            `    table_address: {ansi.cyan}{if state.format.table_address then 1 else 0}{ansi.reset}`,
            `    recursive_table: {ansi.cyan}{if state.format.recursive_table then 1 else 0}{ansi.reset}`,
            `    max_depth: {ansi.cyan}{state.format.max_depth}{ansi.reset}`,
            `    buffer_max_display: {ansi.cyan}{state.format.buffer_max_display}{ansi.reset}`,
        }, "\n")
    )

    bit_at = writeBits(buf, bit_at, if state.release then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, if state.limbo then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, state.debug_level, 2)
    bit_at = writeBits(buf, bit_at, state.optimization_level, 2)
    bit_at = writeBits(buf, bit_at, if state.ncg then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, if state.jit then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, if state.format.enabled then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, if state.format.use_color then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, if state.format.table_address then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, if state.format.recursive_table then 1 else 0, 1)
    bit_at = writeBits(buf, bit_at, state.format.max_depth, 8)
    bit_at = writeBits(buf, bit_at, state.format.buffer_max_display, 15)
    bit_at = writeBits(buf, bit_at, 0, 5) -- reserved
    mem.reverse(buf, bit_at // 8 - 5, 5)

    local feature_names = {
        "io",
        "mem",
        "fmt",
        "luau",
        "task",
        "debug",
        "ascii",
        "serde",
        "regex",
        "config",
        "crypto",
        "random",
        "require",
        "testing",
        "process",
        "platform",
        "fs",
        "c",
        "gpio",
        "net",
        "time",
        "thread",
    }
    for _, feature in feature_names do
        local enabled = if (config.runtime.features :: any)[feature] == true then 1 else 0
        verbose(ansi.blue, "info", `checking feature {ansi.yellow}{feature}{ansi.reset} enabled: {enabled}`)
        bit_at = writeBits(buf, bit_at, enabled, 1)
    end

    bit_at = writeBits(buf, bit_at, 0, 32 - #feature_names)
    mem.reverse(buf, bit_at // 8 - 4, 4)

    verbose(ansi.blue, "info", `writing home path: {#state.home}`)
    bit_at = writeBits(buf, bit_at, #state.home, 16)
    mem.reverse(buf, bit_at // 8 - 2, 2)

    buffer.writestring(buf, 11, state.home)

    verbose(ansi.blue, "info", `finalizing bundle header`)
    into:writeAll(buf)
end

local function pipeFile(path: string, size: number)
    local opened, file = pcall(function()
        return cwd:openFile(path, { mode = "r" })
    end)
    if not opened then
        if (file :: any) == "FileNotFound" then
            fail("error", `'{path}' was not found`)
            return
        end
        fail("error", tostring(file))
        return
    end
    local moved = io.createReader(file, { positional = true }):pipe(into, size)
    file:close()
    if moved ~= size then
        fail("error", `'{path}' ended early`)
    end
end

for _, item in items do
    local buf = buffer.create(7 + #item.name + 1)
    local bit_at = 0
    bit_at = writeBits(buf, bit_at, item.kind, 1)
    bit_at = writeBits(buf, bit_at, 0, 3) -- compression none
    bit_at = writeBits(buf, bit_at, #item.name, 15)
    bit_at = writeBits(buf, bit_at, item.size % (2 ^ 32), 32)
    bit_at = writeBits(buf, bit_at, item.size // (2 ^ 32), 5)
    mem.reverse(buf, bit_at // 8 - 7, 7)
    buffer.writestring(buf, 7, item.name)
    buffer.writeu8(buf, 7 + #item.name, 0)
    into:writeAll(buf)
    local body = item.body
    if body then
        verbose(ansi.blue, "info", `writing body of file {ansi.green}'{item.path}'{ansi.reset} of size {item.size}`)
        into:writeAll(body)
    else
        verbose(ansi.blue, "info", `piping file {ansi.green}'{item.path}'{ansi.reset} of size {item.size}`)
        pipeFile(item.path, item.size)
    end
end

if payload.len ~= payload_len then
    fail("error", "bundle payload length does not match")
    return
end

local exe = fs.path.resolve(state.exe_path or process.getExePath())
local out = fs.path.resolve(state.out_path or fs.path.stem(fs.path.basename(state.scripts[1])))
verbose(ansi.blue, "info", `resolved exe path: {ansi.green}'{exe}'{ansi.reset}`)
verbose(ansi.blue, "info", `resolved output path: {ansi.green}'{out}'{ansi.reset}`)
if out == exe then
    fail("error", "refusing to patch the executable in place")
    return
end

verbose(ansi.blue, "info", `reading executable file {ansi.green}'{exe}'{ansi.reset}`)
local exe_file = readFile(exe)
local hits = {}
local from = 0
while true do
    local at = mem.findPos(exe_file, from, IMAGE_PATTERN)
    if at == nil then
        break
    end
    table.insert(hits, at)
    from = at + 1
end
if #hits == 0 then
    fail("error", "executable has no bundle image")
    return
end
if #hits ~= 1 then
    fail("error", "executable has more than one bundle image")
    return
end

local at = hits[1]

verbose(ansi.blue, "info", `patching executable at offset {at}`)
buffer.writebits(exe_file, (at + 8) * 8, 32, #items)
mem.reverse(exe_file, at + 8, 4)
buffer.writeu8(exe_file, at + 12, 1)

zune.mem.writeu64(exe_file, at + 16, payload.len)
mem.reverse(exe_file, at + 16, 8)
zune.mem.writeu64(exe_file, at + 24, buffer.len(exe_file))
mem.reverse(exe_file, at + 24, 8)

local parent = fs.path.dirname(out)
if parent and #parent > 0 then
    local ok, err = pcall(function()
        cwd:createDirPath(parent)
    end)
    if not ok and err ~= "PathAlreadyExists" then
        fail("error", `failed to create '{parent}': {tostring(err)}`)
    end
end

local created, handle = pcall(function()
    return cwd:createFile(out, {
        truncate = true,
        nonblocking = true,
        permissions = 493, -- o755
    })
end)
if not created or type(handle) ~= "userdata" then
    fail("error", `failed to create '{out}': {tostring(handle)}`)
end

local writer = io.createWriter(handle, { positional = true })
writer:writeAll(exe_file)

io.createReader(payload, { positional = true }):pipe(writer)

handle:sync()
handle:close()
