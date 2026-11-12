--!strict
--!optimize 2

local Writer = {} :: WriterImpl
Writer.__index = Writer

type WriterImpl = {
    __index: WriterImpl,
    write: (self: Writer, src: buffer | string, src_offset: number?, count: number?) -> (number, string?),
    writeAll: (self: Writer, src: buffer | string, offset: number?, count: number?) -> string?,
    writeu8: (self: Writer, value: number) -> (),
    writei8: (self: Writer, value: number) -> (),
    writeu16: (self: Writer, value: number) -> (),
    writei16: (self: Writer, value: number) -> (),
    writeu32: (self: Writer, value: number) -> (),
    writei32: (self: Writer, value: number) -> (),
    writef32: (self: Writer, value: number) -> (),
    writef64: (self: Writer, value: number) -> (),
}
export type Writer = setmetatable<
    {
        ud: any,
        offset: number?,
        write_impl: (
            self: any,
            offset: number,
            src: buffer | string,
            src_offset: number?,
            count: number?
        ) -> (number, string?),
    },
    WriterImpl
>

function Writer.write(self: Writer, src: buffer | string, offset: number?, count: number?)
    local n, err = self.write_impl(self.ud, self.offset or 0, src, offset, count)
    if self.offset then
        self.offset += n
    end
    return n, err
end

function Writer.writeAll(self: Writer, src: buffer | string, src_offset: number?, count: number?)
    local n = 0
    local offset = src_offset or 0
    local total = count or (if type(src) == "string" then #src else buffer.len(src)) - offset
    while n < total do
        local written, err = self:write(src, offset + n, total - n)
        if err then
            return err
        end
        n += written
    end
    return nil
end

function Writer.writeu8(self: Writer, value: number)
    local b = buffer.create(1)
    buffer.writeu8(b, 0, value)
    self:writeAll(b, 0, 1)
end

function Writer.writei8(self: Writer, value: number)
    local b = buffer.create(1)
    buffer.writei8(b, 0, value)
    self:writeAll(b, 0, 1)
end

function Writer.writeu16(self: Writer, value: number)
    local b = buffer.create(2)
    buffer.writeu16(b, 0, value)
    self:writeAll(b, 0, 2)
end

function Writer.writei16(self: Writer, value: number)
    local b = buffer.create(2)
    buffer.writei16(b, 0, value)
    self:writeAll(b, 0, 2)
end

function Writer.writeu32(self: Writer, value: number)
    local b = buffer.create(4)
    buffer.writeu32(b, 0, value)
    self:writeAll(b, 0, 4)
end

function Writer.writei32(self: Writer, value: number)
    local b = buffer.create(4)
    buffer.writei32(b, 0, value)
    self:writeAll(b, 0, 4)
end

function Writer.writef32(self: Writer, value: number)
    local b = buffer.create(4)
    buffer.writef32(b, 0, value)
    self:writeAll(b, 0, 4)
end

function Writer.writef64(self: Writer, value: number)
    local b = buffer.create(8)
    buffer.writef64(b, 0, value)
    self:writeAll(b, 0, 8)
end

return Writer
