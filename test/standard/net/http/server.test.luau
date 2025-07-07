--!strict
local net = zune.net;
local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

test("Basic", function()
    local requests: {ServerRequest} = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(requests, req);
            return {
                statusCode = 200,
                body = "Hello",
            }
        end,
    });
    expect(server).toBe(expect.type("userdata"));

    local res = net.http.request("http://localhost:8080");
    expect(res).toBe(expect.type("table"));
    expect(res.ok).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe("Hello");
    expect(res.headers).toBe(expect.type("table"));
    expect(res.headers["Content-Length"]).toBe("5");
    expect(res.statusReason).toBe("OK");

    expect(requests).toHaveLength(1);

    local request = requests[1];
    expect(request).toBe(expect.type("table"));
    expect(request.method).toBe("GET");
    expect(request.path).toBe("/");
    expect(request.headers).toBe(expect.type("table"));
    expect(request.headers["host"]).toBe("localhost:8080");
    expect(request.headers["user-agent"]).toBe("zune/" .. version);
    
    expect(function()
        local _ = net.http.request("http://localhost:8085");
    end).toThrow("ConnectionRefused");

    expect(requests).toHaveLength(1);

    expect(not server:isRunning()).toBe(false);
    server:stop();
    expect(not server:isRunning()).toBe(true);
    server:stop();
    expect(not server:isRunning()).toBe(true);
    expect(requests);

    expect(function()
        local _ = net.http.request("http://localhost:8080");
    end).toThrow("ConnectionRefused");

    expect(requests).toHaveLength(1);
end)

test("Other method", function()
    local requests: {ServerRequest} = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(requests, req);
            return {
                statusCode = 200,
                body = "Hello",
            }
        end,
    });
    testing.defer(function()
        server:stop();
    end)
    expect(server).toBe(expect.type("userdata"));

    local res = net.http.request("http://localhost:8080", {
        method = "PUT",
        headers = {
            ["Content-Type"] = "text/plain",
        },
        body = "test",
    });
    expect(res).toBe(expect.type("table"));
    expect(res.ok).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe("Hello");
    expect(res.headers).toBe(expect.type("table"));
    expect(res.headers["Content-Length"]).toBe("5");
    expect(res.statusReason).toBe("OK");

    expect(requests).toHaveLength(1);

    local request = requests[1];
    expect(request).toBe(expect.type("table"));
    expect(request.method).toBe("PUT");
    expect(request.path).toBe("/");
    expect(request.headers).toBe(expect.type("table"));
    expect(request.headers["host"]).toBe("localhost:8080");
    expect(request.headers["user-agent"]).toBe("zune/" .. version);
    expect(request.headers["content-type"]).toBe("text/plain");
    expect(request.headers["content-length"]).toBe("4");
    expect(request.body).toBe("test");
end)

test("Basic Table Buffer", function()
    local requests = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(requests, req);
            return {
                statusCode = 200,
                body = buffer.fromstring("Hello Table Buffer"),
            }
        end,
    });
    expect(server).toBe(expect.type("userdata"));

    local res = net.http.request("http://localhost:8080");
    expect(res).toBe(expect.type("table"));
    expect(res.ok).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe("Hello Table Buffer");
    expect(res.headers).toBe(expect.type("table"));
    expect(res.headers["Content-Length"]).toBe("18");
    expect(res.statusReason).toBe("OK");

    expect(requests).toHaveLength(1);

    local request = requests[1];
    expect(request).toBe(expect.type("table"));
    expect(request.method).toBe("GET");
    expect(request.path).toBe("/");
    expect(request.headers).toBe(expect.type("table"));
    expect(request.headers["host"]).toBe("localhost:8080");
    expect(request.headers["user-agent"]).toBe("zune/" .. version);

    expect(not server:isRunning()).toBe(false);
    server:stop();
    expect(not server:isRunning()).toBe(true);
end)

test("Basic Buffer", function()
    local requests = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(requests, req);
            return buffer.fromstring("Hello Buffer");
        end,
    });
    expect(server).toBe(expect.type("userdata"));

    local res = net.http.request("http://localhost:8080");
    expect(res).toBe(expect.type("table"));
    expect(res.ok).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe("Hello Buffer");
    expect(res.headers).toBe(expect.type("table"));
    expect(res.headers["Content-Length"]).toBe("12");
    expect(res.statusReason).toBe("OK");

    expect(requests).toHaveLength(1);

    local request = requests[1];
    expect(request).toBe(expect.type("table"));
    expect(request.method).toBe("GET");
    expect(request.path).toBe("/");
    expect(request.headers).toBe(expect.type("table"));
    expect(request.headers["host"]).toBe("localhost:8080");
    expect(request.headers["user-agent"]).toBe("zune/" .. version);

    expect(not server:isRunning()).toBe(false);
    server:stop();
    expect(not server:isRunning()).toBe(true);
end)

test("Long Term", function()
    local requests = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(requests, req);
            return "Hello: " .. #requests;
        end,
    });
    expect(server).toBe(expect.type("userdata"));

    local requestsMade = 0;

    for _ = 1, 10 do
        local res = net.http.request("http://localhost:8080");
        requestsMade += 1;

        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(res.body).toBe("Hello: " .. requestsMade);
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe(tostring(7 + #tostring(requestsMade)));
        expect(res.statusReason).toBe("OK");

        expect(requests).toHaveLength(requestsMade);

        local request = requests[requestsMade];
        expect(request).toBe(expect.type("table"));
        expect(request.method).toBe("GET");
        expect(request.path).toBe("/");
        expect(request.headers).toBe(expect.type("table"));
        expect(request.headers["host"]).toBe("localhost:8080");
        expect(request.headers["user-agent"]).toBe("zune/" .. version);

    end

    expect(function()
        local _ = net.http.request("http://localhost:8085");
    end).toThrow("ConnectionRefused");

    expect(requests).toHaveLength(requestsMade);

    expect(not server:isRunning()).toBe(false);
    server:stop();
    expect(not server:isRunning()).toBe(true);
    server:stop();
    expect(not server:isRunning()).toBe(true);

    expect(function()
        local _ = net.http.request("http://localhost:8080");
    end).toThrow("ConnectionRefused");

    expect(requests).toHaveLength(requestsMade);
end)

test("Short Capacity", function()
    local requests = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        maxConnections = 1,
        request = function(req)
            table.insert(requests, req);
            return "Hello: " .. #requests;
        end,
    });
    expect(server).toBe(expect.type("userdata"));

    local requestsMade = 0;

    for _ = 1, 4 do
        task.spawn(function()
            local res = net.http.request("http://localhost:8080");
            requestsMade += 1;
    
            expect(res).toBe(expect.type("table"));
            expect(res.ok).toBe(true);
            expect(res.statusCode).toBe(200);
            expect(res.body).toBe("Hello: " .. requestsMade);
            expect(res.headers).toBe(expect.type("table"));
            expect(res.headers["Content-Length"]).toBe(tostring(7 + #tostring(requestsMade)));
            expect(res.statusReason).toBe("OK");
    
            expect(requests).toHaveLength(requestsMade);
    
            local request = requests[requestsMade];
            expect(request).toBe(expect.type("table"));
            expect(request.method).toBe("GET");
            expect(request.path).toBe("/");
            expect(request.headers).toBe(expect.type("table"));
            expect(request.headers["host"]).toBe("localhost:8080");
            expect(request.headers["user-agent"]).toBe("zune/" .. version);
        end)
    end

    expect(function()
        local _ = net.http.request("http://localhost:8085");
    end).toThrow("ConnectionRefused");

    repeat
        task.wait(0.1);
    until requestsMade == 4;

    expect(requests).toHaveLength(requestsMade);

    expect(not server:isRunning()).toBe(false);
    server:stop();
    expect(not server:isRunning()).toBe(true);
    server:stop();
    expect(not server:isRunning()).toBe(true);

    expect(function()
        local _ = net.http.request("http://localhost:8080");
    end).toThrow("ConnectionRefused");

    expect(requests).toHaveLength(requestsMade);
end)

test("Fast Timeout", function()
    local requests = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        maxConnections = 1,
        clientTimeout = 1,
        request = function(req)
            table.insert(requests, req);
            return "Hello: " .. #requests;
        end,
    });
    expect(server).toBe(expect.type("userdata"));

    local socket = net.createSocket(
        net.ADDRF.INET,
        bit32.bor(
            net.SOCKF.STREAM,
            if (zune.process.os == "windows") then 0 else net.SOCKF.CLOEXEC
        ),
        net.IPPROTO.TCP
    );

    socket:connect("127.0.0.1", 8080);

    local start_time = os.clock();
    local timedout_time = 0;
    local tcp_err: any;
    local closed = false;
    zune.task.spawn(function()
        local ok, data = pcall(socket.recv, socket, 1);
        if (not ok) then
            tcp_err = data :: any;
            timedout_time = os.clock() - start_time;
        end
        socket:close();
        closed = true;
    end)

    repeat
        task.wait(0.1);
    until tcp_err ~= nil;

    expect(not server:isRunning()).toBe(false);
    server:stop();
    expect(not server:isRunning()).toBe(true);
    server:stop();
    expect(not server:isRunning()).toBe(true);

    expect(function()
        local _ = net.http.request("http://localhost:8080");
    end).toThrow("ConnectionRefused");

    expect(tcp_err).toBe(expect.type("string"));
    expect(timedout_time).toBeCloseTo(1, 0);

    repeat
        task.wait(0.1);
    until closed == true;
end)

describe("Server Error", function()
    test("Immediate", function()
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                error("Server Error");
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        testing.defer(function()
            server:stop();
        end)
        
        local res = net.http.request("http://localhost:8080");
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(false);
        expect(res.statusCode).toBe(500);
        expect(res.body).toBe("An error occurred on the server");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("31");
        expect(res.headers["Content-Type"]).toBe("text/plain");
        expect(res.statusReason).toBe("Internal Server Error");
    end)
    test("Yielded", function()
        local server = net.http.serve({
            port = 8080,
            reuseAddress = true,
            request = function(req)
                task.wait();
                error("Server Error");
            end,
        });
        expect(server).toBe(expect.type("userdata"));

        testing.defer(function()
            server:stop();
        end)

        local res = net.http.request("http://localhost:8080");
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(false);
        expect(res.statusCode).toBe(500);
        expect(res.body).toBe("An error occurred on the server");
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["Content-Length"]).toBe("31");
        expect(res.headers["Content-Type"]).toBe("text/plain");
        expect(res.statusReason).toBe("Internal Server Error");
    end)
end)

return nil;
