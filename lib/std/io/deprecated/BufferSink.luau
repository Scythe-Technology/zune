--!strict
--!native
--!optimize 2

local Io = require("./Io")

local BufferSink = {}
BufferSink.__index = BufferSink

function BufferSink.create(limit: number, size: number?)
    return setmetatable({
        len = 0,
        buffer = buffer.create(size or 0),
        position = 0,
        capacity = size or 0,
        closed = false,
        limit = math.min(limit, 1073741824),
    }, BufferSink)
end

export type BufferSink = typeof(BufferSink.create(0))

local function grow(current: number, minimum: number): number
    local new = math.max(current, 4)
    while true do
        new += (new / 2) // 1
        if new >= minimum then
            return new
        end
    end
end

function BufferSink.close(self: BufferSink)
    self.closed = true
end

function BufferSink.writer(self: BufferSink): Io.Writable
    return self :: any
end

function BufferSink.expandToSizePrecise(self: BufferSink, new_size: number)
    if new_size <= self.capacity then
        return
    end

    local current_size = self.capacity
    self.capacity = new_size

    local current = self.buffer
    self.buffer = buffer.create(new_size)
    buffer.copy(self.buffer, 0, current, 0, current_size)
end

function BufferSink.expandToSize(self: BufferSink, new_size: number)
    self.len = new_size
    if new_size <= self.capacity then
        return
    end
    if new_size > self.limit then
        error("limit exceeded", 0)
    end
    local predicted_size = grow(self.capacity, new_size)
    self:expandToSizePrecise(math.min(predicted_size, self.limit))
end

function BufferSink.flush(self: BufferSink, bytes: boolean?): string | buffer
    if self.closed then
        error("Closed", 0)
    end
    local final = buffer.create(self.position)
    buffer.copy(final, 0, self.buffer, 0, self.position)
    self.capacity = self.len
    self.position = 0
    self.len = 0
    if bytes == false then
        return buffer.tostring(final)
    end
    return final
end

function BufferSink.write(self: BufferSink, value: string | buffer)
    if self.closed then
        error("Closed", 0)
    end
    if type(value) == "string" then
        local amt = #value
        self:expandToSize(self.position + amt)
        buffer.writestring(self.buffer, self.position, value)
        self.position += amt
        return
    else
        local amt = buffer.len(value)
        self:expandToSize(self.position + amt)
        buffer.copy(self.buffer, self.position, value)
        self.position += amt
        return
    end
end

function BufferSink.writei8(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 1)
    buffer.writei8(self.buffer, self.position, value)
    self.position += 1
end

function BufferSink.writeu8(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 1)
    buffer.writeu8(self.buffer, self.position, value)
    self.position += 1
end

function BufferSink.writei16(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 2)
    buffer.writei16(self.buffer, self.position, value)
    self.position += 2
end

function BufferSink.writeu16(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 2)
    buffer.writeu16(self.buffer, self.position, value)
    self.position += 2
end

function BufferSink.writei32(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 4)
    buffer.writei32(self.buffer, self.position, value)
    self.position += 4
end

function BufferSink.writeu32(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 4)
    buffer.writeu32(self.buffer, self.position, value)
    self.position += 4
end

function BufferSink.writef32(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 4)
    buffer.writef32(self.buffer, self.position, value)
    self.position += 4
end

function BufferSink.writef64(self: BufferSink, value: number)
    if self.closed then
        error("Closed", 0)
    end
    self:expandToSize(self.position + 8)
    buffer.writef64(self.buffer, self.position, value)
    self.position += 8
end

function BufferSink.writestring(self: BufferSink, value: string, count: number?)
    if self.closed then
        error("Closed", 0)
    end
    count = count or #value
    assert(type(count) == "number", "Invalid count")
    self:expandToSize(self.position + count + 4)
    buffer.writeu32(self.buffer, self.position, count)
    self.position += 4
    buffer.writestring(self.buffer, self.position, value, count)
    self.position += count
end

return BufferSink
