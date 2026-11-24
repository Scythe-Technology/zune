--!strict
--!optimize 2

local mem = zune.mem

local parse = require("./parse")

export type Request = {
    method: string,
    path: string,
    headers: { [string]: string },
    body: buffer?,
}

export type ParserLimits = {
    body: number?,
    headers: number?,
    header_bytes: number?,
    uri: number?,
}

type Stage = "method" | "url" | "protocol" | "headers" | "body" | "done"
type BodyMode = "none" | "length" | "chunked"
type MethodName = "GET" | "PUT" | "POST" | "HEAD" | "PATCH" | "DELETE" | "OPTIONS" | "CONNECT"

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
    stage: Stage,
    method: MethodName?,
    uri: string?,
    protocol: ("HTTP/1.0" | "HTTP/1.1")?,
    headers: { [string]: string },
    body: buffer?,

    spill: buffer?,
    max_body_size: number,
    max_header_size: number,
    max_headers: number,
    max_uri_size: number,
    state: ParserState,
}

local DEFAULT_BODY = 1048576
local DEFAULT_HEADERS = 100
local DEFAULT_HEADER_BYTES = 4096
local DEFAULT_URI = 8192

local HTTP = parse.HTTP
local GET_ = parse.u32("GET ")
local PUT_ = parse.u32("PUT ")
local POST = parse.u32("POST")
local HEAD = parse.u32("HEAD")
local PATC = parse.u32("PATC")
local DELE = parse.u32("DELE")
local ETE_ = parse.u32("ETE ")
local OPTI = parse.u32("OPTI")
local ONS_ = parse.u32("ONS ")
local CONN = parse.u32("CONN")
local ECT_ = parse.u32("ECT ")
local V1P0 = parse.V1P0
local V1P1 = parse.V1P1

local function isValidUri(buf: buffer, pos: number, len: number): boolean
    if
        mem.findNonePos(
            buf,
            pos,
            " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{|}~",
            len
        )
    then
        return false
    end
    return true
end

local function parseMethod(self: Parser, buf: buffer): boolean
    local pos = self.pos
    if self.size - pos < 8 then
        return parse.needMore(self, buf, pos)
    end
    local word = buffer.readu32(buf, pos)
    if word == GET_ then
        self.method = "GET"
        self.pos = pos + 4
    elseif word == PUT_ then
        self.method = "PUT"
        self.pos = pos + 4
    elseif word == POST then
        if buffer.readu8(buf, pos + 4) ~= 0x20 then -- ' '
            error("unknown method", 0)
        end
        self.method = "POST"
        self.pos = pos + 5
    elseif word == HEAD then
        if buffer.readu8(buf, pos + 4) ~= 0x20 then -- ' '
            error("unknown method", 0)
        end
        self.method = "HEAD"
        self.pos = pos + 5
    elseif word == PATC then
        if buffer.readu8(buf, pos + 4) ~= 0x48 or buffer.readu8(buf, pos + 5) ~= 0x20 then -- 'H', ' '
            error("unknown method", 0)
        end
        self.method = "PATCH"
        self.pos = pos + 6
    elseif word == DELE then
        if buffer.readu32(buf, pos + 3) ~= ETE_ then
            error("unknown method", 0)
        end
        self.method = "DELETE"
        self.pos = pos + 7
    elseif word == OPTI then
        if buffer.readu32(buf, pos + 4) ~= ONS_ then
            error("unknown method", 0)
        end
        self.method = "OPTIONS"
        self.pos = pos + 8
    elseif word == CONN then
        if buffer.readu32(buf, pos + 4) ~= ECT_ then
            error("unknown method", 0)
        end
        self.method = "CONNECT"
        self.pos = pos + 8
    else
        error("unknown method", 0)
    end
    self.stage = "url"
    return false
end

local function parseUrl(self: Parser, buf: buffer): boolean
    local pos = self.pos
    local size = self.size
    if pos >= size then
        return parse.needMore(self, buf, pos)
    end
    local front = buffer.readu8(buf, pos)
    if front == 0x2F then -- '/'
        local space = parse.find(buf, pos + 1, size, 0x20) -- ' '
        if not space then
            if size - pos > self.max_uri_size then
                error("URI too large", 0)
            end
            return parse.needMore(self, buf, pos)
        end
        local uri_len = space - pos
        if uri_len > self.max_uri_size then
            error("URI too large", 0)
        end
        if not isValidUri(buf, pos, uri_len) then
            error("invalid request target", 0)
        end
        self.uri = buffer.readstring(buf, pos, uri_len)
        self.pos = space + 1
        self.stage = "protocol"
        return false
    elseif front == 0x2A then -- '*'
        if pos + 1 >= size then
            return parse.needMore(self, buf, pos)
        end
        if buffer.readu8(buf, pos + 1) ~= 0x20 then -- ' '
            error("invalid request target", 0)
        end
        self.uri = "*"
        self.pos = pos + 2
        self.stage = "protocol"
        return false
    end
    error("invalid request target", 0)
end

local function parseProtocol(self: Parser, buf: buffer): boolean
    local pos = self.pos
    if self.size - pos < 10 then
        return parse.needMore(self, buf, pos)
    end
    if buffer.readu32(buf, pos) ~= HTTP then
        error("unknown protocol", 0)
    end
    local version = buffer.readu32(buf, pos + 4)
    if version == V1P1 then
        self.protocol = "HTTP/1.1"
    elseif version == V1P0 then
        self.protocol = "HTTP/1.0"
    else
        error("unsupported protocol", 0)
    end
    if buffer.readu8(buf, pos + 8) ~= 0x0D or buffer.readu8(buf, pos + 9) ~= 0x0A then -- '\r', '\n'
        error("unknown protocol", 0)
    end
    self.pos = pos + 10
    self.stage = "headers"
    return false
end

local function freshState(): ParserState
    return {
        leftover = nil,
        headers_count = 0,
        body_mode = nil,
        content_length = nil,
        body_got = 0,
        chunk_remain = nil,
        chunk_len = 0,
        chunk_buf = nil,
    }
end

local function captureSpill(self: Parser, buf: buffer)
    if self.pos < self.size then
        self.spill = mem.slice(buf, self.pos, self.size - self.pos)
    else
        self.spill = nil
    end
    self.state.leftover = nil
end

local request = {}

function request.newParser(limits: ParserLimits?): Parser
    local opts = limits or {} :: ParserLimits
    local body = opts.body
    local headers = opts.headers
    local header_bytes = opts.header_bytes
    local uri = opts.uri
    return {
        pos = 0,
        size = 0,
        stage = "method",
        method = nil,
        uri = nil,
        protocol = nil,
        headers = {},
        body = nil,
        spill = nil,
        max_body_size = if body == nil then DEFAULT_BODY else body,
        max_header_size = if header_bytes == nil then DEFAULT_HEADER_BYTES else header_bytes,
        max_headers = if headers == nil then DEFAULT_HEADERS else headers,
        max_uri_size = if uri == nil then DEFAULT_URI else uri,
        state = freshState(),
    }
end

function request.parse(self: Parser, incoming: buffer): boolean
    if self.stage == "done" then
        return true
    end
    if buffer.len(incoming) == 0 then
        return false
    end
    local buf = parse.withLeftover(self, incoming)
    self.pos = 0
    self.size = buffer.len(buf)
    self.spill = nil
    if self.stage == "method" then
        if parseMethod(self, buf) then
            return false
        end
    end
    if self.stage == "url" then
        if parseUrl(self, buf) then
            return false
        end
    end
    if self.stage == "protocol" then
        if parseProtocol(self, buf) then
            return false
        end
    end
    if self.stage == "headers" then
        if parse.headers(self, buf, false) then
            return false
        end
    end
    if self.stage == "body" then
        if parse.body(self, buf) then
            return false
        end
    end
    if self.stage == "done" then
        captureSpill(self, buf)
        return true
    end
    return false
end

function request.canKeepAlive(self: Parser): boolean
    if self.protocol ~= "HTTP/1.1" then
        return false
    end
    return self.headers["connection"] ~= "close"
end

function request.resetParser(self: Parser)
    self.pos = 0
    self.size = 0
    self.stage = "method"
    self.method = nil
    self.uri = nil
    self.protocol = nil
    self.headers = {}
    self.body = nil
    self.spill = nil
    self.state = freshState()
end

return request
