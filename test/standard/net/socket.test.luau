--!strict
local net = zune.net;
local task = zune.task;
local testing = zune.testing;

local expect = testing.expect;
local test = testing.test;

test("Basic TCP", function()
    local server_socket = net.createSocket(
        net.ADDRF.INET,
        bit32.bor(net.SOCKF.STREAM, net.SOCKF.CLOEXEC, net.SOCKF.NONBLOCK),
        net.IPPROTO.TCP
    );

    server_socket:setOption(net.SOCKOPTLV.SOCKET, net.SOCKOPT.REUSEADDR, true);
    if (net.SOCKOPT.REUSEPORT) then
        server_socket:setOption(net.SOCKOPTLV.SOCKET, net.SOCKOPT.REUSEPORT, true);
    end

    server_socket:bindIp("127.0.0.1", 0);
    server_socket:listen(2);
    local server_sockname = server_socket:getName();

    local client_socket = net.createSocket(
        server_sockname.family,
        bit32.bor(
            net.SOCKF.STREAM,
            if (zune.process.os == "windows") then 0 else net.SOCKF.CLOEXEC
        ),
        net.IPPROTO.TCP
    );

    task.spawn(function()
        local connection_socket = server_socket:accept();

        for i = 1, 3 do
            connection_socket:send(`Hello from server {i}`);
            local bytes = connection_socket:recv(19);
            expect(buffer.tostring(bytes)).toBe(`Hello from client {i}`);
        end

        connection_socket:close();
    end)

    client_socket:connect("127.0.0.1", server_sockname.port);

    for i = 1, 3 do
        local bytes = client_socket:recv(19);
        expect(buffer.tostring(bytes)).toBe(`Hello from server {i}`);
        client_socket:send(`Hello from client {i}`);
    end

    client_socket:close();
    
    task.wait(0.5);
end)

test("Basic TCP TLS", function()
    if (zune.process.args[1] ~= "allow") then
        print("Skipping TLS test");
        return;
    end
    
    local server_socket = net.createSocket(
        net.ADDRF.INET,
        bit32.bor(net.SOCKF.STREAM, net.SOCKF.CLOEXEC, net.SOCKF.NONBLOCK),
        net.IPPROTO.TCP
    );

    zune.crypto.tls.setupServer(server_socket, {
        auth = zune.crypto.tls.keyPairFromFile("test/standard/net/cert.pem", "test/standard/net/key.pem"),
    });

    server_socket:setOption(net.SOCKOPTLV.SOCKET, net.SOCKOPT.REUSEADDR, true);
    if (net.SOCKOPT.REUSEPORT) then
        server_socket:setOption(net.SOCKOPTLV.SOCKET, net.SOCKOPT.REUSEPORT, true);
    end

    server_socket:bindIp("127.0.0.1", 0);
    server_socket:listen(2);
    local server_sockname = server_socket:getName();

    local client_socket = net.createSocket(
        server_sockname.family,
        bit32.bor(
            net.SOCKF.STREAM,
            if (zune.process.os == "windows") then 0 else net.SOCKF.CLOEXEC
        ),
        net.IPPROTO.TCP
    );

    zune.crypto.tls.setupClient(client_socket, {
        host = "",
        ca = zune.crypto.tls.bundleFromFile("test/standard/net/cert.pem"),
    });

    task.spawn(function()
        local connection_socket = server_socket:accept();

        for i = 1, 3 do
            connection_socket:send(`Hello from server {i}`);
            local bytes = connection_socket:recv(19);
            expect(buffer.tostring(bytes)).toBe(`Hello from client {i}`);
        end
        connection_socket:close();
    end)

    client_socket:connect("127.0.0.1", server_sockname.port);

    for i = 1, 3 do
        local bytes = client_socket:recv(19);
        expect(buffer.tostring(bytes)).toBe(`Hello from server {i}`);
        client_socket:send(`Hello from client {i}`);
    end

    client_socket:close();

    task.wait(0.5);
end)

return nil;
