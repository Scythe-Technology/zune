--!strict
--- @description Read bundled information from a bundled executable.

local mem = zune.mem
local process = zune.process

local io = require("@zune/io")
local fs = require("@zune/fs")
local ansi = require("@zune/ansi").auto()

local cwd = io.cwd()

local IMAGE_MAGIC = "[ZLBD01]"

local function fail(label: string, msg: string): never
    print(`{ansi.paint(ansi.red, label)}: {msg}`)
    return process.exit(1)
end

local path = process.args[2] or error("no path provided")

local stat = fs.statFile(cwd, path)
do
    if stat.kind == "none" then
        if (stat :: any) == "FileNotFound" then
            fail("error", `'{path}' was not found`)
            return
        end
        fail("error", tostring(stat))
        return
    end
    if stat.kind == "directory" then
        fail("error", `'{path}' is a directory`)
        return
    end
    if stat.kind ~= "file" then
        fail("error", `'{path}' is not a file`)
        return
    end
end

local file_bytes: number = stat.size

local opened, file = pcall(function()
    return cwd:openFile(path, { mode = "r" })
end)
if not opened then
    if (file :: any) == "FileNotFound" then
        fail("error", `'{path}' was not found`)
        return
    end
    if (file :: any) == "IsDir" then
        fail("error", `'{path}' is a directory`)
        return
    end
    fail("error", tostring(file))
    return
end

local reader = io.createReader(file, { positional = true })

local function giveUp(msg: string): never
    file:close()
    return fail("error", msg)
end

local function readAt(offset: number, count: number): buffer
    local buf = buffer.create(count)
    if count == 0 then
        return buf
    end
    reader.offset = offset
    local ok, err = pcall(function()
        reader:readAll(buf, 0, count)
    end)
    if not ok then
        if tostring(err) == "EOF" then
            return giveUp("corrupt bundle")
        end
        file:close()
        return fail("error", tostring(err))
    end
    return buf
end

type BundleImage = {
    sections: number,
    payload_size: number,
    payload_at: number,
}

local function locate(): BundleImage
    local scanned_n = 0
    local limit = file_bytes
    local enabled = 0
    local matched: { BundleImage } = {}
    local pos = 0
    while pos < limit do
        local n = math.min(1048576, file_bytes - pos)
        local buf = readAt(pos, n)
        local from = 0
        while from < n do
            local at = mem.findPos(buf, from, IMAGE_MAGIC)
            if at == nil then
                break
            end
            from = at + 1
            local abs = pos + at
            if abs + #IMAGE_MAGIC <= scanned_n or abs >= limit or abs + 32 > file_bytes then
                continue
            end
            local image = readAt(abs, 32)
            local flags = buffer.readu8(image, 12)
            local reserved_clear = buffer.readu8(image, 13) == 0
                and buffer.readu8(image, 14) == 0
                and buffer.readu8(image, 15) == 0
            if flags % 2 == 1 and reserved_clear then
                enabled += 1
                mem.reverse(image, 16, 8)
                mem.reverse(image, 24, 8)
                local payload_size = zune.mem.readu64(image, 16)
                local payload_at = zune.mem.readu64(image, 24)
                if
                    payload_at >= abs + 32
                    and payload_at <= file_bytes
                    and payload_size <= file_bytes
                    and payload_at + payload_size == file_bytes
                then
                    mem.reverse(image, 8, 4)
                    table.insert(matched, {
                        sections = buffer.readu32(image, 8),
                        payload_size = payload_size,
                        payload_at = payload_at,
                    })
                    if payload_at < limit then
                        limit = payload_at
                    end
                end
            end
        end
        scanned_n = pos + n
        if pos + n >= file_bytes then
            break
        end
        local next_pos = pos + n - #IMAGE_MAGIC - 1
        if next_pos <= pos then
            break
        end
        pos = next_pos
    end
    if #matched == 1 then
        return matched[1]
    end
    if #matched > 1 then
        return giveUp("executable has more than one bundle image")
    end
    if enabled > 0 then
        return giveUp("corrupt bundle")
    end
    return giveUp("executable has no bundle image")
end

local image = locate()
local payload_end = image.payload_at + image.payload_size
if image.payload_size < 11 or payload_end > file_bytes then
    giveUp("corrupt bundle")
    return
end

local prefix = readAt(image.payload_at, 11)
mem.reverse(prefix, 0, 5)

local release = buffer.readbits(prefix, 0, 1) == 1
local limbo = buffer.readbits(prefix, 1, 1) == 1
local debug_level = buffer.readbits(prefix, 2, 2)
local optimization = buffer.readbits(prefix, 4, 2)
local native = buffer.readbits(prefix, 6, 1) == 1
local jit = buffer.readbits(prefix, 7, 1) == 1
local format_on = buffer.readbits(prefix, 8, 1) == 1
local indent = buffer.readbits(prefix, 9, 2)

mem.reverse(prefix, 5, 4)
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
local disabled: { string } = {}
for index, name in feature_names do
    if buffer.readbits(prefix, (5 * 8) + index - 1, 1) == 0 then
        table.insert(disabled, name)
    end
end

mem.reverse(prefix, 9, 2)
local home_len = buffer.readu16(prefix, 9)

local pos = image.payload_at + 11
if pos + home_len > payload_end then
    giveUp("corrupt bundle")
    return
end
local home = if home_len == 0 then "" else buffer.tostring(readAt(pos, home_len))
pos += home_len

local minimum = image.sections * 8
if pos + minimum > payload_end then
    giveUp("corrupt bundle")
end

type DumpSection = {
    kind: number,
    compression: number,
    size: number,
    uncompressed: number?,
    name: string,
}

local sections: { DumpSection } = {}
local script_count = 0
local file_count = 0
for _ = 1, image.sections do
    if pos + 7 > payload_end then
        giveUp("corrupt bundle")
        return
    end
    local header = readAt(pos, 7)
    mem.reverse(header, 0, 7)
    pos += 7
    local kind = buffer.readbits(header, 0, 1)
    local compression = buffer.readbits(header, 1, 3)
    local name_size = buffer.readbits(header, 4, 15)
    local size = buffer.readbits(header, 19, 32) + buffer.readbits(header, 51, 5) * (2 ^ 32)
    if pos + name_size + 1 > payload_end then
        giveUp("corrupt bundle")
        return
    end
    local name = buffer.tostring(readAt(pos, name_size))
    pos += name_size
    if buffer.readu8(readAt(pos, 1), 0) ~= 0 then
        giveUp("corrupt bundle")
        return
    end
    pos += 1
    if pos + size > payload_end then
        giveUp("corrupt bundle")
        return
    end
    local uncompressed: number? = nil
    if compression ~= 0 then
        if size < 5 then
            giveUp("corrupt bundle")
            return
        end
        local stored = readAt(pos, 5)
        mem.reverse(stored, 0, 5)
        uncompressed = buffer.readu8(stored, 0) * (2 ^ 32) + buffer.readu32(stored, 1)
    end
    pos += size
    if kind == 0 then
        script_count += 1
    elseif kind == 1 then
        file_count += 1
    end
    table.insert(sections, {
        kind = kind,
        compression = compression,
        size = size,
        uncompressed = uncompressed,
        name = name,
    })
end
if pos ~= payload_end then
    giveUp("corrupt bundle")
    return
end
file:close()

local function kindName(kind: number): string
    if kind == 0 then
        return "script"
    end
    if kind == 1 then
        return "file"
    end
    return "other"
end

local compression_names = { "none", "zlib", "lz4", "zstd", "gzip", "flate" }

local function pad(text: string, width: number): string
    if #text >= width then
        return text
    end
    return text .. string.rep(" ", width - #text)
end

print(`path: {path}`)
print(`size: {file_bytes}`)
print(`exe: {image.payload_at}`)
print(`payload: {image.payload_size}`)
print(`config:`)
print(`  mode: {if release then "release" else "debug"}`)
print(`  limbo: {tostring(limbo)}`)
print(`  debug_level: {debug_level}`)
print(`  optimization_level: {optimization}`)
print(`  native: {tostring(native)}`)
print(`  jit: {tostring(jit)}`)
print(`  format: {tostring(format_on)}`)
print(`  indent: {indent}`)
if #disabled > 0 then
    print(`  disabled: {table.concat(disabled, ",")}`)
end
if #sections > 0 then
    print(`entry: {sections[1].name}`)
end
print(`home: {home}`)
print()
print(`sections: {image.sections} ({script_count} <scripts> + {file_count} <files>)`)
print(`> {pad("kind", 6)}  {pad("compression", 11)}  {pad("bytes", 12)}  name`)
for _, section in sections do
    local bytes = tostring(section.size)
    local plain = section.uncompressed
    if plain ~= nil then
        bytes = `{bytes} ({plain} uncompressed)`
    end
    print(
        `  {pad(kindName(section.kind), 6)}  {pad(compression_names[section.compression + 1] or "unknown", 11)}  {pad(
            bytes,
            12
        )}  {section.name}`
    )
end
