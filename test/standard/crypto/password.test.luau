--!strict
local crypto = zune.crypto;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function testPassword(password: string, options: any?)
    local hash;
    local hash2;
    test("Hash", function()
        -- Hashes should be different
        hash = crypto.password.hash(password, options);
        hash2 = crypto.password.hash(password, options);
        expect(hash).never.toBe(hash2);
        if (options) then
            expect(hash:sub(1, #options.algorithm + 2)).toBe(`${options.algorithm}$`);
        end
    end)
    test("Verification", function()
        expect(crypto.password.verify(password, hash)).toBe(true);
        expect(crypto.password.verify(password .. 'other', hash)).toBe(false);
    end)
end

describe("Password", function()
    describe("Default", function()
        testPassword("zune+luau")
    end)

    describe("Argon2i", function()
        testPassword("zune+luau", {algorithm = "argon2i", threads = 2})
    end)
    describe("Argon2id", function()
        testPassword("zune+luau", {algorithm = "argon2id", threads = 2})
    end)
    describe("Bcrypt", function()
        testPassword("zune+luau", {algorithm = "bcrypt"})
    end)

    test("Fail", function()
        expect(function()
            crypto.password.hash("blank", {
                algorithm = 123,
            })
        end).toThrow("invalid field 'algorithm' (string expected, got number)");
        expect(function()
            crypto.password.hash("blank", {
                algorithm = "argon2b",
            })
        end).toThrow("invalid algorithm kind");
        expect(function()
            crypto.password.hash("blank", {
                algorithm = "argon2d",
                time_cost = "abc",
            })
        end).toThrow("invalid field 'time_cost' (number expected, got string)");
        expect(function()
            crypto.password.hash("blank", {
                algorithm = "bcrypt",
                cost = "abc",
            })
        end).toThrow("invalid field 'cost' (number expected, got string)");
    end)
end)

return nil;