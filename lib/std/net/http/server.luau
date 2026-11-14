--!strict
--!optimize 2

local net = zune.net
local task = zune.task
local crypto = zune.crypto
local mem = zune.mem

local Encoding = require("./encoding")
local Request = require("./request")
local Response = require("./response")
local session = require("./session")
local websocket = require("./websocket")

local RECV_CHUNK = 8192
local HEADER_LIMIT = 8192
local URI_LIMIT = 256
local HEADER_COUNT_LIMIT = 100

export type Response = Response.Response

export type ServeOptions = {
    --- The port to listen on.
    --- OS picks the port if set to `0`.
    --- - Default: `80`
    port: number?,
    --- The address to bind to.
    --- - Default: `127.0.0.1`
    address: string?,
    --- Whether to reuse the address and port.
    --- - Default: `false`
    reuse_address: boolean?,
    --- The maximum size of the request body.
    --- - Default: `4096`
    max_body_size: number?,
    --- The maximum number of simultaneous connections.
    --- - Default: `1024`
    max_connections: number?,
    --- The maximum number of connections the server will backlog to the OS.
    --- - Default: `512`
    max_backlog: number?,
    --- The idle timeout for the first request, in seconds.
    --- Also used for later requests when `keep_alive.timeout` is `0`.
    --- - Default: `60`
    client_timeout: number?,
    --- The keep-alive configuration for the server.
    keep_alive: {
        --- - Default: `true`
        enabled: boolean?,
        --- - Default: `0` (fall back to `client_timeout`)
        timeout: number?,
    }?,
    --- The TLS configuration for the server.
    tls: {
        auth: TlsCertKeyPair,
    }?,
    --- The function to call when a request is received.
    request: (request: Request.Request) -> string | Response,
    --- The handlers for WebSocket connections.
    websocket: websocket.ServerHandlers?,
}

export type Server = {
    socket: Socket,

    stopped: boolean,
    running: boolean,
    waiting: boolean,
    thread: thread?,
    active: number,
    address: string,
    port: number,

    waiter: thread?,
    clients: { [Socket]: boolean },
    stop: (self: Server) -> (),
}

local function pull(conn: session.Session, buf: buffer, timeout: number): (number, boolean)
    local ok, result = pcall(conn.read, conn, buf, 0, buffer.len(buf), timeout)
    if not ok then
        local name: string = result :: any
        if name == "timed out" then
            return 0, true
        end
        if name ~= nil and name ~= "connection closed" and not session.isClosed(name) then
            print(`Error(Unhandled): {name}`)
        end
        return 0, false
    end
    return result, false
end

local function send(conn: session.Session, message: string | buffer)
    if not conn.socket.open then
        return
    end
    pcall(conn.write, conn, message)
end

local function sendTimeout(conn: session.Session)
    local tls = conn.tls
    if tls ~= nil and not tls.established then
        return
    end
    send(
        conn,
        Response.from({
            status = 408,
            reason = "Request Timeout",
            headers = {
                ["Connection"] = "close",
            },
        })
    )
end

local function reject(conn: session.Session, code: number, reason: string, body: string?)
    local headers: { [string]: string } = {
        ["Connection"] = "close",
    }
    if body then
        headers["Content-Type"] = "text/plain"
    end
    send(
        conn,
        Response.from({
            status = code,
            reason = reason,
            headers = headers,
            body = body,
        })
    )
end

local function listen(
    socket: Socket,
    tls_auth: TlsCertKeyPair?,
    max_body_size: number,
    client_timeout: number,
    keep_alive_timeout: number,
    keep_alive_enabled: boolean,
    callback: (request: Request.Request) -> string | Response,
    handlers: websocket.ServerHandlers?
)
    local tls: CryptoTls? = nil
    if tls_auth then
        tls = crypto.tls.createServer(socket, {
            auth = tls_auth,
        })
    end

    local function idleSeconds(requests: number): number
        if requests > 0 and keep_alive_timeout > 0 then
            return keep_alive_timeout
        end
        return client_timeout
    end

    local ok, conn = pcall(session.accept, socket, tls, idleSeconds(0))
    if not ok then
        local name: string = conn :: any
        if name ~= "timed out" and name ~= "connection closed" and not session.isClosed(name) then
            print(`Error(Unhandled): {name}`)
        end
        return
    end

    local parser = Request.newParser({
        uri = URI_LIMIT,
        headers = HEADER_COUNT_LIMIT,
        header_bytes = HEADER_LIMIT,
        body = max_body_size,
    })
    local requests = 0
    local recv_buf = buffer.create(RECV_CHUNK)
    local pending: buffer? = nil

    local cached_text: string? = nil
    local cached_wire: string? = nil

    while socket.open do
        local chunk: buffer
        if pending ~= nil then
            chunk = pending
            pending = nil
        else
            local n, timed_out = pull(conn, recv_buf, idleSeconds(requests))
            if timed_out then
                sendTimeout(conn)
                break
            end
            if n == 0 or not socket.open then
                break
            end
            chunk = mem.slice(recv_buf, 0, n)
        end

        local parsed_ok, parsed = pcall(Request.parse, parser, chunk)
        if not parsed_ok then
            local err = parsed :: any
            if err == "too many headers" or err == "header too large" then
                reject(conn, 431, "Request Header Fields Too Large", "Request Header Fields Too Large")
            elseif err == "body too large" then
                reject(conn, 413, "Content Too Large", "Content Too Large")
            elseif err == "URI too large" then
                reject(conn, 414, "URI Too Large", "URI Too Large")
            end
            break
        end
        if parsed ~= true then
            continue
        end

        local method = parser.method
        local path = parser.uri
        if not method or not path then
            break
        end

        requests += 1
        local path_or_err: string
        if string.find(path, "%", 1, true) == nil then
            path_or_err = path
        else
            local decoded_ok, decoded = pcall(Encoding.url.decode, path)
            if not decoded_ok or type(decoded) ~= "string" then
                reject(conn, 400, "Bad Request", "Bad Request")
                break
            end
            path_or_err = decoded
        end

        local keep_alive = keep_alive_enabled and Request.canKeepAlive(parser)
        local incoming: Request.Request = {
            method = method,
            path = path_or_err,
            headers = parser.headers :: any,
            body = parser.body,
        }
        local spill = parser.spill
        Request.resetParser(parser)

        if handlers ~= nil and websocket.handles(method, incoming.headers) then
            websocket.accept(conn, incoming, spill, handlers)
            return
        end

        local call_ok, response = xpcall(callback, function(_err) end, incoming)
        if not call_ok then
            reject(conn, 500, "Internal Server Error", "An error occurred on the server")
            break
        end
        if type(response) == "string" then
            local wire = cached_wire
            if wire == nil or cached_text ~= response then
                wire = Response.from({ body = response })
                cached_text = response
                cached_wire = wire
            end
            send(conn, wire :: string)
        elseif type(response) == "table" then
            send(conn, Response.from(response :: Response))
        else
            reject(conn, 500, "Internal Server Error", "An error occurred on the server")
            break
        end
        if not keep_alive then
            break
        end
        pending = spill
    end
end

local function noteQuiet(server: Server)
    local waiter = server.waiter
    if not waiter or server.running or server.active > 0 then
        return
    end
    server.waiter = nil
    if coroutine.status(waiter) == "suspended" then
        task.spawn(waiter)
    end
end

local function waitUntilQuiet(self: Server)
    while self.running or self.active > 0 do
        self.waiter = coroutine.running()
        if not self.running and self.active == 0 then
            self.waiter = nil
            return
        end
        coroutine.yield()
    end
end

local function finishConnection(server: Server, socket: Socket)
    server.clients[socket] = nil
    pcall(function()
        socket:close()
    end)
    server.active -= 1
    if server.waiting and server.thread and coroutine.status(server.thread) == "suspended" then
        server.waiting = false
        task.spawn(server.thread)
    end
    noteQuiet(server)
end

local function stopServer(self: Server)
    if not self.stopped then
        self.stopped = true
        pcall(function()
            self.socket:close()
        end)
        if self.waiting and self.thread and coroutine.status(self.thread) == "suspended" then
            self.waiting = false
            task.spawn(self.thread)
        end
        local pending: { Socket } = {}
        for sock in self.clients do
            table.insert(pending, sock)
        end
        for _, sock in pending do
            pcall(function()
                sock:close()
            end)
        end
    end
    waitUntilQuiet(self)
end

local function startServer(
    server: Server,
    tls_auth: TlsCertKeyPair?,
    max_body_size: number,
    max_connections: number,
    client_timeout: number,
    keep_alive_timeout: number,
    keep_alive_enabled: boolean,
    callback: (request: Request.Request) -> string | Response,
    handlers: websocket.ServerHandlers?
)
    server.running = true
    server.thread = coroutine.running()
    local ok, err = xpcall(function(): any
        while not server.stopped do
            if server.active >= max_connections then
                server.waiting = true
                coroutine.yield()
                server.waiting = false
                continue
            end
            local accepted_ok, conn = pcall(function()
                return server.socket:accept()
            end)
            if not accepted_ok then
                local name: string = conn :: any
                if not server.stopped and name ~= nil and not session.isClosed(name) and not session.isClosed(conn) then
                    print(`Error(Unhandled): {name}`)
                end
                server.stopped = true
                break
            end
            if server.stopped then
                pcall(function()
                    conn:close()
                end)
                break
            end
            conn:setNoDelay(true)
            server.active += 1
            server.clients[conn] = true
            task.spawn(function()
                local call_ok, call_err = xpcall(function(): any
                    return listen(
                        conn,
                        tls_auth,
                        max_body_size,
                        client_timeout,
                        keep_alive_timeout,
                        keep_alive_enabled,
                        callback,
                        handlers
                    )
                end, function(e)
                    return debug.traceback(e, 2)
                end)
                if not call_ok then
                    print(`error: {call_err}`)
                end
                finishConnection(server, conn)
            end)
        end
        return
    end, function(e)
        return debug.traceback(e, 2)
    end)
    if not ok then
        print(`error: {err}`)
        server.stopped = true
    end
    server.running = false
    noteQuiet(server)
end

local server = {}

function server.serve(opts: ServeOptions): Server
    assert(type(opts) == "table", "expected opts to be a table")

    local port = if opts.port == nil then 80 else opts.port
    local address = opts.address or "127.0.0.1"
    local max_backlog = opts.max_backlog or 512
    local max_body_size = opts.max_body_size or 4096
    local reuse_address = opts.reuse_address or false
    local client_timeout = if opts.client_timeout == nil then 60 else opts.client_timeout
    local max_connections = opts.max_connections or 1024
    local keep_alive = opts.keep_alive or { enabled = true, timeout = 0 }
    local callback = opts.request
    local tls_auth = if opts.tls then opts.tls.auth else nil

    assert(type(port) == "number", "expected port to be a number")
    assert(type(address) == "string", "expected address to be a string")
    assert(type(max_backlog) == "number", "expected max_backlog to be a number")
    assert(type(max_body_size) == "number", "expected max_body_size to be a number")
    assert(type(reuse_address) == "boolean", "expected reuse_address to be a boolean")
    assert(type(client_timeout) == "number", "expected client_timeout to be a number")
    assert(type(max_connections) == "number", "expected max_connections to be a number")
    assert(type(keep_alive) == "table", "expected keep_alive to be a table")
    assert(type(callback) == "function", "expected request to be a function")
    if opts.tls ~= nil then
        assert(type(opts.tls) == "table", "expected tls to be a table")
        assert(tls_auth ~= nil, "expected tls.auth")
    end

    local handlers: websocket.ServerHandlers? = nil
    if opts.websocket ~= nil then
        assert(type(opts.websocket) == "table", "expected websocket to be a table")
        local ws = opts.websocket
        local function check(value: any, name: string)
            if value ~= nil and type(value) ~= "function" then
                error(`expected websocket.{name} to be a function`, 0)
            end
        end
        check(ws.upgrade, "upgrade")
        check(ws.open, "open")
        check(ws.message, "message")
        check(ws.close, "close")
        if ws.upgrade ~= nil or ws.open ~= nil or ws.message ~= nil or ws.close ~= nil then
            handlers = ws
        end
    end

    local keep_alive_timeout = keep_alive.timeout or 0
    local keep_alive_enabled = if keep_alive.enabled == nil then true else keep_alive.enabled
    assert(type(keep_alive_timeout) == "number", "expected keep_alive.timeout to be a number")
    assert(type(keep_alive_enabled) == "boolean", "expected keep_alive.enabled to be a boolean")

    local domain: "ipv4" | "ipv6" = if string.find(address, ":", 1, true) then "ipv6" else "ipv4"
    local socket = net.openSocket(domain, "stream", "tcp")
    if reuse_address then
        socket:setReuseAddress(true)
        socket:setReusePort(true)
    end
    socket:bindAddress(address, port)
    socket:listen(max_backlog)

    local bound = socket:address()
    local self: Server = {
        socket = socket,
        stopped = false,
        running = false,
        waiting = false,
        thread = nil,
        active = 0,
        address = address,
        port = bound.port or port,
        waiter = nil,
        clients = {},
        stop = stopServer,
    }

    task.spawn(
        startServer,
        self,
        tls_auth,
        max_body_size,
        max_connections,
        client_timeout,
        keep_alive_timeout,
        keep_alive_enabled,
        callback,
        handlers
    )

    return self
end

return server
