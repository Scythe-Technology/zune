--!strict
local crypto = zune.crypto

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function hash(kind: string, value: string): string
    local hasher = crypto.createHash(kind :: any)
    hasher:update(value)
    return hasher:digest("hex")
end

describe("hash", function()
    test("sha1", function()
        expect(hash("sha1", "test")).toBe("a94a8fe5ccb19ba61c4c0873d391e987982fbbd3")
        expect(hash("sha1", "zune+luau")).toBe("e47cdb8177c155af61402e8b190eaf9fcda19be3")
    end)

    test("md5", function()
        expect(hash("md5", "test")).toBe("098f6bcd4621d373cade4e832627b4f6")
        expect(hash("md5", "zune+luau")).toBe("e478afbf1154b4c52fdc83f01ab9a177")
    end)

    test("blake3", function()
        expect(hash("blake3", "test")).toBe("4878ca0425c739fa427f7eda20fe845f6b2e46ba5fe2a14df5b1e32f50603215")
        expect(hash("blake3", "zune+luau")).toBe("f1126dcda96d8cd8dde7029db26ff88bbb5cecffe40e58518489339fc8dc256d")
    end)

    describe("sha2", function()
        test("sha224", function()
            expect(hash("sha224", "test")).toBe("90a3ed9e32b2aaf4c61c410eb925426119e1a9dc53d4286ade99a809")
            expect(hash("sha224", "zune+luau")).toBe("c314498b655562271ecc28b6e92075a8b22e7f38f5b2449506c9f354")
        end)
        test("sha256", function()
            expect(hash("sha256", "test")).toBe("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
            expect(hash("sha256", "zune+luau")).toBe("d8e2b7516dea78ab5e68429e26a48b33e4f1a84955d7fe3f0a261c3549d3c41a")
        end)
        test("sha384", function()
            expect(hash("sha384", "test")).toBe(
                "768412320f7b0aa5812fce428dc4706b3cae50e02a64caa16a782249bfe8efc4b7ef1ccb126255d196047dfedf17a0a9"
            )
            expect(hash("sha384", "zune+luau")).toBe(
                "c8d3ba84d8fbe5025d9913cc015dc69c635af4d9b946f0bab1f9814f05a1372d84e6b5179824e4ad8e1a1022ec0e6bfa"
            )
        end)
        test("sha512", function()
            expect(hash("sha512", "test")).toBe(
                "ee26b0dd4af7e749aa1a8ee3c10ae9923f618980772e473f8819a5d4940e0db27ac185f8a0e1d5f84f88bc887fd67b143732c304cc5fa9ad8e6f57f50028a8ff"
            )
            expect(hash("sha512", "zune+luau")).toBe(
                "232dcb06ce1e2001400f409d51acda3d8e8361e42505b20aea41a60432b1699173de3d8784301ffdba5019e1ad2b91cd1acfb93c4e1bf5814ce8da6be600b928"
            )
        end)
    end)

    describe("sha3", function()
        test("sha3_224", function()
            expect(hash("sha3_224", "test")).toBe("3797bf0afbbfca4a7bbba7602a2b552746876517a7f9b7ce2db0ae7b")
            expect(hash("sha3_224", "zune+luau")).toBe("bf4a366cffa2dc443d7c369fdc2c691da46e1d592d23450217e6acdb")
        end)
        test("sha3_256", function()
            expect(hash("sha3_256", "test")).toBe("36f028580bb02cc8272a9a020f4200e346e276ae664e45ee80745574e2f5ab80")
            expect(hash("sha3_256", "zune+luau")).toBe(
                "7cff4669db67cb0feadb81327cdbfe15d585ca00b778ebba82b16585c61517f5"
            )
        end)
        test("sha3_384", function()
            expect(hash("sha3_384", "test")).toBe(
                "e516dabb23b6e30026863543282780a3ae0dccf05551cf0295178d7ff0f1b41eecb9db3ff219007c4e097260d58621bd"
            )
            expect(hash("sha3_384", "zune+luau")).toBe(
                "d278ebf323e253cf0dfbb7b404dfa4534ba84c973ca9f514545e3c2353659e1cde817360d7e5dce11a11b6f0adcc2dfd"
            )
        end)
        test("sha3_512", function()
            expect(hash("sha3_512", "test")).toBe(
                "9ece086e9bac491fac5c1d1046ca11d737b92a2b2ebd93f005d7b710110c0a678288166e7fbe796883a4f2e9b3ca9f484f521d0ce464345cc1aec96779149c14"
            )
            expect(hash("sha3_512", "zune+luau")).toBe(
                "884cddf86715170e6538f518de9eca945005c1f09237d2cceba90bb120cfac59fedfed37b604bde3b9a509a545328dec7d73c81acfd8c0768b5c02e86042db96"
            )
        end)
        test("sha3_shake128", function()
            expect(hash("sha3_shake128", "test")).toBe(
                "d3b0aa9cd8b7255622cebc631e867d4093d6f6010191a53973c45fec9b07c774"
            )
            expect(hash("sha3_shake128", "zune+luau")).toBe(
                "790db5030ee94a3442f5371c70d6959968025458a82d0166e5a56b3a0e7e131d"
            )
        end)
        test("sha3_shake256", function()
            expect(hash("sha3_shake256", "test")).toBe(
                "b54ff7255705a71ee2925e4a3e30e41aed489a579d5595e0df13e32e1e4dd202a7c7f68b31d6418d9845eb4d757adda6ab189e1bb340db818e5b3bc725d992fa"
            )
            expect(hash("sha3_shake256", "zune+luau")).toBe(
                "de83a434056e119e563a8399fe8a4ddb0de61aa1f08250c35f59e9d2a39005664769f832d024a717edb0a9a3b1fb797a0ff559fdf9281dd0fb62841322837a30"
            )
        end)
    end)

    describe("blake2", function()
        test("b128", function()
            expect(hash("blake2b128", "test")).toBe("44a8995dd50b6657a037a7839304535b")
            expect(hash("blake2b128", "zune+luau")).toBe("c97ab5fc7cb9b15db8f5471514da1fdb")
        end)
        test("b160", function()
            expect(hash("blake2b160", "test")).toBe("a34fc3b6d2cce8beb3216c2bbb5e55739e8121ed")
            expect(hash("blake2b160", "zune+luau")).toBe("506805b2c79624b73aea9e82cd57703953b0e042")
        end)
        test("b256", function()
            expect(hash("blake2b256", "test")).toBe("928b20366943e2afd11ebc0eae2e53a93bf177a4fcf35bcc64d503704e65e202")
            expect(hash("blake2b256", "zune+luau")).toBe(
                "9ffe181c04b44ca97758eb3f788a3c90d7dc9aac9e6e2588906bc1ae40ac7c00"
            )
        end)
        test("b384", function()
            expect(hash("blake2b384", "test")).toBe(
                "8a84b8666c8fcfb69f2ec41f578d7c85fbdb504ea6510fb05b50fcbf7ed8153c77943bc2da73abb136834e1a0d4f22cb"
            )
            expect(hash("blake2b384", "zune+luau")).toBe(
                "68f3f00f46c5f041ec37c04214a3c53b3bfdfe431ba00f99b48ffff1b28f9b774cca510de345b96e5d3daafeaa3ed593"
            )
        end)
        test("b512", function()
            expect(hash("blake2b512", "test")).toBe(
                "a71079d42853dea26e453004338670a53814b78137ffbed07603a41d76a483aa9bc33b582f77d30a65e6f29a896c0411f38312e1d66e0bf16386c86a89bea572"
            )
            expect(hash("blake2b512", "zune+luau")).toBe(
                "b67df6024a3c4aa3f1d570046a6df2813a8e632b378c08e5e3a559c6908445ff4bcf97de1176157a292418eb1708788fb8a8f1db1cf27c427e46311dc08ad32d"
            )
        end)

        test("s128", function()
            expect(hash("blake2s128", "test")).toBe("e9ddd9926b9dcb382e09be39ba403d2c")
            expect(hash("blake2s128", "zune+luau")).toBe("fc48cc89b0a33c36e3484aa4c5956e27")
        end)
        test("s160", function()
            expect(hash("blake2s160", "test")).toBe("d6197dabec2bd6f4ff303b8e519e8f15d42a453d")
            expect(hash("blake2s160", "zune+luau")).toBe("124cb016c7c70034aeedfaee5451c42bf5f8af32")
        end)
        test("s224", function()
            expect(hash("blake2s224", "test")).toBe("3a844209334631559b69dbea0fc9a71f580909c075a07c5078aabb9b")
            expect(hash("blake2s224", "zune+luau")).toBe("5eb74952f0923c8d9a9195a888b0773581cdbc511d2df63b5bec0385")
        end)
        test("s256", function()
            expect(hash("blake2s256", "test")).toBe("f308fc02ce9172ad02a7d75800ecfc027109bc67987ea32aba9b8dcc7b10150e")
            expect(hash("blake2s256", "zune+luau")).toBe(
                "7c70ca6e74e51566f3610af111d3bd3b47a91984902e6db5261fccb63e6d2470"
            )
        end)
    end)
end)

return nil
