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
end)

return nil
