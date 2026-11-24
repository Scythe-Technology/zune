--!strict
--!optimize 2

local mem = zune.mem
local ascii = zune.ascii
local crypto = zune.crypto

local io = require("@zune/io")
local uri = require("@zune/net/uri")
local head = require("@zune/net/http/head")
local session = require("@zune/net/http/session")
local spec = require("@zune/spec")

local CHUNK = 65536
local HEADER_LIMIT = 65536
local MAX_REDIRECTS = 8

export type FetchResult = {
    status: number,
    hash: string,
    size: number,
    headers: { [string]: string },
    final_url: string,
}

export type FetchOptions = {
    method: string?,
    headers: { [string]: string }?,
    body: (string | buffer)?,
    timeout: number?,
    hash: boolean?,
    on_progress: ((got: number, total: number?) -> ())?,
    should_stop: (() -> boolean)?,
}

local fetch = {}

function fetch.encode(hasher: CryptoHash): string
    local text = hasher:digest("base64")
    text = (string.gsub(text, "+", "-"))
    return (string.gsub(text, "/", "_"))
end

function fetch.hashBuffer(bytes: buffer): string
    local hasher = crypto.createHash("blake3")
    hasher:update(bytes)
    return fetch.encode(hasher)
end

function fetch.hashFile(path: string): string
    local file = io.cwd():openFile(path, { mode = "r" })
    local hasher = crypto.createHash("blake3")
    local reader = io.createPosReader(file)
    local chunk = buffer.create(CHUNK)
    while true do
        local got, err = reader:read(chunk)
        if err then
            file:close()
            error("short read", 0)
        end
        if got == 0 then
            break
        end
        hasher:update(mem.slice(chunk, 0, got))
    end
    file:close()
    return fetch.encode(hasher)
end

function fetch.loadArray(path: string): BufferArray
    local file = io.cwd():openFile(path, { mode = "r" })
    local size = file:size()
    local array = zune.io.createBufferArray({
        limit = math.max(size, 1),
        size = size,
    })
    local reader = io.createPosReader(file)
    local writer = io.createPosWriter(array)
    local moved, err = reader:pipe(writer, size)
    file:close()
    if err or moved ~= size then
        error("short read", 0)
    end
    return array
end

function fetch.arrayToBuffer(array: BufferArray): buffer
    local size = array.len
    local dest = buffer.create(size)
    if size == 0 then
        return dest
    end
    local got, err = array:readPositional(0, dest)
    if err or got ~= size then
        error("short read", 0)
    end
    return dest
end

local function fileUrlPath(url: string): string?
    if not mem.eqlSlice(url, 0, "file://", 0, 7) then
        return nil
    end
    local parsed = uri.parse(url)
    if parsed.path == "" then
        error("file url missing path", 0)
    end
    return parsed.path
end

local function joinUrl(base: string, location: string): string
    if mem.findPos(location, 0, "://") then
        return location
    end
    local parsed = session.parseUrl(base)
    if mem.eqlSlice(location, 0, "/", 0, 1) then
        local scheme = if parsed.tls then "https" else "http"
        local host = parsed.host
        if parsed.port ~= (if parsed.tls then 443 else 80) then
            host = `{host}:{parsed.port}`
        end
        return `{scheme}://{host}{location}`
    end
    local scheme_at = mem.findPos(base, 0, "://")
    assert(scheme_at)
    local path_at = mem.findPos(base, (scheme_at :: number) + 3, "/")
    local origin = if path_at then string.sub(base, 1, path_at + 1) else `{base}/`
    return `{origin}{location}`
end

local httpSpaceSpec = spec.oneOf(9, 10, 11, 12, 13, 32)
local function headerMap(src: buffer, from: number, to: number): { [string]: string }
    local headers: { [string]: string } = {}
    local start = from
    while start < to do
        local stop = mem.findPos(src, start, "\r\n", to - start)
        local line_end = if stop then stop else to
        if line_end > start then
            local colon = mem.findPos(src, start, ":", line_end - start)
            if colon then
                local key = string.lower(if colon > start then buffer.readstring(src, start, colon - start) else "")
                local value_at = colon + 1
                while value_at < line_end and httpSpaceSpec(buffer.readu8(src, value_at)) do
                    value_at += 1
                end
                local value = if value_at < line_end then buffer.readstring(src, value_at, line_end - value_at) else ""
                headers[key] = value
            end
        end
        if not stop then
            break
        end
        start = stop + 2
    end
    return headers
end

local function readHeader(conn: session.Session, should_stop: (() -> boolean)?): (number, { [string]: string }, buffer)
    local acc = zune.io.createBufferArray({ limit = HEADER_LIMIT })
    local chunk = buffer.create(4096)
    while acc.len < HEADER_LIMIT do
        if should_stop and should_stop() then
            error("stopped", 0)
        end
        local got = conn:read(chunk, 0, 4096)
        if got == 0 then
            error("connection closed", 0)
        end
        local wrote, err = acc:append(chunk, 0, got)
        if err or wrote ~= got then
            error("header too large", 0)
        end
        local window = fetch.arrayToBuffer(acc)
        local at = mem.find(window, "\r\n\r\n")
        if at then
            local rest = mem.slice(window, at + 4)
            local line_end = mem.findPos(window, 0, "\r\n", at)
            local status_line = if line_end and line_end > 0
                then buffer.readstring(window, 0, line_end)
                elseif line_end then ""
                elseif at > 0 then buffer.readstring(window, 0, at)
                else ""
            local code = tonumber(string.match(status_line, "HTTP/%d%.%d (%d%d%d)"))
            if not code then
                error("bad status", 0)
            end
            local header_from = if line_end then line_end + 2 else at
            return code, headerMap(window, header_from, at), rest
        end
    end
    error("header too large", 0)
end

local function pump(
    conn: session.Session,
    first: buffer,
    headers: { [string]: string },
    writer: io.Writer,
    hasher: CryptoHash?,
    on_progress: ((got: number, total: number?) -> ())?,
    should_stop: (() -> boolean)?
): number
    local total: number? = nil
    local length = headers["content-length"]
    if length and headers["transfer-encoding"] == nil then
        total = tonumber(length)
    end
    local got = 0
    local function take(bytes: buffer, count: number)
        if count <= 0 then
            return
        end
        if writer:writeAll(bytes, 0, count) then
            error("write failed", 0)
        end
        if hasher then
            hasher:update(mem.slice(bytes, 0, count))
        end
        got += count
        if on_progress then
            on_progress(got, total)
        end
    end

    local pending = first
    if headers["transfer-encoding"] and ascii.findIgnoreCase(headers["transfer-encoding"], "chunked") then
        local hold = pending
        pending = buffer.create(0)
        local function readExact(n: number): buffer
            local stop = should_stop
            local out = buffer.create(n)
            local filled = 0
            if buffer.len(hold) > 0 then
                local take_n = math.min(n, buffer.len(hold))
                buffer.copy(out, 0, hold, 0, take_n)
                hold = mem.slice(hold, take_n, buffer.len(hold) - take_n)
                filled = take_n
            end
            while filled < n do
                if stop and stop() then
                    error("stopped", 0)
                end
                local buf = buffer.create(math.min(CHUNK, n - filled))
                local got_n = conn:read(buf, 0, buffer.len(buf))
                if got_n == 0 then
                    error("connection closed", 0)
                end
                buffer.copy(out, filled, buf, 0, got_n)
                filled += got_n
            end
            return out
        end
        while true do
            local nl = mem.findPos(hold, 0, "\n")
            while not nl do
                local buf = buffer.create(64)
                local n = conn:read(buf, 0, 64)
                if n == 0 then
                    error("connection closed", 0)
                end
                local hold_len = buffer.len(hold)
                local grown = buffer.create(hold_len + n)
                if hold_len > 0 then
                    buffer.copy(grown, 0, hold, 0, hold_len)
                end
                buffer.copy(grown, hold_len, buf, 0, n)
                hold = grown
                nl = mem.findPos(hold, 0, "\n")
            end
            if not nl then
                error("bad chunk", 0)
            end
            local end_at = nl
            if end_at > 0 and buffer.readu8(hold, end_at - 1) == 13 then
                end_at -= 1
            end
            local semi = if end_at > 0 then mem.findPos(hold, 0, ";", end_at) else nil
            if semi then
                end_at = semi
            end
            local text = if end_at > 0 then buffer.readstring(hold, 0, end_at) else ""
            local size = tonumber((string.gsub(text, "\r", "")), 16)
            if not size then
                error("bad chunk", 0)
            end
            hold = mem.slice(hold, nl + 1)
            if size == 0 then
                break
            end
            local data = readExact(size)
            take(data, size)
            local crlf = readExact(2)
            if buffer.readu8(crlf, 0) ~= 13 or buffer.readu8(crlf, 1) ~= 10 then
                error("bad chunk", 0)
            end
        end
        return got
    end

    if total then
        local left = total
        if buffer.len(pending) > 0 then
            local n = math.min(left, buffer.len(pending))
            take(pending, n)
            left -= n
            pending = buffer.create(0)
        end
        while left > 0 do
            local buf = buffer.create(math.min(CHUNK, left))
            if should_stop and should_stop() then
                error("stopped", 0)
            end
            local n = conn:read(buf, 0, buffer.len(buf))
            if n == 0 then
                error("connection closed", 0)
            end
            take(buf, n)
            left -= n
        end
        return got
    end

    if buffer.len(pending) > 0 then
        take(pending, buffer.len(pending))
        pending = buffer.create(0)
    end
    while true do
        local buf = buffer.create(CHUNK)
        if should_stop and should_stop() then
            error("stopped", 0)
        end
        local n = conn:read(buf, 0, CHUNK)
        if n == 0 then
            break
        end
        take(buf, n)
    end
    return got
end

local redirectSpec = spec.oneOf(301, 302, 303, 307, 308)
local function requestOnce(
    url: string,
    options: FetchOptions,
    file: File,
    hasher: CryptoHash?
): (number, { [string]: string }, string)
    local parsed = session.parseUrl(url)
    local method = options.method or "GET"
    local headers = options.headers or {} :: { [string]: string }
    local lines = { `{method} {parsed.target} HTTP/1.1` }
    local saw_host, saw_agent = false, false
    for key, value in headers do
        if ascii.eqlIgnoreCase(key, "host") then
            saw_host = true
        elseif ascii.eqlIgnoreCase(key, "user-agent") then
            saw_agent = true
        end
        table.insert(lines, `{key}: {value}`)
    end
    if not saw_host then
        table.insert(lines, `Host: {head.host(parsed.host, parsed.port, if parsed.tls then 443 else 80)}`)
    end
    if not saw_agent then
        table.insert(lines, `User-Agent: {session.user_agent}`)
    end
    table.insert(lines, "Connection: close")
    local body = options.body
    if body then
        table.insert(lines, `Content-Length: {head.bytes(body)}`)
    end
    local text = `{table.concat(lines, "\r\n")}\r\n\r\n`
    local conn = session.open(parsed, options.timeout or 300)
    local ok, err = pcall(function()
        conn:write(text)
        if body then
            conn:write(body)
        end
    end)
    if not ok then
        conn:close()
        error(tostring(err), 0)
    end
    local code, response_headers, rest = readHeader(conn, options.should_stop)
    if redirectSpec(code) then
        conn:close()
        return code, response_headers, url
    end
    pump(conn, rest, response_headers, io.createPosWriter(file), hasher, options.on_progress, options.should_stop)
    conn:close()
    if code < 200 or code >= 300 then
        error(`http {code}`, 0)
    end
    return code, response_headers, url
end

local keepMethodSpec = spec.oneOf(307, 308)
local headerSpec = spec.strict(spec.struct({
    [spec.string] = spec.string,
}))
local optionsSpec = spec.struct({
    method = spec.optional(spec.string),
    headers = spec.optional(headerSpec),
    body = spec.optional(spec.union(spec.string, spec.buffer)),
    timeout = spec.optional(spec.number),
    hash = spec.optional(spec.boolean),
    on_progress = spec.optional(spec.fn),
    should_stop = spec.optional(spec.fn),
})
function fetch.toFile(url: string, path: string, options: FetchOptions?): FetchResult
    if options ~= nil then
        local ok, reason = optionsSpec(options)
        if not ok then
            error(reason, 0)
        end
    end
    local opts = options or {} :: FetchOptions
    local local_path = fileUrlPath(url)
    if local_path then
        local src = io.cwd():openFile(local_path, { mode = "r" })
        local dest = io.cwd():createFile(path, { truncate = true })
        local hasher = if opts.hash == false then nil else crypto.createHash("blake3")
        local size = src:size()
        local reader = io.createPosReader(src)
        local writer = io.createPosWriter(dest)
        local chunk = buffer.create(CHUNK)
        local offset = 0
        while offset < size do
            if opts.should_stop and opts.should_stop() then
                src:close()
                dest:close()
                error("stopped", 0)
            end
            local want = math.min(CHUNK, size - offset)
            local got, err = reader:read(chunk, 0, want)
            if err or got == 0 then
                src:close()
                dest:close()
                error("short read", 0)
            end
            if writer:writeAll(chunk, 0, got) then
                error("write failed", 0)
            end
            if hasher then
                hasher:update(mem.slice(chunk, 0, got))
            end
            offset += got
            if opts.on_progress then
                opts.on_progress(offset, size)
            end
        end
        src:close()
        dest:close()
        return {
            status = 200,
            hash = if hasher then fetch.encode(hasher) else "",
            size = size,
            headers = {},
            final_url = url,
        }
    end

    local current = url
    local method = opts.method or "GET"
    local body = opts.body
    for _ = 1, MAX_REDIRECTS do
        local parent = string.match(path, "^(.*)/[^/]+$")
        if parent and parent ~= "" then
            pcall(function()
                io.cwd():createDirPath(parent)
            end)
        end
        local file = io.cwd():createFile(path, { truncate = true })
        local hasher = if opts.hash == false then nil else crypto.createHash("blake3")
        local round: FetchOptions = {
            method = method,
            headers = opts.headers,
            body = body,
            timeout = opts.timeout,
            on_progress = opts.on_progress,
            should_stop = opts.should_stop,
        }
        local ok, code, headers = pcall(requestOnce, current, round, file, hasher)
        file:close()
        if not ok then
            pcall(function()
                io.cwd():deleteFile(path)
            end)
            error(tostring(code), 0)
        end
        if redirectSpec(code) then
            local location = headers["location"]
            if not location or location == "" then
                error("redirect missing location", 0)
            end
            current = joinUrl(current, location)
            if not keepMethodSpec(code) then
                method = "GET"
                body = nil
            end
            pcall(function()
                io.cwd():deleteFile(path)
            end)
            continue
        end
        local size = 0
        pcall(function()
            local opened = io.cwd():openFile(path, { mode = "r" })
            size = opened:size()
            opened:close()
        end)
        return {
            status = code,
            hash = if hasher then fetch.encode(hasher) else "",
            size = size,
            headers = headers,
            final_url = current,
        }
    end
    error("too many redirects", 0)
end

return fetch
