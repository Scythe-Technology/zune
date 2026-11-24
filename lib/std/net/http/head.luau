--!strict
--!optimize 2

local mem = zune.mem

local spec = require("@zune/spec")

local head = {}

function head.bytes(message: string | buffer): number
    if spec.buffer(message) then
        return buffer.len(message :: buffer)
    end
    return #(message :: string)
end

function head.host(host: string, port: number?, default_port: number?): string
    local name = if mem.findScalar(host, 58) then `[{host}]` else host -- ':'
    if port and default_port and port ~= default_port then
        return `{name}:{port}`
    end
    return name
end

function head.lines(headers: { [string]: string }?, blocked: { [string]: string }?): ({ string }, boolean, boolean)
    local saw_host = false
    local saw_agent = false
    local lines: { string } = {}
    if not headers then
        return lines, saw_host, saw_agent
    end
    if not spec.table(headers) then
        error("headers must be a table", 0)
    end
    for key, value in headers do
        if not spec.string(key) then
            error(`header index is not a string (got {type(key)})`, 0)
        end
        if not spec.string(value) then
            error(`header value must be a string (got {type(value)})`, 0)
        end
        local lower = string.lower(key)
        if blocked then
            local reason = blocked[lower]
            if reason then
                error(reason, 0)
            end
        end
        if lower == "host" then
            saw_host = true
        elseif lower == "user-agent" then
            saw_agent = true
        end
        if #value > 0 then
            table.insert(lines, `{key}: {value}`)
        end
    end
    return lines, saw_host, saw_agent
end

function head.join(text: string, body: (string | buffer)?): buffer
    local text_len = #text
    local body_len = if body then head.bytes(body) else 0
    local out = buffer.create(text_len + body_len)
    buffer.writestring(out, 0, text)
    if not body or body_len == 0 then
        return out
    end
    if spec.buffer(body) then
        buffer.copy(out, text_len, body :: buffer, 0, body_len)
    else
        buffer.writestring(out, text_len, body :: string)
    end
    return out
end

return head
