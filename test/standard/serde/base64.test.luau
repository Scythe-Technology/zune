--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Base64", function()
    test("Encoding", function()
        expect(serde.base64.encode("Hello, World!")).toBe("SGVsbG8sIFdvcmxkIQ==");
    end)

    test("Decoding", function()
        expect(serde.base64.decode("SGVsbG8sIFdvcmxkIQ==")).toBe("Hello, World!");
    end)
    
    test("Error", function()
        expect(function()
            serde.base64.decode("InvalidBase64String")
        end).toThrow("InvalidPadding");
    end)
end)

return nil;
