--!strict
local TEMP_DIR = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")

local net = zune.net
local task = zune.task

local fs = require("@zune/fs")
local testing = require("@zune/testing")

local expect = testing.expect
local test = testing.test

test("basic stream", function()
    local server_socket = net.openSocket(net.ADDRF.INET, net.SOCK.STREAM, net.IPPROTO.TCP)

    server_socket:setReuseAddress(true)
    server_socket:setReusePort(true)

    server_socket:bindAddress("127.0.0.1", 0)
    server_socket:listen(2)
    local server_address = server_socket:address()

    local client_socket = net.openSocket("ipv4", "stream", "tcp")

    local disconnected: thread? = coroutine.running()
    task.spawn(function()
        local connection_socket = server_socket:accept()

        local b = buffer.create(19)
        for i = 1, 3 do
            local sent, send_err = connection_socket:send(`Hello from server {i}`)
            expect(sent).toBe(19)
            expect(send_err).toBeNil()

            local bytes, recv_err = connection_socket:recv(b, 0)
            expect(bytes).toBe(19)
            expect(recv_err).toBeNil()
            expect(buffer.tostring(b)).toBe(`Hello from client {i}`)
        end

        local end_n, end_err = connection_socket:recv(b, 0)
        expect(end_n).toBe(0)
        expect(end_err).toBeNil()

        connection_socket:close()
        if disconnected and coroutine.status(disconnected) == "suspended" then
            task.spawn(disconnected)
        end
        disconnected = nil
    end)

    assert(server_address.port)
    client_socket:connectAddress("127.0.0.1", server_address.port)

    local b = buffer.create(19)
    for i = 1, 3 do
        local bytes, recv_err = client_socket:recv(b, 0)
        expect(bytes).toBe(19)
        expect(recv_err).toBeNil()
        expect(buffer.tostring(b)).toBe(`Hello from server {i}`)

        local sent, send_err = client_socket:sendVec({ { `Hello from `, 0, 10 } :: NetworkVec, ` client {i}` })
        expect(sent).toBe(19)
        expect(send_err).toBeNil()
    end

    client_socket:close()
    if disconnected then
        coroutine.yield()
    end
    server_socket:close()
end)

test("basic datagram", function()
    local socket_a = net.openSocket("ipv4", "dgram", "udp")
    local socket_b = net.openSocket("ipv4", "dgram", "udp")
    socket_a:bindAddress("127.0.0.1", 0)
    socket_b:bindAddress("127.0.0.1", 0)
    local address_a = socket_a:address()
    local address_b = socket_b:address()

    assert(address_a.port)
    assert(address_b.port)

    local sent_a, sent_a_err = socket_a:sendToAddress(address_b.address, address_b.port, "Hello from A")
    local sent_b, sent_b_err = socket_b:sendToAddress(address_a.address, address_a.port, "Hello from B")
    expect(sent_a).toBe(12)
    expect(sent_a_err).toBeNil()
    expect(sent_b).toBe(12)
    expect(sent_b_err).toBeNil()

    local b_a = buffer.create(13)
    local b_b = buffer.create(13)

    local bytes_a, address_a_from, err_a = socket_a:recvFrom(b_a, 0)
    local bytes_b, address_b_from, err_b = socket_b:recvFrom(b_b, 0)
    expect(bytes_a).toBe(12)
    expect(bytes_b).toBe(12)
    expect(err_a).toBeNil()
    expect(err_b).toBeNil()
    assert(address_a_from)
    assert(address_b_from)
    expect(address_a_from.address).toBe(address_b.address)
    expect(address_a_from.port).toBe(address_b.port)
    expect(address_b_from.address).toBe(address_a.address)
    expect(address_b_from.port).toBe(address_a.port)
    expect(buffer.readstring(b_a, 0, 12)).toBe("Hello from B")
    expect(buffer.readstring(b_b, 0, 12)).toBe("Hello from A")

    socket_a:close()
    socket_b:close()
end)

test("basic unix stream", function()
    if not net.HAS_UNIX_SOCKETS then
        error("SkipTest", 0)
    end
    if fs.stat(fs.path.join(TEMP_DIR, "zune_test.sock")).kind ~= "none" then
        fs.deleteFile(fs.path.join(TEMP_DIR, "zune_test.sock"))
    end
    local server_socket = net.openSocket("unix", "stream", "ip")
    server_socket:bindUnix(fs.path.join(TEMP_DIR, "zune_test.sock"))
    server_socket:listen(2)
    local server_address = server_socket:address()
    local client_socket = net.openSocket("unix", "stream", "ip")

    local disconnected: thread? = coroutine.running()
    task.spawn(function()
        local connection_socket = server_socket:accept()

        local b = buffer.create(19)
        for i = 1, 3 do
            connection_socket:send(`Hello from server {i}`)
            local bytes = connection_socket:recv(b, 0)
            assert(bytes == 19)
            expect(buffer.tostring(b)).toBe(`Hello from client {i}`)
        end

        connection_socket:close()
        if disconnected and coroutine.status(disconnected) == "suspended" then
            task.spawn(disconnected)
        end
        disconnected = nil
    end)

    client_socket:connectUnix(server_address.address)

    local b = buffer.create(19)
    for i = 1, 3 do
        local bytes = client_socket:recv(b, 0)
        assert(bytes == 19)
        expect(buffer.tostring(b)).toBe(`Hello from server {i}`)
        client_socket:send(`Hello from client {i}`)
    end

    client_socket:close()
    if disconnected then
        coroutine.yield()
    end
    server_socket:close()
end)

test("basic unix datagram", function()
    if not net.HAS_UNIX_SOCKETS then
        error("SkipTest", 0)
    end
    if fs.stat(fs.path.join(TEMP_DIR, "zune_test_a.sock")).kind ~= "none" then
        fs.deleteFile(fs.path.join(TEMP_DIR, "zune_test_a.sock"))
    end
    if fs.stat(fs.path.join(TEMP_DIR, "zune_test_b.sock")).kind ~= "none" then
        fs.deleteFile(fs.path.join(TEMP_DIR, "zune_test_b.sock"))
    end
    local socket_a = net.openSocket("unix", "dgram", "ip")
    local socket_b = net.openSocket("unix", "dgram", "ip")

    socket_a:bindUnix(fs.path.join(TEMP_DIR, "zune_test_a.sock"))
    local address_a = socket_a:address()

    socket_b:bindUnix(fs.path.join(TEMP_DIR, "zune_test_b.sock"))
    local address_b = socket_b:address()

    socket_a:sendToUnix(address_b.address, "Hello from A")
    socket_b:sendToUnix(address_a.address, "Hello from B")

    local b_a = buffer.create(13)
    local b_b = buffer.create(13)

    local bytes_a, address_a_from = socket_a:recvFrom(b_a, 0)
    local bytes_b, address_b_from = socket_b:recvFrom(b_b, 0)

    assert(address_a_from)
    assert(address_b_from)

    expect(address_a_from.address).toBe(fs.path.join(TEMP_DIR, "zune_test_b.sock"))
    expect(address_b_from.address).toBe(fs.path.join(TEMP_DIR, "zune_test_a.sock"))

    assert(bytes_a == 12)
    assert(bytes_b == 12)
    expect(buffer.readstring(b_a, 0, 12)).toBe("Hello from B")
    expect(buffer.readstring(b_b, 0, 12)).toBe("Hello from A")

    socket_a:close()
    socket_b:close()
end)

test("misuse", function()
    local socket = net.openSocket("ipv4", "stream", "tcp")
    local buf = buffer.create(1)

    expect(function()
        socket:send("x")
    end).toThrow("socket not connected")

    expect(function()
        socket:recv(buf)
    end).toThrow("socket not connected")

    socket:close()

    expect(function()
        socket:send("x")
    end).toThrow("socket closed")

    expect(function()
        socket:recv(buf)
    end).toThrow("socket closed")

    local listener = net.openSocket("ipv4", "stream", "tcp")

    expect(function()
        listener:accept()
    end).toThrow("socket not binded")

    listener:bindAddress("127.0.0.1", 0)

    expect(function()
        listener:accept()
    end).toThrow("socket not listening")

    expect(function()
        listener:bindAddress("127.0.0.1", 0)
    end).toThrow("socket already binded")

    local wide = net.openSocket("ipv4", "stream", "tcp")

    expect(function()
        wide:bindAddress("127.0.0.1", 70000)
    end).toThrow("port out of range")
    wide:close()

    expect(function()
        listener:shutdown("nope")
    end).toThrow("invalid shutdown how option")

    listener:listen(1)
    local peer = net.openSocket("ipv4", "stream", "tcp")
    local address = listener:address()
    assert(address.port)

    task.spawn(function()
        local accepted = listener:accept()
        accepted:close()
    end)
    peer:connectAddress("127.0.0.1", address.port)

    expect(function()
        peer:sendToAddress("127.0.0.1", address.port, "x")
    end).toThrow("socket has peer")

    local n, err = peer:send(buffer.create(0))
    expect(n).toBe(0)
    expect(err).toBeNil()

    peer:close()
    listener:close()
end)

test("basic stream tls", function()
    if fs.stat("/tmp/certs/test.crt").kind == "none" or fs.stat("/tmp/certs/test.key").kind == "none" then
        print("tls test certs not found, skipping test")
        error("SkipTest", 0)
    end
    local server_socket = net.openSocket("ipv4", "stream", "tcp")

    server_socket:setReuseAddress(true)
    server_socket:setReusePort(true)

    server_socket:bindAddress("127.0.0.1", 0)
    server_socket:listen(2)
    local server_address = server_socket:address()

    local client_socket = net.openSocket("ipv4", "stream", "tcp")

    local disconnected: thread? = coroutine.running()
    task.spawn(function()
        local server_tls = zune.crypto.tls.createServer(server_socket, {
            auth = zune.crypto.tls.keyPairFromFile("/tmp/certs/test.crt", "/tmp/certs/test.key"),
        })
        expect(server_tls.established).toBe(false)
        local connection_socket = server_socket:accept()

        local ciphertext = buffer.create(zune.crypto.tls.MAX_RECORD_SIZE)
        local cleartext = buffer.create(zune.crypto.tls.MAX_RECORD_SIZE)
        do
            local recv_amt = 0
            while true do
                recv_amt += connection_socket:recv(cleartext, 0)
                local done, consumed, produced = server_tls:handshake(cleartext, 0, recv_amt, ciphertext)
                if consumed > 0 then
                    buffer.copy(cleartext, 0, cleartext, consumed)
                end
                if done then
                    break
                end
                local sent = 0
                while sent < produced do
                    sent += connection_socket:send(ciphertext, sent, produced - sent)
                end
            end
        end

        for i = 1, 3 do
            local msg = `Hello from server {i}`
            local offset = 0
            while offset < #msg do
                buffer.writestring(cleartext, offset, msg)
                local consumed, produced = server_tls:encrypt(cleartext, 0, #msg - offset, ciphertext)
                offset += consumed
                local send = 0
                while send < produced do
                    send += connection_socket:send(ciphertext, send, produced - send)
                end
            end
            local recv_amt = 0
            local msg_len = 0
            while true do
                local bytes = connection_socket:recv(ciphertext, recv_amt)
                recv_amt += bytes
                local consumed, produced, _ = server_tls:decrypt(ciphertext, 0, recv_amt, cleartext, msg_len)
                recv_amt -= consumed
                msg_len += produced
                if consumed > 0 then
                    buffer.copy(ciphertext, 0, ciphertext, consumed)
                end
                if recv_amt == 0 then
                    break
                end
            end
            assert(msg_len == 19)
            expect(buffer.readstring(cleartext, 0, msg_len)).toBe(`Hello from client {i}`)
        end

        connection_socket:close()
        if disconnected and coroutine.status(disconnected) == "suspended" then
            task.spawn(disconnected)
        end
        disconnected = nil
    end)

    local client_tls = zune.crypto.tls.createClient(client_socket, {
        host = "example.test",
        ca = zune.crypto.tls.bundleFromFile("/tmp/certs/test.crt"),
    })
    assert(server_address.port)
    client_socket:connectAddress("127.0.0.1", server_address.port)
    expect(client_tls.established).toBe(false)
    local ciphertext = buffer.create(zune.crypto.tls.MAX_RECORD_SIZE)
    local cleartext = buffer.create(zune.crypto.tls.MAX_RECORD_SIZE)
    do
        local recv_amt = 0
        while true do
            local done, consumed, produced = client_tls:handshake(cleartext, 0, recv_amt, ciphertext)
            if consumed > 0 then
                buffer.copy(cleartext, 0, cleartext, consumed)
            end
            local sent = 0
            while sent < produced do
                sent += client_socket:send(ciphertext, sent, produced - sent)
            end
            if done then
                break
            end
            recv_amt += client_socket:recv(cleartext, 0)
        end
    end

    for i = 1, 3 do
        local msg = `Hello from client {i}`
        local offset = 0
        while offset < #msg do
            buffer.writestring(cleartext, offset, msg)
            local consumed, produced = client_tls:encrypt(cleartext, 0, #msg - offset, ciphertext)
            offset += consumed
            local send = 0
            while send < produced do
                send += client_socket:send(ciphertext, send, produced - send)
            end
        end
        expect(offset).toBe(#msg)
        local recv_amt = 0
        local msg_len = 0
        while true do
            local bytes = client_socket:recv(ciphertext, recv_amt)
            recv_amt += bytes
            local consumed, produced = client_tls:decrypt(ciphertext, 0, recv_amt, cleartext, msg_len)
            recv_amt -= consumed
            msg_len += produced
            if consumed > 0 then
                buffer.copy(ciphertext, 0, ciphertext, consumed)
            end
            if recv_amt == 0 then
                break
            end
        end
        assert(msg_len == 19)
        expect(buffer.readstring(cleartext, 0, msg_len)).toBe(`Hello from server {i}`)
    end

    client_socket:close()
    if disconnected then
        coroutine.yield()
    end
    server_socket:close()
end)

return nil
