--!strict
--!optimize 2

local net = zune.net
local mem = zune.mem
local task = zune.task
local crypto = zune.crypto

local uri = require("@zune/net/uri")
local spec = require("@zune/spec")

local PLAIN_RECORD = 8192

local USER_AGENT = `zune/{_RUNTIME.version.display}`

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

function session.isClosed(err: any): boolean
    return spec.string(err) and CLOSED_ERRORS[err :: string] == true
end

local function remaining(gate: Gate): number?
    if gate.timed_out then
        error("timed out", 0)
    end
    local deadline = gate.deadline
    if not deadline then
        return nil
    end
    local left = deadline - os.clock()
    if left <= 0 then
        gate.timed_out = true
        error("timed out", 0)
    end
    return left
end

function session.parseUrl(raw: string): ParsedUrl
    local parsed = uri.parse(raw)
    local scheme = parsed.scheme
    local tls = scheme == "https" or scheme == "wss"
    if scheme ~= "http" and scheme ~= "https" and scheme ~= "ws" and scheme ~= "wss" then
        error("unsupported URI scheme", 0)
    end
    local host = parsed.host
    if host == nil or host == "" then
        error("URI missing host", 0)
    end
    local port = parsed.port or (if tls then 443 else 80)
    local target = parsed.path
    if target == "" then
        target = "/"
    end
    local query = parsed.query
    if query ~= nil then
        target = `{target}?{query}`
    end
    return {
        scheme = scheme,
        tls = tls,
        host = host,
        port = port,
        target = target,
    }
end

local function socketRecv(self: Connection, dest: buffer, offset: number, count: number, timeout: number?): number
    if count <= 0 then
        return 0
    end
    local limit = timeout
    if not limit then
        limit = remaining(self.gate)
    end
    local amount, err = self.socket:recv(dest, offset, count, limit)
    if err then
        if self.gate.timed_out or err == "Timeout" then
            if not timeout then
                self.gate.timed_out = true
            end
            error("timed out", 0)
        end
        if session.isClosed(err) then
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
        if err then
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
    local total = if spec.buffer(message) then buffer.len(message :: buffer) else #(message :: string)
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
    local ok, list: { NetworkAddress } = pcall(net.getAddressList, host, port)
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
        local domain: "ipv4" | "ipv6" = if mem.findScalar(addr.address, 58) then "ipv6" else "ipv4" -- ':'
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
    if sock and sock.open then
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

function session.open(parsed: ParsedUrl, timeout_seconds: number?, tls_opts: TlsOptions?): Session
    local sni = parsed.host
    local ca: TlsCertBundle? = nil
    if tls_opts then
        if tls_opts.host then
            sni = tls_opts.host
        end
        ca = tls_opts.ca
    end

    local tls: CryptoTls? = nil
    if parsed.tls or tls_opts then
        local bundle = ca or crypto.tls.bundleFromSystem()
        tls = crypto.tls.createClient({
            host = sni,
            ca = bundle,
        })
    end

    local gate: Gate = {
        timed_out = false,
        socket = nil,
        deadline = if timeout_seconds then os.clock() + timeout_seconds else nil,
    }
    local watchdog: thread? = nil
    if timeout_seconds then
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
        if sock and sock.open then
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
