--!strict
--!optimize 2

local mem = zune.mem

local Entry = {} :: EntryImpl
Entry.__index = Entry

type EntryImpl = {
    __index: EntryImpl,
    bytes: (self: Entry) -> buffer,
}

export type Entry = setmetatable<{
    path: string,
    kind: "file" | "dir",
    mode: number,
    size: number,
    src: buffer,
    at: number,
}, EntryImpl>

function Entry.bytes(self: Entry): buffer
    if self.size == 0 then
        return buffer.create(0)
    end
    return mem.slice(self.src, self.at, self.size)
end

return Entry
