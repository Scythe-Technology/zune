--!strict
--!optimize 2

local mem = zune.mem

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

export type Read = (offset: number, dest: buffer, count: number) -> ()

export type Span = {
    path: string,
    kind: "file" | "dir",
    mode: number,
    size: number,
    method: number,
    count: number,
    at: number,
}

function Iterator.next(self: Iterator): Entry.Entry?
    local entry = self.entries[self.index]
    if not entry then
        return nil
    end
    self.index += 1
    return entry
end

local function zip64(extra: buffer, uncompressed: number, compressed: number, offset: number): (number, number, number)
    local at = 0
    while at + 4 <= buffer.len(extra) do
        local id = buffer.readu16(extra, at)
        local len = buffer.readu16(extra, at + 2)
        at += 4
        if at + len > buffer.len(extra) then
            break
        end
        if id == 1 then
            local cursor = at
            if uncompressed == 0xFFFFFFFF and cursor + 8 <= at + len then
                uncompressed = mem.readu64(extra, cursor)
                cursor += 8
            end
            if compressed == 0xFFFFFFFF and cursor + 8 <= at + len then
                compressed = mem.readu64(extra, cursor)
                cursor += 8
            end
            if offset == 0xFFFFFFFF and cursor + 8 <= at + len then
                offset = mem.readu64(extra, cursor)
            end
            return uncompressed, compressed, offset
        end
        at += len
    end
    return uncompressed, compressed, offset
end

local function load(read: Read, offset: number, count: number): buffer
    local buf = buffer.create(count)
    if count > 0 then
        read(offset, buf, count)
    end
    return buf
end

local function spans(read: Read, limit: number): { Span }
    if limit < 22 then
        error("zip directory missing", 0)
    end
    local tail = math.min(limit, 22 + 65535)
    local window = load(read, limit - tail, tail)
    local rel = mem.findLast(window, "PK\x05\x06")
    if not rel or rel + 22 > tail then
        error("zip directory missing", 0)
    end
    local eocd_offset = limit - tail + rel
    local count = buffer.readu16(window, rel + 10)
    local cd_size = buffer.readu32(window, rel + 12)
    local cd_offset = buffer.readu32(window, rel + 16)
    if count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF then
        if eocd_offset < 20 then
            error("zip64 locator required", 0)
        end
        local loc = load(read, eocd_offset - 20, 20)
        if buffer.readu32(loc, 0) ~= 0x07064b50 then
            error("zip64 locator required", 0)
        end
        local z64_offset = mem.readu64(loc, 8)
        if z64_offset + 56 > limit then
            error("bad zip64", 0)
        end
        local z64 = load(read, z64_offset, 56)
        if buffer.readu32(z64, 0) ~= 0x06064b50 then
            error("bad zip64", 0)
        end
        count = mem.readu64(z64, 32)
        cd_size = mem.readu64(z64, 40)
        cd_offset = mem.readu64(z64, 48)
    end
    local cd_end = cd_offset + cd_size
    if cd_end > limit or (count > 0 and cd_size / 46 < count) then
        error("bad zip directory", 0)
    end
    local entries: { Span } = {}
    local at = cd_offset
    for _ = 1, count do
        if at + 46 > cd_end then
            error("bad zip directory", 0)
        end
        local hdr = load(read, at, 46)
        if buffer.readu32(hdr, 0) ~= 0x02014b50 then
            error("bad zip directory", 0)
        end
        local flags = buffer.readu16(hdr, 8)
        local method = buffer.readu16(hdr, 10)
        local compressed = buffer.readu32(hdr, 20)
        local uncompressed = buffer.readu32(hdr, 24)
        local name_len = buffer.readu16(hdr, 28)
        local extra_len = buffer.readu16(hdr, 30)
        local comment_len = buffer.readu16(hdr, 32)
        local local_at = buffer.readu32(hdr, 42)
        local step = 46 + name_len + extra_len + comment_len
        if at + step > cd_end then
            error("bad zip directory", 0)
        end
        local name = ""
        if name_len > 0 then
            name = buffer.readstring(load(read, at + 46, name_len), 0, name_len)
        end
        if uncompressed == 0xFFFFFFFF or compressed == 0xFFFFFFFF or local_at == 0xFFFFFFFF then
            local extra = if extra_len > 0 then load(read, at + 46 + name_len, extra_len) else buffer.create(0)
            uncompressed, compressed, local_at = zip64(extra, uncompressed, compressed, local_at)
            if uncompressed == 0xFFFFFFFF or compressed == 0xFFFFFFFF or local_at == 0xFFFFFFFF then
                error("bad zip directory", 0)
            end
        end
        at += step
        local kind: "file" | "dir" = "file"
        if #name > 0 then
            local mark = string.byte(name, #name)
            if mark == 47 or mark == 92 then -- '/', '\\'
                kind = "dir"
            end
        end
        local data_at = 0
        if kind == "dir" then
            uncompressed = 0
            compressed = 0
        else
            if bit32.band(flags, 1) ~= 0 then
                error("encrypted zip", 0)
            end
            if local_at + 30 > limit then
                error("bad zip header", 0)
            end
            local local_hdr = load(read, local_at, 30)
            if buffer.readu32(local_hdr, 0) ~= 0x04034b50 then -- zip signature
                error("bad zip header", 0)
            end
            local nlen = buffer.readu16(local_hdr, 26)
            local elen = buffer.readu16(local_hdr, 28)
            data_at = local_at + 30 + nlen + elen
            if data_at > limit or data_at + compressed > limit then
                error("truncated zip", 0)
            end
        end
        local span: Span = {
            path = name,
            kind = kind,
            mode = if kind == "dir" then 493 else 420,
            size = uncompressed,
            method = method,
            count = compressed,
            at = data_at,
        }
        table.insert(entries, span)
    end
    return entries
end

function Iterator.spans(read: Read, limit: number): { Span }
    return spans(read, limit)
end

function Iterator.create(src: buffer): Iterator
    local list = spans(function(offset: number, dest: buffer, count: number)
        if count == 0 then
            return
        end
        buffer.copy(dest, 0, src, offset, count)
    end, buffer.len(src))
    local entries: { Entry.Entry } = {}
    for _, span in list do
        table.insert(
            entries,
            setmetatable({
                path = span.path,
                kind = span.kind,
                mode = span.mode,
                size = span.size,
                method = span.method,
                src = src,
                local_at = 0,
                count = span.count,
                at = span.at,
                ready = true,
            }, Entry)
        )
    end
    return setmetatable({
        entries = entries,
        index = 1,
    }, Iterator)
end

return Iterator
