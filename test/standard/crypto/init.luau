--!strict

local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("HashObject", function()
    test("Hash", function()
        local hasher = crypto.createHash("sha1");
        hasher:update("test");
        expect(hasher:digest("base64")).toBe("qUqP5cyxm6YcTAhz05Hph5gvu9M=");
        hasher:update("test");
        expect(hasher:digest("hex")).toBe("a94a8fe5ccb19ba61c4c0873d391e987982fbbd3");
        hasher:update("test");
        expect(buffer.tostring(hasher:digest())).toBe("\xA9J\x8F\xE5\xCC\xB1\x9B\xA6\x1CL\bs\xD3\x91\xE9\x87\x98/\xBB\xD3");
        hasher:update("test");
        expect(buffer.tostring(hasher:digest("binary"))).toBe("\xA9J\x8F\xE5\xCC\xB1\x9B\xA6\x1CL\bs\xD3\x91\xE9\x87\x98/\xBB\xD3");
        
        expect(hasher:digest("base64")).toBe("2jmj7l5rSw0yVb/vlWAYkK/YBwk=");
        expect(hasher:digest("base64")).toBe("2jmj7l5rSw0yVb/vlWAYkK/YBwk=");

        hasher:update("test");
        local copy = hasher:copy();
        expect(copy:digest("base64")).toBe("qUqP5cyxm6YcTAhz05Hph5gvu9M=");
        expect(hasher:digest("base64")).toBe("qUqP5cyxm6YcTAhz05Hph5gvu9M=");
    end)

    test("Hmac", function()
        local hasher = crypto.createHash("sha1", "ez secret");
        hasher:update("test");
        local copy = hasher:copy();
        expect(hasher:digest("base64")).toBe("dLxpVOlznkVJH7UJfDJ0Ms6wO+8=");
        expect(function()
            hasher:update("test");
        end).toThrow("Hasher already used");
        expect(copy:digest("base64")).toBe("dLxpVOlznkVJH7UJfDJ0Ms6wO+8=");
        expect(function()
            copy:copy();
        end).toThrow("Hasher already used");
    end)
end)

require("@self/hash.test");
require("@self/hmac.test");
require("@self/random.test");

describe("aead", function()
    require("@self/aead/aegis");
    require("@self/aead/aes_gcm");
    require("@self/aead/aes_ocb");
    require("@self/aead/chacha_poly");
    require("@self/aead/isap");
    require("@self/aead/salsa_poly");
end)

require("@self/password.test");