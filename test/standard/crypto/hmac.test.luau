--!strict
local crypto = zune.crypto

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function hmac(kind: string, value: string, key: string): string
    local hasher = crypto.createHash(kind :: any, key)
    hasher:update(value)
    return hasher:digest("hex")
end

describe("hmac", function()
    test("sha1", function()
        expect(hmac("sha1", "test", "some-key")).toBe("663a5152a12a3431459c0f284fe9ddff8d8e0153")
        expect(hmac("sha1", "zune+luau", "runtime")).toBe("b11d13f56ca5f82ea69c1ed1a3581f502ea3dca0")
    end)

    test("md5", function()
        expect(hmac("md5", "test", "some-key")).toBe("257e3a4df0ef0da897d69c7c182fb8e9")
        expect(hmac("md5", "zune+luau", "runtime")).toBe("607657d1110114b4083cfc796b4ba4b1")
    end)

    test("blake3", function()
        expect(hmac("blake3", "test", "some-key")).toBe(
            "395b0ebc7db29f0fce312ae2f3f235feb74303daac3cc5edd828f784fce6346e"
        )
        expect(hmac("blake3", "zune+luau", "runtime")).toBe(
            "226148d571df6c1850bae14e37045a5b36cdf8352f0fbbbdeaeb95d74e1641ad"
        )
    end)

    describe("sha2", function()
        test("sha224", function()
            expect(hmac("sha224", "test", "some-key")).toBe("54fa1f243580d0d9bdbcd5243d6b40b6540f99d42663ea8d22cfe5ee")
            expect(hmac("sha224", "zune+luau", "runtime")).toBe(
                "1cca3905ba8de9d9dfcded575156aaee816147e411787f633334ef4c"
            )
        end)
        test("sha256", function()
            expect(hmac("sha256", "test", "some-key")).toBe(
                "08c22ecc31c998cece3771f92dcbb623fb71998ce067f406f51a45fc4802ea7a"
            )
            expect(hmac("sha256", "zune+luau", "runtime")).toBe(
                "68f6b45c033c963884fdfea51530e57092a7722b7235d14724e7617e91b55e04"
            )
        end)
        test("sha384", function()
            expect(hmac("sha384", "test", "some-key")).toBe(
                "a37be4ffdddbf9bbf20ccaf05a33207e33964fd228280db7734827cc67c83e0e12f80f68c08680cce0024621e7b7b69f"
            )
            expect(hmac("sha384", "zune+luau", "runtime")).toBe(
                "b21d024b2e243187b308e9cd7b603b50732184b144dce56a026286c4adcef9c73449eb64144d5400028a17c4e5ce91c7"
            )
        end)
        test("sha512", function()
            expect(hmac("sha512", "test", "some-key")).toBe(
                "5d150ffa09b582906efd6e68556513a221444c71f814234e08d2b23e8c94b99ace54c4394b93aa4ffcb9fa09763f0f6ad83d70219d0c859d37514e3cd06010b6"
            )
            expect(hmac("sha512", "zune+luau", "runtime")).toBe(
                "7dca7dc138842b8f27e126bfad7d7c36794cd3e03f8dc8991e13fe72f1d5d6b8b1ce0bca1c4e3a6ff2040417f20b013883b4d3515fabe5d19c3e5662249095c0"
            )
        end)
    end)

    describe("sha3", function()
        test("sha3_224", function()
            expect(hmac("sha3_224", "test", "some-key")).toBe(
                "4a4f2229c72784ead0a97fee4bac9b3d41be32f79f6207d3dd91be9b"
            )
            expect(hmac("sha3_224", "zune+luau", "runtime")).toBe(
                "8a0169afad4e6adae7a59f98172b4a002d1d69f3fc6a3665155f2773"
            )
        end)
        test("sha3_256", function()
            expect(hmac("sha3_256", "test", "some-key")).toBe(
                "b5fd647e9d8c8b425322fafee4de2b7f46119d6082bdee5d6ca77ac5cf1ce059"
            )
            expect(hmac("sha3_256", "zune+luau", "runtime")).toBe(
                "ac8d782eb429817e39244cc7e3bc23cf9ae5e8279c985957ae8fd7b2b8e29665"
            )
        end)
        test("sha3_384", function()
            expect(hmac("sha3_384", "test", "some-key")).toBe(
                "e2f092be4fd489d994d85b6d9c0b7ba6891cdaad96b5cfa1827aeea073334266dcc07e666081d1ddbd66cdcadbee1f7e"
            )
            expect(hmac("sha3_384", "zune+luau", "runtime")).toBe(
                "18f0289ae1405080fe5ab2962212daa46180584044bee8ef95264ee300696ae784bc7cd5a387d26a72d3ec9f36acf677"
            )
        end)
        test("sha3_512", function()
            expect(hmac("sha3_512", "test", "some-key")).toBe(
                "7f3c9c71b86f1279395d4989b497784583560558e50f8a31348ab6c81a2ac188f66ce16fdcdfc67886817d1eb795327353edfeeca913fc559af1126754f2c125"
            )
            expect(hmac("sha3_512", "zune+luau", "runtime")).toBe(
                "e9c4a0caf18f7ddcea1ac1b50eb7d1d1144d8eecb4bcd94d4d5257c7ace6055d343184f92cb2a381b12d15db61f124af965e4b57323da1414bbad6c244ed8c9f"
            )
        end)
        test("sha3_shake128", function()
            expect(hmac("sha3_shake128", "test", "some-key")).toBe(
                "f65e7233d295cee6ba52a145fc482c27af55274ac15e293d644aaf082722d861"
            )
            expect(hmac("sha3_shake128", "zune+luau", "runtime")).toBe(
                "439af0b09dc354d805e3351194fd79df2402a552f4c6640be073f8fbd0ee7921"
            )
        end)
        test("sha3_shake256", function()
            expect(hmac("sha3_shake256", "test", "some-key")).toBe(
                "10849b80e5af62406f42e1398acd305c19a45eb124f20646ff3010feeff60091e7e1ffee37a20e6a6939b93ebe8254011fb9d5a38ac120aba259a33767c4b4af"
            )
            expect(hmac("sha3_shake256", "zune+luau", "runtime")).toBe(
                "dfa80a5f5da701e03c18c2aca719893969505ff3729232d3fcb21c503613eabde2e02c54495a997dd0a001d137f5010fb89c7511ac527c852a7337d5171564ad"
            )
        end)
    end)

    describe("blake2", function()
        test("b128", function()
            expect(hmac("blake2b128", "test", "some-key")).toBe("438c66c9aae2e28baa7f99b4ba7f8cc6")
            expect(hmac("blake2b128", "zune+luau", "runtime")).toBe("4abb551cf85ca8cf4dc0516abcce8ef1")
        end)
        test("b160", function()
            expect(hmac("blake2b160", "test", "some-key")).toBe("dd9e1caacf9f29879381906eb2e5bcf3c64b860c")
            expect(hmac("blake2b160", "zune+luau", "runtime")).toBe("755475da5965133dee884014d11c875c58d720e1")
        end)
        test("b256", function()
            expect(hmac("blake2b256", "test", "some-key")).toBe(
                "bc87fab7982b6d73001e235d599029e2a00dbda92f763e0bda53124bbe3d13e9"
            )
            expect(hmac("blake2b256", "zune+luau", "runtime")).toBe(
                "0d760abdc0f6a4a608c720c3b23ba70c65ae14fbc99a9c5c1e4d63c8f3415ac0"
            )
        end)
        test("b384", function()
            expect(hmac("blake2b384", "test", "some-key")).toBe(
                "345bd3a69008ee336931da61ffbb7179711aafdd8c2b298a95b6f3a1d96b70f19a965319cf79a55ee6436c9c7d30efd8"
            )
            expect(hmac("blake2b384", "zune+luau", "runtime")).toBe(
                "39f5ac95daccf12ed5cf9d3593d527e151b47dfac6cd10454c9e65c2db92bbca9db1d990d31681a55e9a66731f6b1f02"
            )
        end)
        test("b512", function()
            expect(hmac("blake2b512", "test", "some-key")).toBe(
                "f199d0d53e94f114ed8a1115949d283e2895f020a675c2cea0117e715de470110873594654cc6b5d2a60b768d7a11499e1303309240ecbde44e7a916fa39fe01"
            )
            expect(hmac("blake2b512", "zune+luau", "runtime")).toBe(
                "a5c06e6a5a76e610e4a985617d7e60d29a709e96203b50e0a141a70c1978937fe1237d21dd65a85cbdb7f6511f06e2ad40a2931559495da5fadc877fbd1643d2"
            )
        end)

        test("s128", function()
            expect(hmac("blake2s128", "test", "some-key")).toBe("b7cecf1a2f2e2e59e2b70e6a296545b7")
            expect(hmac("blake2s128", "zune+luau", "runtime")).toBe("eedd3b59d776e6c552a83fe2b180daaf")
        end)
        test("s160", function()
            expect(hmac("blake2s160", "test", "some-key")).toBe("3c8968ee6a2f75931783551958259a960fb2d790")
            expect(hmac("blake2s160", "zune+luau", "runtime")).toBe("b88f93824f9eac02b75133165404dffeae358cae")
        end)
        test("s224", function()
            expect(hmac("blake2s224", "test", "some-key")).toBe(
                "6aeef170baa920953b7df0dc3613cd79040a256cb99cbb2685c06eac"
            )
            expect(hmac("blake2s224", "zune+luau", "runtime")).toBe(
                "ca99a58dc2815bac1f0ebf83c6eef9eb2ca99012256c466251d64768"
            )
        end)
        test("s256", function()
            expect(hmac("blake2s256", "test", "some-key")).toBe(
                "0dac61f5e3a0d88a6e0b82c22b95a9e6b04c4404dbfb53a76ffff2e091518710"
            )
            expect(hmac("blake2s256", "zune+luau", "runtime")).toBe(
                "6b0a921884d662f74ac09802350302b3935307d1c75b004bad6959f18907a79b"
            )
        end)
    end)
end)

return nil
