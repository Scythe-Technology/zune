--!strict
-- Shared by the HTTP suites. Not a `*.test.luau`, so the lib runner does not execute it.

local net = zune.net
local task = zune.task

local HttpServer = require("@zune/net/http/server")
local HttpClient = require("@zune/net/http/client")

export type Server = HttpServer.Server
export type Response = HttpServer.Response
export type ClientResponse = HttpClient.Response

export type Incoming = {
    method: string,
    path: string,
    headers: { [string]: string },
    body: buffer?,
}

export type Seen = {
    method: string,
    path: string,
    host: string?,
    connection: string?,
    contentType: string?,
    contentLength: string?,
    userAgent: string?,
    body: string?,
}

export type ServeExtra = {
    max_body_size: number?,
    max_connections: number?,
    client_timeout: number?,
}

type RecvWithDeadline = (
    self: Socket,
    dest: buffer,
    destOffset: number?,
    count: number?,
    timeout: number?
) -> (number, string?)

local support = {}

support.client = HttpClient

function support.agent(): string
    local version = string.match(_VERSION, "^zune%s+([^%+]+)") or "0.0.0"
    return `zune/{version}`
end

function support.text(body: buffer?): string
    if body == nil then
        return ""
    end
    return buffer.tostring(body)
end

function support.url(server: Server, path: string?): string
    return `http://127.0.0.1:{server.port}{path or "/"}`
end

function support.serve(request: (incoming: Incoming) -> string | Response, extra: ServeExtra?): Server
    local opts: HttpServer.ServeOptions = {
        port = 0,
        address = "127.0.0.1",
        reuse_address = true,
        request = request,
    }
    if extra then
        opts.max_body_size = extra.max_body_size
        opts.max_connections = extra.max_connections
        opts.client_timeout = extra.client_timeout
    end
    return HttpServer.serve(opts)
end

function support.record(incoming: Incoming): Seen
    local headers = incoming.headers
    return {
        method = incoming.method,
        path = incoming.path,
        host = headers.host,
        connection = headers.connection,
        contentType = headers["content-type"],
        contentLength = headers["content-length"],
        userAgent = headers["user-agent"],
        body = if incoming.body then buffer.tostring(incoming.body) else nil,
    }
end

function support.closedPort(): number
    local socket = net.openSocket("ipv4", "stream", "tcp")
    socket:bindAddress("127.0.0.1", 0)
    local port = socket:address().port
    socket:close()
    if port == nil then
        error("missing port", 0)
    end
    return port
end

-- Writes `data`, then reads until the peer closes. A transfer error is raised.
function support.exchange(port: number, data: string, timeout: number?): string
    local socket = net.openSocket("ipv4", "stream", "tcp")
    socket:connectAddress("127.0.0.1", port)
    local payload = buffer.fromstring(data)
    local sent = 0
    while sent < buffer.len(payload) do
        local wrote, err = socket:send(payload, sent)
        if err ~= nil then
            error(err, 0)
        end
        sent += wrote
    end
    local incoming = buffer.create(8192)
    local recv: RecvWithDeadline = socket.recv :: any
    local got = 0
    while got < buffer.len(incoming) do
        local n, err = recv(socket, incoming, got, nil, timeout or 2)
        if err ~= nil then
            error(err, 0)
        end
        if n == 0 then
            break
        end
        got += n
    end
    socket:close()
    return buffer.readstring(incoming, 0, got)
end

-- Accepts one request and writes `response` unchanged. The caller closes `listener`.
function support.rawServe(response: string): Socket
    local listener = net.openSocket("ipv4", "stream", "tcp")
    listener:bindAddress("127.0.0.1", 0)
    listener:listen(4)
    task.spawn(function()
        local accepted, conn = pcall(function()
            return listener:accept()
        end)
        if not accepted then
            return
        end
        local peer = conn :: Socket
        local buf = buffer.create(4096)
        local recv: RecvWithDeadline = peer.recv :: any
        local got = 0
        while got < buffer.len(buf) do
            local n, err = recv(peer, buf, got, nil, 2)
            if err ~= nil then
                error(err, 0)
            end
            if n == 0 then
                break
            end
            got += n
            if string.find(buffer.readstring(buf, 0, got), "\r\n\r\n", 1, true) then
                break
            end
        end
        local payload = buffer.fromstring(response)
        local sent = 0
        while sent < buffer.len(payload) do
            local wrote, err = peer:send(payload, sent)
            if err ~= nil then
                error(err, 0)
            end
            sent += wrote
        end
        peer:close()
    end)
    return listener
end

return support
