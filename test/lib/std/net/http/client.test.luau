--!strict

local task = zune.task

local testing = require("@zune/testing")
local support = require("./support")

local expect = testing.expect
local test = testing.test

local function stop(server: support.Server)
    testing.defer(function()
        server:stop()
    end)
end

local function bodyOf(res: support.ClientResponse): string
    expect(res.body).toBe(expect.type("buffer"))
    return support.text(res.body)
end

test("rejects bad requests", function()
    expect(function()
        support.client.request("not a url")
    end).toThrow("unsupported URI scheme")
    expect(function()
        support.client.request("ftp://example.com/")
    end).toThrow("unsupported URI scheme")
    expect(function()
        support.client.request("http://")
    end).toThrow("URI missing host")
    expect(function()
        support.client.request("http://127.0.0.1/", { method = "FOO" })
    end).toThrow("invalid request method")
    expect(function()
        support.client.request("http://127.0.0.1/", {
            headers = { ["Content-Length"] = "1" },
        })
    end).toThrow("content-length cannot be set")
    expect(function()
        support.client.request("http://127.0.0.1/", "nope" :: any)
    end).toThrow("expected options to be a table")
end)

test("basic", function()
    local seen: { support.Seen } = {}
    local server = support.serve(function(incoming)
        table.insert(seen, support.record(incoming))
        return {
            status = 200,
            reason = "OK",
            headers = { ["Content-Type"] = "text/plain" },
            body = "Hello",
        }
    end)
    stop(server)

    local res = support.client.request(support.url(server), {
        headers = { ["Content-Type"] = "text/plain" },
    })
    expect(res.ok).toBe(true)
    expect(res.code).toBe(200)
    expect(res.reason).toBe("OK")
    expect(bodyOf(res)).toBe("Hello")
    expect(res.headers["content-length"]).toBe("5")
    expect(res.headers["content-type"]).toBe("text/plain")
    expect(seen).toHaveLength(1)
    expect(seen[1].method).toBe("GET")
    expect(seen[1].contentType).toBe("text/plain")
    expect(seen[1].userAgent).toBe(support.agent())
    expect(seen[1].host).toBe("127.0.0.1")
end)

test("concurrent", function()
    local server = support.serve(function()
        return "Hello"
    end)
    stop(server)

    local left = 8
    local failed: string? = nil
    for i = 1, 8 do
        task.spawn(function()
            local ok, err = pcall(function()
                local res = support.client.request(support.url(server), {
                    method = if i > 4 then "POST" else "GET",
                    body = if i > 4 then "x" else nil,
                    timeout = 5,
                })
                expect(res.ok).toBe(true)
                expect(res.code).toBe(200)
                expect(bodyOf(res)).toBe("Hello")
            end)
            if not ok then
                failed = tostring(err)
            end
            left -= 1
        end)
    end
    repeat
        task.wait(0.1)
    until left == 0
    if failed then
        error(failed, 0)
    end
end)

test("no content and not found", function()
    local server = support.serve(function(incoming)
        if incoming.path == "/missing" then
            return {
                status = 404,
                reason = "Not Found",
                body = "gone",
            }
        end
        return {
            status = 204,
            reason = "No Content",
        }
    end)
    stop(server)

    local empty = support.client.request(support.url(server, "/empty"))
    expect(empty.ok).toBe(true)
    expect(empty.code).toBe(204)
    expect(empty.reason).toBe("No Content")
    expect(empty.body).toBeNil()

    local missing = support.client.request(support.url(server, "/missing"))
    expect(missing.ok).toBe(false)
    expect(missing.code).toBe(404)
    expect(missing.reason).toBe("Not Found")
    expect(bodyOf(missing)).toBe("gone")
end)

test("timeout", function()
    local server = support.serve(function()
        task.wait(1)
        return "late"
    end)
    stop(server)
    expect(function()
        support.client.request(support.url(server), { timeout = 0.25 })
    end).toThrow("timed out")
end)

test("connection refused", function()
    local port = support.closedPort()
    expect(function()
        support.client.request(`http://127.0.0.1:{port}/`, { timeout = 6 })
    end).toThrow("connection refused")
end)

test("limits and chunked", function()
    local listener = support.rawServe(table.concat({
        "HTTP/1.1 200 OK\r\n",
        "Content-Length: 32\r\n",
        "\r\n",
        string.rep("x", 32),
    }, ""))
    testing.defer(function()
        listener:close()
    end)
    local port = listener:address().port
    expect(port).toBe(expect.type("number"))
    expect(function()
        support.client.request(`http://127.0.0.1:{port}/`, { max_body_size = 8, timeout = 6 })
    end).toThrow("body too large")

    local chunked = support.rawServe(table.concat({
        "HTTP/1.1 200 OK\r\n",
        "Transfer-Encoding: chunked\r\n",
        "\r\n",
        "5\r\n",
        "Hello\r\n",
        "0\r\n",
        "\r\n",
    }, ""))
    testing.defer(function()
        chunked:close()
    end)
    local chunkPort = chunked:address().port
    local res = support.client.request(`http://127.0.0.1:{chunkPort}/`, { timeout = 6 })
    expect(res.ok).toBe(true)
    expect(res.code).toBe(200)
    expect(res.reason).toBe("OK")
    expect(bodyOf(res)).toBe("Hello")
end)

return nil
