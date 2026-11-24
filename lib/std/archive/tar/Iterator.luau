--!strict
--!optimize 2

local mem = zune.mem

local spec = require("@zune/spec")

local Entry = require("./Entry")

local Iterator = {} :: IteratorImpl
Iterator.__index = Iterator

type IteratorImpl = {
    __index: IteratorImpl,
    create: (src: buffer) -> Iterator,
    spans: (read: Read, limit: number) -> { Span },
    next: (self: Iterator) -> Entry.Entry?,
}

export type Iterator = setmetatable<{
    entries: { Entry.Entry },
    index: number,
}, IteratorImpl>

function Iterator.next(self: Iterator): Entry.Entry?
    local entry = self.entries[self.index]
    if not entry then
        return nil
    end
    self.index += 1
    return entry
end

local function headerName(header: buffer): string
    local name_end = mem.findScalarPos(header, 0, 0, 100)
    local name = buffer.readstring(header, 0, if name_end then name_end else 100)
    if mem.eqlSlice(header, 257, "ustar", 0, 5) then
        local prefix_end = mem.findScalarPos(header, 345, 0, 155)
        if prefix_end ~= 345 then
            local prefix = buffer.readstring(header, 345, if prefix_end then prefix_end - 345 else 155)
            return `{prefix}/{name}`
        end
    end
    return name
end

local function parsePax(body: buffer): { [string]: string }
    local values: { [string]: string } = {}
    local at = 0
    local len = buffer.len(body)
    while at < len do
        local space = mem.findPos(body, at, " ", len - at)
        if not space then
            break
        end
        local length = if space > at then tonumber(buffer.readstring(body, at, space - at)) else nil
        if not length or at + length > len then
            break
        end
        local record_at = space + 1
        local record_end = at + length
        if record_end < record_at then
            break
        end
        local eq = mem.findPos(body, record_at, "=", record_end - record_at)
        if eq then
            local key = if eq > record_at then buffer.readstring(body, record_at, eq - record_at) else ""
            local value_at = eq + 1
            if record_end > value_at and mem.eqlSlice(body, record_end - 1, "\n", 0, 1) then
                record_end -= 1
            end
            local value = if record_end > value_at then buffer.readstring(body, value_at, record_end - value_at) else ""
            values[key] = value
        end
        at += length
    end
    return values
end

local function octalField(text: string): number
    local trimmed = buffer.tostring(mem.trim(text, "\0 "))
    if trimmed == "" then
        return 0
    end
    local value = tonumber(trimmed, 8)
    if not value then
        error("bad tar number", 0)
    end
    return value
end

export type Read = (offset: number, dest: buffer, count: number) -> ()

export type Span = {
    path: string,
    kind: "file" | "dir",
    mode: number,
    size: number,
    at: number,
}

local META_MAX = 8388608

local function spans(read: Read, limit: number): { Span }
    local entries: { Span } = {}
    local at = 0
    local long_name: string? = nil
    local pax_path: string? = nil
    while at + 512 <= limit do
        local header = buffer.create(512)
        read(at, header, 512)
        at += 512
        if mem.findNone(header, "\0") == nil then
            break
        end
        local size = octalField(buffer.readstring(header, 124, 12))
        local typeflag = buffer.readu8(header, 156)
        local name = headerName(header)
        if long_name then
            name = long_name
            long_name = nil
        end
        if pax_path and typeflag ~= 120 and typeflag ~= 103 then -- 'x', 'g'
            name = pax_path
            pax_path = nil
        end
        local step = size + ((512 - (size % 512)) % 512)
        if at + step > limit then
            error("truncated tar", 0)
        end
        local meta = typeflag == 76 or typeflag == 120 or typeflag == 103 -- 'L', 'x', 'g'
        if meta and size > META_MAX then
            error("tar header too large", 0)
        end
        local body: buffer? = nil
        if meta and size > 0 then
            body = buffer.create(size)
            read(at, body, size)
        end
        if typeflag == 76 then -- 'L'
            local nul = if body then mem.findScalarPos(body, 0, 0, size) else nil -- '\0'
            if nul and nul > 0 then
                long_name = buffer.readstring(body :: buffer, 0, nul)
            elseif nul or not body then
                long_name = ""
            else
                long_name = buffer.readstring(body :: buffer, 0, size)
            end
        elseif typeflag == 120 or typeflag == 103 then -- 'x', 'g'
            local values = parsePax(body or buffer.create(0))
            local path = values.path
            if typeflag == 120 and spec.string(path) then -- 'x'
                pax_path = path
            end
        elseif typeflag == 48 or typeflag == 0 or typeflag == 53 then -- '0', '\0', '5'
            local kind = "file"
            if typeflag == 53 then -- '5'
                kind = "dir"
            end
            local span: Span = {
                path = name,
                kind = kind,
                mode = octalField(buffer.readstring(header, 100, 8)),
                size = size,
                at = at,
            }
            table.insert(entries, span)
        end
        at += step
    end
    return entries
end

function Iterator.spans(read: Read, limit: number): { Span }
    return spans(read, limit)
end

function Iterator.create(src: buffer): Iterator
    local entries: { Entry.Entry } = {}
    local list = spans(function(offset: number, dest: buffer, count: number)
        buffer.copy(dest, 0, src, offset, count)
    end, buffer.len(src))
    for _, span in list do
        table.insert(
            entries,
            setmetatable({
                path = span.path,
                kind = span.kind,
                mode = span.mode,
                size = span.size,
                src = src,
                at = span.at,
            }, Entry) :: Entry.Entry
        )
    end
    return setmetatable({
        entries = entries,
        index = 1,
    }, Iterator)
end

return Iterator
