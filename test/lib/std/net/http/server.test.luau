--!strict

local task = zune.task

local testing = require("@zune/testing")
local support = require("./support")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local AGENT = support.agent()

local function stop(server: support.Server)
    testing.defer(function()
        server:stop()
    end)
end

local function bodyOf(res: support.ClientResponse): string
    expect(res.body).toBe(expect.type("buffer"))
    return support.text(res.body)
end

test("basic", function()
    local seen: { support.Seen } = {}
    local server = support.serve(function(incoming)
        table.insert(seen, support.record(incoming))
        return "Hello"
    end)
    stop(server)
    expect(server).toBe(expect.type("table"))
    expect(server.port).toBeGreaterThan(0)
    expect(server.running).toBe(true)

    local res = support.client.request(support.url(server))
    expect(res.ok).toBe(true)
    expect(res.code).toBe(200)
    expect(res.reason).toBe("")
    expect(bodyOf(res)).toBe("Hello")
    expect(res.headers["content-length"]).toBe("5")
    expect(server.running).toBe(true)

    expect(seen).toHaveLength(1)
    local request = seen[1]
    expect(request.method).toBe("GET")
    expect(request.path).toBe("/")
    expect(request.host).toBe("127.0.0.1")
    expect(request.userAgent).toBe(AGENT)
    expect(request.connection).toBe("close")
    expect(request.body).toBeNil()

    server:stop()
    expect(server.running).toBe(false)
    server:stop()
    expect(server.running).toBe(false)

    expect(function()
        support.client.request(support.url(server), { timeout = 6 })
    end).toThrow("connection refused")
    expect(seen).toHaveLength(1)
end)

test("table and buffer body", function()
    local server = support.serve(function(incoming)
        if incoming.path == "/buf" then
            return {
                status = 201,
                reason = "Created",
                headers = { ["Content-Type"] = "text/plain" },
                body = buffer.fromstring("Hello Buffer"),
            }
        end
        return {
            status = 200,
            reason = "OK",
            headers = { ["Content-Type"] = "text/plain" },
            body = "Hello",
        }
    end)
    stop(server)

    local text = support.client.request(support.url(server))
    expect(text.ok).toBe(true)
    expect(text.code).toBe(200)
    expect(text.reason).toBe("OK")
    expect(bodyOf(text)).toBe("Hello")
    expect(text.headers["content-type"]).toBe("text/plain")
    expect(text.headers["content-length"]).toBe("5")

    local buf = support.client.request(support.url(server, "/buf"))
    expect(buf.ok).toBe(true)
    expect(buf.code).toBe(201)
    expect(buf.reason).toBe("Created")
    expect(bodyOf(buf)).toBe("Hello Buffer")
    expect(buf.headers["content-length"]).toBe("12")
    expect(buf.headers["content-type"]).toBe("text/plain")
end)

test("methods and path", function()
    local seen: { support.Seen } = {}
    local server = support.serve(function(incoming)
        table.insert(seen, support.record(incoming))
        return "Hello"
    end)
    stop(server)

    local put = support.client.request(support.url(server, "/a%20b?q=1"), {
        method = "PUT",
        headers = { ["Content-Type"] = "text/plain" },
        body = "test",
    })
    expect(put.ok).toBe(true)
    expect(bodyOf(put)).toBe("Hello")
    expect(seen).toHaveLength(1)
    expect(seen[1].method).toBe("PUT")
    expect(seen[1].path).toBe("/a b?q=1")
    expect(seen[1].contentType).toBe("text/plain")
    expect(seen[1].contentLength).toBe("4")
    expect(seen[1].body).toBe("test")

    local posted = buffer.fromstring("xyz")
    local post = support.client.request(support.url(server, "/http://ignored"), {
        method = "POST",
        body = posted,
    })
    expect(post.code).toBe(200)
    expect(seen[2].method).toBe("POST")
    expect(seen[2].body).toBe("xyz")
    expect(seen[2].contentLength).toBe("3")

    local removed = support.client.request(support.url(server, "/item"), { method = "DELETE" })
    expect(removed.code).toBe(200)
    expect(seen[3].method).toBe("DELETE")
    expect(seen[3].path).toBe("/item")
    expect(seen[3].body).toBeNil()

    local headed = support.client.request(`http://user:pass@127.0.0.1:{server.port}/secret#frag`)
    expect(headed.code).toBe(200)
    expect(seen[4].path).toBe("/secret")
    expect(seen[4].host).toBe("127.0.0.1")
end)

test("sequential", function()
    local count = 0
    local server = support.serve(function()
        count += 1
        return `Hello: {count}`
    end)
    stop(server)

    for n = 1, 8 do
        local res = support.client.request(support.url(server))
        expect(res.ok).toBe(true)
        expect(res.code).toBe(200)
        expect(bodyOf(res)).toBe(`Hello: {n}`)
        expect(res.headers["content-length"]).toBe(tostring(7 + #tostring(n)))
    end
    expect(count).toBe(8)
end)

test("body limit", function()
    local seen: { support.Seen } = {}
    local server = support.serve(function(incoming)
        table.insert(seen, support.record(incoming))
        return `Hello: {#seen}`
    end, { max_body_size = 4096 })
    stop(server)

    local huge = string.rep("Hello World! ", 1000)
    local rejected = support.client.request(support.url(server), {
        method = "POST",
        body = huge,
        timeout = 5,
    })
    expect(rejected.ok).toBe(false)
    expect(rejected.code).toBe(413)
    expect(rejected.reason).toBe("Content Too Large")
    expect(bodyOf(rejected)).toBe("Content Too Large")
    expect(rejected.headers["content-type"]).toBe("text/plain")
    expect(rejected.headers["content-length"]).toBe("17")
    expect(seen).toHaveLength(0)

    local small = string.rep("Hello World! ", 100)
    local accepted = support.client.request(support.url(server), {
        method = "POST",
        body = small,
    })
    expect(accepted.ok).toBe(true)
    expect(bodyOf(accepted)).toBe("Hello: 1")
    expect(seen).toHaveLength(1)
    expect(seen[1].method).toBe("POST")
    expect(seen[1].body).toBe(small)
    expect(seen[1].contentLength).toBe(tostring(#small))
end)

test("connection cap", function()
    local count = 0
    local server = support.serve(function()
        count += 1
        return `Hello: {count}`
    end, { max_connections = 1 })
    stop(server)

    local left = 4
    local failed: string? = nil
    for _ = 1, 4 do
        task.spawn(function()
            local ok, err = pcall(function()
                local res = support.client.request(support.url(server), { timeout = 5 })
                expect(res.ok).toBe(true)
                expect(res.code).toBe(200)
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
    expect(count).toBe(4)
end)

test("idle timeout", function()
    local seen: { support.Seen } = {}
    local server = support.serve(function(incoming)
        table.insert(seen, support.record(incoming))
        return "Hello"
    end, { client_timeout = 0.4 })
    stop(server)

    local started = os.clock()
    local raw = support.exchange(server.port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n", 2)
    local elapsed = os.clock() - started
    expect(seen).toHaveLength(0)
    expect(string.find(raw, "HTTP/1.1 408", 1, true) ~= nil).toBe(true)
    expect(string.find(raw, "Request Timeout", 1, true) ~= nil).toBe(true)
    expect(elapsed).toBeGreaterThan(0.2)
    expect(elapsed).toBeLessThan(2)
end)

test("keep alive pipeline", function()
    local seen: { support.Seen } = {}
    local server = support.serve(function(incoming)
        table.insert(seen, support.record(incoming))
        return "Hello"
    end, { client_timeout = 2 })
    stop(server)

    local head = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: zune/test\r\n"
    local raw = support.exchange(
        server.port,
        head .. "Connection: keep-alive\r\n\r\n" .. head .. "Connection: close\r\n\r\n",
        2
    )
    expect(seen).toHaveLength(2)
    expect(seen[1].method).toBe("GET")
    expect(seen[1].connection).toBe("keep-alive")
    expect(seen[2].method).toBe("GET")
    expect(seen[2].connection).toBe("close")
    local _, responses = string.gsub(raw, "HTTP/1.1 200", "")
    expect(responses).toBe(2)
end)

describe("handler error", function()
    test("immediate", function()
        local server = support.serve(function()
            error("Server Error")
        end)
        stop(server)
        local res = support.client.request(support.url(server))
        expect(res.ok).toBe(false)
        expect(res.code).toBe(500)
        expect(res.reason).toBe("Internal Server Error")
        expect(bodyOf(res)).toBe("An error occurred on the server")
        expect(res.headers["content-type"]).toBe("text/plain")
        expect(res.headers["content-length"]).toBe("31")
    end)

    test("yielded", function()
        local server = support.serve(function()
            task.wait(0.05)
            error("Server Error")
        end)
        stop(server)
        local started = os.clock()
        -- The client watchdog arms a long timer first. The handler wait has to move it.
        local res = support.client.request(support.url(server), { timeout = 5 })
        expect(os.clock() - started).toBeLessThan(1)
        expect(res.ok).toBe(false)
        expect(res.code).toBe(500)
        expect(bodyOf(res)).toBe("An error occurred on the server")
    end)
end)

return nil
