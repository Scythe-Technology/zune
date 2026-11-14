--!strict
local platform = zune.platform

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("platform", function()
    test("properties", function()
        expect(platform.os).toBe(expect.any("string"))
        expect(#platform.os).toBeGreaterThan(0)

        expect(platform.cpu.arch).toBe(expect.any("string"))
        expect(#platform.cpu.arch).toBeGreaterThan(0)
        expect(platform.cpu.endian).toBe(expect.any("string"))
        expect(#platform.cpu.endian).toBeGreaterThan(0)
        expect(table.find({ "big", "little" }, platform.cpu.endian) ~= nil).toBeTruthy()

        expect(table.find({ "io_uring", "epoll", "kqueue", "iocp" }, platform.async) ~= nil).toBeTruthy()
    end)

    test("memory", function()
        local total_memory = platform.getTotalMemory()
        expect(total_memory).toBe(expect.any("number"))
        expect(total_memory).toBeGreaterThan(0)

        local free_memory = platform.getFreeMemory()
        expect(free_memory).toBe(expect.any("number"))
        expect(free_memory).toBeGreaterThan(0)
    end)

    test("hostName", function()
        local host_name = platform.getHostName()
        expect(host_name).toBe(expect.any("string"))
        expect(#host_name).toBeGreaterThan(0)
    end)

    test("kernel version", function()
        local kernel_version = platform.getKernelVersion()
        expect(kernel_version).toBe(expect.any("string"))
        expect(#kernel_version).toBeGreaterThan(0)
    end)
end)
