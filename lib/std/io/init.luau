--!strict
--!optimize 2

local internal = zune.io

local io = setmetatable({}, { __index = internal })

local Writer = require("@self/Writer")
export type Writer = Writer.Writer
local Reader = require("@self/Reader")
export type Reader = Reader.Reader

local function streaming<T>(fn: (self: any, src: T, src_offset: number?, count: number?) -> (number, string?))
    return function(self: any, _: number, src: T, src_offset: number?, count: number?)
        return fn(self, src, src_offset, count)
    end
end

--- Creates a streaming writer.
--- @param target The target object with a `write` method.
--- @param track Whether to track the write offset.
function io.createWriter(target: any, track: boolean?): Writer
    local fn = target.write
    if type(fn) ~= "function" then
        error("must have a write method", 2)
    end
    return setmetatable({
        ud = target,
        offset = if track then 0 else nil,
        write_impl = streaming<<buffer | string>>(fn),
    }, Writer)
end

--- Creates a positional writer.
--- @param target The target object with a `writePositional` method.
--- @param offset The starting offset for the writer.
function io.createPosWriter(target: any, offset: number?): Writer
    local fn = target.writePositional
    if type(fn) ~= "function" then
        error("must have a write method", 2)
    end
    return setmetatable({
        ud = target,
        offset = offset or 0,
        write_impl = fn,
    }, Writer)
end

--- Creates a streaming reader.
--- @param target The target object with a `read` method.
--- @param track Whether to track the read offset.
function io.createReader(target: any, track: boolean?): Reader
    local fn = target.read
    assert(type(fn) == "function", "must have a read method")
    return setmetatable({
        ud = target,
        offset = if track then 0 else nil,
        read_impl = streaming<<buffer>>(fn),
    }, Reader)
end

--- Creates a positional reader.
--- @param target The target object with a `readPositional` method.
--- @param offset The starting offset for the reader.
function io.createPosReader(target: any, offset: number?): Reader
    local fn = target.readPositional
    assert(type(fn) == "function", "must have a read method")
    return setmetatable({
        ud = target,
        offset = offset or 0,
        read_impl = fn,
    }, Reader)
end

export type BufferSinkOptions = {
    --- The maximum amount of bytes allowed to be written to the buffer.
    --- @default 1073741824
    limit: number?,
    --- The initial size of the buffer.
    --- @default 0
    size: number?,
}
@deprecated
function io.createBufferSink(opts: BufferSinkOptions?)
    local options: BufferSinkOptions = opts or {}
    return require("@self/deprecated/BufferSink").create(options.limit or 1073741824, options.size or 0)
end

@deprecated
function io.createFixedBufferStream(buffer: buffer)
    return require("@self/deprecated/BufferStream").create(buffer)
end

@deprecated
function io.format(...)
    return zune.fmt.format(...)
end

return io
