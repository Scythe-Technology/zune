--!strict
--!optimize 2

local mem = zune.mem
local ascii = zune.ascii

local parse = {}

export type State = {
    leftover: buffer?,
    headers_count: number,
    body_mode: ("none" | "length" | "chunked")?,
    content_length: number?,
    body_got: number,
    chunk_remain: number?,
    chunk_len: number,
    chunk_buf: buffer?,
}

export type Parser = {
    pos: number,
    size: number,
    stage: any,
    headers: { [string]: string },
    body: buffer?,
    max_body_size: number,
    max_header_size: number,
    max_headers: number,
    state: State,
}

local VALUE: { [number]: boolean } = {}
VALUE[0x09] = true -- '\t'
VALUE[0x20] = true -- ' '
for i = 0x21, 0x7E do -- '!', '~'
    VALUE[i] = true
end

function parse.u32(text: string): number
    return buffer.readu32(buffer.fromstring(text), 0)
end

parse.HTTP = parse.u32("HTTP")
parse.V1P0 = parse.u32("/1.0")
parse.V1P1 = parse.u32("/1.1")

function parse.token(byte: number): boolean
    return (byte >= 0x41 and byte <= 0x5A) -- 'A', 'Z'
        or (byte >= 0x61 and byte <= 0x7A) -- 'a', 'z'
        or (byte >= 0x30 and byte <= 0x39) -- '0', '9'
        or byte == 0x2D -- '-'
        or byte == 0x5F -- '_'
end

local function join(left: buffer, right: buffer): buffer
    local left_len = buffer.len(left)
    local right_len = buffer.len(right)
    local out = buffer.create(left_len + right_len)
    buffer.copy(out, 0, left, 0, left_len)
    buffer.copy(out, left_len, right, 0, right_len)
    return out
end

function parse.withLeftover(self: Parser, target: buffer): buffer
    local left = self.state.leftover
    if left and self.pos < self.size then
        local joined = join(mem.slice(left, self.pos, self.size - self.pos), target)
        self.state.leftover = nil
        return joined
    end
    self.state.leftover = nil
    return target
end

function parse.needMore(self: Parser, buf: buffer, pos: number): boolean
    self.pos = pos
    self.state.leftover = buf
    return true
end

function parse.find(buf: buffer, pos: number, size: number, byte: number): number?
    if pos >= size then
        return nil
    end
    local found = mem.findScalarPos(buf, pos, byte)
    if not found or found >= size then
        return nil
    end
    return found
end

function parse.crlf(buf: buffer, pos: number, size: number): number?
    if pos >= size then
        return nil
    end
    local found = mem.findPos(buf, pos, "\r\n")
    if not found or found + 1 >= size then
        return nil
    end
    return found
end

local function skipSpace(buf: buffer, size: number, pos: number): number
    while pos < size do
        local byte = buffer.readu8(buf, pos)
        if byte ~= 0x20 and byte ~= 0x09 then -- ' ', '\t'
            break
        end
        pos += 1
    end
    return pos
end

function parse.prepare(self: Parser)
    local headers = self.headers
    local length = headers["content-length"]
    if length then
        local n = tonumber(length)
        if not n or not math.isfinite(n) then
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
    if not encoding then
        self.state.body_mode = "none"
        self.stage = "done"
        return
    end
    if not ascii.eqlIgnoreCase(encoding, "chunked") then
        error("unsupported transfer encoding", 0)
    end
    self.state.body_mode = "chunked"
    self.state.chunk_remain = nil
    self.state.chunk_len = 0
    self.state.chunk_buf = nil
    self.stage = "body"
end

local function put(self: Parser, name: string, value: string, count_all: boolean)
    local headers = self.headers
    local existing = headers[name]
    if count_all then
        if self.state.headers_count >= self.max_headers then
            error("too many headers", 0)
        end
        if existing then
            if #existing + #value > self.max_header_size then
                error("header too large", 0)
            end
            headers[name] = `{existing},{value}`
        else
            headers[name] = value
        end
        self.state.headers_count += 1
        return
    end
    if not existing then
        if self.state.headers_count >= self.max_headers then
            error("too many headers", 0)
        end
        self.state.headers_count += 1
        headers[name] = value
        return
    end
    if #existing + #value > self.max_header_size then
        error("header too large", 0)
    end
    headers[name] = `{existing},{value}`
end

function parse.headers(self: Parser, buf: buffer, count_all: boolean): boolean
    local pos = self.pos
    local size = self.size
    while true do
        if pos >= size then
            return parse.needMore(self, buf, pos)
        end
        if buffer.readu8(buf, pos) == 0x0D then -- '\r'
            if pos + 1 >= size then
                return parse.needMore(self, buf, pos)
            end
            if buffer.readu8(buf, pos + 1) ~= 0x0A then -- '\n'
                error("invalid header line", 0)
            end
            self.pos = pos + 2
            parse.prepare(self)
            return false
        end

        local colon: number? = nil
        local i = pos
        while i < size do
            if i - pos > self.max_header_size then
                error("header too large", 0)
            end
            local byte = buffer.readu8(buf, i)
            if parse.token(byte) then
                i += 1
            elseif byte == 0x3A then -- ':'
                colon = i
                break
            else
                error("invalid header line", 0)
            end
        end
        if not colon then
            return parse.needMore(self, buf, pos)
        end

        local value_start = skipSpace(buf, size, colon + 1)
        if value_start >= size then
            return parse.needMore(self, buf, pos)
        end
        local value_end: number? = nil
        local j = value_start
        while j < size do
            if j - pos > self.max_header_size then
                error("header too large", 0)
            end
            local byte = buffer.readu8(buf, j)
            if VALUE[byte] then
                j += 1
            elseif byte == 0x0D then -- '\r'
                if j + 1 >= size then
                    return parse.needMore(self, buf, pos)
                end
                if buffer.readu8(buf, j + 1) ~= 0x0A then -- '\n'
                    error("invalid header line", 0)
                end
                value_end = j
                break
            else
                error("invalid header line", 0)
            end
        end
        if not value_end then
            return parse.needMore(self, buf, pos)
        end

        local name = string.lower(buffer.readstring(buf, pos, colon - pos))
        local value = buffer.readstring(buf, value_start, value_end - value_start)
        put(self, name, value, count_all)
        pos = value_end + 2
    end
    error("unreachable", 0)
end

local function append(self: Parser, buf: buffer, pos: number, count: number)
    if count <= 0 then
        return
    end
    local have = self.state.chunk_len
    local need = have + count
    if need > self.max_body_size then
        error("body too large", 0)
    end
    local dest = self.state.chunk_buf
    if not dest or buffer.len(dest) < need then
        local cap = if not dest then math.max(need, 64) else buffer.len(dest)
        while cap < need do
            cap *= 2
        end
        if cap > self.max_body_size then
            cap = self.max_body_size
        end
        local grown = buffer.create(cap)
        if dest and have > 0 then
            buffer.copy(grown, 0, dest, 0, have)
        end
        self.state.chunk_buf = grown
        dest = grown
    end
    buffer.copy(dest :: buffer, have, buf, pos, count)
    self.state.chunk_len = need
end

local function finishChunks(self: Parser)
    local len = self.state.chunk_len
    local raw = self.state.chunk_buf
    if len == 0 or not raw then
        self.body = buffer.create(0)
        return
    end
    self.body = mem.slice(raw, 0, len)
end

local function chunks(self: Parser, buf: buffer): boolean
    while true do
        local remain = self.state.chunk_remain
        if remain then
            local available = self.size - self.pos
            if available <= 0 then
                return parse.needMore(self, buf, self.pos)
            end
            if remain <= 2 then
                local take = math.min(remain, available)
                for i = 0, take - 1 do
                    local byte = buffer.readu8(buf, self.pos + i)
                    local expect = if (remain - i) == 1 then 0x0A else 0x0D -- '\n', '\r'
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
                append(self, buf, self.pos, take)
                self.pos += take
                self.state.chunk_remain = remain - take
            end
        else
            local line_end = parse.find(buf, self.pos, self.size, 0x0A) -- '\n'
            if not line_end then
                if self.size - self.pos > self.max_header_size then
                    error("invalid chunked encoding", 0)
                end
                return parse.needMore(self, buf, self.pos)
            end
            if line_end <= self.pos or buffer.readu8(buf, line_end - 1) ~= 0x0D then -- '\r'
                error("invalid chunked encoding", 0)
            end
            local hex = buffer.readstring(buf, self.pos, line_end - 1 - self.pos)
            local chunk_size = tonumber(hex, 16)
            if not chunk_size or not math.isfinite(chunk_size) then
                error("invalid chunked encoding", 0)
            end
            if chunk_size == 0 then
                if self.size < line_end + 3 then
                    return parse.needMore(self, buf, self.pos)
                end
                if buffer.readu8(buf, line_end + 1) ~= 0x0D or buffer.readu8(buf, line_end + 2) ~= 0x0A then -- '\r', '\n'
                    error("invalid chunked encoding", 0)
                end
                self.pos = line_end + 3
                finishChunks(self)
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

function parse.body(self: Parser, buf: buffer): boolean
    if self.state.body_mode == "chunked" then
        return chunks(self, buf)
    end
    local total = self.state.content_length
    if not total or self.state.body_got >= total then
        self.stage = "done"
        return false
    end
    local available = self.size - self.pos
    if available <= 0 then
        return parse.needMore(self, buf, self.pos)
    end
    local take = math.min(total - self.state.body_got, available)
    local dest = self.body
    if not dest then
        dest = buffer.create(total)
        self.body = dest
    end
    buffer.copy(dest :: buffer, self.state.body_got, buf, self.pos, take)
    self.pos += take
    self.state.body_got += take
    if self.state.body_got < total then
        return parse.needMore(self, buf, self.pos)
    end
    self.stage = "done"
    return false
end

return parse
