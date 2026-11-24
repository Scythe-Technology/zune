--!strict
--!optimize 2

local mem = zune.mem

local Entry = require("@self/Entry")
local Iterator = require("@self/Iterator")

export type Entry = Entry.Entry
export type Iterator = Iterator.Iterator

export type File = {
    path: string,
    mode: number,
    data: buffer,
    kind: ("file" | "dir")?,
}

local tar = {}

local function putOctal(dest: buffer, at: number, value: number, width: number)
    local digits = width - 1
    local text = string.format(`%0{digits}o`, value)
    if #text > digits then
        error("tar field too wide", 0)
    end
    buffer.writestring(dest, at, text)
end

local function split(path: string): (string?, string?)
    if #path <= 100 then
        return path, ""
    end
    local chosen: number? = nil
    local i = 0
    local len = #path
    while i < len do
        local slash = mem.findPos(path, i, "/", len - i)
        if not slash then
            break
        end
        local name_len = len - (slash + 1)
        if slash <= 155 and name_len <= 100 and name_len > 0 then
            chosen = slash
        end
        i = slash + 1
    end
    if not chosen then
        return nil, nil
    end
    return string.sub(path, chosen + 2), string.sub(path, 1, chosen)
end

local function paxRecord(key: string, value: string): string
    local body = `{key}={value}\n`
    for digits = 1, 20 do
        local total = digits + 1 + #body
        if #tostring(total) == digits then
            return `{total} {body}`
        end
    end
    error("pax record too large")
end

type TypeFlag = "0" | "5" | "x"

local function headerFor(path: string, size: number, mode: number, typeflag: TypeFlag): buffer
    local header = buffer.create(512)
    local name, prefix = split(path)
    name = name or string.sub(path, math.max(#path - 99, 1))
    prefix = prefix or ""
    mem.copy(header, 0, name, 0, math.min(#name, 100))
    putOctal(header, 100, mode, 8)
    putOctal(header, 108, 0, 8)
    putOctal(header, 116, 0, 8)
    putOctal(header, 124, size, 12)
    putOctal(header, 136, 0, 12)
    buffer.writeu8(header, 156, string.byte(typeflag) :: number)
    mem.copy(header, 257, "ustar", 0, 5)
    buffer.writeu8(header, 262, 0)
    mem.copy(header, 263, "00", 0, 2)
    mem.copy(header, 345, prefix, 0, math.min(#prefix, 155))
    buffer.writestring(header, 148, "        ") -- checksum space
    local sum = 0
    for i = 0, 511 do
        sum += buffer.readu8(header, i)
    end
    local check = string.format("%06o", sum)
    buffer.writestring(header, 148, check)
    buffer.writeu8(header, 154, 0)
    buffer.writeu8(header, 155, 32)
    return header
end

function tar.iterate(src: buffer): Iterator.Iterator
    return Iterator.create(src)
end

function tar.spans(read: Iterator.Read, size: number): { Iterator.Span }
    return Iterator.spans(read, size)
end

function tar.write(files: { File }): buffer
    table.sort(files, function(left: File, right: File)
        return left.path < right.path
    end)
    local blocks: { buffer } = {}
    local total = 0
    local function add(block: buffer)
        table.insert(blocks, block)
        total += buffer.len(block)
    end
    for _, file in files do
        if not split(file.path) then
            local record = paxRecord("path", file.path)
            add(headerFor(file.path, #record, 420, "x"))
            add(buffer.fromstring(record))
            local padding = (512 - (#record % 512)) % 512
            if padding > 0 then
                add(buffer.create(padding))
            end
        end
        local directory = file.kind == "dir"
        local size = if directory then 0 else buffer.len(file.data)
        add(headerFor(file.path, size, file.mode, if directory then "5" else "0"))
        if not directory and buffer.len(file.data) > 0 then
            add(file.data)
        end
        local padding = (512 - (size % 512)) % 512
        if padding > 0 then
            add(buffer.create(padding))
        end
    end
    add(buffer.create(1024))
    local out = buffer.create(total)
    local at = 0
    for _, block in blocks do
        buffer.copy(out, at, block, 0, buffer.len(block))
        at += buffer.len(block)
    end
    return out
end

return tar
