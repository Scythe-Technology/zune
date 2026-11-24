--!strict
--!optimize 2

local mem = zune.mem

local Iterator = {} :: IteratorImpl
Iterator.__index = Iterator

type PktKind = "flush" | "delim" | "data"

export type Item = {
    kind: PktKind,
    data: buffer?,
}

type IteratorImpl = {
    __index: IteratorImpl,
    create: (src: buffer) -> Iterator,
    next: (self: Iterator) -> Item?,
}

export type Iterator = setmetatable<{
    src: buffer,
    at: number,
}, IteratorImpl>

local function read(src: buffer, offset: number): (PktKind, number, buffer?)
    if offset + 4 > buffer.len(src) then
        error("truncated pkt", 0)
    end
    local len = tonumber(buffer.readstring(src, offset, 4), 16)
    if not len then
        error("bad pkt", 0)
    end
    if len <= 1 then
        return if len == 0 then "flush" else "delim", offset + 4, nil
    end
    if len < 4 or offset + len > buffer.len(src) then
        error("truncated pkt", 0)
    end
    return "data", offset + len, mem.slice(src, offset + 4, len - 4)
end

function Iterator.next(self: Iterator): Item?
    if self.at >= buffer.len(self.src) then
        return nil
    end
    local kind, offset, data = read(self.src, self.at)
    self.at = offset
    return {
        kind = kind,
        data = data,
    }
end

function Iterator.create(src: buffer): Iterator
    return setmetatable({
        src = src,
        at = 0,
    }, Iterator)
end

return Iterator
