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
    local server_events = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(server_events, `request`);
            return "";
        end,
        websocket = {
            upgrade = function(req)
                table.insert(server_events, `upgrade`);
                return true;
            end,
            open = function(ws)
                table.insert(server_events, `open`);
            end,
            message = function(ws, message)
                table.insert(server_events, `message: {message}`);
                ws:send(`Echo: {message}`);
                ws:close(1000);
            end,
            close = function(ws, code)
                table.insert(server_events, `close: {code}`);
            end,
        },
    });
    expect(server).toBe(expect.type("userdata"));

    testing.defer(function()
        server:stop();
    end)

    local client_events = {};
    local resume_thread: thread? = nil;
    local socket = net.http.websocket("ws://localhost:8080", {
        timeout = 1,
        error = function(socket, scope, err)
            table.insert(client_events, `error: {scope}, {err}`);
        end,
        message = function(socket, message)
            table.insert(client_events, `message: {message}`);
        end,
        close = function(socket, closeCode)
            table.insert(client_events, `close: {closeCode}`);
            if (resume_thread) then
                task.defer(resume_thread);
            end
        end,
    });
    expect(socket).toBe(expect.type("userdata"));
    testing.defer(function()
        socket:close();
    end)

    expect(socket).toBe(expect.type("userdata"));
    expect(socket:isConnected()).toBe(true);

    expect(server_events).toBe(expect.similar({
        "upgrade",
        "open",
    }));
    expect(client_events).toBe(expect.similar({}));

    task.wait();
    
    socket:send("Test 1");

    expect(socket:isConnected()).toBe(true);

    resume_thread = coroutine.running();
    coroutine.yield();

    expect(socket:isConnected()).toBe(false);

    expect(server_events).toBe(expect.similar({
        "upgrade",
        "open",
        "message: Test 1",
        "close: 1000",
    }));
    expect(client_events).toBe(expect.similar({
        "message: Echo: Test 1",
        "close: 1000",
    }));
end)

test("Slow server", function()
    local server_events = {};
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(server_events, `request`);
            return "";
        end,
        websocket = {
            upgrade = function(req)
                table.insert(server_events, `upgrade`);
                task.wait(0.5);
                return true;
            end,
            open = function(ws)
                table.insert(server_events, `open`);
            end,
            message = function(ws, message)
                table.insert(server_events, `message: {message}`);
                if (#server_events >= 5) then
                    task.delay(1, function()
                        ws:close(1000);
                    end)
                end
                task.wait(0.5);
                ws:send("Echo: " .. message);
            end,
            close = function(ws, code)
                table.insert(server_events, `close: {code}`);
            end,
        },
    });
    expect(server).toBe(expect.type("userdata"));

    testing.defer(function()
        server:stop();
    end)

    local client_events = {};
    local resume_thread: thread? = nil;
    local socket = net.http.websocket("ws://localhost:8080", {
        timeout = 5,
        error = function(socket, scope, err)
            table.insert(client_events, `error: {scope}, {err}`);
        end,
        message = function(socket, message)
            table.insert(client_events, `message: {message}`);
        end,
        close = function(socket, closeCode)
            table.insert(client_events, `close: {closeCode}`);
            if (resume_thread) then
                task.defer(resume_thread);
            end
        end,
    });
    expect(socket).toBe(expect.type("userdata"));
    testing.defer(function()
        socket:close();
    end)

    expect(socket).toBe(expect.type("userdata"));
    expect(socket:isConnected()).toBe(true);

    expect(server_events).toBe(expect.similar({
        "upgrade",
        "open",
    }));
    expect(client_events).toBe(expect.similar({}));

    task.wait();
    
    socket:send("Test 1");
    socket:send("Test 2");
    socket:send("Test 3");

    expect(socket:isConnected()).toBe(true);

    resume_thread = coroutine.running();
    coroutine.yield();

    expect(socket:isConnected()).toBe(false);

    expect(server_events).toBe(expect.similar({
        "upgrade",
        "open",
        "message: Test 1",
        "message: Test 2",
        "message: Test 3",
        "close: 1000",
    }));
    expect(client_events).toBe(expect.similar({
        "message: Echo: Test 1",
        "message: Echo: Test 2",
        "message: Echo: Test 3",
        "close: 1000",
    }));
end)

test("Time out", function()
    local server_events = {};
    local resume_thread: thread? = nil;
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            table.insert(server_events, `request`);
            return "";
        end,
        websocket = {
            upgrade = function(req)
                table.insert(server_events, `upgrade`);
                task.wait(3);
                return true;
            end,
            open = function(ws)
                table.insert(server_events, `open`);
            end,
            message = function(ws, message)
                table.insert(server_events, `message: {message}`);
            end,
            close = function(ws, code)
                table.insert(server_events, `close: {code}`);
                if (resume_thread) then
                    task.defer(resume_thread);
                end
            end,
        },
    });
    expect(server).toBe(expect.type("userdata"));

    testing.defer(function()
        server:stop();
    end)

    expect(function()
        net.http.websocket("ws://localhost:8080", {
            timeout = 1,
            error = function(socket, scope, err)
            end,
            message = function(socket, message)
            end,
            close = function(socket, closeCode)
            end,
        });
    end).toThrow("Timeout");

    resume_thread = coroutine.running();
    coroutine.yield();

    expect(server_events).toBe(expect.similar({
        "upgrade",
        "open",
        "close: 1006",
    }));
end)

test("TLS", function()
    if (zune.process.args[1] ~= "allow") then
        print(`Skip TLS test`);
        return;
    end
    local events = {};
    local resume_thread: thread? = nil;
    local socket = net.http.websocket("wss://echo.websocket.org", {
        headers = {},
        timeout = 10,
        error = function(socket, scope, err)
            table.insert(events, `error: {scope}, {err}`);
        end,
        accept = function(socket, res)
            expect(res).toBe(expect.type("table"));
            expect(res.statusCode).toBe(101);
            table.insert(events, `accept: {res.statusCode}`);
            return true;
        end,
        message = function(socket, message)
            table.insert(events, `message: {message}`);
        end,
        close = function(socket, closeCode)
            table.insert(events, `close: {closeCode}`);
            if (resume_thread) then
                task.defer(resume_thread);
            end
        end,
    });
    expect(socket).toBe(expect.type("userdata"));
    testing.defer(function()
        socket:close();
    end)

    expect(events).toBe(expect.similar({
        "accept: 101",
    }));

    -- expect(socket.connected).toBe(true);
    socket:send("Hello");
    socket:send("Hello");
    socket:send("Hello");
    socket:send("Hello");
    task.delay(0.5, socket.close, socket);

    expect(socket:isConnected()).toBe(true);

    resume_thread = coroutine.running();
    coroutine.yield();

    expect(socket:isConnected()).toBe(false);

    table.remove(events, 2); -- remove echo.websocket.org "Request served by ..."

    expect(events).toBe(expect.similar({
        "accept: 101",
        "message: Hello",
        "message: Hello",
        "message: Hello",
        "message: Hello",
        "close: 1000",
    }));
end)

return nil;
