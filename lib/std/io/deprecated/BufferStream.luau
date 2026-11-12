--!strict
--!native
--!optimize 2

local Io = require("./Io")

local BufferStream = {}
BufferStream.__index = BufferStream

function BufferStream.create(buf: buffer)
    local len = buffer.len(buf)
    return setmetatable({
        len = len,
        buffer = buf,
        offset = 0,
    }, BufferStream)
end

export type BufferStream = typeof(BufferStream.create(buffer.create(0)))

function BufferStream.reader(self: BufferStream): Io.Readable
    return self :: any
end

function BufferStream.writer(self: BufferStream): Io.Writable
    return self :: any
end

function BufferStream.pos(self: BufferStream): number
    return self.offset
end

function BufferStream.size(self: BufferStream): number
    return self.len
end

function BufferStream.seekTo(self: BufferStream, pos: number)
    self.offset = pos
end

function BufferStream.seekBy(self: BufferStream, pos: number)
    self.offset = math.clamp((self.offset + pos) // 1, 0, self.len)
end

function BufferStream.inBounds(self: BufferStream, size: number)
    return self.offset + size <= self.len
end

BufferStream.canRead = BufferStream.inBounds

function BufferStream.read(self: BufferStream, amount: number?, bytes: boolean?): (string | buffer)?
    local len = amount or self.len - self.offset
    if amount and amount <= 0 then
        return if bytes == false then "" else buffer.create(0)
    end
    if bytes == false then
        local value = buffer.readstring(self.buffer, self.offset, len)
        self.offset += len
        return value
    else
        local copy = buffer.create(len)
        buffer.copy(copy, 0, self.buffer, self.offset, len)
        self.offset += len
        return copy
    end
end

function BufferStream.readi8(self: BufferStream): number
    if not self:inBounds(1) then
        error("EOF", 0)
    end
    local value = buffer.readi8(self.buffer, self.offset)
    self.offset += 1
    return value
end

function BufferStream.readu8(self: BufferStream): number
    if not self:inBounds(1) then
        error("EOF", 0)
    end
    local value = buffer.readu8(self.buffer, self.offset)
    self.offset += 1
    return value
end

function BufferStream.readi16(self: BufferStream): number
    if not self:inBounds(2) then
        error("EOF", 0)
    end
    local value = buffer.readi16(self.buffer, self.offset)
    self.offset += 2
    return value
end

function BufferStream.readu16(self: BufferStream): number
    if not self:inBounds(2) then
        error("EOF", 0)
    end
    local value = buffer.readu16(self.buffer, self.offset)
    self.offset += 2
    return value
end

function BufferStream.readi32(self: BufferStream): number
    if not self:inBounds(4) then
        error("EOF", 0)
    end
    local value = buffer.readi32(self.buffer, self.offset)
    self.offset += 4
    return value
end

function BufferStream.readu32(self: BufferStream): number
    if not self:inBounds(4) then
        error("EOF", 0)
    end
    local value = buffer.readu32(self.buffer, self.offset)
    self.offset += 4
    return value
end

function BufferStream.readf32(self: BufferStream): number
    if not self:inBounds(4) then
        error("EOF", 0)
    end
    local value = buffer.readf32(self.buffer, self.offset)
    self.offset += 4
    return value
end

function BufferStream.readf64(self: BufferStream): number
    if not self:inBounds(8) then
        error("EOF", 0)
    end
    local value = buffer.readf64(self.buffer, self.offset)
    self.offset += 8
    return value
end

function BufferStream.write(self: BufferStream, value: string | buffer)
    if type(value) == "string" then
        if not self:inBounds(#value) then
            error("out of bounds", 0)
        end
        buffer.writestring(self.buffer, self.offset, value)
        self.offset += #value
        return
    else
        if not self:inBounds(buffer.len(value)) then
            error("out of bounds", 0)
        end
        buffer.copy(self.buffer, self.offset, value)
        self.offset += buffer.len(value)
        return
    end
end

function BufferStream.writei8(self: BufferStream, value: number)
    if not self:inBounds(1) then
        error("out of bounds", 0)
    end
    buffer.writei8(self.buffer, self.offset, value)
    self.offset += 1
end

function BufferStream.writeu8(self: BufferStream, value: number)
    if not self:inBounds(1) then
        error("out of bounds", 0)
    end
    buffer.writeu8(self.buffer, self.offset, value)
    self.offset += 1
end

function BufferStream.writei16(self: BufferStream, value: number)
    if not self:inBounds(2) then
        error("out of bounds", 0)
    end
    buffer.writei16(self.buffer, self.offset, value)
    self.offset += 2
end

function BufferStream.writeu16(self: BufferStream, value: number)
    if not self:inBounds(2) then
        error("out of bounds", 0)
    end
    buffer.writeu16(self.buffer, self.offset, value)
    self.offset += 2
end

function BufferStream.writei32(self: BufferStream, value: number)
    if not self:inBounds(4) then
        error("out of bounds", 0)
    end
    buffer.writei32(self.buffer, self.offset, value)
    self.offset += 4
end

function BufferStream.writeu32(self: BufferStream, value: number)
    if not self:inBounds(4) then
        error("out of bounds", 0)
    end
    buffer.writeu32(self.buffer, self.offset, value)
    self.offset += 4
end

function BufferStream.writef32(self: BufferStream, value: number)
    if not self:inBounds(4) then
        error("out of bounds", 0)
    end
    buffer.writef32(self.buffer, self.offset, value)
    self.offset += 4
end

function BufferStream.writef64(self: BufferStream, value: number)
    if not self:inBounds(8) then
        error("out of bounds", 0)
    end
    buffer.writef64(self.buffer, self.offset, value)
    self.offset += 8
end

return BufferStream
