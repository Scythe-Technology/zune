--!strict
--!optimize 2

local mem = zune.mem

local session = require("./session")
local Response = require("./response")

local RECV_CHUNK = 8192

local METHODS: { [string]: boolean } = {
    GET = true,
    HEAD = true,
    POST = true,
    PUT = true,
    DELETE = true,
    CONNECT = true,
    OPTIONS = true,
    TRACE = true,
    PATCH = true,
}

export type RequestOptions = {
    method: string?,
    headers: { [string]: string }?,
    body: (string | buffer)?,
    timeout: number?,
    max_body_size: number?,
    max_header_size: number?,
    max_headers: number?,
    tls: {
        host: string?,
        ca: TlsCertBundle?,
    }?,
}

export type Response = {
    ok: boolean,
    code: number,
    reason: string,
    headers: { [string]: string },
    body: buffer?,
}

type ParsedUrl = session.ParsedUrl

local function payloadLen(body: string | buffer): number
    if type(body) == "buffer" then
        return buffer.len(body)
    end
    return #body
end

local function joinRequest(head: string, body: (string | buffer)?): buffer
    local head_len = #head
    local body_len = if body ~= nil then payloadLen(body) else 0
    local out = buffer.create(head_len + body_len)
    buffer.writestring(out, 0, head)
    if body == nil or body_len == 0 then
        return out
    end
    if type(body) == "buffer" then
        buffer.copy(out, head_len, body, 0, body_len)
    else
        buffer.writestring(out, head_len, body)
    end
    return out
end

local function buildHead(method: string, url: ParsedUrl, options: RequestOptions?, body: (string | buffer)?): string
    local host_handled = false
    local user_agent_handled = false
    local lines: { string } = {}
    local headers = if options then options.headers else nil
    if headers ~= nil then
        if type(headers) ~= "table" then
            error("invalid headers (expected table)", 0)
        end
        for key, value in headers do
            if type(key) ~= "string" then
                error(`header index is not a string (got {type(key)})`, 0)
            end
            if type(value) ~= "string" then
                error(`header value must be a string (got {type(value)})`, 0)
            end
            local lower = string.lower(key)
            if lower == "content-length" then
                error("content-length cannot be set", 0)
            elseif lower == "host" then
                host_handled = true
            elseif lower == "user-agent" then
                user_agent_handled = true
            end
            if #value > 0 then
                table.insert(lines, `{key}: {value}`)
            end
        end
    end

    local head: { string } = { `{method} {url.target} HTTP/1.1` }
    if not host_handled then
        local host = if string.find(url.host, ":", 1, true) ~= nil then `[{url.host}]` else url.host
        table.insert(head, `Host: {host}`)
    end
    for _, line in lines do
        table.insert(head, line)
    end
    table.insert(head, "Connection: close")
    if not user_agent_handled then
        table.insert(head, `User-Agent: {session.user_agent}`)
    end
    if body ~= nil then
        table.insert(head, `Content-Length: {payloadLen(body)}`)
    end
    return table.concat(head, "\r\n") .. "\r\n\r\n"
end

local function readResponse(conn: session.Session, limits: Response.ParserLimits): Response
    local parser = Response.newParser(limits)
    local recv_buf = buffer.create(RECV_CHUNK)
    while true do
        local n = conn:read(recv_buf, 0, RECV_CHUNK)
        if n == 0 then
            error("connection closed", 0)
        end
        if Response.parse(parser, mem.slice(recv_buf, 0, n)) then
            break
        end
    end
    local status = parser.status
    if status == nil then
        error("connection closed", 0)
    end
    local out: Response = {
        ok = status >= 200 and status < 300,
        code = status,
        reason = parser.reason or "",
        headers = parser.headers,
    }
    local body = parser.body
    if body ~= nil then
        out.body = body
    end
    return out
end

local function realNumber(value: number?): number?
    if value == nil then
        return nil
    end
    if type(value) ~= "number" or value < 0 or not math.isfinite(value) then
        error("invalid number", 0)
    end
    return math.floor(value)
end

local client = {}

function client.request(url: string, options: RequestOptions?): Response
    local parsed = session.parseUrl(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        error("unsupported URI scheme", 0)
    end
    if options ~= nil and type(options) ~= "table" then
        error("expected options to be a table", 0)
    end

    local method = "GET"
    if options ~= nil and options.method ~= nil then
        if type(options.method) ~= "string" or not METHODS[options.method] then
            error("invalid request method", 0)
        end
        method = options.method
    end

    local body: (string | buffer)? = nil
    if options ~= nil and options.body ~= nil then
        local value = options.body
        if type(value) ~= "string" and type(value) ~= "buffer" then
            error("body must be a string or buffer", 0)
        end
        body = value
    end

    local timeout_seconds: number? = 30
    if options ~= nil and options.timeout ~= nil then
        if type(options.timeout) ~= "number" then
            error("expected timeout to be a number", 0)
        end
        if options.timeout == 0 then
            timeout_seconds = nil
        elseif options.timeout < 0 then
            error("expected timeout to be a number", 0)
        else
            timeout_seconds = options.timeout
        end
    end

    local limits: Response.ParserLimits = {
        body = realNumber(if options then options.max_body_size else nil),
        header_bytes = realNumber(if options then options.max_header_size else nil),
        headers = realNumber(if options then options.max_headers else nil),
    }

    local force_tls = false
    local sni = parsed.host
    local ca: TlsCertBundle? = nil
    if options ~= nil and options.tls ~= nil then
        if type(options.tls) ~= "table" then
            error("expected field 'tls' to be a table", 0)
        end
        force_tls = true
        if options.tls.host ~= nil then
            if type(options.tls.host) ~= "string" then
                error("expected field 'tls.host' to be a string", 0)
            end
            sni = options.tls.host
        end
        if options.tls.ca ~= nil then
            if type(options.tls.ca) ~= "userdata" then
                error("expected field 'tls.ca' to be a CertBundle", 0)
            end
            ca = options.tls.ca
        end
    end

    local head = buildHead(method, parsed, options, body)
    local tls_arg: session.TlsOptions? = nil
    if parsed.tls or force_tls then
        tls_arg = {
            host = sni,
            ca = ca,
        } :: session.TlsOptions
    end
    local conn = session.open(parsed, timeout_seconds, tls_arg)
    local ok, result = pcall(function(): Response
        conn:write(joinRequest(head, body))
        return readResponse(conn, limits)
    end)
    local timed_out = conn:timedOut()
    conn:close()
    if not ok then
        if timed_out then
            error("timed out", 0)
        end
        error(result, 0)
    end
    return result
end

return client
