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

export type WriterOptions = {
    positional: boolean?,
}
function io.createWriter(target: any, opts: WriterOptions?): Writer
    local options: WriterOptions = opts or { positional = false }
    local fn = if options.positional then target.writePositional else target.write
    assert(type(fn) == "function", "must have a write method")
    return setmetatable({
        ud = target,
        offset = if options.positional then 0 else nil,
        write_impl = if options.positional then fn else streaming<<buffer | string>>(fn),
    }, Writer)
end

export type ReaderOptions = {
    positional: boolean?,
}
function io.createReader(target: any, opts: ReaderOptions?): Reader
    local options: ReaderOptions = opts or { positional = false }
    local fn = if options.positional then target.readPositional else target.read
    assert(type(fn) == "function", "must have a read method")
    return setmetatable({
        ud = target,
        offset = if options.positional then 0 else nil,
        read_impl = if options.positional then fn else streaming<<buffer>>(fn),
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
