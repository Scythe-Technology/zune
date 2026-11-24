--!strict
--!optimize 2

local mem = zune.mem

local spec = require("@zune/spec")

local parse = require("./parse")

export type Response = {
    headers: { [string]: string }?,
    status: number?,
    reason: string?,
    body: (buffer | string)?,
}

export type ParserLimits = {
    body: number?,
    headers: number?,
    header_bytes: number?,
}

type BodyMode = "none" | "length" | "chunked"

type ParserState = {
    leftover: buffer?,
    headers_count: number,
    body_mode: BodyMode?,
    content_length: number?,
    body_got: number,

    chunk_remain: number?,
    chunk_len: number,
    chunk_buf: buffer?,
}

export type Parser = {
    pos: number,
    size: number,
    stage: "status" | "headers" | "body" | "done",
    protocol: ("HTTP/1.0" | "HTTP/1.1")?,
    status: number?,
    reason: string?,
    headers: { [string]: string },
    body: buffer?,

    spill: buffer?,
    max_body_size: number,
    max_header_size: number,
    max_headers: number,
    state: ParserState,
}

local DEFAULT_BODY = 1048576
local DEFAULT_HEADERS = 100
local DEFAULT_HEADER_BYTES = 4096

local HTTP = parse.HTTP
local V1P0 = parse.V1P0
local V1P1 = parse.V1P1

local function parseStatus(self: Parser, buf: buffer): boolean
    if self.size < 12 then
        return parse.needMore(self, buf, 0)
    end
    local line_end = parse.crlf(buf, 0, self.size)
    if not line_end then
        if self.size > 64 then
            error("status line too large", 0)
        end
        return parse.needMore(self, buf, 0)
    end
    if line_end < 12 then
        return parse.needMore(self, buf, 0)
    end

    if buffer.readu32(buf, 0) ~= HTTP then
        error("unknown protocol", 0)
    end
    local version = buffer.readu32(buf, 4)
    if version == V1P1 then
        self.protocol = "HTTP/1.1"
    elseif version == V1P0 then
        self.protocol = "HTTP/1.0"
    else
        error("unsupported protocol", 0)
    end
    if buffer.readu8(buf, 8) ~= 0x20 then -- ' '
        error("invalid status code", 0)
    end

    local code = 0
    for i = 0, 2 do
        local byte = buffer.readu8(buf, 9 + i)
        if byte < 0x30 or byte > 0x39 then -- '0', '9'
            error("invalid status code", 0)
        end
        code = code * 10 + (byte - 0x30)
    end
    if code < 100 or code > 599 then
        error("invalid status code", 0)
    end
    self.status = code

    local after = buffer.readu8(buf, 12)
    if after == 0x20 and line_end > 13 then -- ' '
        self.reason = buffer.readstring(buf, 13, line_end - 13)
    elseif after == 0x0D and line_end == 12 then -- '\r'
        self.reason = nil
    else
        error("invalid status code", 0)
    end
    self.pos = line_end + 2
    return false
end

local response = {}

local function toStringHeaders(info: Response, body: string?): string
    local headers: { [string]: string } = info.headers or {}
    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local result = {}
    for key, value in headers do
        table.insert(result, `{key}: {value}\r\n`)
    end
    return table.concat(result)
end

function response.from(info: Response): string
    local body = if spec.buffer(info.body) then buffer.tostring(info.body :: buffer) else info.body :: string?
    local reason = if info.reason then ` {info.reason}` else ""
    return `HTTP/1.1 {info.status or 200}{reason}\r\n{toStringHeaders(info, body)}\r\n{body or ""}`
end

function response.newParser(limits: ParserLimits?): Parser
    local opts: ParserLimits = limits or {}
    local body = opts.body
    local headers = opts.headers
    local header_bytes = opts.header_bytes
    return {
        pos = 0,
        size = 0,
        stage = "status",
        protocol = nil,
        status = nil,
        reason = nil,
        headers = {},
        body = nil,
        spill = nil,
        max_body_size = if body == nil then DEFAULT_BODY else body,
        max_header_size = if header_bytes == nil then DEFAULT_HEADER_BYTES else header_bytes,
        max_headers = if headers == nil then DEFAULT_HEADERS else headers,
        state = {
            leftover = nil,
            headers_count = 0,
            body_mode = nil,
            content_length = nil,
            body_got = 0,
            chunk_remain = nil,
            chunk_len = 0,
            chunk_buf = nil,
        },
    }
end

function response.parse(self: Parser, incoming: buffer): boolean
    if self.stage == "done" then
        return true
    end
    if buffer.len(incoming) == 0 then
        return false
    end
    local buf = parse.withLeftover(self, incoming)
    self.pos = 0
    self.size = buffer.len(buf)
    if self.stage == "status" then
        if parseStatus(self, buf) then
            return false
        end
        self.stage = "headers"
    end
    if self.stage == "headers" then
        if parse.headers(self, buf, true) then
            return false
        end
    end
    if self.stage == "body" then
        if parse.body(self, buf) then
            return false
        end
    end
    if self.stage == "done" then
        if self.pos < self.size then
            self.spill = mem.slice(buf, self.pos, self.size - self.pos)
        end
        return true
    end
    return false
end

return response
