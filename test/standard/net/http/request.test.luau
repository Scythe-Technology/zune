--!strict
local net = zune.net;
local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function warn(message: string)
    print("\27[33m" .. message .. "\27[0m");
end

local _, version, _ = string.match(_VERSION, "(zune) (%d+%.%d+%.%d+.*)+(%d+%.%d+)");
assert(version and #version > 0, "No version");

test("Basic", function()
    local server = net.http.serve({
        port = 8080,
        reuseAddress = true,
        request = function(req)
            return {
                statusCode = 200,
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
    for _ = 1, spawned do
        task.spawn(function()
            local res = net.http.request("http://localhost:8080", {
                method = "GET",
                headers = {
                    ["Content-Type"] = "text/plain",
                },
            });
            expect(res).toBe(expect.type("table"));
            expect(res.ok).toBe(true);
            expect(res.statusCode).toBe(200);
            expect(res.body).toBe("Hello");
            expect(res.headers).toBe(expect.type("table"));
            expect(res.headers["Content-Length"]).toBe("5");
            expect(res.headers["Content-Type"]).toBe("text/plain");
            expect(res.statusReason).toBe("OK");
            spawned -= 1;
        end)
    end
    repeat
        task.wait();
    until (spawned == 0);
end)

test("TLS", function()
    if (zune.process.args[1] ~= "allow") then
        print(`Skip TLS test`);
        return;
    end
    local res = net.http.request("https://github.com", {
        method = "GET",
        headers = {
            ["Content-Type"] = "text/plain",
        },
    });
    expect(res).toBe(expect.type("table"));
    expect(res.ok).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(res.body).toBe(expect.type("string"));
    expect(res.headers).toBe(expect.type("table"));
    expect(res.headers["Content-Type"]).toBe(expect.type("string"));
end)

return nil;
