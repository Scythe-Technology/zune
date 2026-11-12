--!strict

local net = zune.net
local task = zune.task
local crypto = zune.crypto
local mem = zune.mem

local testing = require("@zune/testing")
local websocket = require("@zune/net/http/websocket")
local HttpServer = require("@zune/net/http/server")
local HttpClient = require("@zune/net/http/client")
local support = require("./support")

local expect = testing.expect
local test = testing.test

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type Recv = (Socket, buffer, number?, number?, number?) -> (number, string?)

local function sendAll(sock: Socket, src: string | buffer)
    local total = if type(src) == "string" then #src else buffer.len(src)
    local sent = 0
    while sent < total do
        local n, err = sock:send(src, sent, total - sent)
        if err ~= nil or n == 0 then
            error(err or "short write", 0)
        end
        sent += n
    end
end

local function acceptOf(key: string): string
    local hasher = crypto.createHash("sha1")
    hasher:update(key)
    hasher:update(GUID)
    return hasher:digest("base64") :: string
end

local function switching(key: string): string
    return "HTTP/1.1 101 Switching Protocols\r\n"
        .. "Upgrade: websocket\r\n"
        .. "Connection: Upgrade\r\n"
        .. `Sec-WebSocket-Accept: {acceptOf(key)}\r\n\r\n`
end

local function unmasked(opcode: number, payload: string, fin: boolean?): buffer
    local raw = buffer.fromstring(payload)
    local plen = #payload
    local len7 = if plen < 126 then plen elseif plen <= 65535 then 126 else 127
    local ext = if len7 == 126 then 2 elseif len7 == 127 then 8 else 0
    local out = buffer.create(2 + ext + plen)
    local flags = if fin == false then 0 else 0x80
    buffer.writeu8(out, 0, opcode + flags)
    buffer.writeu8(out, 1, len7)
    local pos = 2
    if len7 == 126 then
        buffer.writeu8(out, 2, bit32.rshift(plen, 8))
        buffer.writeu8(out, 3, bit32.band(plen, 0xFF))
        pos = 4
    elseif len7 == 127 then
        local n = plen
        for i = 7, 0, -1 do
            buffer.writeu8(out, 2 + i, n % 256)
            n = math.floor(n / 256)
        end
        pos = 10
    end
    if plen > 0 then
        buffer.copy(out, pos, raw, 0, plen)
    end
    return out
end

local function listen(handler: (Socket) -> ())
    local listener = net.openSocket("ipv4", "stream", "tcp")
    listener:bindAddress("127.0.0.1", 0)
    listener:listen(16)
    local port = listener:address().port
    if port == nil then
        error("missing port", 0)
    end
    testing.defer(function()
        pcall(function()
            listener:close()
        end)
    end)
    task.spawn(function()
        local ok, conn = pcall(function()
            return listener:accept()
        end)
        if not ok or conn == nil then
            return
        end
        local peer = conn :: Socket
        pcall(handler, peer)
        pcall(function()
            peer:close()
        end)
    end)
    return port
end

local function headerText(peer: Socket): (string, string)
    local recv = peer.recv :: Recv
    local buf = buffer.create(1024)
    local store = ""
    while string.find(store, "\r\n\r\n", 1, true) == nil do
        local amt, err = recv(peer, buf, 0, 1024, 2)
        if err ~= nil then
            error(err, 0)
        end
        if amt == 0 then
            error("eof", 0)
        end
        store ..= buffer.readstring(buf, 0, amt)
        if #store > 8192 then
            error("headers", 0)
        end
    end
    local at = string.find(store, "\r\n\r\n", 1, true) :: number
    return string.sub(store, 1, at + 3), string.sub(store, at + 4)
end

type Reader = {
    frame: (self: Reader) -> (number, string, boolean),
}

local function reader(peer: Socket, pending: string): Reader
    local inbox = if #pending > 0 then buffer.fromstring(pending) else buffer.create(0)
    local recv = peer.recv :: Recv
    local self = {}
    function self.frame(_self: Reader): (number, string, boolean)
        local function pull(n: number): buffer
            while buffer.len(inbox) < n do
                local chunk = buffer.create(4096)
                local amt, err = recv(peer, chunk, 0, 4096, 2)
                if err ~= nil then
                    error(err, 0)
                end
                if amt == 0 then
                    error("eof", 0)
                end
                local have = buffer.len(inbox)
                local grown = buffer.create(have + amt)
                if have > 0 then
                    buffer.copy(grown, 0, inbox, 0, have)
                end
                buffer.copy(grown, have, chunk, 0, amt)
                inbox = grown
            end
            local out = mem.slice(inbox, 0, n)
            local rest = buffer.len(inbox) - n
            inbox = if rest == 0 then buffer.create(0) else mem.slice(inbox, n, rest)
            return out
        end

        local hdr = pull(2)
        local b0 = buffer.readu8(hdr, 0)
        local b1 = buffer.readu8(hdr, 1)
        local fin = bit32.band(b0, 0x80) ~= 0
        local opcode = bit32.band(b0, 0x0F)
        if bit32.band(b1, 0x80) == 0 then
            error("client frame was not masked", 0)
        end
        local len = bit32.band(b1, 0x7F)
        if len == 126 then
            local ext = pull(2)
            len = buffer.readu8(ext, 0) * 256 + buffer.readu8(ext, 1)
        elseif len == 127 then
            local ext = pull(8)
            len = 0
            for i = 0, 7 do
                len = len * 256 + buffer.readu8(ext, i)
            end
        end
        local mask = pull(4)
        local payload = if len > 0 then pull(len) else buffer.create(0)
        for i = 0, len - 1 do
            buffer.writeu8(payload, i, bit32.bxor(buffer.readu8(payload, i), buffer.readu8(mask, i % 4)))
        end
        return opcode, buffer.tostring(payload), fin
    end
    return self :: Reader
end

local function keyFrom(head: string): string
    local key = string.match(head, "Sec%-WebSocket%-Key: ([%w+/=]+)")
    if key == nil then
        error("missing key", 0)
    end
    return key
end

test("rejects bad requests", function()
    expect(function()
        websocket.connect("not a url")
    end).toThrow("unsupported URI scheme")
    expect(function()
        websocket.connect("http://127.0.0.1/")
    end).toThrow("unsupported URI scheme")
    expect(function()
        websocket.connect("ws://")
    end).toThrow("URI missing host")
    expect(function()
        websocket.connect("ws://127.0.0.1/", { timeout = 0 })
    end).toThrow("timeout cannot be 0")
    expect(function()
        websocket.connect("ws://127.0.0.1/", {
            headers = { Upgrade = "nope" },
        })
    end).toThrow("upgrade cannot be set")
    expect(function()
        websocket.connect("ws://127.0.0.1/", {
            headers = { ["Sec-WebSocket-Protocol"] = "chat" },
        })
    end).toThrow("sec-websocket-protocol must be set in protocols, not headers")
    expect(function()
        websocket.connect("ws://127.0.0.1/", "nope" :: any)
    end).toThrow("expected options to be a table")
end)

test("echo, fragments, and close", function()
    local messages: { string } = {}
    local kinds: { string } = {}
    local closed: number? = nil
    local port = listen(function(peer)
        local head, rest = headerText(peer)
        expect(string.find(head, "GET /chat?x=1 HTTP/1.1", 1, true)).toBeTruthy()
        expect(string.find(head, "Host: 127.0.0.1\r\n", 1, true)).toBeTruthy()
        expect(string.find(head, "Upgrade: websocket", 1, true)).toBeTruthy()
        expect(string.find(head, "Connection: keep-alive, Upgrade", 1, true)).toBeTruthy()
        expect(string.find(head, "Sec-WebSocket-Version: 13", 1, true)).toBeTruthy()
        expect(string.find(head, "Sec-WebSocket-Protocol: chat, superchat", 1, true)).toBeTruthy()
        expect(string.find(head, `User-Agent: {support.agent()}`, 1, true)).toBeTruthy()
        local early = unmasked(0x1, "early")
        local opening = buffer.create(#switching(keyFrom(head)) + buffer.len(early))
        buffer.writestring(opening, 0, switching(keyFrom(head)))
        buffer.copy(opening, #switching(keyFrom(head)), early, 0, buffer.len(early))
        sendAll(peer, opening)
        if #rest > 0 then
            error("request spilled into frames", 0)
        end
        local frames = reader(peer, "")
        local op, text = frames:frame()
        expect(op).toBe(0x1)
        expect(text).toBe("hi")
        sendAll(peer, unmasked(0x1, "hi"))
        op, text = frames:frame()
        expect(op).toBe(0x2)
        expect(text).toBe("bin")
        sendAll(peer, unmasked(0x2, "bin"))
        local part = buffer.create(buffer.len(unmasked(0x1, "AB", false)) + buffer.len(unmasked(0x0, "CD", true)))
        local left = unmasked(0x1, "AB", false)
        local right = unmasked(0x0, "CD", true)
        buffer.copy(part, 0, left, 0, buffer.len(left))
        buffer.copy(part, buffer.len(left), right, 0, buffer.len(right))
        sendAll(peer, part)
        op, text = frames:frame()
        expect(op).toBe(0x8)
        expect(string.byte(text, 1)).toBe(0x03)
        expect(string.byte(text, 2)).toBe(0xE8)
        sendAll(peer, unmasked(0x8, string.char(3, 232)))
    end)

    local sock = websocket.connect(`ws://127.0.0.1:{port}/chat?x=1`, {
        protocols = { "chat", "superchat" },
        message = function(_sock, message)
            table.insert(kinds, type(message))
            if type(message) == "buffer" then
                table.insert(messages, buffer.tostring(message))
            else
                table.insert(messages, message)
            end
        end,
        close = function(_sock, closeCode)
            closed = closeCode
        end,
        error = function(_sock, scope, err)
            error(`{scope}: {err}`, 0)
        end,
    })
    testing.defer(function()
        sock:close()
    end)

    expect(sock:isConnected()).toBe(true)
    repeat
        task.wait()
    until #messages >= 1
    expect(messages[1]).toBe("early")
    sock:send("hi")
    repeat
        task.wait()
    until #messages >= 2
    expect(messages[2]).toBe("hi")
    sock:send(buffer.fromstring("bin"))
    repeat
        task.wait()
    until #messages >= 4
    expect(kinds[3]).toBe("buffer")
    expect(messages[3]).toBe("bin")
    expect(messages[4]).toBe("ABCD")
    sock:close(1000)
    repeat
        task.wait()
    until closed ~= nil
    expect(closed).toBe(1000)
    expect(sock:isConnected()).toBe(false)
end, 5)

test("large payload", function()
    local body = string.rep("a", 20000)
    local got: string? = nil
    local port = listen(function(peer)
        local head = headerText(peer)
        sendAll(peer, switching(keyFrom(head)))
        local frames = reader(peer, "")
        local op, text = frames:frame()
        expect(op).toBe(0x1)
        expect(text).toBe(body)
        sendAll(peer, unmasked(0x1, text))
        frames:frame()
    end)
    local sock = websocket.connect(`ws://127.0.0.1:{port}/`, {
        message = function(_sock, message)
            got = message :: string
        end,
    })
    testing.defer(function()
        sock:close()
    end)
    sock:send(body)
    repeat
        task.wait()
    until got ~= nil
    expect(got).toBe(body)
    sock:close()
end, 5)

test("ping is echoed", function()
    local got: string? = nil
    local port = listen(function(peer)
        local head = headerText(peer)
        sendAll(peer, switching(keyFrom(head)))
        sendAll(peer, unmasked(0x9, "xy"))
        local frames = reader(peer, "")
        local op, text, fin = frames:frame()
        expect(op).toBe(0xA)
        expect(fin).toBe(true)
        expect(text).toBe("xy")
        sendAll(peer, unmasked(0x1, "ok"))
        frames:frame()
    end)
    local sock = websocket.connect(`ws://127.0.0.1:{port}/`, {
        message = function(_sock, message)
            got = message :: string
        end,
    })
    testing.defer(function()
        sock:close()
    end)
    repeat
        task.wait()
    until got ~= nil
    expect(got).toBe("ok")
    sock:close()
end, 5)

test("masked server frame and oversized message", function()
    local errors: { string } = {}
    local closed: number? = nil
    local port = listen(function(peer)
        local head = headerText(peer)
        local frame = buffer.create(6)
        buffer.writeu8(frame, 0, 0x81)
        buffer.writeu8(frame, 1, 0x84)

        sendAll(peer, switching(keyFrom(head)) .. buffer.tostring(frame) .. "abcd")
        local frames = reader(peer, "")
        local op = frames:frame()
        expect(op).toBe(0x8)
    end)
    local sock = websocket.connect(`ws://127.0.0.1:{port}/`, {
        error = function(_sock, _scope, err)
            table.insert(errors, err)
        end,
        close = function(_sock, closeCode)
            closed = closeCode
        end,
    })
    testing.defer(function()
        sock:close()
    end)
    repeat
        task.wait()
    until closed ~= nil
    expect(errors[1]).toBe("MaskedMessage")
    expect(closed).toBe(1002)
end, 5)

test("message too large", function()
    local errors: { string } = {}
    local closed: number? = nil
    local port = listen(function(peer)
        local head = headerText(peer)
        sendAll(peer, switching(keyFrom(head)) .. buffer.tostring(unmasked(0x1, "hello")))
        local frames = reader(peer, "")
        local op = frames:frame()
        expect(op).toBe(0x8)
    end)
    local sock = websocket.connect(`ws://127.0.0.1:{port}/`, {
        max_message = 4,
        error = function(_sock, _scope, err)
            table.insert(errors, err)
        end,
        close = function(_sock, closeCode)
            closed = closeCode
        end,
    })
    testing.defer(function()
        sock:close()
    end)
    repeat
        task.wait()
    until closed ~= nil
    expect(errors[1]).toBe("message too large")
    expect(closed).toBe(1009)
end, 5)

test("upgrade failed, rejected, and timeout", function()
    local refused = listen(function(peer)
        headerText(peer)
        sendAll(peer, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    end)
    expect(function()
        websocket.connect(`ws://127.0.0.1:{refused}/`)
    end).toThrow("upgrade failed")

    local rejected = listen(function(peer)
        local head = headerText(peer)
        sendAll(peer, switching(keyFrom(head)))
    end)
    expect(function()
        websocket.connect(`ws://127.0.0.1:{rejected}/`, {
            accept = function()
                return false
            end,
        })
    end).toThrow("upgrade rejected")

    local slow = listen(function(peer)
        headerText(peer)
        local buf = buffer.create(16)
        local recv = peer.recv :: Recv
        pcall(function()
            recv(peer, buf, 0, 16, 2)
        end)
    end)
    expect(function()
        websocket.connect(`ws://127.0.0.1:{slow}/`, { timeout = 0.25 })
    end).toThrow("timed out")
end, 5)

test("invalid close code", function()
    local port = listen(function(peer)
        local head = headerText(peer)
        sendAll(peer, switching(keyFrom(head)))
        local frames = reader(peer, "")
        frames:frame()
    end)
    local sock = websocket.connect(`ws://127.0.0.1:{port}/`)
    testing.defer(function()
        sock:close()
    end)
    expect(sock:isConnected()).toBe(true)
    expect(function()
        sock:close(1005)
    end).toThrow("invalid close code, cannot be used")
    expect(sock:isConnected()).toBe(true)
    sock:close()
end, 5)

local function waitFor(pred: () -> boolean)
    local started = os.clock()
    while not pred() do
        if os.clock() - started > 2 then
            error("timed out waiting", 0)
        end
        task.wait(0.02)
    end
end

test("server upgrade", function()
    local events: { string } = {}
    local server = HttpServer.serve({
        port = 0,
        address = "127.0.0.1",
        reuse_address = true,
        request = function()
            table.insert(events, "request")
            return "plain"
        end,
        websocket = {
            upgrade = function(req)
                table.insert(events, `upgrade:{req.path}`)
                return true
            end,
            open = function(ws)
                table.insert(events, "open")
                expect(ws:isConnected()).toBe(true)
            end,
            message = function(ws, message)
                table.insert(events, `message:{message}`)
                if type(message) == "buffer" then
                    local copy = buffer.create(buffer.len(message))
                    buffer.copy(copy, 0, message, 0, buffer.len(message))
                    ws:send(copy)
                    return
                end
                ws:send(`Echo: {message}`)
                if message == "bye" then
                    ws:close(1000)
                end
            end,
            close = function(_ws, code)
                table.insert(events, `close:{code}`)
            end,
        },
    })
    testing.defer(function()
        server:stop()
    end)

    local plain = HttpClient.request(`http://127.0.0.1:{server.port}/index`)
    expect(plain.ok).toBe(true)
    expect(support.text(plain.body)).toBe("plain")
    expect(events).toBe(expect.similar({ "request" }))

    local client_events: { string } = {}
    local sock = websocket.connect(`ws://127.0.0.1:{server.port}/chat?x=1`, {
        message = function(_sock, message)
            if type(message) == "buffer" then
                table.insert(client_events, buffer.tostring(message))
            else
                table.insert(client_events, message)
            end
        end,
        close = function(_sock, code)
            table.insert(client_events, `close:{code}`)
        end,
    })
    testing.defer(function()
        sock:close()
    end)
    expect(sock:isConnected()).toBe(true)
    expect(events).toBe(expect.similar({ "request", "upgrade:/chat?x=1", "open" }))

    sock:send("hi")
    waitFor(function()
        return #client_events >= 1
    end)
    expect(client_events[1]).toBe("Echo: hi")

    local blob = buffer.fromstring("xyz")
    sock:send(blob)
    waitFor(function()
        return #client_events >= 2
    end)
    expect(client_events[2]).toBe("xyz")

    sock:send("bye")
    waitFor(function()
        return events[#events] == "close:1000"
    end)
    expect(client_events).toBe(expect.similar({ "Echo: hi", "xyz", "Echo: bye", "close:1000" }))
    expect(sock:isConnected()).toBe(false)
end, 5)

test("server rejects the upgrade", function()
    local saw = false
    local server = HttpServer.serve({
        port = 0,
        address = "127.0.0.1",
        reuse_address = true,
        request = function()
            return "no"
        end,
        websocket = {
            upgrade = function()
                saw = true
                return false
            end,
        },
    })
    testing.defer(function()
        server:stop()
    end)
    expect(function()
        websocket.connect(`ws://127.0.0.1:{server.port}/`)
    end).toThrow("upgrade failed")
    expect(saw).toBe(true)
end, 5)

test("server stop closes the socket", function()
    local opened = false
    local server = HttpServer.serve({
        port = 0,
        address = "127.0.0.1",
        reuse_address = true,
        request = function()
            return ""
        end,
        websocket = {
            open = function()
                opened = true
            end,
        },
    })
    local sock = websocket.connect(`ws://127.0.0.1:{server.port}/`)
    expect(opened).toBe(true)
    expect(sock:isConnected()).toBe(true)
    server:stop()
    waitFor(function()
        return not sock:isConnected()
    end)
    expect(sock:isConnected()).toBe(false)
end, 5)

return nil
