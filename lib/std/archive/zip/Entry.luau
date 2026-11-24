--!strict
--!optimize 2

local mem = zune.mem
local serde = zune.serde

local Entry = {} :: EntryImpl
Entry.__index = Entry

type EntryImpl = {
    __index: EntryImpl,
    locate: (self: Entry) -> (),
    bytes: (self: Entry) -> buffer,
}

export type Entry = setmetatable<{
    path: string,
    kind: "file" | "dir",
    mode: number,
    size: number,
    method: number,
    src: buffer,
    local_at: number,
    count: number,
    at: number,
    ready: boolean,
}, EntryImpl>

function Entry.locate(self: Entry)
    if self.ready then
        return
    end
    if self.kind == "dir" then
        self.ready = true
        return
    end
    if self.local_at + 30 > buffer.len(self.src) or buffer.readu32(self.src, self.local_at) ~= 0x04034b50 then
        error("bad zip header", 0)
    end
    self.at = self.local_at
        + 30
        + buffer.readu16(self.src, self.local_at + 26)
        + buffer.readu16(self.src, self.local_at + 28)
    self.ready = true
end

function Entry.bytes(self: Entry): buffer
    if self.kind == "dir" then
        return buffer.create(0)
    end
    self:locate()
    if self.method == 0 then
        if self.count == 0 then
            return buffer.create(0)
        end
        return mem.slice(self.src, self.at, self.count)
    end
    if self.method ~= 8 then
        error("unsupported zip method", 0)
    end
    local dest = buffer.create(self.size)
    if serde.flate.decompress(dest, 0, self.src, self.at, self.count) ~= self.size then
        error("zip size mismatch", 0)
    end
    return dest
end

return Entry
