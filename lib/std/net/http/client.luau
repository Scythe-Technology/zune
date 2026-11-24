--!strict
--!optimize 2

local mem = zune.mem

local head = require("./head")
local session = require("./session")
local Response = require("./response")
local spec = require("@zune/spec")

local RECV_CHUNK = 8192

local BLOCKED: { [string]: string } = {
    ["content-length"] = "content-length cannot be set",
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

local function buildHead(method: string, url: ParsedUrl, options: RequestOptions?, body: (string | buffer)?): string
    local headers = if options then options.headers else nil
    local lines, saw_host, saw_agent = head.lines(headers, BLOCKED)
    local out: { string } = { `{method} {url.target} HTTP/1.1` }
    if not saw_host then
        table.insert(out, `Host: {head.host(url.host)}`)
    end
    for _, line in lines do
        table.insert(out, line)
    end
    table.insert(out, "Connection: close")
    if not saw_agent then
        table.insert(out, `User-Agent: {session.user_agent}`)
    end
    if body then
        table.insert(out, `Content-Length: {head.bytes(body)}`)
    end
    table.insert(out, "\r\n")
    return table.concat(out, "\r\n")
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
    if not status then
        error("connection closed", 0)
    end
    local out: Response = {
        ok = status >= 200 and status < 300,
        code = status,
        reason = parser.reason or "",
        headers = parser.headers,
    }
    local body = parser.body
    if body then
        out.body = body
    end
    return out
end

local nonNegativeSpec = spec.strict(spec.minNumber(0))
local function realNumber(value: number?): number?
    if not value then
        return nil
    end
    if not nonNegativeSpec(value) then
        error("invalid number", 0)
    end
    return math.floor(value)
end

local client = {}

local schemeSpec = spec.oneOf("http", "https")
local methodSpec = spec.oneOf("GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH")
local bodySpec = spec.union(spec.string, spec.buffer)
local certBundleSpec = spec.object("CryptoTlsCertBundle")
function client.request(url: string, options: RequestOptions?): Response
    local parsed = session.parseUrl(url)
    if not schemeSpec(parsed.scheme) then
        error("unsupported URI scheme", 0)
    end
    if options and not spec.table(options) then
        error("expected options to be a table", 0)
    end

    local method = "GET"
    if options and options.method then
        if not methodSpec(options.method) then
            error("invalid request method", 0)
        end
        method = options.method
    end

    local body: (string | buffer)? = nil
    if options and options.body then
        local value = options.body
        if not bodySpec(value) then
            error("body must be a string or buffer", 0)
        end
        body = value
    end

    local timeout_seconds: number? = 30
    if options and options.timeout then
        if not spec.number(options.timeout) then
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
    if options and options.tls then
        if not spec.table(options.tls) then
            error("expected field 'tls' to be a table", 0)
        end
        force_tls = true
        if options.tls.host then
            if not spec.string(options.tls.host) then
                error("expected field 'tls.host' to be a string", 0)
            end
            sni = options.tls.host
        end
        if options.tls.ca then
            if not certBundleSpec(options.tls.ca) then
                error("expected field 'tls.ca' to be a CertBundle", 0)
            end
            ca = options.tls.ca
        end
    end

    local text = buildHead(method, parsed, options, body)
    local tls_arg: session.TlsOptions? = nil
    if parsed.tls or force_tls then
        tls_arg = {
            host = sni,
            ca = ca,
        } :: session.TlsOptions
    end
    local conn = session.open(parsed, timeout_seconds, tls_arg)
    local ok, result = pcall(function(): Response
        conn:write(head.join(text, body))
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
