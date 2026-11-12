--!strict
--!optimize 2

local encoding = {}

encoding.url = {}

function encoding.url.decode(data: string): string
    -- gsub builds a new string even when the path has no escapes.
    if string.find(data, "%", 1, true) == nil then
        return data
    end
    return (
        data:gsub("%%(%x%x)", function(hex: string): string
            local num = tonumber(hex, 16)
            if not num then
                error("invalid hex", 0)
            end
            return string.char(num)
        end)
    )
end

function encoding.url.encode(data: string): string
    return (
        data:gsub("([^%w%.%-_])", function(char: string): string
            return string.format("%%%02X", string.byte(char))
        end)
    )
end

return encoding
