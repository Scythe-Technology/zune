--!strict
--!optimize 2

local mem = zune.mem
local serde = zune.serde

local Entry = require("@self/Entry")
local Iterator = require("@self/Iterator")

export type Entry = Entry.Entry
export type Iterator = Iterator.Iterator
export type Method = "store" | "deflate"

export type File = {
    path: string,
    data: buffer?,
    method: Method?,
}

local zip = {}

local function deflate(src: buffer): buffer
    local bound = serde.flate.calcSize(buffer.len(src))
    local dest = buffer.create(bound)
    local wrote = serde.flate.compress(dest, 0, src, 0, buffer.len(src))
    return mem.slice(dest, 0, wrote)
end

local function fit32(value: number)
    if value >= 0xFFFFFFFF then
        error("zip field too wide", 0)
    end
end

local UTF8_FLAG = 0x800
local VERSION = 20

local function localHeader(path: string, method: number, crc: number, compressed: number, uncompressed: number): buffer
    local header = buffer.create(30 + #path)
    buffer.writeu32(header, 0, 0x04034b50)
    buffer.writeu16(header, 4, VERSION)
    buffer.writeu16(header, 6, UTF8_FLAG)
    buffer.writeu16(header, 8, method)
    buffer.writeu32(header, 14, crc)
    buffer.writeu32(header, 18, compressed)
    buffer.writeu32(header, 22, uncompressed)
    buffer.writeu16(header, 26, #path)
    buffer.writestring(header, 30, path)
    return header
end

type Piece = {
    path: string,
    method: number,
    crc: number,
    compressed_len: number,
    uncompressed_len: number,
    offset: number,
}

local function centralHeader(piece: Piece): buffer
    local header = buffer.create(46 + #piece.path)
    buffer.writeu32(header, 0, 0x02014b50)
    buffer.writeu16(header, 4, VERSION)
    buffer.writeu16(header, 6, VERSION)
    buffer.writeu16(header, 8, UTF8_FLAG)
    buffer.writeu16(header, 10, piece.method)
    buffer.writeu32(header, 16, piece.crc)
    buffer.writeu32(header, 20, piece.compressed_len)
    buffer.writeu32(header, 24, piece.uncompressed_len)
    buffer.writeu16(header, 28, #piece.path)
    buffer.writeu32(header, 42, piece.offset)
    buffer.writestring(header, 46, piece.path)
    return header
end

local function eocd(count: number, cd_size: number, cd_offset: number): buffer
    local header = buffer.create(22)
    buffer.writeu32(header, 0, 0x06054b50)
    buffer.writeu16(header, 8, count)
    buffer.writeu16(header, 10, count)
    buffer.writeu32(header, 12, cd_size)
    buffer.writeu32(header, 16, cd_offset)
    return header
end

function zip.iterate(src: buffer): Iterator.Iterator
    return Iterator.create(src)
end

function zip.spans(read: Iterator.Read, size: number): { Iterator.Span }
    return Iterator.spans(read, size)
end

-- TODO: with BufferArray support for streaming zip writing
function zip.write(files: { File }): buffer
    if #files > 65535 then
        error("zip field too wide", 0)
    end
    local parts: { buffer } = {}
    local total = 0
    local function add(part: buffer)
        table.insert(parts, part)
        total += buffer.len(part)
    end
    local pieces: { Piece } = {}
    for _, file in files do
        local path = file.path
        if #path > 65535 then
            error("zip field too wide", 0)
        end
        local directory = false
        if #path > 0 then
            local tail = string.byte(path, #path)
            if tail == 47 or tail == 92 then -- '/', '\\'
                directory = true
            end
        end
        local data = file.data or buffer.create(0)
        local method = 0
        local compressed = buffer.create(0)
        local crc = 0
        local uncompressed = 0
        if not directory then
            if file.method == "deflate" then
                method = 8
                compressed = deflate(data)
            elseif file.method ~= nil and file.method ~= "store" then
                error("unsupported zip method", 0)
            else
                compressed = data
            end
            crc = zune.hash.crc32(data)
            uncompressed = buffer.len(data)
        end
        local compressed_len = buffer.len(compressed)
        fit32(compressed_len)
        fit32(uncompressed)
        fit32(total)
        table.insert(pieces, {
            path = path,
            method = method,
            crc = crc,
            compressed_len = compressed_len,
            uncompressed_len = uncompressed,
            offset = total,
        })
        add(localHeader(path, method, crc, compressed_len, uncompressed))
        if compressed_len > 0 then
            add(compressed)
        end
    end
    local cd_offset = total
    for _, piece in pieces do
        add(centralHeader(piece))
    end
    local cd_size = total - cd_offset
    fit32(cd_size)
    fit32(cd_offset)
    add(eocd(#pieces, cd_size, cd_offset))
    local out = buffer.create(total)
    local offset = 0
    for _, part in parts do
        local len = buffer.len(part)
        if len > 0 then
            buffer.copy(out, offset, part, 0, len)
            offset += len
        end
    end
    return out
end

return zip
