--!strict
--!optimize 2

local crypto = zune.crypto
local mem = zune.mem
local serde = zune.serde

local Iterator = require("@self/Iterator")

export type Item = Iterator.Item
export type Iterator = Iterator.Iterator

export type Kind = "commit" | "tree" | "blob" | "tag"

export type Object = {
    kind: Kind,
    data: buffer,
    oid: string,
}

local pack = {}

type PackMode = "top" | "pack"

function pack.packets(src: buffer): Iterator.Iterator
    return Iterator.create(src)
end

function pack.sideband(src: buffer): buffer
    local array = zune.io.createBufferArray()
    local mode: PackMode = "top"
    local cursor = pack.packets(src)
    while true do
        local item = cursor:next()
        if not item then
            break
        end
        local data = item.data
        if item.kind == "flush" then
            if mode == "pack" then
                break
            end
            mode = "top"
        elseif item.kind == "delim" then
            mode = "top"
        elseif data then
            if mem.eql(data, "packfile\n") then
                mode = "pack"
            elseif mem.eqlSlice(data, 0, "ERR ", 0, 4) then
                error((string.gsub(buffer.tostring(data), "\n", "")), 0)
            elseif mode == "pack" then
                if mem.startsWith(data, "PACK") then
                    local err = select(2, array:append(data, 0, buffer.len(data)))
                    if err then
                        error("pack too large", 0)
                    end
                else
                    local band = buffer.readu8(data, 0)
                    if band == 1 then
                        local err = select(2, array:append(data, 1, buffer.len(data) - 1))
                        if err then
                            error("pack too large", 0)
                        end
                    elseif band == 3 then
                        error(buffer.readstring(data, 1, buffer.len(data) - 1), 0)
                    end
                end
            end
        end
    end
    if array.len < 32 then
        error("pack missing", 0)
    end
    local packed = buffer.create(array.len)
    local got, err = array:readPositional(0, packed)
    if err or got ~= array.len then
        error("short read", 0)
    end
    if not mem.startsWith(packed, "PACK") then
        error("pack missing", 0)
    end
    return packed
end

local function readSize(src: buffer, at: number): (number, number, number)
    local byte = buffer.readu8(src, at)
    local cursor = at + 1
    local kind = bit32.rshift(bit32.band(byte, 112), 4)
    local size = bit32.band(byte, 15)
    local shift = 4
    while bit32.band(byte, 128) ~= 0 do
        byte = buffer.readu8(src, cursor)
        cursor += 1
        size += bit32.band(byte, 127) * (2 ^ shift)
        shift += 7
    end
    return kind, size, cursor
end

local function readOfs(src: buffer, at: number): (number, number)
    local byte = buffer.readu8(src, at)
    local cursor = at + 1
    local value = bit32.band(byte, 127)
    while bit32.band(byte, 128) ~= 0 do
        byte = buffer.readu8(src, cursor)
        cursor += 1
        value = (value + 1) * 128 + bit32.band(byte, 127)
    end
    return value, cursor
end

local function inflate(src: buffer, offset: number, size: number): (buffer, number)
    local remaining = buffer.len(src) - offset
    local function fits(count: number): boolean
        if count < 2 or count > remaining then
            return false
        end
        local dest = buffer.create(math.max(size, 1))
        local ok, wrote = pcall(serde.zlib.decompress, dest, 0, src, offset, count)
        return ok and wrote == size
    end
    if not fits(remaining) then
        error("corrupt pack object", 0)
    end
    local lo = 2
    local hi = remaining
    while lo < hi do
        local mid = (lo + hi) // 2
        if fits(mid) then
            hi = mid
        else
            lo = mid + 1
        end
    end
    local out = buffer.create(size)
    if size == 0 then
        return out, lo
    end
    local wrote = serde.zlib.decompress(out, 0, src, offset, lo)
    if wrote ~= size then
        error("corrupt pack object", 0)
    end
    return out, lo
end

local function readVarInt(src: buffer, offset: number): (number, number)
    local value = 0
    local shift = 0
    while true do
        local byte = buffer.readu8(src, offset)
        offset += 1
        value += bit32.band(byte, 127) * (2 ^ shift)
        if bit32.band(byte, 128) == 0 then
            return value, offset
        end
        shift += 7
    end
end

local function applyDelta(base: buffer, delta: buffer): buffer
    local base_size, at = readVarInt(delta, 0)
    local result_size, cursor = readVarInt(delta, at)
    if base_size ~= buffer.len(base) then
        error("delta base mismatch", 0)
    end
    local out = buffer.create(result_size)
    local written = 0
    while cursor < buffer.len(delta) do
        local cmd = buffer.readu8(delta, cursor)
        cursor += 1
        if cmd == 0 then
            error("bad delta", 0)
        end
        if bit32.band(cmd, 0x80) ~= 0 then
            local offset = 0
            local count = 0
            for bit = 0, 3 do
                if bit32.band(cmd, bit32.lshift(1, bit)) ~= 0 then
                    offset += buffer.readu8(delta, cursor) * (2 ^ (8 * bit))
                    cursor += 1
                end
            end
            for bit = 0, 2 do
                if bit32.band(cmd, bit32.lshift(1, 4 + bit)) ~= 0 then
                    count += buffer.readu8(delta, cursor) * (2 ^ (8 * bit))
                    cursor += 1
                end
            end
            if count == 0 then
                count = 0x10000
            end
            buffer.copy(out, written, base, offset, count)
            written += count
        else
            buffer.copy(out, written, delta, cursor, cmd)
            cursor += cmd
            written += cmd
        end
    end
    if written ~= result_size then
        error("delta size mismatch", 0)
    end
    return out
end

local KINDS: { [number]: Kind } = {
    [1] = "commit",
    [2] = "tree",
    [3] = "blob",
    [4] = "tag",
}

type Pending = {
    kind: Kind?,
    data: buffer?,
    delta: buffer?,
    header_at: number,
    base_at: number?,
    base_oid: string?,
    oid: string?,
    busy: boolean?,
}

local function objectId(kind: Kind, data: buffer): string
    local hasher = crypto.createHash("sha1")
    hasher:update(`{kind} {buffer.len(data)}\0`)
    if buffer.len(data) > 0 then
        hasher:update(data)
    end
    return hasher:digest("hex") :: string
end

function pack.parse(src: buffer): { [string]: Object }
    if not mem.startsWith(src, "PACK") then
        error("pack missing", 0)
    end
    local version = buffer.readu8(src, 4) * 16777216
        + buffer.readu8(src, 5) * 65536
        + buffer.readu8(src, 6) * 256
        + buffer.readu8(src, 7)
    if version ~= 2 then
        error("unsupported pack", 0)
    end
    local count = buffer.readu8(src, 8) * 16777216
        + buffer.readu8(src, 9) * 65536
        + buffer.readu8(src, 10) * 256
        + buffer.readu8(src, 11)
    local objects: { Pending } = {}
    local offset = 12
    for i = 1, count do
        local header_at = offset
        local code, size, cursor = readSize(src, offset)
        offset = cursor
        local base_at: number? = nil
        local base_oid: string? = nil
        if code == 6 then
            local distance
            distance, offset = readOfs(src, offset)
            base_at = header_at - distance
        elseif code == 7 then
            local parts = table.create(20)
            for b = 0, 19 do
                parts[b + 1] = string.format("%02x", buffer.readu8(src, offset + b))
            end
            base_oid = table.concat(parts)
            offset += 20
        elseif KINDS[code] == nil then
            error("bad pack type", 0)
        end
        local data, consumed = inflate(src, offset, size)
        offset += consumed
        objects[i] = {
            kind = KINDS[code],
            data = if code == 6 or code == 7 then nil else data,
            header_at = header_at,
            base_at = base_at,
            base_oid = base_oid,
        }
        if code == 6 or code == 7 then
            objects[i].delta = data
        end
    end

    local by_offset: { [number]: Pending } = {}
    local by_oid_now: { [string]: Pending } = {}
    for _, object in objects do
        by_offset[object.header_at] = object
    end

    local function resolve(object: Pending): boolean
        if object.oid then
            return true
        end
        if object.busy then
            return false
        end
        object.busy = true
        local function finish(ok: boolean): boolean
            object.busy = false
            return ok
        end
        if object.data and object.kind then
            object.oid = objectId(object.kind, object.data)
            if object.oid then
                by_oid_now[object.oid :: any] = object
            end
            return finish(true)
        end
        local base: Pending? = nil
        if object.base_at then
            base = by_offset[object.base_at]
        elseif object.base_oid then
            base = by_oid_now[object.base_oid]
        end
        if not base or not object.delta then
            return finish(false)
        end
        if not resolve(base) or not base.data or not base.kind then
            return finish(false)
        end
        object.data = applyDelta(base.data, object.delta)
        object.kind = base.kind
        object.oid = objectId(object.kind :: Kind, object.data :: buffer)
        object.delta = nil
        if object.oid then
            by_oid_now[object.oid :: any] = object
        end
        return finish(true)
    end

    local pending = #objects
    while pending > 0 do
        local moved = 0
        for _, object in objects do
            if not object.oid and resolve(object) then
                moved += 1
                pending -= 1
            end
        end
        if moved == 0 then
            error("unresolved delta", 0)
        end
    end

    local by_oid: { [string]: Object } = {}
    for _, object in objects do
        local oid = object.oid
        local kind = object.kind
        local data = object.data
        if not oid or not kind or not data then
            error("unresolved delta", 0)
        end
        by_oid[oid] = {
            kind = kind,
            data = data,
            oid = oid,
        }
    end
    return by_oid
end

return pack
