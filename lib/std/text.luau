--!strict
--!optimize 2

local text = {}

local UNITS = { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB" }

local TIME_NAME = { "s", "m", "h", "d", "w" }
local TIME_SPAN = { 60, 60, 24, 7 }

--- - `0 B`
--- - `1 KiB`
--- - `1 MiB`
--- - `1 GiB`
--- - `1 TiB`
function text.bytes(bytes: number): string
    local value = bytes
    local i = 1
    while value >= 1024 and i < #UNITS do
        value /= 1024
        i += 1
    end
    if i == 1 then
        return `{math.floor(value)} {UNITS[i]}`
    end
    if value >= 10 or value == math.floor(value) then
        return string.format("%.0f %s", value, UNITS[i])
    end
    return string.format("%.1f %s", value, UNITS[i])
end

--- - `0s`
--- - `1m00s`
--- - `1h00m`
function text.time(seconds: number): string
    if seconds < 0 or not math.isfinite(seconds) then
        seconds = 0
    end
    local count = math.floor(seconds + 0.5)
    local rest = 0
    local i = 1
    while i <= #TIME_SPAN and count >= TIME_SPAN[i] do
        rest = count % TIME_SPAN[i]
        count = math.floor(count / TIME_SPAN[i])
        i += 1
    end
    if i == 1 then
        return `{count}{TIME_NAME[i]}`
    end
    return `{count}{TIME_NAME[i]}{string.format("%02d", rest)}{TIME_NAME[i - 1]}`
end

--- - `abcdefg`
--- - `abcd...`
function text.fit(value: string, width: number): string
    if not math.isfinite(width) or width < 1 then
        error("width must be positive", 0)
    end
    width = math.floor(width)
    if #value <= width then
        return value
    end
    if width <= 3 then
        return string.sub(value, 1, width)
    end
    return `{string.sub(value, 1, width - 3)}...`
end

--- - `'  abc'`
--- - `'abc  '`
function text.pad(value: string, width: number, align: ("left" | "right")?): string
    if not math.isfinite(width) or width < 1 then
        error("width must be positive", 0)
    end
    width = math.floor(width)
    if #value >= width then
        return value
    end
    local gap = string.rep(" ", width - #value)
    if align == "right" then
        return gap .. value
    end
    return value .. gap
end

return text
