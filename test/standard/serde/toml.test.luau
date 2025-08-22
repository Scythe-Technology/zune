--!strict
local serde = zune.serde;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Toml", function()
    describe("Encoding", function()
        test("Test 1", function()
            expect(serde.toml.encode({a = 1, b = 2, c = 3})).toBe("a = 1\nc = 3\nb = 2\n");
        end)
        test("Test 2", function()
            expect(serde.toml.encode({f = {a = 1, b = 2, c = 3}})).toBe("[f]\na = 1\nc = 3\nb = 2\n");
        end)
    end)
    describe("Decoding", function()
        test("Example", function()
            -- Example from https://github.com/toml-lang/toml
            local sample = [=[
            # This is a TOML document.

            title = "TOML Example"

            [owner]
            name = "Tom Preston-Werner"
            dob = 1979-05-27T07:32:00-08:00 # First class dates

            [database]
            server = "192.168.1.1"
            ports = [ 8000, 8001, 8002 ]
            connection_max = 5000
            enabled = true

            [servers]

                # Indentation (tabs and/or spaces) is allowed but not required
                [servers.alpha]
                ip = "10.0.0.1"
                dc = "eqdc10"

                [servers.beta]
                ip = "10.0.0.2"
                dc = "eqdc10"

            [clients]
            data = [ ["gamma", "delta"], [1, 2] ]

            # Line breaks are OK when inside arrays
            hosts = [
                "alpha",
                "omega"
            ]]=];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                title = "TOML Example",
                owner = {
                    name = "Tom Preston-Werner",
                    -- TODO: Convert thisto date class
                    dob = "1979-05-27T07:32:00-08:00",
                },
                database = {
                    ports = {8000, 8001, 8002},
                    enabled = true,
                    connection_max = 5000,
                    server = "192.168.1.1",
                },
                servers = {
                    alpha = {
                        ip = "10.0.0.1",
                        dc = "eqdc10",
                    },
                    beta = {
                        ip = "10.0.0.2",
                        dc = "eqdc10",
                    },
                },
                clients = {
                    data = {
                        {"gamma", "delta"},
                        {1, 2}::any,
                    },
                    hosts = {"alpha", "omega"},
                },
            }));
        end)
        test("Test 1", function()
            --based on https://github.com/mattyhall/tomlz/blob/9a16dd53927ef2012478b6494bafb4475e44f4c9/tests/fuzzing/id-000000%2Csig-06%2Csrc-000024%2Ctime-10060%2Cexecs-1850%2Cop-havoc%2Crep-4
            local sample = [[
            oneline = '''This string has a ' quote character.'''
            firstnl = '''
This string has a ' quote character.'''
            multiline = '''
This string
has ' a quote character
and more than
on0 newline
in it.g'''
            ]];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                oneline = "This string has a ' quote character.",
                firstnl = "This string has a ' quote character.",
                multiline = "This string\nhas ' a quote character\nand more than\non0 newline\nin it.g",
            }));
        end)
        test("Test 2", function()
            local sample = [=[a = [ { a= {} }, {a.b = """str""", a.c = '\ntest' } ]]=];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                a = {
                    {
                        a = {}
                    },
                    {
                        a = {
                            b = "str",
                            c = "\\ntest"
                        }
                    }
                }
            }));
        end)
        test("Test 3", function()
            local sample = [[
            a.'"b"' = 2
            a.'b@+\' = 3
            ]];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                a = {
                   ['"b"'] = 2,
                   ['b@+\\'] = 3,
                }
            }));
        end)
        test("Test 4", function()
            local sample = [[
            "ab.c" = "ab"
            ]];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                ["ab.c"] = "ab",
            }));
        end)
        test("Test 5", function()
            local sample = [[
            "file://ab/c.luau"      =        "ab"
            ]];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                ["file://ab/c.luau"] = "ab",
            }));
        end)
        test("Test 6", function()
            local sample = [=[
            [a]
            test = 1
            [a]
            test2 = 4
            [something]
            test = 2
            ]=];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                a = {
                    test = 1,
                    test2 = 4,
                },
                something = {
                    test = 2,
                },
            }));
        end)
        test("Test 7", function()
            local sample = [=[
            [a]
            test = 1
            [[b]]
            [[b]]
            [[b]]
            [[b]]
            test = 4
            [something]
            test = 2
            ]=];
            expect(serde.toml.decode(sample)).toBe(expect.similar({
                a = {
                    test = 1,
                },
                b = {{}, {}, {}, {
                    test = 4
                }},
                something = {
                    test = 2,
                },
            }));
        end)
        test("Test 1 - Error", function()
            -- based on https://github.com/mattyhall/tomlz/blob/9a16dd53927ef2012478b6494bafb4475e44f4c9/tests/fuzzing/id-000000%2Csig-06%2Csrc-000035%2Ctime-345%2Cexecs-551%2Cop-havoc%2Crep-2
            local sample = [=[a = [ { = {} } ]]=];
            expect(function() serde.toml.decode(sample) end).toThrow(`InvalidCharacter at line 1, col 11`);
        end)
        test("Test 2 - Error", function()
            -- based on https://github.com/mattyhall/tomlz/blob/9a16dd53927ef2012478b6494bafb4475e44f4c9/tests/fuzzing/id-000000%2Csig-06%2Csrc-000052%2B000007%2Ctime-701543%2Cexecs-28399%2Cop-splice%2Crep-2
            local sample = [=[answej4 = """"\u03B4"
answer8 = "\U000003B4"]]=];
            expect(function() serde.toml.decode(sample) end).toThrow(`InvalidString at line 2, col 22`);
        end)
        test("Test 3 - Error", function()
            local sample = [=[
            [a]
            test = 1
            [[b]]=];
            expect(function() serde.toml.decode(sample) end).toThrow(`InvalidArray at line 3, col 12`);
        end)
        test("Test 4 - Error", function()
            local sample = [=[
            [a]
            test = 1
            [[b]=];
            expect(function() serde.toml.decode(sample) end).toThrow(`InvalidArray at line 3, col 12`);
        end)
    end)
end)

return nil;
