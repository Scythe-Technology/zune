--!strict
local serde = zune.serde

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("flate", function()
    local sample = string.rep(
        [[
        Lorem ipsum dolor sit amet, consectetur adipiscing elit.
    ]],
        20
    )

    local function roundTrip(src: string, lvl: number?): string
        local compressed = buffer.create(serde.flate.calcSize(#src))
        local n = if lvl == nil
            then serde.flate.compress(compressed, 0, src, 0)
            else serde.flate.compress(compressed, 0, src, 0, nil, lvl)
        local plain = buffer.create(#src)
        local wrote = serde.flate.decompress(plain, 0, compressed, 0, n)
        return buffer.readstring(plain, 0, wrote)
    end

    describe("compression", function()
        test("roundtrip", function()
            expect(roundTrip(sample)).toBe(sample)
        end)

        test("buffer", function()
            local src = buffer.fromstring(sample)
            local compressed = buffer.create(serde.flate.calcSize(buffer.len(src)))
            local n = serde.flate.compress(compressed, 0, src, 0)
            local plain = buffer.create(#sample)
            local wrote = serde.flate.decompress(plain, 0, compressed, 0, n)
            expect(buffer.readstring(plain, 0, wrote)).toBe(sample)
        end)

        test("level", function()
            expect(roundTrip(sample, 1)).toBe(sample)
        end)

        test("portion", function()
            local src = ">>" .. sample
            local compressed = buffer.create(serde.flate.calcSize(#sample))
            local n = serde.flate.compress(compressed, 0, src, 2, #sample)
            local plain = buffer.create(#sample + 2)
            local wrote = serde.flate.decompress(plain, 2, compressed, 0, n)
            expect(buffer.readstring(plain, 2, wrote)).toBe(sample)
        end)

        test("fail", function()
            local dest = buffer.create(serde.flate.calcSize(#sample))
            expect(function()
                serde.flate.compress(dest, 0, sample, 0, nil, 10)
            end).toThrow("options 'level' must be between 1 and 9")
            expect(function()
                serde.flate.compress(dest, 0, sample, 0, nil, 0)
            end).toThrow("options 'level' must be between 1 and 9")
            expect(function()
                serde.flate.compress(true :: any, 0, sample, 0)
            end).toThrow("expected a buffer or userdata")
            expect(function()
                serde.flate.compress(buffer.create(4), 0, sample, 0)
            end).toThrow("no space")
        end)
    end)

    describe("stream", function()
        local function srcLen(src: string | buffer): number
            return if type(src) == "string" then #src else buffer.len(src)
        end

        local function readAll(array: BufferArray): string
            if array.len == 0 then
                return ""
            end
            local out = buffer.create(array.len)
            local n, err = array:readPositional(0, out, 0, array.len)
            expect(err).toBeNil()
            expect(n).toBe(array.len)
            return buffer.readstring(out, 0, n)
        end

        local function drain(stream: DeflateStream, src: string | buffer, step: number): string
            local fed = 0
            local total = srcLen(src)
            local guard = 0
            while fed < total do
                guard += 1
                if guard > total + 8 then
                    error("stream made no progress", 0)
                end
                local n, err = stream:write(src, fed, math.min(step, total - fed))
                expect(err).toBeNil()
                if n == 0 then
                    error("stream made no progress", 0)
                end
                fed += n
            end
            stream:finish()
            expect(fed).toBe(total)
            return readAll(stream.array)
        end

        local function readPlain(stream: InflateStream): string
            local dest = buffer.create(65536)
            local out = zune.io.createBufferArray()
            local closed = false
            local guard = 0
            while true do
                guard += 1
                if guard > 100000 then
                    error("stream made no progress", 0)
                end
                local n, err = stream:read(dest)
                expect(err).toBeNil()
                if n > 0 then
                    local wrote, write_err = out:append(dest, 0, n)
                    expect(write_err).toBeNil()
                    expect(wrote).toBe(n)
                elseif not closed then
                    stream:finish()
                    closed = true
                else
                    break
                end
            end
            return readAll(out)
        end

        local function inflateBlob(codec: typeof(serde.flate), blob: string | buffer, count: number?): string
            local plain = buffer.create(1024 * 1024)
            local n = if count == nil
                then codec.decompress(plain, 0, blob, 0)
                else codec.decompress(plain, 0, blob, 0, count)
            return buffer.readstring(plain, 0, n)
        end

        local function inflateFeed(
            codec: typeof(serde.flate),
            src: string | buffer,
            step: number,
            count: number?
        ): string
            local total = if count ~= nil then count else srcLen(src)
            local stream = codec.createDecompressor(zune.io.createBufferArray())
            local packed = stream.array
            local dest = buffer.create(65536)
            local out = zune.io.createBufferArray()
            local fed = 0
            local closed = false
            local need_more = false
            local guard = 0
            while true do
                guard += 1
                if guard > total * 2 + 64 then
                    error("stream made no progress", 0)
                end
                if fed < total and (packed.offset == packed.len or need_more) then
                    local take = math.min(step, total - fed)
                    local wrote, err = packed:append(src, fed, take)
                    expect(err).toBeNil()
                    expect(wrote).toBe(take)
                    fed += take
                    need_more = false
                end
                local n, err = stream:read(dest)
                expect(err).toBeNil()
                if n > 0 then
                    local wrote, write_err = out:append(dest, 0, n)
                    expect(write_err).toBeNil()
                    expect(wrote).toBe(n)
                elseif fed == total and not closed then
                    stream:finish()
                    closed = true
                elseif closed then
                    break
                elseif fed < total then
                    need_more = true
                else
                    error("stream made no progress", 0)
                end
            end
            return readAll(out)
        end

        local function roundTrip(codec: typeof(serde.flate), src: string | buffer, step: number, level: number?): string
            local compressed = drain(codec.createCompressor(zune.io.createBufferArray(), level), src, step)
            return inflateFeed(codec, compressed, step)
        end

        test("roundtrip", function()
            expect(roundTrip(serde.flate, sample, 64)).toBe(sample)
            expect(roundTrip(serde.flate, sample, 1, 1)).toBe(sample)
        end)

        test("window", function()
            local src = buffer.create(70000)
            for i = 0, 69999 do
                buffer.writeu8(src, i, (i * 17) % 251)
            end
            local text = buffer.tostring(src)
            expect(roundTrip(serde.flate, src, 1024)).toBe(text)
            expect(roundTrip(serde.flate, src, 40001, 1)).toBe(text)

            local compressed = buffer.create(serde.flate.calcSize(70000))
            local n = serde.flate.compress(compressed, 0, src, 0)
            expect(inflateBlob(serde.flate, compressed, n)).toBe(text)
            expect(inflateFeed(serde.flate, compressed, 1, n)).toBe(text)
        end)

        test("split write", function()
            local src = string.rep("abc", 20000)
            local stream = serde.flate.createCompressor(zune.io.createBufferArray())
            local n, err = stream:write(src, 0, 1000)
            expect(err).toBeNil()
            expect(n).toBe(1000)

            local compressed = drain(stream, string.sub(src, 1001), 16384)
            expect(inflateBlob(serde.flate, compressed)).toBe(src)
        end)

        test("clear", function()
            local src = string.rep("abc", 20000)
            local stream = serde.flate.createCompressor(zune.io.createBufferArray())
            local half = math.floor(#src / 2)
            local n, err = stream:write(src, 0, half)
            expect(err).toBeNil()
            expect(n).toBe(half)

            local first = readAll(stream.array)

            stream.array:clear()

            local rest = drain(stream, string.sub(src, half + 1), 4096)
            expect(inflateBlob(serde.flate, first .. rest)).toBe(src)
        end)

        test("offset", function()
            local src = ">>hello<<"
            local stream = serde.flate.createCompressor(zune.io.createBufferArray())
            local n, err = stream:write(src, 2, 5)
            expect(err).toBeNil()
            expect(n).toBe(5)

            local compressed = drain(stream, "", 16)

            expect(inflateBlob(serde.flate, compressed)).toBe("hello")
        end)

        test("ended", function()
            local stream = serde.flate.createCompressor(zune.io.createBufferArray())
            local n, err = stream:write("hi", 0, 2)
            expect(err).toBeNil()
            expect(n).toBe(2)

            stream:finish()

            expect(stream.array.len > 0).toBe(true)

            local first = readAll(stream.array)

            stream.array:clear()

            local second = drain(stream, "yo", 8)
            expect(inflateBlob(serde.flate, first)).toBe("hi")
            expect(inflateFeed(serde.flate, second, 1)).toBe("yo")
        end)

        test("reset", function()
            local stream = serde.flate.createCompressor(zune.io.createBufferArray())
            local n, err = stream:write("one", 0, 3)
            expect(err).toBeNil()
            expect(n).toBe(3)
            stream:finish()

            local first = readAll(stream.array)

            stream.array:clear()
            stream:reset()

            local second = drain(stream, "two", 8)
            expect(inflateBlob(serde.flate, first)).toBe("one")
            expect(inflateBlob(serde.flate, second)).toBe("two")
        end)

        test("swap", function()
            local first_array = zune.io.createBufferArray()
            local stream = serde.flate.createCompressor(first_array)
            expect(stream.array).toBe(first_array)
            local n, err = stream:write("one", 0, 3)
            expect(err).toBeNil()
            expect(n).toBe(3)

            stream:finish()

            local first = readAll(stream.array)
            local second_array = zune.io.createBufferArray()

            stream:swapArray(second_array)

            expect(stream.array).toBe(second_array)

            local second = drain(stream, "two", 8)
            expect(inflateBlob(serde.flate, first)).toBe("one")
            expect(inflateBlob(serde.flate, second)).toBe("two")
        end)

        test("array", function()
            local output = zune.io.createBufferArray()
            local compressor = serde.flate.createCompressor(output)
            expect(compressor.array).toBe(output)
            local next = zune.io.createBufferArray()

            compressor:swapArray(next)

            expect(compressor.array).toBe(next)

            local input = zune.io.createBufferArray()
            local decompressor = serde.flate.createDecompressor(input)
            expect(decompressor.array).toBe(input)
            expect(decompressor.array:append("y")).toBe(1)
            expect(input.len).toBe(1)
        end)

        test("drop front", function()
            local stream = serde.flate.createCompressor(zune.io.createBufferArray())
            local n, err = stream:write("hello", 0, 5)
            expect(err).toBeNil()
            expect(n).toBe(5)

            stream:finish()

            expect(stream.array.len >= 2).toBe(true)

            local head = readAll(stream.array)
            stream.array:seekTo(2)

            local again, again_err = stream:write("world", 0, 5)
            expect(again_err).toBeNil()
            expect(again).toBe(5)

            stream:finish()

            expect(stream.array.offset).toBe(2)
            expect(stream.array.len > #head).toBe(true)

            stream.array:dropFront(#head)

            expect(stream.array.offset).toBe(2)

            stream.array:seekTo(0)

            local second = readAll(stream.array)
            expect(inflateBlob(serde.flate, head)).toBe("hello")
            expect(inflateBlob(serde.flate, second)).toBe("world")

            local plain = serde.flate.createDecompressor(zune.io.createBufferArray())
            local packed = plain.array
            local cut = math.max(1, math.floor(#head / 2))
            expect(packed:append(string.sub(head, 1, cut))).toBe(cut)
            expect(packed.offset).toBe(0)

            local dest = buffer.create(8)
            local got, read_err = plain:read(dest)
            expect(read_err).toBeNil()

            local at = packed.offset
            expect(packed:append(string.sub(head, cut + 1))).toBe(#head - cut)
            expect(packed.offset).toBe(at)
            local out = if got > 0 then buffer.readstring(dest, 0, got) else ""
            local closed = false
            local guard = 0
            while true do
                guard += 1
                if guard > 64 then
                    error("stream made no progress", 0)
                end
                local more, more_err = plain:read(dest)
                expect(more_err).toBeNil()
                if more > 0 then
                    out ..= buffer.readstring(dest, 0, more)
                elseif not closed then
                    plain:finish()
                    closed = true
                else
                    break
                end
            end
            expect(out).toBe("hello")
            expect(packed.len).toBe(#head)
            expect(packed.offset).toBe(packed.len)
        end)

        test("copy", function()
            local compressed = drain(serde.flate.createCompressor(zune.io.createBufferArray()), "hello", 8)
            local blob = buffer.fromstring(compressed)
            local plain = serde.flate.createDecompressor(zune.io.createBufferArray())
            expect(plain.array:append(blob)).toBe(buffer.len(blob))
            for i = 0, buffer.len(blob) - 1 do
                buffer.writeu8(blob, i, 0)
            end
            expect(readPlain(plain)).toBe("hello")
        end)

        test("truncated", function()
            expect(function()
                serde.flate.decompress(buffer.create(16), 0, buffer.create(0), 0)
            end).toThrow("ReadFailed")
            expect(function()
                serde.flate.createDecompressor(zune.io.createBufferArray()):finish()
            end).toThrow("truncated")
            expect(function()
                serde.flate.createDecompressor(buffer.create(0) :: any)
            end).toThrow("expected BufferArray")
            expect(function()
                serde.flate.createDecompressor(1 :: any)
            end).toThrow("expected BufferArray")
        end)

        test("corrupt", function()
            local stream = serde.flate.createDecompressor(zune.io.createBufferArray())
            local text = "this is not deflate"
            expect(stream.array:append(text)).toBe(#text)

            local dest = buffer.create(64)
            local err: string? = nil
            local closed = false
            local guard = 0
            while err == nil do
                guard += 1
                if guard > 64 then
                    error("stream made no progress", 0)
                end
                local n, read_err = stream:read(dest)
                err = read_err
                if err == nil and n == 0 then
                    if closed then
                        error("stream made no progress", 0)
                    end
                    local ok, thrown = pcall(function()
                        stream:finish()
                    end)
                    closed = true
                    if not ok then
                        err = if type(thrown) == "string" then thrown:match("^.+:%d+: (.+)$") or thrown else nil
                    end
                end
            end
            expect(err == "bad flate" or err == "truncated").toBe(true)
        end)

        test("level", function()
            expect(function()
                serde.flate.createCompressor(zune.io.createBufferArray(), 0)
            end).toThrow("options 'level' must be between 1 and 9")
            expect(function()
                serde.flate.createCompressor(zune.io.createBufferArray(), 10)
            end).toThrow("options 'level' must be between 1 and 9")
        end)

        test("gzip", function()
            local src = string.rep("gzip-stream-", 4000)
            expect(roundTrip(serde.gzip, src, 1000)).toBe(src)
        end)

        test("zlib", function()
            local src = string.rep("zlib-stream-", 4000)
            expect(roundTrip(serde.zlib, src, 1000, 1)).toBe(src)
        end)
    end)
end)

return nil
