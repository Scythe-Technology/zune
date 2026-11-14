--!strict
--!optimize 2

local io = zune.io
local mem = zune.mem
local task = zune.task
local serde = zune.serde
local crypto = zune.crypto

local session = require("./session")
local Response = require("./response")

local RECV_CHUNK = 8192
local LARGE = 8192
local MAX_MESSAGE = 8 * 1024 * 1024
local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local OP_CONT = 0
local OP_TEXT = 1
local OP_BIN = 2
local OP_CLOSE = 8
local OP_PING = 9
local OP_PONG = 10

local BLOCKED: { [string]: string } = {
    ["sec-websocket-protocol"] = "sec-websocket-protocol must be set in protocols, not headers",
    ["sec-websocket-version"] = "sec-websocket-version cannot be set",
    ["sec-websocket-key"] = "sec-websocket-key cannot be set",
    ["upgrade"] = "upgrade cannot be set",
    ["connection"] = "connection cannot be set",
    ["content-length"] = "content-length cannot be set",
}

export type Handshake = {
    status_code: number,
    reason: string,
    headers: { [string]: string },
}

export type Socket = {
    send: (self: Socket, message: string | buffer) -> (),
    close: (self: Socket, code: number?) -> (),
    isConnected: (self: Socket) -> boolean,
}

export type ConnectOptions = {
    timeout: number?,
    headers: { [string]: string }?,
    protocols: { string }?,
    max_message: number?,
    tls: {
        host: string?,
        ca: TlsCertBundle?,
    }?,
    accept: ((socket: Socket, response: Handshake) -> boolean)?,
    message: ((socket: Socket, message: string | buffer) -> ())?,
    close: ((socket: Socket, code: number) -> ())?,
    error: ((socket: Socket, scope: string, err: string) -> ())?,
}

export type UpgradeRequest = {
    method: string,
    path: string,
    headers: { [string]: string },
    body: buffer?,
}

export type ServerHandlers = {
    upgrade: ((request: UpgradeRequest) -> boolean)?,
    open: ((socket: Socket) -> ())?,
    message: ((socket: Socket, message: string | buffer) -> ())?,
    close: ((socket: Socket, code: number) -> ())?,
}

type Outgoing = {
    opcode: number,
    payload: buffer,
    close: boolean,
}

type Stage = "opening" | "active" | "closing" | "closed"

type PeerOpts = {
    mask_out: boolean,
    mask_in: boolean,
    max_message: number,
    on_message: ((socket: Socket, message: string | buffer) -> ())?,
    on_close: ((socket: Socket, code: number) -> ())?,
    on_error: ((socket: Socket, scope: string, err: string) -> ())?,
}

type Peer = {
    conn: session.Session,
    socket: Socket,
    mask_out: boolean,
    max_message: number,
    on_message: ((socket: Socket, message: string | buffer) -> ())?,
    on_close: ((socket: Socket, code: number) -> ())?,
    on_error: ((socket: Socket, scope: string, err: string) -> ())?,

    stage: Stage,
    close_code: number,
    failed: boolean,
    remote_closed: boolean,
    close_queued: boolean,
    close_written: boolean,
    close_timer: thread?,
    read_thread: thread?,
    sending: boolean,
    queue: { Outgoing },
    queue_head: number,
    queue_tail: number,
}

type Phase = "header" | "length" | "mask" | "payload"

type Reader = {
    mask_in: boolean,
    phase: Phase,
    filled: number,
    mask: { number },
    unmask: buffer?,
    header_byte: number,
    length_byte: number,
    extended_size: number,
    extended: buffer,
    opcode: number,
    is_final: boolean,
    payload_size: number,
    payload_offset: number,
    payload: buffer?,
    payload_large: BufferArray?,
    message_opcode: number?,
    message_size: number,
    message: buffer?,
    message_large: BufferArray?,
}

local function acceptValue(key: string): string
    local hasher = crypto.createHash("sha1")
    hasher:update(key)
    hasher:update(GUID)
    return hasher:digest("base64") :: string
end

local function closePayload(code: number): buffer
    local out = buffer.create(2)
    buffer.writeu8(out, 0, bit32.rshift(code, 8))
    buffer.writeu8(out, 1, bit32.band(code, 0xFF))
    return out
end

local function maskCopy(dest: buffer, dest_off: number, src: buffer, src_off: number, count: number, key: { number })
    for i = 0, count - 1 do
        local at = src_off + i
        buffer.writeu8(dest, dest_off + i, bit32.bxor(buffer.readu8(src, at), key[(at % 4) + 1]))
    end
end

local function writeFrame(conn: session.Session, opcode: number, payload: buffer, plen: number, do_mask: boolean)
    local len7 = if plen < 126 then plen elseif plen <= 65535 then 126 else 127
    local ext = if len7 == 126 then 2 elseif len7 == 127 then 8 else 0
    local mask_len = if do_mask then 4 else 0
    local header_len = 2 + ext + mask_len
    local header = buffer.create(header_len)
    buffer.writeu8(header, 0, opcode + 0x80)
    buffer.writeu8(header, 1, if do_mask then len7 + 0x80 else len7)

    local pos = 2
    if len7 == 126 then
        buffer.writeu8(header, pos, bit32.rshift(plen, 8))
        buffer.writeu8(header, pos + 1, bit32.band(plen, 0xFF))
        pos += 2
    elseif len7 == 127 then
        local n = plen
        for i = 7, 0, -1 do
            buffer.writeu8(header, pos + i, n % 256)
            n = math.floor(n / 256)
        end
        pos += 8
    end

    local key: { number }? = nil
    if do_mask then
        local mask = buffer.create(4)
        crypto.random.fill(mask, 0, 4)
        key = {
            buffer.readu8(mask, 0),
            buffer.readu8(mask, 1),
            buffer.readu8(mask, 2),
            buffer.readu8(mask, 3),
        }
        buffer.copy(header, pos, mask, 0, 4)
    end

    if plen <= LARGE then
        local out = buffer.create(header_len + plen)
        buffer.copy(out, 0, header, 0, header_len)
        if plen > 0 then
            if key ~= nil then
                maskCopy(out, header_len, payload, 0, plen, key)
            else
                buffer.copy(out, header_len, payload, 0, plen)
            end
        end
        conn:write(out)
        return
    end

    conn:write(header)
    local off = 0
    while off < plen do
        local count = math.min(LARGE, plen - off)
        local chunk = buffer.create(count)
        if key ~= nil then
            maskCopy(chunk, 0, payload, off, count, key)
        else
            buffer.copy(chunk, 0, payload, off, count)
        end
        conn:write(chunk)
        off += count
    end
end

local function hostHeader(host: string): string
    if string.find(host, ":", 1, true) ~= nil then
        return `[{host}]`
    end
    return host
end

local function optionalFunction(options: ConnectOptions, field: string): ((...any) -> ...any)?
    local value = (options :: any)[field]
    if value == nil then
        return nil
    end
    if type(value) ~= "function" then
        error(`{field} must be a function`, 0)
    end
    return value
end

local function timeoutSeconds(opts: ConnectOptions): number?
    local timeout_seconds: number? = 30
    if opts.timeout == nil then
        return timeout_seconds
    end
    if type(opts.timeout) ~= "number" then
        error("timeout must be a number", 0)
    end
    if opts.timeout == 0 then
        error("timeout cannot be 0", 0)
    end
    if opts.timeout < 0 then
        return nil
    end
    return opts.timeout
end

local function messageLimit(opts: ConnectOptions): number
    if opts.max_message == nil then
        return MAX_MESSAGE
    end
    if type(opts.max_message) ~= "number" or opts.max_message < 0 then
        error("invalid limit", 0)
    end
    return math.floor(opts.max_message)
end

local function headerLines(headers: { [string]: string }?): ({ string }, boolean, boolean)
    local host_handled = false
    local user_agent_handled = false
    local lines: { string } = {}
    if headers == nil then
        return lines, host_handled, user_agent_handled
    end
    if type(headers) ~= "table" then
        error("headers must be a table", 0)
    end
    for key, value in headers do
        if type(key) ~= "string" then
            error(`header index is not a string (got {type(key)})`, 0)
        end
        if type(value) ~= "string" then
            error(`header value must be a string (got {type(value)})`, 0)
        end
        local lower = string.lower(key)
        local reason = BLOCKED[lower]
        if reason ~= nil then
            error(reason, 0)
        end
        if lower == "host" then
            host_handled = true
        elseif lower == "user-agent" then
            user_agent_handled = true
        end
        if #value > 0 then
            table.insert(lines, `{key}: {value}`)
        end
    end
    return lines, host_handled, user_agent_handled
end

local function protocolHeader(protocols: { string }?): string?
    if protocols == nil then
        return nil
    end
    if type(protocols) ~= "table" then
        error("protocols must be a table", 0)
    end
    local parts: { string } = {}
    local index = 1
    while protocols[index] ~= nil do
        local value = protocols[index]
        if type(value) ~= "string" then
            error(`protocol value is not a string (got {type(value)})`, 0)
        end
        table.insert(parts, value)
        index += 1
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, ", ")
end

local function upgradeHead(
    parsed: session.ParsedUrl,
    key: string,
    extra: { string },
    host_handled: boolean,
    user_agent_handled: boolean,
    protocols: string?
): buffer
    local lines: { string } = { `GET {parsed.target} HTTP/1.1` }
    if not host_handled then
        table.insert(lines, `Host: {hostHeader(parsed.host)}`)
    end
    for _, line in extra do
        table.insert(lines, line)
    end
    table.insert(lines, "Upgrade: websocket")
    table.insert(lines, "Connection: keep-alive, Upgrade")
    table.insert(lines, "Sec-WebSocket-Version: 13")
    table.insert(lines, `Sec-WebSocket-Key: {key}`)
    if protocols ~= nil then
        table.insert(lines, `Sec-WebSocket-Protocol: {protocols}`)
    end
    if not user_agent_handled then
        table.insert(lines, `User-Agent: {session.user_agent}`)
    end
    return buffer.fromstring(table.concat(lines, "\r\n") .. "\r\n\r\n")
end

local function readUpgrade(conn: session.Session): (Handshake, buffer?)
    local parser = Response.newParser({ body = 0 })
    local recv_buf = buffer.create(RECV_CHUNK)
    while true do
        local n = conn:read(recv_buf, 0, RECV_CHUNK)
        if n == 0 then
            error("connection closed", 0)
        end
        local ok, done = pcall(Response.parse, parser, mem.slice(recv_buf, 0, n))
        if not ok then
            if (done :: any) == "body too large" and parser.status ~= nil and parser.status ~= 101 then
                return {
                    status_code = parser.status,
                    reason = parser.reason or "",
                    headers = parser.headers,
                },
                    nil
            end
            error(done)
        end
        if done == true then
            break
        end
    end
    local status = parser.status
    if status == nil then
        error("connection closed", 0)
    end
    return {
        status_code = status,
        reason = parser.reason or "",
        headers = parser.headers,
    },
        parser.spill
end

local function emit(peer: Peer, scope: string, err: string)
    local on_error = peer.on_error
    if on_error == nil then
        return
    end
    pcall(on_error, peer.socket, scope, err)
end

local function finish(peer: Peer)
    if peer.stage == "closed" then
        return
    end
    peer.stage = "closed"
    if peer.close_timer then
        pcall(task.cancel, peer.close_timer)
        peer.close_timer = nil
    end
    peer.conn:close()
    local on_close = peer.on_close
    if on_close ~= nil then
        pcall(on_close, peer.socket, peer.close_code)
    end
    local waiting = peer.read_thread
    peer.read_thread = nil
    if waiting ~= nil then
        task.spawn(waiting)
    end
end

local function pump(peer: Peer)
    while peer.queue_head <= peer.queue_tail do
        local item = peer.queue[peer.queue_head]
        peer.queue[peer.queue_head] = nil :: any
        peer.queue_head += 1
        local wrote, err =
            pcall(writeFrame, peer.conn, item.opcode, item.payload, buffer.len(item.payload), peer.mask_out)
        if not wrote then
            peer.sending = false
            if peer.stage ~= "closed" then
                emit(peer, "send", tostring(err))
                if peer.stage == "active" then
                    peer.close_code = 1006
                end
                finish(peer)
            end
            return
        end
        if item.close then
            peer.close_written = true
            peer.sending = false
            if peer.remote_closed or peer.failed then
                finish(peer)
            else
                peer.close_timer = task.delay(3, function()
                    peer.close_timer = nil
                    if peer.stage ~= "closed" then
                        finish(peer)
                    end
                end)
            end
            return
        end
    end
    peer.sending = false
    if peer.queue_head <= peer.queue_tail then
        peer.sending = true
        task.spawn(pump, peer)
    end
end

local function enqueue(peer: Peer, item: Outgoing)
    if peer.close_written or peer.stage == "closed" then
        return
    end
    peer.queue_tail += 1
    peer.queue[peer.queue_tail] = item
    if peer.sending then
        return
    end
    peer.sending = true
    task.spawn(pump, peer)
end

local function sendMessage(peer: Peer, message: string | buffer)
    if peer.stage ~= "active" then
        error("closed", 0)
    end
    local payload: buffer
    local opcode: number
    local plen: number
    if type(message) == "string" then
        payload = buffer.fromstring(message)
        plen = #message
        opcode = OP_TEXT
    elseif type(message) == "buffer" then
        plen = buffer.len(message)
        payload = buffer.create(plen)
        if plen > 0 then
            buffer.copy(payload, 0, message, 0, plen)
        end
        opcode = OP_BIN
    else
        error("message must be a string or buffer", 0)
    end
    if plen > peer.max_message then
        error("message too large", 0)
    end
    enqueue(peer, {
        opcode = opcode,
        payload = payload,
        close = false,
    })
end

local function sendClose(peer: Peer, close_code: number?)
    if peer.stage ~= "active" then
        return
    end
    local chosen = if close_code == nil then 1000 else close_code
    if type(chosen) ~= "number" or chosen ~= math.floor(chosen) or chosen < 0 or chosen > 65535 then
        error("invalid close code, cannot be used", 0)
    end
    if chosen == 1005 or chosen == 1006 or chosen == 1015 then
        error("invalid close code, cannot be used", 0)
    end
    peer.stage = "closing"
    peer.close_code = chosen
    peer.close_queued = true
    enqueue(peer, {
        opcode = OP_CLOSE,
        payload = closePayload(chosen),
        close = true,
    })
end

local function failProtocol(peer: Peer, scope: string, name: string, close_code: number)
    if peer.failed or peer.stage == "closed" then
        return
    end
    peer.failed = true
    peer.close_code = close_code
    emit(peer, scope, name)
    if peer.close_written then
        finish(peer)
        return
    end
    if not peer.close_queued then
        peer.stage = "closing"
        peer.close_queued = true
        peer.remote_closed = true
        enqueue(peer, {
            opcode = OP_CLOSE,
            payload = closePayload(close_code),
            close = true,
        })
    end
end

local function deliver(peer: Peer, op: number, payload: buffer)
    if peer.stage ~= "active" or peer.on_message == nil then
        return
    end
    local on_message = peer.on_message
    if op == OP_TEXT then
        pcall(on_message, peer.socket, buffer.tostring(payload))
    else
        pcall(on_message, peer.socket, payload)
    end
end

local function readBig(peer: Peer, src: BufferArray, n: number): buffer
    local out = buffer.create(n)
    if n == 0 then
        return out
    end
    src:seekTo(0)
    local got = src:read(out, 0, n)
    if got ~= n then
        failProtocol(peer, "protocol", "message too large", 1009)
    end
    return out
end

local function writeExact(peer: Peer, dest: BufferArray, src: buffer, count: number): boolean
    local wrote = dest:write(src, 0, count)
    if wrote ~= count then
        failProtocol(peer, "protocol", "message too large", 1009)
        return false
    end
    return true
end

local function writeIncoming(peer: Peer, dest: BufferArray, src: buffer, src_off: number, count: number): boolean
    local wrote, werr = dest:write(src, src_off, count)
    if wrote ~= count then
        failProtocol(peer, "protocol", if type(werr) == "string" then werr else "message too large", 1009)
        return false
    end
    return true
end

local function appendFragment(
    peer: Peer,
    reader: Reader,
    piece: buffer?,
    piece_large: BufferArray?,
    piece_len: number
): boolean
    if reader.message_size == 0 and piece_large ~= nil then
        reader.message_large = piece_large
        reader.message_size = piece_len
        return true
    end

    local message_large = reader.message_large
    if message_large ~= nil then
        if piece_large ~= nil then
            local bytes = readBig(peer, piece_large, piece_len)
            if peer.failed or not writeExact(peer, message_large, bytes, piece_len) then
                return false
            end
        elseif piece ~= nil and piece_len > 0 then
            if not writeExact(peer, message_large, piece, piece_len) then
                return false
            end
        end
        reader.message_size += piece_len
        return true
    end

    if piece_large ~= nil or reader.message_size + piece_len > LARGE then
        local grown = io.createBufferArray({
            size = reader.message_size + piece_len,
            limit = peer.max_message,
        })
        local message = reader.message
        if message ~= nil and reader.message_size > 0 then
            if not writeExact(peer, grown, message, reader.message_size) then
                return false
            end
        end
        if piece_large ~= nil then
            local bytes = readBig(peer, piece_large, piece_len)
            if peer.failed or not writeExact(peer, grown, bytes, piece_len) then
                return false
            end
        elseif piece ~= nil and piece_len > 0 then
            if not writeExact(peer, grown, piece, piece_len) then
                return false
            end
        end
        reader.message_large = grown
        reader.message = nil
        reader.message_size += piece_len
        return true
    end

    local grown = buffer.create(reader.message_size + piece_len)
    local message = reader.message
    if message ~= nil and reader.message_size > 0 then
        buffer.copy(grown, 0, message, 0, reader.message_size)
    end
    if piece ~= nil and piece_len > 0 then
        buffer.copy(grown, reader.message_size, piece, 0, piece_len)
    end
    reader.message = grown
    reader.message_size += piece_len
    return true
end

local function onFrame(peer: Peer, reader: Reader): boolean
    local piece = reader.payload
    local piece_large = reader.payload_large
    local piece_len = reader.payload_size
    local opcode = reader.opcode
    reader.payload = nil
    reader.payload_large = nil
    reader.phase = "header"
    reader.filled = 0

    if opcode >= 8 then
        if opcode == OP_PING then
            if peer.stage == "active" or peer.stage == "closing" then
                enqueue(peer, {
                    opcode = OP_PONG,
                    payload = piece or buffer.create(0),
                    close = false,
                })
            end
        elseif opcode == OP_CLOSE then
            if piece_len == 1 then
                failProtocol(peer, "protocol", "InvalidClose", 1002)
                return false
            end
            local remote_code = 1000
            if piece_len >= 2 and piece ~= nil then
                remote_code = buffer.readu8(piece, 0) * 256 + buffer.readu8(piece, 1)
            end
            peer.close_code = remote_code
            peer.remote_closed = true
            if peer.close_written then
                finish(peer)
            elseif not peer.close_queued then
                peer.stage = "closing"
                peer.close_queued = true
                enqueue(peer, {
                    opcode = OP_CLOSE,
                    payload = closePayload(remote_code),
                    close = true,
                })
            end
        elseif opcode ~= OP_PONG then
            failProtocol(peer, "protocol", "InvalidOpcode", 1002)
        end
        return not peer.failed
    end

    local data_op = opcode
    if opcode == OP_CONT then
        if reader.message_opcode == nil then
            failProtocol(peer, "protocol", "UnexpectedContinuation", 1002)
            return false
        end
        data_op = reader.message_opcode :: number
    elseif opcode == OP_TEXT or opcode == OP_BIN then
        if reader.message_opcode ~= nil then
            failProtocol(peer, "protocol", "FragmentInProgress", 1002)
            return false
        end
    else
        failProtocol(peer, "protocol", "InvalidOpcode", 1002)
        return false
    end

    if reader.message_size + piece_len > peer.max_message then
        failProtocol(peer, "protocol", "message too large", 1009)
        return false
    end

    if reader.is_final and reader.message_opcode == nil then
        local payload = if piece_large ~= nil
            then readBig(peer, piece_large, piece_len)
            else (piece or buffer.create(0))
        if not peer.failed then
            deliver(peer, data_op, payload)
        end
        return not peer.failed
    end

    if reader.message_opcode == nil then
        reader.message_opcode = data_op
    end
    if not appendFragment(peer, reader, piece, piece_large, piece_len) then
        return false
    end
    if reader.is_final then
        local op = reader.message_opcode :: number
        local payload = if reader.message_large ~= nil
            then readBig(peer, reader.message_large, reader.message_size)
            else (reader.message or buffer.create(0))
        reader.message_opcode = nil
        reader.message_size = 0
        reader.message = nil
        reader.message_large = nil
        if not peer.failed then
            deliver(peer, op, payload)
        end
    end
    return not peer.failed
end

local function beginPayload(peer: Peer, reader: Reader, size: number): boolean
    if size > peer.max_message or reader.message_size + size > peer.max_message then
        failProtocol(peer, "protocol", "message too large", 1009)
        return false
    end
    reader.payload_size = size
    reader.payload_offset = 0
    if size > LARGE then
        reader.payload_large = io.createBufferArray({
            size = size,
            limit = peer.max_message,
        })
        reader.payload = nil
    else
        reader.payload = buffer.create(size)
        reader.payload_large = nil
    end
    if reader.mask_in then
        reader.phase = "mask"
        reader.filled = 0
        return true
    end
    reader.phase = "payload"
    if size == 0 then
        return onFrame(peer, reader)
    end
    return true
end

local function onHeader(peer: Peer, reader: Reader): boolean
    reader.is_final = bit32.band(reader.header_byte, 0x80) ~= 0
    local reserved = bit32.band(reader.header_byte, 0x70)
    reader.opcode = bit32.band(reader.header_byte, 0x0F)
    local masked = bit32.band(reader.length_byte, 0x80) ~= 0
    local short_length = bit32.band(reader.length_byte, 0x7F)
    if reserved ~= 0 then
        failProtocol(peer, "protocol", "ReservedBits", 1002)
        return false
    end
    if reader.mask_in then
        if not masked then
            failProtocol(peer, "protocol", "UnmaskedMessage", 1002)
            return false
        end
    elseif masked then
        failProtocol(peer, "protocol", "MaskedMessage", 1002)
        return false
    end
    if reader.opcode >= 8 and (not reader.is_final or short_length > 125) then
        failProtocol(peer, "protocol", "InvalidControl", 1002)
        return false
    end
    if short_length < 126 then
        return beginPayload(peer, reader, short_length)
    end
    reader.extended_size = if short_length == 126 then 2 else 8
    reader.phase = "length"
    reader.filled = 0
    return true
end

local function consume(peer: Peer, reader: Reader, buf: buffer, count: number): boolean
    local i = 0
    while i < count do
        if peer.failed or peer.stage == "closed" then
            return false
        end
        if reader.phase == "header" then
            local take = math.min(2 - reader.filled, count - i)
            for j = 0, take - 1 do
                local byte = buffer.readu8(buf, i + j)
                if reader.filled + j == 0 then
                    reader.header_byte = byte
                else
                    reader.length_byte = byte
                end
            end
            reader.filled += take
            i += take
            if reader.filled < 2 then
                return true
            end
            reader.filled = 0
            if not onHeader(peer, reader) then
                return false
            end
        elseif reader.phase == "length" then
            local take = math.min(reader.extended_size - reader.filled, count - i)
            buffer.copy(reader.extended, reader.filled, buf, i, take)
            reader.filled += take
            i += take
            if reader.filled < reader.extended_size then
                return true
            end
            if reader.extended_size == 8 and buffer.readu8(reader.extended, 0) >= 128 then
                failProtocol(peer, "protocol", "message too large", 1009)
                return false
            end
            local size = 0
            for j = 0, reader.extended_size - 1 do
                size = size * 256 + buffer.readu8(reader.extended, j)
            end
            reader.filled = 0
            if not beginPayload(peer, reader, size) then
                return false
            end
        elseif reader.phase == "mask" then
            local take = math.min(4 - reader.filled, count - i)
            for j = 0, take - 1 do
                reader.mask[reader.filled + j + 1] = buffer.readu8(buf, i + j)
            end
            reader.filled += take
            i += take
            if reader.filled < 4 then
                return true
            end
            reader.filled = 0
            reader.phase = "payload"
            if reader.payload_size == 0 and not onFrame(peer, reader) then
                return false
            end
        else
            local take = math.min(reader.payload_size - reader.payload_offset, count - i)
            if take > 0 then
                if reader.mask_in then
                    local tmp = reader.unmask :: buffer
                    if buffer.len(tmp) < take then
                        tmp = buffer.create(take)
                        reader.unmask = tmp
                    end
                    local key = reader.mask
                    local offset = reader.payload_offset
                    for j = 0, take - 1 do
                        buffer.writeu8(tmp, j, bit32.bxor(buffer.readu8(buf, i + j), key[(offset + j) % 4 + 1]))
                    end
                    if reader.payload_large then
                        if not writeIncoming(peer, reader.payload_large, tmp, 0, take) then
                            return false
                        end
                    elseif reader.payload then
                        buffer.copy(reader.payload, offset, tmp, 0, take)
                    end
                elseif reader.payload_large then
                    if not writeIncoming(peer, reader.payload_large, buf, i, take) then
                        return false
                    end
                elseif reader.payload then
                    buffer.copy(reader.payload, reader.payload_offset, buf, i, take)
                end
                reader.payload_offset += take
                i += take
            end
            if reader.payload_offset < reader.payload_size then
                return true
            end
            if not onFrame(peer, reader) then
                return false
            end
        end
    end
    return true
end

local function readLoop(peer: Peer, reader: Reader, spill: buffer?)
    local ok, err = pcall(function()
        if spill ~= nil and buffer.len(spill) > 0 then
            if not consume(peer, reader, spill, buffer.len(spill)) then
                return
            end
        end
        local buf = buffer.create(RECV_CHUNK)
        while peer.stage == "active" or (peer.stage == "closing" and not peer.failed) do
            local n = peer.conn:read(buf, 0, RECV_CHUNK)
            if n == 0 then
                if peer.stage == "active" then
                    peer.close_code = 1006
                end
                break
            end
            if not consume(peer, reader, buf, n) then
                return
            end
        end
    end)
    if not ok and peer.stage ~= "closed" and not peer.failed then
        if peer.stage == "active" then
            emit(peer, "receive", tostring(err))
            peer.close_code = 1006
        end
    end
    if not peer.failed then
        finish(peer)
    end
    if peer.stage ~= "closed" then
        peer.read_thread = coroutine.running()
        coroutine.yield()
    end
end

local function bindSocket(peer: Peer): Socket
    local socket = {} :: Socket

    function socket.send(_: Socket, message: string | buffer)
        sendMessage(peer, message)
    end

    function socket.close(_: Socket, close_code: number?)
        sendClose(peer, close_code)
    end

    function socket.isConnected(_: Socket): boolean
        return peer.stage == "active" or peer.stage == "closing"
    end

    return socket
end

local function createReader(mask_in: boolean): Reader
    return {
        mask_in = mask_in,
        phase = "header",
        filled = 0,
        mask = { 0, 0, 0, 0 },
        unmask = if mask_in then buffer.create(RECV_CHUNK) else nil,
        header_byte = 0,
        length_byte = 0,
        extended_size = 0,
        extended = buffer.create(8),
        opcode = 0,
        is_final = true,
        payload_size = 0,
        payload_offset = 0,
        payload = nil,
        payload_large = nil,
        message_opcode = nil,
        message_size = 0,
        message = nil,
        message_large = nil,
    }
end

local function createPeer(conn: session.Session, opts: PeerOpts): (Peer, Reader)
    local peer: Peer = {
        conn = conn,
        socket = {} :: Socket,
        mask_out = opts.mask_out,
        max_message = opts.max_message,
        on_message = opts.on_message,
        on_close = opts.on_close,
        on_error = opts.on_error,
        stage = "opening",
        close_code = 1006,
        failed = false,
        remote_closed = false,
        close_queued = false,
        close_written = false,
        close_timer = nil,
        read_thread = nil,
        sending = false,
        queue = {},
        queue_head = 1,
        queue_tail = 0,
    }
    peer.socket = bindSocket(peer)
    return peer, createReader(opts.mask_in)
end

local websocket = {}

function websocket.connect(url: string, options: ConnectOptions?): Socket
    if options ~= nil and type(options) ~= "table" then
        error("expected options to be a table", 0)
    end
    local opts: ConnectOptions = options or {}

    local on_accept = optionalFunction(opts, "accept")
    local on_message = optionalFunction(opts, "message")
    local on_close = optionalFunction(opts, "close")
    local on_error = optionalFunction(opts, "error")
    local timeout_seconds = timeoutSeconds(opts)
    local max_message = messageLimit(opts)

    local parsed = session.parseUrl(url)
    if parsed.scheme ~= "ws" and parsed.scheme ~= "wss" then
        error("unsupported URI scheme", 0)
    end

    local extra, host_handled, user_agent_handled = headerLines(opts.headers)
    local protocols = protocolHeader(opts.protocols)

    local force_tls = false
    local sni = parsed.host
    local ca: TlsCertBundle? = nil
    if opts.tls ~= nil then
        if type(opts.tls) ~= "table" then
            error("expected field 'tls' to be a table", 0)
        end
        force_tls = true
        if opts.tls.host ~= nil then
            if type(opts.tls.host) ~= "string" then
                error("expected field 'tls.host' to be a string", 0)
            end
            sni = opts.tls.host
        end
        if opts.tls.ca ~= nil then
            if type(opts.tls.ca) ~= "userdata" then
                error("expected field 'tls.ca' to be a CertBundle", 0)
            end
            ca = opts.tls.ca
        end
    end

    local raw_key = buffer.create(16)
    local key_buf = buffer.create(serde.base64.calcSize(16))

    crypto.random.fill(raw_key, 0, 16)

    local wrote = serde.base64.encode(key_buf, 0, raw_key, 0)

    local key = buffer.readstring(key_buf, 0, wrote)

    local expect_accept = acceptValue(key)
    local head = upgradeHead(parsed, key, extra, host_handled, user_agent_handled, protocols)

    local tls_arg: session.TlsOptions? = nil
    if parsed.tls or force_tls then
        tls_arg = {
            host = sni,
            ca = ca,
        } :: session.TlsOptions
    end
    local conn = session.open(parsed, timeout_seconds, tls_arg)
    local peer, reader = createPeer(conn, {
        mask_out = true,
        mask_in = false,
        max_message = max_message,
        on_message = on_message :: any,
        on_close = on_close :: any,
        on_error = on_error :: any,
    })
    local socket = peer.socket

    local ok, result = pcall(function(): { info: Handshake, spill: buffer? }
        conn:write(head)
        local info, spill = readUpgrade(conn)
        return {
            info = info,
            spill = spill,
        }
    end)
    if not ok then
        conn:close()
        if conn:timedOut() then
            error("timed out", 0)
        end
        error(result, 0)
    end
    local upgrade = result :: { info: Handshake, spill: buffer? }
    local info = upgrade.info

    local accepted = true
    if on_accept ~= nil then
        ok, result = pcall(on_accept, socket, info)
        if not ok then
            conn:close()
            error("upgrade failed", 0)
        end
        accepted = result == true
    end
    if conn:timedOut() then
        conn:close()
        error("timed out", 0)
    end
    if not accepted then
        conn:close()
        error("upgrade rejected", 0)
    end
    if info.status_code ~= 101 or info.headers["sec-websocket-accept"] ~= expect_accept then
        conn:close()
        error("upgrade failed", 0)
    end

    conn:releaseDeadline()
    peer.stage = "active"
    task.spawn(readLoop, peer, reader, upgrade.spill)
    return socket
end

local function hasToken(value: string?, token: string): boolean
    if value == nil then
        return false
    end
    local lower = string.lower(value)
    local i = 1
    while i <= #lower do
        local comma = string.find(lower, ",", i, true)
        local part = if comma then string.sub(lower, i, comma - 1) else string.sub(lower, i)
        if (string.match(part, "^%s*(.-)%s*$") or "") == token then
            return true
        end
        if comma == nil then
            return false
        end
        i = comma + 1
    end
    return false
end

function websocket.handles(method: string, headers: { [string]: string }): boolean
    if method ~= "GET" then
        return false
    end
    if not hasToken(headers.connection, "upgrade") then
        return false
    end
    local upgrade = headers.upgrade
    if upgrade ~= nil and string.lower(upgrade) ~= "websocket" then
        return false
    end
    return true
end

local function rejectHttp(
    conn: session.Session,
    status: number,
    reason: string,
    body: string,
    extra: { [string]: string }?
)
    local headers: { [string]: string } = {
        ["Connection"] = "close",
        ["Content-Type"] = "text/plain",
    }
    if extra ~= nil then
        for name, value in extra do
            headers[name] = value
        end
    end
    pcall(
        conn.write,
        conn,
        Response.from({
            status = status,
            reason = reason,
            headers = headers,
            body = body,
        })
    )
end

function websocket.accept(conn: session.Session, incoming: UpgradeRequest, spill: buffer?, handlers: ServerHandlers)
    local headers = incoming.headers
    local version = headers["sec-websocket-version"]
    if version == nil or string.sub(version, 1, 2) ~= "13" then
        rejectHttp(conn, 426, "Upgrade Required", "Unsupported WebSocket version. Use 13.", {
            ["Sec-WebSocket-Version"] = "13",
        })
        return
    end
    local key = headers["sec-websocket-key"]
    if type(key) ~= "string" or #key ~= 24 then
        rejectHttp(conn, 400, "Bad Request", "Invalid WebSocket key.")
        return
    end

    local upgrade = handlers.upgrade
    if upgrade ~= nil then
        local ok, result = pcall(upgrade, incoming)
        if not ok or type(result) ~= "boolean" then
            rejectHttp(conn, 500, "Internal Server Error", "An error occurred on the server")
            return
        end
        if result ~= true then
            rejectHttp(conn, 403, "Forbidden", "WebSocket upgrade rejected")
            return
        end
    end

    local protocol = headers["sec-websocket-protocol"]
    local reply_headers: { [string]: string } = {
        ["Upgrade"] = "websocket",
        ["Connection"] = "Upgrade",
        ["Sec-WebSocket-Accept"] = acceptValue(key),
    }
    if type(protocol) == "string" and protocol ~= "" then
        reply_headers["Sec-WebSocket-Protocol"] = protocol
    end
    local peer, reader = createPeer(conn, {
        mask_out = false,
        mask_in = true,
        max_message = MAX_MESSAGE,
        on_message = handlers.message,
        on_close = handlers.close,
        on_error = nil,
    })
    local wrote = pcall(
        conn.write,
        conn,
        Response.from({
            status = 101,
            reason = "Switching Protocols",
            headers = reply_headers,
        })
    )
    if not wrote then
        readLoop(peer, reader, nil)
        return
    end
    peer.stage = "active"
    local open = handlers.open
    if open ~= nil then
        open(peer.socket)
    end
    readLoop(peer, reader, spill)
end

return websocket
