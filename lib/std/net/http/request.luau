--!strict
--!optimize 2

local mem = zune.mem
local ascii = zune.ascii

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

local function asU32(str: string): number
    return buffer.readu32(buffer.fromstring(str), 0)
end

local HTTP = asU32("HTTP")
local GET_ = asU32("GET ")
local PUT_ = asU32("PUT ")
local POST = asU32("POST")
local HEAD = asU32("HEAD")
local PATC = asU32("PATC")
local DELE = asU32("DELE")
local ETE_ = asU32("ETE ")
local OPTI = asU32("OPTI")
local ONS_ = asU32("ONS ")
local CONN = asU32("CONN")
local ECT_ = asU32("ECT ")
local V1P0 = asU32("/1.0")
local V1P1 = asU32("/1.1")

local VALID_HEADER_VALUE: { [number]: boolean } = {}
VALID_HEADER_VALUE[0x09] = true
VALID_HEADER_VALUE[0x20] = true
for i = 0x21, 0x7E do
    VALID_HEADER_VALUE[i] = true
end

local function isHeaderToken(byte: number): boolean
    return (byte >= 0x41 and byte <= 0x5A)
        or (byte >= 0x61 and byte <= 0x7A)
        or (byte >= 0x30 and byte <= 0x39)
        or byte == 0x2D
        or byte == 0x5F
end

local function joinBuffers(left: buffer, right: buffer): buffer
    local left_len = buffer.len(left)
    local right_len = buffer.len(right)
    local out = buffer.create(left_len + right_len)
    buffer.copy(out, 0, left, 0, left_len)
    buffer.copy(out, left_len, right, 0, right_len)
    return out
end

local function withLeftover(self: Parser, target: buffer): buffer
    local left = self.state.leftover
    if left and self.pos < self.size then
        local joined = joinBuffers(mem.slice(left, self.pos, self.size - self.pos), target)
        self.state.leftover = nil
        return joined
    end
    self.state.leftover = nil
    return target
end

local function needMore(self: Parser, buf: buffer, pos: number): boolean
    self.pos = pos
    self.state.leftover = buf
    return true
end

local function findScalar(buf: buffer, pos: number, size: number, byte: number): number?
    if pos >= size then
        return nil
    end
    local found = mem.findScalarPos(buf, pos, byte)
    if found == nil or found >= size then
        return nil
    end
    return found
end

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
        return needMore(self, buf, pos)
    end
    local word = buffer.readu32(buf, pos)
    if word == GET_ then
        self.method = "GET"
        self.pos = pos + 4
    elseif word == PUT_ then
        self.method = "PUT"
        self.pos = pos + 4
    elseif word == POST then
        if buffer.readu8(buf, pos + 4) ~= 0x20 then
            error("unknown method", 0)
        end
        self.method = "POST"
        self.pos = pos + 5
    elseif word == HEAD then
        if buffer.readu8(buf, pos + 4) ~= 0x20 then
            error("unknown method", 0)
        end
        self.method = "HEAD"
        self.pos = pos + 5
    elseif word == PATC then
        if buffer.readu8(buf, pos + 4) ~= 0x48 or buffer.readu8(buf, pos + 5) ~= 0x20 then
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
        return needMore(self, buf, pos)
    end
    local front = buffer.readu8(buf, pos)
    if front == 0x2F then
        local space = findScalar(buf, pos + 1, size, 0x20)
        if space == nil then
            if size - pos > self.max_uri_size then
                error("URI too large", 0)
            end
            return needMore(self, buf, pos)
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
    elseif front == 0x2A then
        if pos + 1 >= size then
            return needMore(self, buf, pos)
        end
        if buffer.readu8(buf, pos + 1) ~= 0x20 then
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
        return needMore(self, buf, pos)
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
    if buffer.readu8(buf, pos + 8) ~= 0x0D or buffer.readu8(buf, pos + 9) ~= 0x0A then
        error("unknown protocol", 0)
    end
    self.pos = pos + 10
    self.stage = "headers"
    return false
end

local function skipWhitespace(buf: buffer, size: number, pos: number): number
    while pos < size do
        local byte = buffer.readu8(buf, pos)
        if byte ~= 0x20 and byte ~= 0x09 then
            break
        end
        pos += 1
    end
    return pos
end

local function requireChunked(encoding: string)
    if not ascii.eqlIgnoreCase(encoding, "chunked") then
        error("unsupported transfer encoding", 0)
    end
end

-- Content-Length wins. Body bytes already in `buf` stay at `self.pos`.
local function prepareForBody(self: Parser)
    local headers = self.headers
    local length = headers["content-length"]
    if length ~= nil then
        local n = tonumber(length)
        if n == nil or not math.isfinite(n) then
            error("invalid content length", 0)
        end
        if n > self.max_body_size then
            error("body too large", 0)
        end
        self.state.body_mode = "length"
        self.state.content_length = n
        self.state.body_got = 0
        if n == 0 then
            self.stage = "done"
            return
        end
        self.body = buffer.create(n)
        self.stage = "body"
        return
    end
    local encoding = headers["transfer-encoding"]
    if encoding == nil then
        self.state.body_mode = "none"
        self.stage = "done"
        return
    end
    requireChunked(encoding)
    self.state.body_mode = "chunked"
    self.state.chunk_remain = nil
    self.state.chunk_len = 0
    self.state.chunk_buf = nil
    self.stage = "body"
end

local function parseHeaders(self: Parser, buf: buffer): boolean
    local headers = self.headers
    local pos = self.pos
    local size = self.size
    while true do
        if pos >= size then
            return needMore(self, buf, pos)
        end
        if buffer.readu8(buf, pos) == 0x0D then
            if pos + 1 >= size then
                return needMore(self, buf, pos)
            end
            if buffer.readu8(buf, pos + 1) ~= 0x0A then
                error("invalid header line", 0)
            end
            self.pos = pos + 2
            prepareForBody(self)
            return false
        end

        local colon: number? = nil
        local i = pos
        while i < size do
            if i - pos > self.max_header_size then
                error("header too large", 0)
            end
            local byte = buffer.readu8(buf, i)
            if isHeaderToken(byte) then
                i += 1
            elseif byte == 0x3A then
                colon = i
                break
            else
                error("invalid header line", 0)
            end
        end
        if colon == nil then
            return needMore(self, buf, pos)
        end

        local value_start = skipWhitespace(buf, size, colon + 1)
        if value_start >= size then
            return needMore(self, buf, pos)
        end
        local value_end: number? = nil
        local j = value_start
        while j < size do
            if j - pos > self.max_header_size then
                error("header too large", 0)
            end
            local byte = buffer.readu8(buf, j)
            if VALID_HEADER_VALUE[byte] then
                j += 1
            elseif byte == 0x0D then
                if j + 1 >= size then
                    return needMore(self, buf, pos)
                end
                if buffer.readu8(buf, j + 1) ~= 0x0A then
                    error("invalid header line", 0)
                end
                value_end = j
                break
            else
                error("invalid header line", 0)
            end
        end
        if value_end == nil then
            return needMore(self, buf, pos)
        end

        local name = string.lower(buffer.readstring(buf, pos, colon - pos))
        local value = buffer.readstring(buf, value_start, value_end - value_start)
        local existing = headers[name]
        if existing == nil then
            if self.state.headers_count >= self.max_headers then
                error("too many headers", 0)
            end
            self.state.headers_count += 1
            headers[name] = value
        else
            if #existing + #value > self.max_header_size then
                error("header too large", 0)
            end
            headers[name] = `{existing},{value}`
        end
        pos = value_end + 2
    end
    error("unreachable", 0)
end

local function appendChunk(self: Parser, buf: buffer, pos: number, count: number)
    if count <= 0 then
        return
    end
    local have = self.state.chunk_len
    local need = have + count
    if need > self.max_body_size then
        error("body too large", 0)
    end
    local dest = self.state.chunk_buf
    if dest == nil or buffer.len(dest) < need then
        local cap = if dest == nil then math.max(need, 64) else buffer.len(dest)
        while cap < need do
            cap *= 2
        end
        if cap > self.max_body_size then
            cap = self.max_body_size
        end
        local grown = buffer.create(cap)
        if dest ~= nil and have > 0 then
            buffer.copy(grown, 0, dest, 0, have)
        end
        self.state.chunk_buf = grown
        dest = grown
    end
    buffer.copy(dest :: buffer, have, buf, pos, count)
    self.state.chunk_len = need
end

local function finishChunked(self: Parser)
    local len = self.state.chunk_len
    local raw = self.state.chunk_buf
    if len == 0 or raw == nil then
        self.body = buffer.create(0)
        return
    end
    if buffer.len(raw) == len then
        self.body = raw
    else
        self.body = mem.slice(raw, 0, len)
    end
end

local function parseChunked(self: Parser, buf: buffer): boolean
    while true do
        local remain = self.state.chunk_remain
        if remain ~= nil then
            local available = self.size - self.pos
            if available <= 0 then
                return needMore(self, buf, self.pos)
            end
            if remain <= 2 then
                local take = math.min(remain, available)
                for i = 0, take - 1 do
                    local byte = buffer.readu8(buf, self.pos + i)
                    local expect = if (remain - i) == 1 then 0x0A else 0x0D
                    if byte ~= expect then
                        error("invalid chunked encoding", 0)
                    end
                end
                self.pos += take
                local left = remain - take
                if left == 0 then
                    self.state.chunk_remain = nil
                else
                    self.state.chunk_remain = left
                end
            else
                local payload = remain - 2
                local take = math.min(payload, available)
                appendChunk(self, buf, self.pos, take)
                self.pos += take
                self.state.chunk_remain = remain - take
            end
        else
            local line_end = findScalar(buf, self.pos, self.size, 0x0A)
            if line_end == nil then
                if self.size - self.pos > self.max_header_size then
                    error("invalid chunked encoding", 0)
                end
                return needMore(self, buf, self.pos)
            end
            if line_end <= self.pos or buffer.readu8(buf, line_end - 1) ~= 0x0D then
                error("invalid chunked encoding", 0)
            end
            local hex = buffer.readstring(buf, self.pos, line_end - 1 - self.pos)
            local chunk_size = tonumber(hex, 16)
            if chunk_size == nil or not math.isfinite(chunk_size) then
                error("invalid chunked encoding", 0)
            end
            if chunk_size == 0 then
                if self.size < line_end + 3 then
                    return needMore(self, buf, self.pos)
                end
                if buffer.readu8(buf, line_end + 1) ~= 0x0D or buffer.readu8(buf, line_end + 2) ~= 0x0A then
                    error("invalid chunked encoding", 0)
                end
                self.pos = line_end + 3
                finishChunked(self)
                self.stage = "done"
                return false
            end
            if self.state.chunk_len + chunk_size > self.max_body_size then
                error("body too large", 0)
            end
            self.state.chunk_remain = chunk_size + 2
            self.pos = line_end + 1
        end
    end
    error("unreachable", 0)
end

local function parseBody(self: Parser, buf: buffer): boolean
    if self.state.body_mode == "chunked" then
        return parseChunked(self, buf)
    end
    local total = self.state.content_length
    if total == nil or self.state.body_got >= total then
        self.stage = "done"
        return false
    end
    local available = self.size - self.pos
    if available <= 0 then
        return needMore(self, buf, self.pos)
    end
    local take = math.min(total - self.state.body_got, available)
    local dest = self.body
    if dest == nil then
        dest = buffer.create(total)
        self.body = dest
    end
    buffer.copy(dest :: buffer, self.state.body_got, buf, self.pos, take)
    self.pos += take
    self.state.body_got += take
    if self.state.body_got < total then
        return needMore(self, buf, self.pos)
    end
    self.stage = "done"
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

-- True when `incoming` finished the request. False when more bytes are required.
function request.parse(self: Parser, incoming: buffer): boolean
    if self.stage == "done" then
        return true
    end
    if buffer.len(incoming) == 0 then
        return false
    end
    local buf = withLeftover(self, incoming)
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
        if parseHeaders(self, buf) then
            return false
        end
    end
    if self.stage == "body" then
        if parseBody(self, buf) then
            return false
        end
    end
    if (self.stage :: any) == "done" then
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
