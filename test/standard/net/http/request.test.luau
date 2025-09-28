--!strict
local net = zune.net;
local task = zune.task;
local testing = zune.testing;

local expect = testing.expect;
local test = testing.test;

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

test("Basic", function()
    local server = net.http.serve({
        port = 8080,
        reuse_address = true,
        request = function(req)
            return {
                status_code = 200,
                body = "Hello",
                headers = {
                    ["Content-Type"] = "text/plain",
                },
            }
        end,
    });
    testing.defer(function()
        server:stop();
    end)
    local spawned = 10;
    for i = 1, spawned do
        local use_buffer = i > 5;
        task.spawn(function()
            local res = net.http.request("http://localhost:8080", {
                method = "GET",
                headers = {
                    ["Content-Type"] = "text/plain",
                },
            }, use_buffer);
            expect(res).toBe(expect.type("table"));
            expect(res.ok).toBe(true);
            expect(res.status_code).toBe(200);
            if (use_buffer) then
                expect(res.body).toBe(expect.type("buffer"));
                expect(buffer.tostring(res.body :: buffer)).toBe("Hello");
            else
                expect(res.body).toBe("Hello");
            end
            expect(res.headers).toBe(expect.type("table"));
            expect(res.headers["content-length"]).toBe("5");
            expect(res.headers["content-type"]).toBe("text/plain");
            expect(res.status_reason).toBe("OK");
            spawned -= 1;
        end)
    end
    repeat
        task.wait();
    until (spawned == 0);
end)

test("TLS", function()
    if (not table.find(zune.process.args, "allow")) then
        print(`Skip TLS test`);
        return;
    end
    do
        local res = net.http.request("https://github.com", {
            method = "GET",
            headers = {
                ["Content-Type"] = "text/plain",
            },
        }, false);
        
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.status_code).toBe(200);
        expect(res.body).toBe(expect.type("string"));
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["content-type"]).toBe(expect.type("string"));
    end
    do
        -- should be able to use http protocol and tls port
        -- the tls config should force tls usage
        local res = net.http.request("http://github.com:443", {
            method = "GET",
            headers = {
                ["Content-Type"] = "text/plain",
            },
            tls = {
                host = "github.com",
                ca = zune.crypto.tls.bundleFromSystem(),
            },
        }, false);
        
        expect(res).toBe(expect.type("table"));
        expect(res.ok).toBe(true);
        expect(res.status_code).toBe(200);
        expect(res.body).toBe(expect.type("string"));
        expect(res.headers).toBe(expect.type("table"));
        expect(res.headers["content-type"]).toBe(expect.type("string"));
    end
end)

return nil;
