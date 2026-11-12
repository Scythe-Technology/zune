--!strict
--- @description Start REPL session.

local mem = zune.mem
local process = zune.process

local fs = require("@zune/fs")
local io = require("@zune/io")
local ansi = require("@zune/ansi").auto()

local MAX_HISTORY = 200

local out = io.createWriter(io.stdout)
local one = buffer.create(1)

local line = ""
local cursor = 0
local history: { string } = {}
local position = 1
local draft: string? = nil
local exit_armed = false
local finished = false
local history_path: string? = nil

local env = getfenv()

local function readByte(): number?
    local n = io.stdin:read(one, 0, 1)
    if n == 0 then
        return nil
    end
    return buffer.readu8(one, 0)
end

local function draw()
    local tail = #line - cursor
    local rest = if tail > 0 then ansi.cursorMove("left", tail) else ""
    out:writeAll(`{ansi.erase("entire_line")}\r{ansi.paint(ansi.green, "› ")}{line}{rest}`)
end

local function atLatest(): boolean
    return position > #history
end

local function remember(entry: string)
    if string.match(entry, "^ *$") then
        return
    end
    if history[#history] == entry then
        return
    end
    table.insert(history, entry)
    while #history > MAX_HISTORY do
        table.remove(history, 1)
    end
end

local function loadHistory(path: string)
    local ok, file = pcall(function(): File
        return io.cwd():openFile(path)
    end)
    if not ok then
        if (file :: any) == "FileNotFound" then
            return
        end
        error(tostring(file), 0)
    end

    local reader = io.createReader(file, { positional = true })
    local text = buffer.tostring(reader:readRemainingAlloc())
    file:close()

    local start = 1
    while start <= #text do
        local new_line = string.find(text, "\n", start, true)
        local stop = if new_line then new_line - 1 else #text
        local entry = text:sub(start, stop)
        if not string.match(entry, "^[ \r]*$") then
            table.insert(history, entry)
        end
        if not new_line then
            break
        end
        start = new_line + 1
    end

    while #history > MAX_HISTORY do
        table.remove(history, 1)
    end
end

local function saveHistory()
    local path = history_path
    if not path then
        return
    end
    local parent = fs.path.dirname(path)
    if parent then
        io.cwd():createDirPath(parent)
    end
    local file = io.cwd():createFile(path, {
        truncate = false,
        nonblocking = true,
    })
    local writer = io.createWriter(file, { positional = true })
    writer.offset = file:size()
    if #history > 0 then
        writer:writeAll(table.concat(history, "\n"))
        writer:writeAll("\n")
    end
    file:close()
end

local function finish()
    if finished then
        return
    end
    finished = true
    pcall(saveHistory)
    pcall(function()
        io.terminal.restoreMode()
    end)
end

local function show(kind: string, message: string)
    out:writeAll(`{ansi.paint(ansi.red, kind)} {message}`)
    if string.sub(message, -1) ~= "\n" then
        out:writeAll("\n")
    end
end

local function resumeRaw()
    if io.terminal.enableRawMode() then
        return
    end
    out:writeAll(`{ansi.paint(ansi.red, "error")} failed to enable raw mode\n`)
    finish()
    process.exit(1)
end

local function call(fn: () -> ()): ...any
    local this = coroutine.running()

    local done = false
    local result: { [number]: any, n: number }

    zune.task.spawn(function()
        result = table.pack(pcall(fn))
        done = true
        if coroutine.status(this) == "suspended" then
            zune.task.spawn(this)
        end
    end)

    if not done then
        coroutine.yield()
    end

    if not result[1] then
        error(result[2], 0)
    end

    return table.unpack(result, 2, result.n)
end

local function run(source: string)
    io.terminal.restoreMode()
    local compiled, bytecode = pcall(function()
        return zune.luau.compile(source)
    end)
    if not compiled then
        show("syntax", tostring(bytecode))
        resumeRaw()
        return
    end
    local loaded, fn = pcall(function()
        return zune.luau.load(bytecode, {
            chunk_name = "REPL",
            env = env,
        })
    end)
    if not loaded or type(fn) ~= "function" then
        show("syntax", tostring(fn))
        resumeRaw()
        return
    end
    local packed = table.pack(pcall(call, fn))
    if not packed[1] then
        show("error", tostring(packed[2]))
    elseif packed.n > 1 then
        local values = {}
        for index = 2, packed.n do
            values[index - 1] = packed[index]
        end
        out:writeAll(`{zune.fmt.format(table.unpack(values, 1, packed.n - 1))}\n`)
    end
    resumeRaw()
end

local NON_LETTER = " `~!@#$%^&*()-_=+[]{}\\|;:'\",<.>/?"

local function wordRight(from: number): number
    local front = mem.findAnyPos(line, from, NON_LETTER)
    if not front then
        return #line
    end
    return mem.findNonePos(line, front, NON_LETTER) or #line
end

local function wordLeft(from: number): number
    local prefix = mem.slice(line, 0, from)
    local letter = mem.findNoneLast(prefix, NON_LETTER)
    if not letter then
        return 0
    end
    local sep = mem.findAnyLast(mem.slice(prefix, 0, letter), NON_LETTER)
    return if sep then sep + 1 else 0
end

local function recall(text: string)
    line = text
    cursor = #line
    draw()
end

local function interrupt()
    if exit_armed then
        out:writeAll("\n")
        finish()
        process.exit(0)
    end
    exit_armed = true
    out:writeAll(`\n{ansi.paint(ansi.yellow, "^C")} again to exit.\n`)
    draw()
end

local home = process.env.HOME or process.env.USERPROFILE
if type(home) == "string" and home ~= "" then
    history_path = fs.path.join(home, ".zune", ".history")
    loadHistory(history_path)
end
position = #history + 1

if not io.terminal.isTty() then
    out:writeAll(`{ansi.paint(ansi.red, "error")} not a terminal\n`)
    process.exit(1)
end
if not io.terminal.enableRawMode() then
    out:writeAll(`{ansi.paint(ansi.red, "error")} failed to enable raw mode\n`)
    process.exit(1)
end

local version = if type(_VERSION) == "string" then _VERSION else "unknown zune version"
out:writeAll(`{ansi.paint(ansi.bold, version)}\n{ansi.paint(ansi.dim, "ctrl-c twice to exit")}\n`)
draw()

process.onSignal("INT", interrupt)

local function loop()
    while true do
        local byte = readByte()
        if byte == nil then
            out:writeAll("\n")
            return
        end
        if byte ~= 3 and byte ~= 4 then
            exit_armed = false
        end
        if byte == 0x1B then
            if readByte() ~= string.byte("[") then
                continue
            end
            local key = readByte()
            if not key then
                return
            end
            local move = "none"
            if key == string.byte("1") then
                if readByte() ~= string.byte(";") then
                    continue
                end
                local modifier = readByte()
                if modifier == string.byte("5") then
                    move = "ctrl"
                elseif
                    modifier == string.byte("2")
                    or modifier == string.byte("3")
                    or modifier == string.byte("4")
                    or modifier == string.byte("6")
                then
                    move = "other"
                else
                    continue
                end
                key = readByte()
                if not key then
                    return
                end
            end
            if key == string.byte("A") then
                if #history == 0 then
                    continue
                end
                if atLatest() then
                    draft = line
                end
                if position > 1 then
                    position -= 1
                end
                local entry = history[position]
                if entry then
                    recall(entry)
                end
            elseif key == string.byte("B") then
                if position <= #history then
                    position += 1
                end
                if atLatest() then
                    recall(draft or "")
                    draft = nil
                else
                    local entry = history[position]
                    if entry then
                        recall(entry)
                    end
                end
            elseif key == string.byte("C") then
                if move == "other" or cursor == #line then
                    continue
                end
                cursor = if move == "ctrl" then wordRight(cursor) else cursor + 1
                draw()
            elseif key == string.byte("D") then
                if move == "other" or cursor == 0 then
                    continue
                end
                cursor = if move == "ctrl" then wordLeft(cursor) else cursor - 1
                draw()
            end
        elseif byte == 10 or byte == 13 then
            out:writeAll("\n")
            local source = line
            remember(source)
            position = #history + 1
            draft = nil
            line = ""
            cursor = 0
            run(source)
            draw()
        elseif byte == 127 then
            if cursor == 0 then
                continue
            end
            line = `{line:sub(1, cursor - 1)}{line:sub(cursor + 1)}`
            cursor -= 1
            draw()
        elseif byte == 23 then
            local next_cursor = wordLeft(cursor)
            if next_cursor == cursor then
                continue
            end
            line = `{line:sub(1, next_cursor)}{line:sub(cursor + 1)}`
            cursor = next_cursor
            draw()
        elseif byte == 3 or byte == 4 then
            interrupt()
        elseif byte >= 22 and byte <= 31 then
            continue
        else
            if byte == 9 then
                byte = string.byte(" ")
            end
            local char = string.char(byte)
            line = `{line:sub(1, cursor)}{char}{line:sub(cursor + 1)}`
            cursor += 1
            draw()
        end
    end
end

local ok, err = pcall(loop)
finish()
if not ok then
    error(tostring(err), 0)
end
