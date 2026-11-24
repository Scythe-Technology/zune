--!strict
--!optimize 2

local mem = zune.mem

local spec = require("@zune/spec")

local uri = {}

export type Uri = {
    scheme: string,
    host: string?,
    port: number?,
    path: string,
    query: string?,
    fragment: string?,
}

local portSpec = spec.union(spec.minInteger(0), spec.maxInteger(65535))
local function portNumber(digits: string): number
    local port = tonumber(digits)
    if not portSpec(port) then
        error(`invalid port ({port})`, 0)
    end
    return port :: number
end

local function readHost(authority: string): (string?, number?)
    if authority == "" then
        return nil, nil
    end
    local at = mem.findScalar(authority, 64) -- '@'
    if at then
        authority = string.sub(authority, at + 2)
        if authority == "" then
            error("URI missing host", 0)
        end
    end
    if mem.startsWith(authority, "[") then
        local end_bracket = mem.findScalar(authority, 93) -- ']'
        if not end_bracket then
            error("URI missing host", 0)
        end
        local host = string.sub(authority, 2, end_bracket)
        if host == "" then
            error("URI missing host", 0)
        end
        local tail = string.sub(authority, end_bracket + 2)
        if tail == "" then
            return host, nil
        end
        local digits = string.match(tail, "^:(%d+)$")
        if not digits then
            error("URI missing host", 0)
        end
        return host, portNumber(digits)
    end
    local name, digits = string.match(authority, "^(.-):(%d+)$")
    if name and digits and not mem.findScalar(name, 58) then -- ':'
        if name == "" then
            error("URI missing host", 0)
        end
        return name, portNumber(digits)
    end
    if mem.findScalar(authority, 58) then -- ':'
        error("URI missing host", 0)
    end
    return authority, nil
end

function uri.parse(raw: string): Uri
    if raw == "" then
        error("bad URI", 0)
    end
    local scheme, rest = string.match(raw, "^([%a][%w+.-]*)://(.*)$")
    if scheme == nil or rest == nil then
        error("bad URI", 0)
    end
    scheme = string.lower(scheme)

    local fragment: string? = nil
    local hash = mem.findScalar(rest, 35) -- '#'
    if hash then
        fragment = string.sub(rest, hash + 2)
        rest = string.sub(rest, 1, hash)
    end

    local query: string? = nil
    local mark = mem.findScalar(rest, 63) -- '?'
    if mark then
        query = string.sub(rest, mark + 2)
        rest = string.sub(rest, 1, mark)
    end

    local authority: string, path: string
    local slash = mem.findScalar(rest, 47) -- '/'
    if slash then
        authority = string.sub(rest, 1, slash)
        path = string.sub(rest, slash + 1)
    else
        authority, path = rest, ""
    end

    local host, port = readHost(authority)
    return {
        scheme = scheme,
        host = host,
        port = port,
        path = path,
        query = query,
        fragment = fragment,
    }
end

return uri
