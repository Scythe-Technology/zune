--!strict

local session = require("@zune/net/http/session")
local uri = require("@zune/net/uri")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

describe("parse", function()
    test("basic", function()
        local parsed = uri.parse("https://example.com/a/b?x=1#frag")
        expect(parsed.scheme).toBe("https")
        expect(parsed.host).toBe("example.com")
        expect(parsed.port).toBeNil()
        expect(parsed.path).toBe("/a/b")
        expect(parsed.query).toBe("x=1")
        expect(parsed.fragment).toBe("frag")

        local plain = uri.parse("HTTP://user:pass@example.com:8080")
        expect(plain.scheme).toBe("http")
        expect(plain.host).toBe("example.com")
        expect(plain.port).toBe(8080)
        expect(plain.path).toBe("")
        expect(plain.query).toBeNil()
        expect(plain.fragment).toBeNil()

        local v6 = uri.parse("http://[::1]:9/a")
        expect(v6.host).toBe("::1")
        expect(v6.port).toBe(9)
        expect(v6.path).toBe("/a")
    end)

    test("file", function()
        local parsed = uri.parse("file:///tmp/pkg.tar")
        expect(parsed.scheme).toBe("file")
        expect(parsed.host).toBeNil()
        expect(parsed.path).toBe("/tmp/pkg.tar")

        local hosted = uri.parse("file://localhost/tmp/pkg.tar")
        expect(hosted.host).toBe("localhost")
        expect(hosted.path).toBe("/tmp/pkg.tar")

        local empty = uri.parse("http://")
        expect(empty.host).toBeNil()
        expect(empty.path).toBe("")
    end)

    test("reject", function()
        expect(function()
            uri.parse("not a url")
        end).toThrow("bad URI")
        expect(function()
            uri.parse("http://host:abc")
        end).toThrow("URI missing host")
        expect(function()
            uri.parse("http://host:99999")
        end).toThrow("invalid port (99999)")
    end)

    test("http", function()
        local parsed = session.parseUrl("https://example.com:444/a?b=1#z")
        expect(parsed.scheme).toBe("https")
        expect(parsed.tls).toBe(true)
        expect(parsed.host).toBe("example.com")
        expect(parsed.port).toBe(444)
        expect(parsed.target).toBe("/a?b=1")

        local plain = session.parseUrl("http://example.com")
        expect(plain.tls).toBe(false)
        expect(plain.port).toBe(80)
        expect(plain.target).toBe("/")

        local query = session.parseUrl("http://example.com?b=1")
        expect(query.target).toBe("/?b=1")
    end)
end)

return nil
