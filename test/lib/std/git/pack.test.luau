--!strict

local mem = zune.mem
local serde = zune.serde

local pack = require("@zune/git/pack")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local HELLO = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"
local HELLO_BANG = "3462721fd4da6b3f451e6e720c547d0bbd546db3"

local function join(parts: { buffer }): buffer
    local total = 0
    for _, part in parts do
        total += buffer.len(part)
    end
    local out = buffer.create(total)
    local at = 0
    for _, part in parts do
        local len = buffer.len(part)
        if len > 0 then
            buffer.copy(out, at, part, 0, len)
            at += len
        end
    end
    return out
end

local function frame(payload: string | buffer): buffer
    local size = if type(payload) == "string" then #payload else buffer.len(payload :: buffer)
    local out = buffer.create(4 + size)
    buffer.writestring(out, 0, string.format("%04x", 4 + size))
    if type(payload) == "string" then
        buffer.writestring(out, 4, payload)
    elseif size > 0 then
        buffer.copy(out, 4, payload :: buffer, 0, size)
    end
    return out
end

local function header(count: number, version: number?): buffer
    local out = buffer.create(12)
    buffer.writestring(out, 0, "PACK")
    buffer.writeu32(out, 4, bit32.byteswap(version or 2))
    buffer.writeu32(out, 8, bit32.byteswap(count))
    return out
end

local function zlib(src: buffer): buffer
    local bound = serde.zlib.calcSize(buffer.len(src))
    local dest = buffer.create(math.max(bound, 1))
    local wrote = serde.zlib.compress(dest, 0, src, 0, buffer.len(src))
    return mem.slice(dest, 0, wrote)
end

local function sizeBytes(type_code: number, size: number): buffer
    local bytes: { number } = {}
    local rest = math.floor(size / 16)
    local first = bit32.bor(bit32.lshift(type_code, 4), bit32.band(size, 15))
    if rest > 0 then
        first = bit32.bor(first, 128)
    end
    table.insert(bytes, first)
    while rest > 0 do
        local seven = bit32.band(rest, 127)
        rest = math.floor(rest / 128)
        if rest > 0 then
            seven = bit32.bor(seven, 128)
        end
        table.insert(bytes, seven)
    end
    local out = buffer.create(#bytes)
    for index, byte in bytes do
        buffer.writeu8(out, index - 1, byte)
    end
    return out
end

local function encodeOfs(distance: number): buffer
    local tail: { number } = { bit32.band(distance, 127) }
    local rest = math.floor(distance / 128)
    while rest > 0 do
        rest -= 1
        table.insert(tail, 1, bit32.bor(128, bit32.band(rest, 127)))
        rest = math.floor(rest / 128)
    end
    local out = buffer.create(#tail)
    for index, byte in tail do
        buffer.writeu8(out, index - 1, byte)
    end
    return out
end

describe("packets", function()
    test("read", function()
        local src = join({
            frame("hi\n"),
            buffer.fromstring("0000"),
            buffer.fromstring("0001"),
        })
        local cursor = pack.packets(src)
        local data = assert(cursor:next(), "missing packet")
        expect(data.kind).toBe("data")
        expect(buffer.tostring(data.data :: buffer)).toBe("hi\n")
        local flush = assert(cursor:next(), "missing packet")
        expect(flush.kind).toBe("flush")
        expect(flush.data).toBeNil()
        local delim = assert(cursor:next(), "missing packet")
        expect(delim.kind).toBe("delim")
        expect(delim.data).toBeNil()
        expect(cursor:next()).toBeNil()
    end)

    test("bad", function()
        expect(function()
            pack.packets(buffer.fromstring("0008ab")):next()
        end).toThrow("truncated pkt")
        expect(function()
            pack.packets(buffer.fromstring("zzzz")):next()
        end).toThrow("bad pkt")
    end)
end)

describe("sideband", function()
    test("pack", function()
        local body = buffer.create(32)
        buffer.writestring(body, 0, "PACK")
        local src = join({
            frame("NAK\n"),
            frame("packfile\n"),
            frame(body),
            buffer.fromstring("0000"),
        })
        expect(buffer.tostring(pack.sideband(src))).toBe(buffer.tostring(body))
    end)

    test("error", function()
        expect(function()
            pack.sideband(frame("ERR nope\n"))
        end).toThrow("ERR nope")
        expect(function()
            pack.sideband(join({
                frame("packfile\n"),
                frame("\x03bad\n"),
            }))
        end).toThrow("bad\n")
    end)

    test("missing", function()
        expect(function()
            pack.sideband(buffer.fromstring("0000"))
        end).toThrow("pack missing")
    end)
end)

describe("parse", function()
    test("empty", function()
        local objects = pack.parse(header(0))
        local count = 0
        for _ in objects do
            count += 1
        end
        expect(count).toBe(0)
    end)

    test("bad", function()
        expect(function()
            pack.parse(buffer.fromstring("nope"))
        end).toThrow("pack missing")
        expect(function()
            pack.parse(header(0, 3))
        end).toThrow("unsupported pack")
        local bad = join({ header(1), sizeBytes(5, 0) })
        expect(function()
            pack.parse(bad)
        end).toThrow("bad pack type")
    end)

    test("blob", function()
        local body = buffer.fromstring("hello")
        local packed = join({ header(1), sizeBytes(3, buffer.len(body)), zlib(body) })
        local object = pack.parse(packed)[HELLO]
        expect(object.kind).toBe("blob")
        expect(object.oid).toBe(HELLO)
        expect(buffer.tostring(object.data)).toBe("hello")
    end)

    test("delta", function()
        local body = buffer.fromstring("hello")
        local compressed = zlib(body)
        local blob_head = sizeBytes(3, buffer.len(body))
        local delta = buffer.create(6)
        buffer.writeu8(delta, 0, 5)
        buffer.writeu8(delta, 1, 6)
        buffer.writeu8(delta, 2, 0x90)
        buffer.writeu8(delta, 3, 5)
        buffer.writeu8(delta, 4, 1)
        buffer.writeu8(delta, 5, (string.byte("!")))
        local distance = buffer.len(blob_head) + buffer.len(compressed)
        local packed = join({
            header(2),
            blob_head,
            compressed,
            sizeBytes(6, buffer.len(delta)),
            encodeOfs(distance),
            zlib(delta),
        })
        local objects = pack.parse(packed)
        expect(buffer.tostring(objects[HELLO].data)).toBe("hello")
        local changed = objects[HELLO_BANG]
        expect(changed.kind).toBe("blob")
        expect(changed.oid).toBe(HELLO_BANG)
        expect(buffer.tostring(changed.data)).toBe("hello!")
    end)
end)

return nil
