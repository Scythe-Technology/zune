--!strict
--!optimize 2

local Writer = require("./Writer")

local mem = zune.mem

local Reader = {} :: ReaderImpl
Reader.__index = Reader

type ReaderImpl = {
    __index: ReaderImpl,
    read: (self: Reader, dest: buffer, dest_offset: number?, count: number?) -> (number, string?),
    readRemaining: (self: Reader, dest: buffer, dest_offset: number?, count: number?) -> (boolean, string?),
    readAll: (self: Reader, dest: buffer, dest_offset: number?, count: number?) -> (),
    readRemainingAlloc: (self: Reader, limit: number?) -> buffer,
    readu8: (self: Reader) -> number,
    readi8: (self: Reader) -> number,
    readu16: (self: Reader) -> number,
    readi16: (self: Reader) -> number,
    readu32: (self: Reader) -> number,
    readi32: (self: Reader) -> number,
    readf32: (self: Reader) -> number,
    readf64: (self: Reader) -> number,
    pipe: (self: Reader, writer: Writer.Writer, limit: number?) -> (number, string?),
}
export type Reader = setmetatable<{
    ud: any,
    offset: number?,
    read_impl: (self: any, offset: number, dest: buffer, dest_offset: number?, count: number?) -> (number, string?),
}, ReaderImpl>

function Reader.read(self: Reader, dest: buffer, dest_offset: number?, count: number?): (number, string?)
    local n, err = self.read_impl(self.ud, self.offset or 0, dest, dest_offset, count)
    if self.offset then
        self.offset += n
    end
    return n, err
end

function Reader.readRemaining(self: Reader, dest: buffer, dest_offset: number?, count: number?)
    local n = 0
    local off = dest_offset or 0
    local total = count or buffer.len(dest) - off
    while n < total do
        local amt, err = self:read(dest, off + n, total - n)
        if amt == 0 then
            return false, err
        end
        n += amt
    end
    return true, nil
end

function Reader.readAll(self: Reader, dest: buffer, dest_offset: number?, count: number?)
    local done, err = self:readRemaining(dest, dest_offset, count)
    if not done then
        error(err or "EOF", 0)
    end
end

local function grow(current: number, minimum: number): number
    local new = math.max(current, 4)
    while true do
        new += (new / 2) // 1
        if new >= minimum then
            return new
        end
    end
end

function Reader.readRemainingAlloc(self: Reader, limit: number?): buffer
    if limit ~= nil and (limit <= 0 or limit > mem.MAX_SIZE) then
        error("invalid limit", 2)
    end
    local lim = limit or mem.MAX_SIZE
    local written = 0
    local capacity = math.min(1024, lim)
    local buf = buffer.create(capacity)
    while true do
        local bytes, err = self:read(buf, written)
        if bytes == 0 or written == lim then
            if err then
                error(err, 0)
            end
            break
        end
        written += bytes
        if capacity < lim then
            local predicted_size = grow(capacity, written + 1)
            if predicted_size > capacity then
                predicted_size = math.min(predicted_size, lim)
                local new_buf = buffer.create(predicted_size)
                buffer.copy(new_buf, 0, buf, 0, written)
                buf, capacity = new_buf, predicted_size
            end
        end
    end
    if capacity > written then
        local new_buf = buffer.create(written)
        buffer.copy(new_buf, 0, buf, 0, written)
        buf = new_buf
    end
    return buf
end

function Reader.readu8(self: Reader)
    local b = buffer.create(1)
    self:readAll(b, 0, 1)
    return buffer.readu8(b, 0)
end

function Reader.readi8(self: Reader)
    local b = buffer.create(1)
    self:readAll(b, 0, 1)
    return buffer.readi8(b, 0)
end

function Reader.readu16(self: Reader)
    local b = buffer.create(2)
    self:readAll(b, 0, 2)
    return buffer.readu16(b, 0)
end

function Reader.readi16(self: Reader)
    local b = buffer.create(2)
    self:readAll(b, 0, 2)
    return buffer.readi16(b, 0)
end

function Reader.readu32(self: Reader)
    local b = buffer.create(4)
    self:readAll(b, 0, 4)
    return buffer.readu32(b, 0)
end

function Reader.readi32(self: Reader)
    local b = buffer.create(4)
    self:readAll(b, 0, 4)
    return buffer.readi32(b, 0)
end

function Reader.readf32(self: Reader)
    local b = buffer.create(4)
    self:readAll(b, 0, 4)
    return buffer.readf32(b, 0)
end

function Reader.readf64(self: Reader)
    local b = buffer.create(8)
    self:readAll(b, 0, 8)
    return buffer.readf64(b, 0)
end

function Reader.pipe(self: Reader, writer: Writer.Writer, limit: number?): (number, string?)
    local moved = 0
    local cap = math.min(65536, limit or 65536)
    local buf = buffer.create(cap)
    while limit == nil or moved < limit do
        local want = if limit then math.min(cap, limit - moved) else cap
        local bytes, err = self:read(buf, 0, want)
        if err then
            return moved, err
        end
        if bytes == 0 then
            break
        end
        writer:writeAll(buf, 0, bytes)
        moved += bytes
    end
    return moved, nil
end

return Reader
