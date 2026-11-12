--!strict
local gpio = zune.gpio

if not gpio then
    return
end

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("gpio", function()
    test("available", function()
        expect(type(gpio.available())).toBe("boolean")
    end)

    test("chip name", function()
        expect(function()
            gpio.chip("gpiochip")
        end).toThrow("unknown chip")
        expect(function()
            gpio.chip("../gpiochip0")
        end).toThrow("unknown chip")
        expect(function()
            gpio.chip("/dev/gpiochip0")
        end).toThrow("unknown chip")
        expect(function()
            gpio.chip(-1)
        end).toThrow("unknown chip")
    end)

    test("request guards", function()
        expect(function()
            gpio.request("chip")
        end).toThrow("expected table")
        expect(function()
            gpio.request({
                chip = 0,
                offset = 0,
                direction = "sideways",
            })
        end).toThrow("invalid direction")
        expect(function()
            gpio.request({
                chip = 0,
                offset = -1,
                direction = "in",
            })
        end).toThrow("offset out of range")
        expect(function()
            gpio.request({
                chip = 0,
                offset = 0,
                direction = "in",
                consumer = "test",
                initial = true,
            })
        end).toThrow("initial requires output")
        expect(function()
            gpio.request({
                chip = 0,
                offset = 0,
                direction = "out",
                consumer = string.rep("a", 32),
            })
        end).toThrow("invalid consumer")
        expect(function()
            gpio.line(0, -1)
        end).toThrow("offset out of range")
    end)

    test("interface", function()
        if gpio.available() then
            local chips = gpio.chips()
            expect(#chips).toBeGreaterThan(0)
            local first = chips[1]
            expect(type(first.name)).toBe("string")
            expect(#first.name).toBeGreaterThan(0)
            expect(type(first.label)).toBe("string")
            expect(first.lines).toBeGreaterThan(0)

            local info = gpio.chip(first.name)
            expect(info.name).toBe(first.name)
            expect(info.lines).toBe(first.lines)

            local line = gpio.line(first.name, 0)
            expect(line.offset).toBe(0)
            expect(type(line.name)).toBe("string")
            expect(type(line.consumer)).toBe("string")
            expect(type(line.used)).toBe("boolean")
            expect(type(line.active_low)).toBe("boolean")
            expect(line.direction == "in" or line.direction == "out" or line.direction == "unknown").toBeTruthy()

            expect(function()
                gpio.line(first.name, first.lines)
            end).toThrow("offset out of range")
            return
        end

        expect(function()
            gpio.chips()
        end).toThrow("gpio unsupported")
        expect(function()
            gpio.chip(0)
        end).toThrow("gpio unsupported")
        expect(function()
            gpio.line(0, 0)
        end).toThrow("gpio unsupported")
        expect(function()
            gpio.request({
                chip = 0,
                offset = 0,
                direction = "in",
                consumer = "test",
            })
        end).toThrow("gpio unsupported")
    end)
end)
