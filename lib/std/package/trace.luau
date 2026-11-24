--!strict
--!optimize 2

local trace = {}

local masked = { getfenv() }

local function skipped(f: (...any) -> ...any): boolean
    local frame_env = getfenv(f)
    return table.find(masked, frame_env) ~= nil
end

function trace.mask(env: { [string]: any })
    table.insert(masked, env)
end

function trace.findSourceTarget(): (number, string?, number?, number)
    local level, count = nil, 1
    local src: string? = nil
    local line: number? = nil
    for i = 1, 30 do
        local f, l, s = debug.info(i + 1, "fls")
        if not f then
            break
        end
        if l < 0 then
            continue
        end
        if not level then
            if not skipped(f) then
                level = i
                src = s
                line = l
            end
        else
            if skipped(f) then
                break
            end
            count += 1
        end
    end
    if not level then
        level = 1
    end
    return level :: number, src, line, count
end

function trace.capture(): (string, number)
    local level, _, line, count = trace.findSourceTarget()
    return zune.debug.dumpStacktrace(level, count), line or 0
end

return trace
