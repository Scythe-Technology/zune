--!strict
--!optimize 2

local net = zune.net
local task = zune.task
local crypto = zune.crypto
local mem = zune.mem

local PLAIN_RECORD = 8192
-- `_RUNTIME.version.display` already appends the Luau version. The token
-- callers compare is the zune version alone.
local version_token = string.match(_VERSION, "^zune%s+([^%+]+)") or "0.0.0"
local USER_AGENT = `zune/{version_token}`

local CLOSED_ERRORS: { [string]: boolean } = {
    ["socket closed"] = true,
    ["ConnectionResetByPeer"] = true,
    ["BrokenPipe"] = true,
    ["ConnectionAborted"] = true,
    ["Canceled"] = true,
    ["EndOfStream"] = true,
    ["UnexpectedEof"] = true,
    ["SocketNotConnected"] = true,
    ["SocketShutdown"] = true,
    ["ConnectionRefused"] = true,
}

export type ParsedUrl = {
    scheme: string,
    tls: boolean,
    host: string,
    port: number,
    target: string,
}

export type TlsOptions = {
    host: string?,
    ca: TlsCertBundle?,
}

type Gate = {
    timed_out: boolean,
    socket: Socket?,
    deadline: number?,
}

type Connection = {
    socket: Socket,
    tls: CryptoTls?,
    gate: Gate,

    cipher: buffer,
    spare: buffer,
    cipher_len: number,
    plain: buffer,
    plain_pos: number,
    plain_len: number,
    saw_close: boolean,
    watchdog: thread?,
    closed: boolean,

    read: (self: Connection, dest: buffer, offset: number, count: number, timeout: number?) -> number,
    write: (self: Connection, message: string | buffer) -> (),
    close: (self: Connection) -> (),
    releaseDeadline: (self: Connection) -> (),
    timedOut: (self: Connection) -> boolean,
}

export type Session = Connection

local session = {}

session.user_agent = USER_AGENT

local function isClosedError(err: any): boolean
    return type(err) == "string" and CLOSED_ERRORS[err] == true
end

function session.isClosed(err: any): boolean
    return isClosedError(err)
end

local function remaining(gate: Gate): number?
    if gate.timed_out then
        error("timed out", 0)
    end
    local deadline = gate.deadline
    if deadline == nil then
        return nil
    end
    local left = deadline - os.clock()
    if left <= 0 then
        gate.timed_out = true
        error("timed out", 0)
    end
    return left
end

local function parseUrl(raw: string): ParsedUrl
    if type(raw) ~= "string" or raw == "" then
        error("unsupported URI scheme", 0)
    end
    local scheme, rest = string.match(raw, "^([%a][%w+.-]*)://(.*)$")
    if scheme == nil or rest == nil then
        error("unsupported URI scheme", 0)
    end
    scheme = string.lower(scheme)
    local tls = false
    local default_port = 80
    if scheme == "https" or scheme == "wss" then
        tls = true
        default_port = 443
    elseif scheme == "http" or scheme == "ws" then
        default_port = 80
    else
        error("unsupported URI scheme", 0)
    end

    local hash = string.find(rest, "#", 1, true)
    if hash then
        rest = string.sub(rest, 1, hash - 1)
    end

    local authority: string
    local target: string
    local slash = string.find(rest, "/", 1, true)
    if slash then
        authority = string.sub(rest, 1, slash - 1)
        target = string.sub(rest, slash)
    else
        local query = string.find(rest, "?", 1, true)
        if query then
            authority = string.sub(rest, 1, query - 1)
            target = "/" .. string.sub(rest, query)
        else
            authority = rest
            target = "/"
        end
    end
    if authority == "" then
        error("URI missing host", 0)
    end

    local at = string.find(authority, "@", 1, true)
    if at then
        authority = string.sub(authority, at + 1)
        if authority == "" then
            error("URI missing host", 0)
        end
    end

    local host: string
    local port: number? = nil
    if mem.startsWith(authority, "[") then
        local end_bracket = string.find(authority, "]", 1, true)
        if end_bracket == nil then
            error("URI missing host", 0)
        end
        host = string.sub(authority, 2, end_bracket - 1)
        local tail = string.sub(authority, end_bracket + 1)
        if tail ~= "" then
            local digits = string.match(tail, "^:(%d+)$")
            if digits == nil then
                error("URI missing host", 0)
            end
            port = tonumber(digits)
        end
    else
        local name, digits = string.match(authority, "^(.-):(%d+)$")
        if name ~= nil and digits ~= nil and string.find(name, ":", 1, true) == nil then
            host = name
            port = tonumber(digits)
        else
            if string.find(authority, ":", 1, true) ~= nil then
                error("URI missing host", 0)
            end
            host = authority
        end
    end
    if host == "" then
        error("URI missing host", 0)
    end
    if port == nil then
        port = default_port
    end
    assert(port)
    if port < 0 or port > 65535 then
        error(`invalid port ({port})`, 0)
    end
    return {
        scheme = scheme,
        tls = tls,
        host = host,
        port = port :: number,
        target = target,
    }
end

local function byteCount(message: string | buffer): number
    if type(message) == "buffer" then
        return buffer.len(message)
    end
    return #message
end

local function socketRecv(self: Connection, dest: buffer, offset: number, count: number, timeout: number?): number
    if count <= 0 then
        return 0
    end
    local limit = timeout
    if limit == nil then
        limit = remaining(self.gate)
    end
    local amount, err = self.socket:recv(dest, offset, count, limit)
    if err ~= nil then
        if self.gate.timed_out or err == "Timeout" then
            if timeout == nil then
                self.gate.timed_out = true
            end
            error("timed out", 0)
        end
        if isClosedError(err) then
            return 0
        end
        error(err, 0)
    end
    return amount
end

local function sendAll(self: Connection, src: string | buffer, count: number)
    local written = 0
    while written < count do
        if not self.socket.open then
            error("connection closed", 0)
        end
        local timeout = remaining(self.gate)
        local amount, err = self.socket:send(src, written, count - written, timeout)
        if err ~= nil then
            if self.gate.timed_out or err == "Timeout" then
                self.gate.timed_out = true
                error("timed out", 0)
            end
            error(err, 0)
        end
        if amount == 0 then
            local this = coroutine.running()
            task.defer(task.spawn, this)
            coroutine.yield()
            if self.gate.timed_out then
                error("timed out", 0)
            end
        else
            written += amount
        end
    end
end

local function writePlain(self: Connection, message: string | buffer)
    local tls = self.tls
    local total = byteCount(message)
    if not tls then
        sendAll(self, message, total)
        return
    end
    local outgoing = buffer.create(crypto.tls.MAX_RECORD_SIZE)
    local offset = 0
    while offset < total do
        local count = math.min(PLAIN_RECORD, total - offset)
        local consumed, produced = tls:encrypt(message, offset, count, outgoing, 0, buffer.len(outgoing))
        if produced > 0 then
            sendAll(self, outgoing, produced)
        end
        if consumed == 0 then
            error("connection closed", 0)
        end
        offset += consumed
    end
end

local function cipherLimit(): number
    return crypto.tls.MAX_RECORD_SIZE * 4
end

local function dropFront(self: Connection, drop: number, len: number): number
    local remain = len - drop
    if remain <= 0 then
        return 0
    end
    if drop <= 0 then
        return len
    end
    if buffer.len(self.spare) < remain then
        self.spare = buffer.create(remain)
    end
    buffer.copy(self.spare, 0, self.cipher, drop, remain)
    self.cipher, self.spare = self.spare, self.cipher
    return remain
end

local function ensureRoom(self: Connection, needed: number): boolean
    if buffer.len(self.cipher) >= needed then
        return true
    end
    if needed > cipherLimit() then
        return false
    end
    local cap = buffer.len(self.cipher)
    while cap < needed do
        cap += (cap / 2) // 1
    end
    if cap > cipherLimit() then
        cap = cipherLimit()
    end
    if cap < needed then
        return false
    end
    local grown = buffer.create(cap)
    if self.cipher_len > 0 then
        buffer.copy(grown, 0, self.cipher, 0, self.cipher_len)
    end
    self.cipher = grown
    self.spare = buffer.create(cap)
    return true
end

-- Client writes ClientHello before the first read. Server reads first.
-- `timeout` is per recv. Nil uses the gate deadline (the client handshake).
local function handshake(self: Connection, read_first: boolean, timeout: number?)
    local tls = self.tls
    if not tls then
        return
    end
    local outgoing = buffer.create(crypto.tls.MAX_RECORD_SIZE)
    local primed = read_first
    while not tls.established do
        if primed then
            local space = buffer.len(self.cipher) - self.cipher_len
            if space == 0 then
                if not ensureRoom(self, self.cipher_len + 1) then
                    error("connection closed", 0)
                end
                space = buffer.len(self.cipher) - self.cipher_len
            end
            local n = socketRecv(self, self.cipher, self.cipher_len, space, timeout)
            if n == 0 then
                error("connection closed", 0)
            end
            self.cipher_len += n
        end
        primed = true
        local done, consumed, produced =
            tls:handshake(self.cipher, 0, self.cipher_len, outgoing, 0, buffer.len(outgoing))
        if consumed > 0 then
            self.cipher_len = dropFront(self, consumed, self.cipher_len)
        end
        if produced > 0 then
            sendAll(self, outgoing, produced)
        end
        if done then
            return
        end
    end
end

local function readChunk(self: Connection, dest: buffer, dest_offset: number, count: number, timeout: number?): number
    if self.plain_pos < self.plain_len then
        local take = math.min(count, self.plain_len - self.plain_pos)
        buffer.copy(dest, dest_offset, self.plain, self.plain_pos, take)
        self.plain_pos += take
        if self.plain_pos >= self.plain_len then
            self.plain_pos = 0
            self.plain_len = 0
        end
        return take
    end
    if self.saw_close then
        return 0
    end
    if not self.tls then
        return socketRecv(self, dest, dest_offset, count, timeout)
    end
    local tls = self.tls :: CryptoTls
    while true do
        if self.cipher_len == 0 then
            local n = socketRecv(self, self.cipher, 0, buffer.len(self.cipher), timeout)
            if n == 0 then
                return 0
            end
            self.cipher_len = n
        end
        if buffer.len(self.plain) < self.cipher_len then
            self.plain = buffer.create(self.cipher_len)
        end
        local consumed, produced, closed =
            tls:decrypt(self.cipher, 0, self.cipher_len, self.plain, 0, buffer.len(self.plain))
        if consumed > 0 then
            self.cipher_len = dropFront(self, consumed, self.cipher_len)
        end
        if produced > 0 then
            self.plain_pos = 0
            self.plain_len = produced
            self.saw_close = closed
            local take = math.min(count, produced)
            buffer.copy(dest, dest_offset, self.plain, 0, take)
            self.plain_pos = take
            if self.plain_pos >= self.plain_len then
                self.plain_pos = 0
                self.plain_len = 0
            end
            return take
        end
        if closed then
            self.saw_close = true
            return 0
        end
        local space = buffer.len(self.cipher) - self.cipher_len
        if space == 0 then
            if not ensureRoom(self, self.cipher_len + 1) then
                return 0
            end
            space = buffer.len(self.cipher) - self.cipher_len
        end
        local n = socketRecv(self, self.cipher, self.cipher_len, space, timeout)
        if n == 0 then
            return 0
        end
        self.cipher_len += n
    end
end

local function connectOne(gate: Gate, host: string, port: number): Socket
    local ok, list: { NetworkAddress } = pcall(function()
        return net.getAddressList(host, port)
    end)
    if not ok then
        error(list :: any, 0)
    end
    if #list == 0 then
        error("unknown host name", 0)
    end

    for _, addr in list do
        if gate.timed_out then
            error("timed out", 0)
        end
        local domain: "ipv4" | "ipv6" = if string.find(addr.address, ":", 1, true) ~= nil then "ipv6" else "ipv4"
        local sock = net.openSocket(domain, "stream", "tcp")
        gate.socket = sock
        local connected, err = pcall(function()
            sock:connectAddress(addr.address, port)
        end)
        if connected then
            sock:setNoDelay(true)
            return sock
        end
        gate.socket = nil
        pcall(function()
            sock:close()
        end)
        if gate.timed_out or err == "Timeout" then
            gate.timed_out = true
            error("timed out", 0)
        end
    end
    error("connection refused", 0)
end

local function closeConn(self: Connection)
    if self.closed then
        return
    end
    self.closed = true
    local watchdog = self.watchdog
    if watchdog then
        pcall(task.cancel, watchdog)
        self.watchdog = nil
    end
    local sock = self.gate.socket
    self.gate.socket = nil
    if sock ~= nil and sock.open then
        pcall(function()
            sock:close()
        end)
    end
end

local function releaseDeadline(self: Connection)
    local watchdog = self.watchdog
    if watchdog then
        pcall(task.cancel, watchdog)
        self.watchdog = nil
    end
    self.gate.deadline = nil
end

local function timedOut(self: Connection): boolean
    return self.gate.timed_out
end

local function newConnection(sock: Socket, tls: CryptoTls?, gate: Gate): Connection
    local record = if tls then crypto.tls.MAX_RECORD_SIZE else 1
    local self: Connection = {
        socket = sock,
        tls = tls,
        gate = gate,
        cipher = buffer.create(record),
        spare = buffer.create(record),
        cipher_len = 0,
        plain = buffer.create(record),
        plain_pos = 0,
        plain_len = 0,
        saw_close = false,
        watchdog = nil,
        closed = false,
        read = readChunk,
        write = writePlain,
        close = closeConn,
        releaseDeadline = releaseDeadline,
        timedOut = timedOut,
    }
    return self
end

function session.parseUrl(raw: string): ParsedUrl
    return parseUrl(raw)
end

function session.open(parsed: ParsedUrl, timeout_seconds: number?, tls_opts: TlsOptions?): Session
    local sni = parsed.host
    local ca: TlsCertBundle? = nil
    if tls_opts ~= nil then
        if tls_opts.host ~= nil then
            sni = tls_opts.host
        end
        ca = tls_opts.ca
    end

    local gate: Gate = {
        timed_out = false,
        socket = nil,
        deadline = if timeout_seconds ~= nil then os.clock() + timeout_seconds else nil,
    }
    local watchdog: thread? = nil
    if timeout_seconds ~= nil then
        watchdog = task.delay(timeout_seconds, function()
            gate.timed_out = true
            local sock = gate.socket
            if sock then
                pcall(function()
                    sock:close()
                end)
            end
        end) :: any
    end

    local ok, result = pcall(function(): Connection
        local sock = connectOne(gate, parsed.host, parsed.port)
        local tls: CryptoTls? = nil
        if parsed.tls or tls_opts ~= nil then
            local bundle = ca or crypto.tls.bundleFromSystem()
            tls = crypto.tls.createClient(sock, {
                host = sni,
                ca = bundle,
            })
        end
        local conn = newConnection(sock, tls, gate)

        handshake(conn, false)

        conn.watchdog = watchdog

        return conn
    end)
    if not ok then
        if watchdog then
            pcall(task.cancel, watchdog)
        end
        local sock = gate.socket
        gate.socket = nil
        if sock ~= nil and sock.open then
            pcall(function()
                sock:close()
            end)
        end
        if gate.timed_out then
            error("timed out", 0)
        end
        error(result, 0)
    end
    return result :: Session
end

function session.accept(sock: Socket, tls: CryptoTls?, timeout: number?): Session
    local gate: Gate = {
        timed_out = false,
        socket = sock,
        deadline = nil,
    }
    local conn = newConnection(sock, tls, gate)
    local ok, err = pcall(handshake, conn, true, timeout)
    if not ok then
        closeConn(conn)
        error(err, 0)
    end
    return conn
end

return session
