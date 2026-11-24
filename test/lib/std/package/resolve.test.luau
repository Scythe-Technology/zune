--!strict

local fs = require("@zune/fs")
local io = require("@zune/io")
local text = require("@zune/text")
local runtime = require("@zune/runtime")
local fetch = require("@zune/package/fetch")
local tar = require("@zune/archive/tar")
local package = require("@zune/package")
local slot = require("@zune/package/slot")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local TEMP_DIR = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")

local function writeSource(dir: string, source: string)
    fs.makeDir(dir, true)
    fs.writeFile(`{dir}/package.luau`, source)
end

local function writePackage(dir: string, name: string, build: string)
    writeSource(
        dir,
        table.concat({
            "return {",
            `    name = "{name}",`,
            '    version = "1.0.0",',
            "    build = function(b)",
            build,
            "    end,",
            "}",
            "",
        }, "\n")
    )
end

local function plain(text: string): string
    return (string.gsub(text, "\x1b%[[0-9;]*m", ""))
end

local function lines(dir: string, target: string?): string
    return plain(table.concat(package.why(nil, { dir = dir, target = target }), "\n"))
end

local function capturePrint(callback: () -> ()): (boolean, any, string)
    local env = getfenv(package.install)
    local saved = env.print

    local chunks: { string } = {}
    local function write(...: any)
        local parts: { string } = {}
        for index = 1, select("#", ...) do
            parts[index] = tostring(select(index, ...))
        end
        table.insert(chunks, table.concat(parts, "\t"))
    end
    rawset(env, "print", write)

    local ok, err = pcall(callback)

    rawset(env, "print", saved)

    return ok, err, plain(table.concat(chunks, "\n"))
end

local function real(path: string): string
    return fs.realPathFileAlloc(io.cwd(), path)
end

local function sizeText(path: string): string
    local stat = fs.stat(path)
    if stat.kind ~= "file" then
        error(`cache missing {path}`, 0)
    end
    return text.bytes(stat.size)
end

local function aliasMap(config: package.LuauConfig): { [string]: string }
    local aliases = config.aliases
    if not aliases then
        error("aliases missing", 0)
    end
    return aliases
end

describe("graph", function()
    test("deps", function()
        local root = `{TEMP_DIR}/pkg-deps`
        writePackage(`{root}/deps/mid/deps/sample`, "sample", "")
        writePackage(
            `{root}/deps/mid`,
            "mid",
            [=[
        b.dependency({ path = "deps/sample" })
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        local sample = b.dependency({ path = "deps/mid" })
        b.bind({
            luau = {
                aliases = {
                    mid = sample,
                    note = sample:path("src"),
                },
            },
        })
]=]
        )
        expect(lines(root)).toBe(table.concat({
            "app (1):",
            `  mid ({real(`{root}/deps/mid`)})`,
            `    sample ({real(`{root}/deps/mid/deps/sample`)})`,
            "",
            "resolved dependents:",
            " 1) mid",
            "      app",
            " 2) sample",
            "      mid",
            "        app",
        }, "\n"))
        local result = package.install({ dir = root })
        expect(result.aliases.mid).toBe("./deps/mid")
        expect(result.aliases.note).toBe("./deps/mid/src")
    end)

    test("alias", function()
        local dir = `{TEMP_DIR}/pkg-alias`
        writePackage(
            dir,
            "app",
            [=[
        b.bind({
            luau = {
                aliases = {
                    here = b.self(),
                    app = b.self():path("src"),
                    plain = "./kept",
                },
            },
        })
]=]
        )
        local result = package.install({ dir = dir })
        expect(result.aliases.here).toBe("./")
        expect(result.aliases.app).toBe("./src")
        expect(result.aliases.plain).toBe("./kept")

        local loaded = aliasMap(package.loadConfig(fs.path.join(result.dir, ".config.luau")))
        expect(loaded.here).toBe("./")
        expect(loaded.app).toBe("./src")
        expect(loaded.plain).toBe("./kept")
        expect(result.root).toBe("app")
        expect(result.dir).toBe(real(dir))
        expect(result.target).toBe(package.hostTarget())
        expect(lines(dir)).toBe("app")
    end)

    test("switch", function()
        local root = `{TEMP_DIR}/pkg-switch`
        writePackage(`{root}/deps/arm`, "arm", "")
        writePackage(`{root}/deps/sample`, "sample", "")
        writePackage(
            root,
            "app",
            [=[
        local info = b.target()
        local place = b.switch({
            ["aarch64-linux"] = "deps/arm",
            default = "deps/sample",
        })
        b.dependency({ path = place })
        b.bind({
            arch = info.arch,
            os = info.os,
            abi = info.abi,
            luau = {
                aliases = {
                    lib = b.switch({
                        ["aarch64-linux"] = "./arm",
                        default = "./host",
                    }),
                    picked = b.switch({
                        ["x86_64-linux-gnu"] = "gnu",
                        ["x86_64-linux"] = "linux",
                        default = "other",
                    }),
                },
            },
        })
]=]
        )
        local arm = package.install({ dir = root, target = "aarch64-linux" })
        expect(arm.target).toBe("aarch64-linux")
        expect(arm.aliases.lib).toBe("./arm")
        expect(arm.aliases.picked).toBe("other")
        expect(lines(root, "aarch64-linux")).toBe(table.concat({
            "app (1):",
            `  arm ({real(`{root}/deps/arm`)})`,
            "",
            "resolved dependents:",
            " 1) arm",
            "      app",
        }, "\n"))
        local text = fs.readFile(fs.path.join(arm.dir, ".config.luau"))
        expect(string.find(text, 'arch = "aarch64"', 1, true)).toBeTruthy()
        expect(string.find(text, 'os = "linux"', 1, true)).toBeTruthy()

        local sample = package.install({ dir = root, target = "x86_64-windows" })
        expect(sample.aliases.lib).toBe("./host")
        expect(sample.aliases.picked).toBe("other")
        expect(lines(root, "x86_64-windows")).toBe(table.concat({
            "app (1):",
            `  sample ({real(`{root}/deps/sample`)})`,
            "",
            "resolved dependents:",
            " 1) sample",
            "      app",
        }, "\n"))
        expect(string.find(fs.readFile(fs.path.join(sample.dir, ".config.luau")), 'arch = "x86_64"', 1, true)).toBeTruthy()

        local gnu = package.install({ dir = root, target = "x86_64-linux-gnu" })
        expect(gnu.target).toBe("x86_64-linux-gnu")
        expect(gnu.aliases.lib).toBe("./host")
        expect(gnu.aliases.picked).toBe("gnu")
        expect(string.find(fs.readFile(fs.path.join(gnu.dir, ".config.luau")), 'abi = "gnu"', 1, true)).toBeTruthy()

        local musl = package.install({ dir = root, target = "x86_64-linux-musl" })
        expect(musl.aliases.picked).toBe("linux")
        expect(string.find(fs.readFile(fs.path.join(musl.dir, ".config.luau")), 'abi = "musl"', 1, true)).toBeTruthy()

        local broad = package.install({ dir = root, target = "x86_64-linux" })
        expect(broad.aliases.picked).toBe("linux")
        expect(string.find(fs.readFile(fs.path.join(broad.dir, ".config.luau")), "abi =", 1, true)).toBe(nil)

        writePackage(
            root,
            "app",
            [=[
        b.switch({
            ["x86_64-linux"] = "linux",
        })
]=]
        )
        local miss_ok, miss_err, miss_log = capturePrint(function()
            package.install({ dir = root, target = "aarch64-linux-gnu" })
        end)
        expect(miss_ok).toBe(false)
        expect(tostring(miss_err)).toBe("install failed")
        expect(string.find(miss_log, "no aarch64-linux-gnu value", 1, true)).toBeTruthy()
        expect(function()
            package.install({ dir = root, target = "x86_64-linux-gnu-extra" })
        end).toThrow("bad target x86_64-linux-gnu-extra")
    end)

    test("artifact", function()
        local root = `{TEMP_DIR}/pkg-artifact`
        writeSource(
            `{root}/deps/sample`,
            [=[
return {
    name = "sample",
    version = "1.2.3",
    build = function(_b)
        error("should not run")
    end,
}
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/sample", artifact = true })
]=]
        )
        expect(lines(root)).toBe(table.concat({
            "app (1):",
            `  sample ({real(`{root}/deps/sample`)})`,
            "",
            "resolved dependents:",
            " 1) sample",
            "      app",
        }, "\n"))
    end)

    test("max size", function()
        local root = `{TEMP_DIR}/pkg-max-size`
        local store = `{TEMP_DIR}/pkg-max-size-src`
        fs.makeDir(store, true)
        local blob = tar.write({
            {
                path = "package.luau",
                mode = 420,
                data = buffer.fromstring(table.concat({
                    "return {",
                    '    name = "sample",',
                    '    version = "1.0.0",',
                    "    build = function(_b)",
                    "    end,",
                    "}",
                    "",
                }, "\n")),
            },
            {
                path = "payload.txt",
                mode = 420,
                data = buffer.fromstring("0123456789"),
            },
        })
        local packed = `{store}/blob.tar`
        fs.writeFile(packed, blob)
        local hash = fetch.hashBuffer(blob)
        local url = `file://{fs.realPathFileAlloc(io.cwd(), packed)}`
        local cache = fs.path.join(slot.cacheRoot(), "pkg")
        testing.defer(function()
            pcall(fs.deleteFile, fs.path.join(cache, `sample-1.0.0-{hash}.tar`))
            pcall(fs.deleteFile, fs.path.join(cache, `P_-{hash}.tar`))
            pcall(fs.deleteFile, fs.path.join(cache, `{hash}.tar`))
        end)
        writePackage(root, "app", `        b.dependency(\{ url = "{url}", hash = "{hash}", max_size = 8 \})`)
        expect(function()
            package.why(nil, { dir = root })
        end).toThrow("archive exceeds max_size")
        local real = fs.realPathFileAlloc(io.cwd(), root)
        local slot = fs.path.join(real, ".zune", "pkg", `sample-1.0.0-{hash}`)
        expect(fs.stat(fs.path.join(slot, "payload.txt")).kind).toBe("none")
        expect(fs.stat(fs.path.join(slot, "package.luau")).kind).toBe("none")

        writePackage(
            root,
            "app",
            `        b.dependency(\{ url = "{url}", hash = "{hash}", max_size = 1024 * 1024 * 1024 * 8 \})`
        )
        expect(lines(root)).toBe(table.concat({
            "app (1):",
            `  sample ({hash})`,
            "",
            "resolved dependents:",
            " 1) sample",
            "      app",
        }, "\n"))
        expect(fs.readFile(fs.path.join(slot, "payload.txt"))).toBe("0123456789")
    end)

    test("hash", function()
        local root = `{TEMP_DIR}/pkg-hash`
        local store = `{TEMP_DIR}/pkg-hash-src`
        fs.makeDir(store, true)
        local sample_tar = tar.write({
            {
                path = "package.luau",
                mode = 420,
                data = buffer.fromstring(table.concat({
                    "return {",
                    '    name = "sample",',
                    '    version = "1.0.0",',
                    "    build = function(_b)",
                    "    end,",
                    "}",
                    "",
                }, "\n")),
            },
        })
        local plain_tar = tar.write({
            {
                path = "readme.txt",
                mode = 420,
                data = buffer.fromstring("plain"),
            },
        })
        local sample_file = `{store}/blob.tar`
        local plain_file = `{store}/plain.tar`
        fs.writeFile(sample_file, sample_tar)
        fs.writeFile(plain_file, plain_tar)
        local sample_hash = fetch.hashBuffer(sample_tar)
        local plain_hash = fetch.hashBuffer(plain_tar)
        expect(#sample_hash).toBe(44)
        expect(#plain_hash).toBe(44)
        local sample_url = `file://{fs.realPathFileAlloc(io.cwd(), sample_file)}`
        local plain_url = `file://{fs.realPathFileAlloc(io.cwd(), plain_file)}`
        writePackage(
            root,
            "app",
            table.concat({
                `        b.dependency(\{ url = "{sample_url}", hash = "{sample_hash}" \})`,
                `        b.dependency(\{ url = "{plain_url}", hash = "{plain_hash}" \})`,
            }, "\n")
        )
        local real = fs.realPathFileAlloc(io.cwd(), root)
        local cache = fs.path.join(slot.cacheRoot(), "pkg")
        local sample_packed = fs.path.join(cache, `sample-1.0.0-{sample_hash}.tar`)
        local plain_packed = fs.path.join(cache, `P_-{plain_hash}.tar`)
        testing.defer(function()
            pcall(fs.deleteFile, sample_packed)
            pcall(fs.deleteFile, fs.path.join(cache, `P_-{sample_hash}.tar`))
            pcall(fs.deleteFile, fs.path.join(cache, `{sample_hash}.tar`))
            pcall(fs.deleteFile, plain_packed)
            pcall(fs.deleteFile, fs.path.join(cache, `{plain_hash}.tar`))
        end)

        expect(lines(root)).toBe(table.concat({
            "app (2):",
            `  sample ({sample_hash})`,
            `  (unresolved) {plain_hash}`,
            "",
            "resolved dependents:",
            " 1) sample",
            "      app",
            "",
            "unresolved dependents:",
            ` 1) {plain_hash} (hash)`,
            "    - app",
        }, "\n"))

        local sample_dir = fs.path.join(real, ".zune", "pkg", `sample-1.0.0-{sample_hash}`)
        expect(table.concat(package.why(sample_hash, { dir = root }), "\n")).toBe(table.concat({
            "sample 1.0.0",
            `  hash: {sample_hash}`,
            `  url: {sample_url}`,
            `  cache path: {sample_packed} ({sizeText(sample_packed)})`,
            `  unpacked path: {sample_dir}`,
        }, "\n"))
        expect(string.find(fs.readFile(fs.path.join(sample_dir, "package.luau")), 'name = "sample"', 1, true)).toBeTruthy()

        local plain_dir = fs.path.join(real, ".zune", "pkg", `P_-{plain_hash}`)
        expect(table.concat(package.why(plain_hash, { dir = root }), "\n")).toBe(table.concat({
            `  hash: {plain_hash}`,
            `  url: {plain_url}`,
            `  cache path: {plain_packed} ({sizeText(plain_packed)})`,
            `  unpacked path: {plain_dir}`,
        }, "\n"))
        expect(fs.readFile(fs.path.join(plain_dir, "readme.txt"))).toBe("plain")

        expect(function()
            package.why("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", { dir = root })
        end).toThrow("unknown hash AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    end)

    test("cycle", function()
        local base = `{TEMP_DIR}/pkg-cycle`
        writePackage(
            `{base}/app/deps/sample`,
            "sample",
            [=[
        b.dependency({ path = "../.." })
]=]
        )
        writePackage(
            `{base}/app`,
            "app",
            [=[
        b.dependency({ path = "deps/sample" })
]=]
        )
        expect(function()
            package.why(nil, { dir = `{base}/app` })
        end).toThrow("cycle on app")
    end)
end)

describe("file", function()
    test("missing", function()
        local dir = `{TEMP_DIR}/pkg-empty`
        fs.makeDir(dir, true)
        expect(function()
            package.why(nil, { dir = dir })
        end).toThrow("package.luau is missing")
        expect(function()
            package.why(nil, { dir = `{TEMP_DIR}/pkg-nope` })
        end).toThrow(`path not found {TEMP_DIR}/pkg-nope`)
        expect(function()
            package.why("", { dir = dir })
        end).toThrow("hash is required")
        expect(function()
            package.install({ dir = dir, target = "nope" })
        end).toThrow("bad target nope")
    end)

    test("reject", function()
        local dir = `{TEMP_DIR}/pkg-reject`
        writePackage(dir, "app", "")
        expect(function()
            package.why("other", { dir = dir })
        end).toThrow("hash must be base64")

        local rejected = {
            {
                [=[return {
    name = "",
    version = "1.0.0",
    build = function(b)
    end,
}]=],
                "package name is required",
            },
            {
                [=[return {
    name = "app.name",
    version = "1.0.0",
    build = function(b)
    end,
}]=],
                "invalid name (cannot have special characters)",
            },
            {
                [=[return {
    name = "app",
    version = "",
    build = function(b)
    end,
}]=],
                "package version is required",
            },
            {
                [=[return {
    name = "app",
    version = "1",
    build = function(b)
    end,
}]=],
                "version must be semver",
            },
            {
                [=[return {
    name = "app",
    version = "1.0.0",
}]=],
                "package build is required",
            },
            {
                [=[return "app"]=],
                "package.luau must return a table",
            },
            {
                [=[return {
    name = "app",
    version = "1.0.0",
    build = function(b)
        return true
    end,
}]=],
                "build must return nothing",
            },
        }
        for _, case in rejected do
            writeSource(dir, case[1])
            expect(function()
                package.why(nil, { dir = dir })
            end).toThrow(case[2])
        end
    end)

    test("paths", function()
        local dir = `{TEMP_DIR}/pkg-paths`
        writeSource(
            dir,
            [=[
return {
    name = "app",
    version = "1.0.0",
    paths = {
        ["x86_64-linux"] = { "src" },
    },
    build = function(b)
    end,
}
]=]
        )
        expect(function()
            package.why(nil, { dir = dir, target = "aarch64-linux" })
        end).toThrow("no aarch64-linux paths")

        writeSource(
            dir,
            [=[
return {
    name = "app",
    version = "1.0.0",
    paths = "src",
    build = function(b)
    end,
}
]=]
        )
        expect(function()
            package.why(nil, { dir = dir, target = "aarch64-linux" })
        end).toThrow('paths: expected array of string and length >= 1, got "src"')

        writeSource(
            dir,
            [=[
return {
    name = "app",
    version = "1.0.0",
    paths = {
        default = { "src" },
    },
    build = function(b)
    end,
}
]=]
        )
        expect(lines(dir, "aarch64-linux"):find("app")).toBeTruthy()

        writeSource(
            dir,
            [=[
return {
    name = "app",
    version = "1.0.0",
    paths = {
        ["x86_64-linux"] = { "src" },
        ["x86_64-linux-musl"] = { "src" },
    },
    build = function(b)
    end,
}
]=]
        )
        expect(lines(dir, "x86_64-linux-gnu"):find("app")).toBeTruthy()
        expect(lines(dir, "x86_64-linux-musl"):find("app")).toBeTruthy()
        expect(function()
            package.why(nil, { dir = dir, target = "aarch64-linux-gnu" })
        end).toThrow("no aarch64-linux-gnu paths")
    end)

    test("path", function()
        local base = `{TEMP_DIR}/pkg-path`
        local root = `{base}/app`
        writePackage(`{base}/other`, "other", "")
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "../other" })
]=]
        )
        expect(lines(root)).toBe(table.concat({
            "app (1):",
            `  other ({real(`{base}/other`)})`,
            "",
            "resolved dependents:",
            " 1) other",
            "      app",
        }, "\n"))

        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/missing" })
]=]
        )
        local found = real(root)
        expect(function()
            package.why(nil, { dir = root })
        end).toThrow(`path not found {fs.path.join(found, "deps/missing")}`)

        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "/tmp" })
]=]
        )
        expect(function()
            package.why(nil, { dir = root })
        end).toThrow("path must be relative")

        fs.makeDir(`{TEMP_DIR}/pkg-out`, true)
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "../../pkg-out" })
]=]
        )
        expect(function()
            package.why(nil, { dir = root })
        end).toThrow("path leaves the workspace")
    end)
end)

describe("config", function()
    test("bare", function()
        local aliases: { [string]: string } = {
            app = "./src",
            zune = "./nope",
        }
        local loaded: package.LuauConfig = {
            languagemode = "strict",
            aliases = aliases,
        }
        local expected = [[local pkg = require("@zune/package")

return {
    name = "app",
    version = "0.0.0",
    build = function(b: pkg.Build)
        b.bind({
            luau = {
                languagemode = "strict",
                aliases = {
                    app = "./src",
                    zune1 = "./nope",
                    zune = b.std(),
                },
            },
        })
    end,
}
]]
        expect(package.bareSource("app", loaded)).toBe(expected)
        expect(function()
            package.bareSource("")
        end).toThrow("package name is required")

        local dir = `{TEMP_DIR}/pkg-bare/app`
        expect(package.writeBare(dir, loaded)).toBe(true)
        expect(fs.readFile(`{dir}/package.luau`)).toBe(expected)
        expect(package.writeBare(dir, loaded)).toBe(false)
        expect(function()
            package.writeBare(`{TEMP_DIR}/pkg-bare/bad name`)
        end).toThrow("package name is required")
    end)

    test("load", function()
        local path = `{TEMP_DIR}/pkg-config/.config.luau`
        fs.makeDir(`{TEMP_DIR}/pkg-config`, true)
        fs.writeFile(
            path,
            [=[
return {
    luau = {
        languageMode = "nonstrict",
        lintErrors = true,
        aliases = {
            App = "./src",
        },
    },
}
]=]
        )
        local config = package.loadConfig(path)
        expect(config.languagemode).toBe("nonstrict")
        expect(config.linterrors).toBe(true)
        expect(aliasMap(config).App).toBe("./src")

        fs.writeFile(path, "return {}\n")
        local empty = package.loadConfig(path)
        expect(empty.languagemode).toBeNil()
        expect(aliasMap(empty).App).toBeNil()

        expect(function()
            package.loadConfig("")
        end).toThrow("config path is required")
        expect(function()
            package.loadConfig(`{TEMP_DIR}/pkg-config/missing.luau`)
        end).toThrow("config was not found")

        fs.writeFile(path, "return 1\n")
        expect(function()
            package.loadConfig(path)
        end).toThrow("config must return a table")
    end)
end)

describe("build", function()
    test("artifact foreign", function()
        local root = `{TEMP_DIR}/pkg-artifact-foreign`
        fs.makeDir(`{root}/deps/plain`, true)
        fs.writeFile(`{root}/deps/plain/readme.txt`, "plain")
        writeSource(
            `{root}/deps/foreign`,
            [=[
local module = {}
function module.foo()
end
return module
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/plain", artifact = true })
        b.dependency({ path = "deps/foreign", artifact = true })
]=]
        )
        local ok, err, log = capturePrint(function()
            package.why(nil, { dir = root })
        end)
        expect(ok).toBe(true)
        expect(log).toBe("")
        expect(lines(root)).toBe(table.concat({
            "app (2):",
            "  d1",
            "  d2",
        }, "\n"))
        expect(fs.readFile(`{root}/deps/plain/readme.txt`)).toBe("plain")

        writeSource(
            `{root}/deps/foreign`,
            [=[
error("foreign")
]=]
        )
        ok, err, log = capturePrint(function()
            package.why(nil, { dir = root })
        end)
        expect(ok).toBe(true)
        expect(log).toBe("")
        expect(lines(root)).toBe(table.concat({
            "app (2):",
            "  d1",
            "  d2",
        }, "\n"))

        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/foreign" })
]=]
        )
        ok, err, log = capturePrint(function()
            package.why(nil, { dir = root })
        end)
        expect(ok).toBe(false)
        expect(tostring(err)).toBe("package.luau failed to load")
        expect(string.find(log, "error: foreign", 1, true)).toBeTruthy()

        writeSource(`{root}/deps/foreign`, "!!!\n")
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/foreign", artifact = true })
]=]
        )
        expect(lines(root)).toBe(table.concat({
            "app (1):",
            "  d1",
        }, "\n"))
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/foreign" })
]=]
        )
        local compile_ok, compile_err = pcall(function()
            package.why(nil, { dir = root })
        end)
        expect(compile_ok).toBe(false)
        expect(string.find(tostring(compile_err), "package.luau failed to compile", 1, true)).toBeTruthy()
    end)

    test("artifact archive", function()
        local root = `{TEMP_DIR}/pkg-artifact-archive`
        local store = `{TEMP_DIR}/pkg-artifact-archive-src`
        fs.makeDir(store, true)
        local blob = tar.write({
            {
                path = "package.luau",
                mode = 420,
                data = buffer.fromstring(table.concat({
                    "return {",
                    '    name = "nope",',
                    "}",
                    "",
                }, "\n")),
            },
            {
                path = "readme.txt",
                mode = 420,
                data = buffer.fromstring("kept"),
            },
        })
        local packed = `{store}/blob.tar`
        fs.writeFile(packed, blob)
        local hash = fetch.hashBuffer(blob)
        local url = `file://{fs.realPathFileAlloc(io.cwd(), packed)}`
        local cache = fs.path.join(slot.cacheRoot(), "pkg")
        testing.defer(function()
            pcall(fs.deleteFile, fs.path.join(cache, `P_-{hash}.tar`))
            pcall(fs.deleteFile, fs.path.join(cache, `{hash}.tar`))
        end)
        writePackage(root, "app", `        b.dependency(\{ url = "{url}", hash = "{hash}", artifact = true \})`)
        expect(lines(root)).toBe(table.concat({
            "app (1):",
            `  (unresolved) {hash}`,
            "",
            "unresolved dependents:",
            ` 1) {hash} (hash)`,
            "    - app",
        }, "\n"))
        local real = fs.realPathFileAlloc(io.cwd(), root)
        local slot_dir = fs.path.join(real, ".zune", "pkg", `P_-{hash}`)
        expect(fs.readFile(fs.path.join(slot_dir, "readme.txt"))).toBe("kept")
        expect(fs.stat(fs.path.join(real, ".zune", "pkg", `nope-1.0.0-{hash}`)).kind).toBe("none")
    end)

    test("sandbox", function()
        local dir = `{TEMP_DIR}/pkg-sandbox`
        writePackage(
            dir,
            "app",
            [=[
        local _meta = setmetatable({}, {})
]=]
        )
        local ok, err, log = capturePrint(function()
            package.install({ dir = dir })
        end)
        expect(ok).toBe(false)
        expect(tostring(err)).toBe("install failed")
        expect(string.find(log, "setmetatable is not available", 1, true)).toBeTruthy()
        local built_ok, built_err, built_log = capturePrint(function()
            package.build({ dir = dir })
        end)
        expect(built_ok).toBe(false)
        expect(tostring(built_err)).toBe("build failed")
        expect(string.find(built_log, "setmetatable is not available", 1, true)).toBeTruthy()
    end)

    test("system library", function()
        local dir = `{TEMP_DIR}/pkg-syslib`
        local root = `{TEMP_DIR}/syslib`
        local os_name = zune.platform.os
        local file = if os_name == "windows"
            then "zunesample.dll"
            elseif os_name == "macos" then "libzunesample.dylib"
            else "libzunesample.so"
        fs.makeDir(root, true)
        fs.writeFile(fs.path.join(root, file), "marker")
        package.setLibraryRoot(root)
        writePackage(
            dir,
            "app",
            [=[
        local missing = b.findSystemLibrary("zunemissing")
        if missing then
            error("found")
        end
        local lib = b.findSystemLibrary("zunesample")
        if not lib then
            error("missing")
        end
        print(lib)
        print({ item = lib })
        b.copy(lib, { name = "found.lib" })
]=]
        )
        local ok, err, log = capturePrint(function()
            package.install({ dir = dir })
        end)
        package.setLibraryRoot(nil)
        if not ok then
            error(`{err}\n{log}`, 0)
        end
        expect(ok).toBe(true)
        expect(fs.readFile(`{dir}/found.lib`)).toBe("marker")
        expect(string.find(log, " <Node library(zunesample)>", 1, true)).toBeTruthy()
        expect(string.find(log, "item = <Node library(zunesample)>", 1, true)).toBeTruthy()
        expect(string.find(log, "recursive", 1, true)).toBeNil()

        local cross_dir = `{TEMP_DIR}/pkg-syslib-cross`
        local arch = zune.platform.cpu.arch
        local cross = if arch == "aarch64" then "x86_64-windows" else "aarch64-linux"
        writePackage(
            cross_dir,
            "app",
            [=[
        local lib = b.findSystemLibrary("zunesample")
        if lib then
            error("found")
        end
]=]
        )
        package.setLibraryRoot(root)
        local cross_ok, cross_err = pcall(function()
            package.install({ dir = cross_dir, target = cross })
        end)
        package.setLibraryRoot(nil)
        expect(cross_ok).toBe(true)
        if not cross_ok then
            error(tostring(cross_err), 0)
        end

        local bad_dir = `{TEMP_DIR}/pkg-syslib-bad`
        writePackage(
            bad_dir,
            "app",
            [=[
        b.findSystemLibrary("")
]=]
        )
        local bad_ok, bad_err, bad_log = capturePrint(function()
            package.install({ dir = bad_dir })
        end)
        expect(bad_ok).toBe(false)
        expect(tostring(bad_err)).toBe("install failed")
        expect(string.find(bad_log, "library name is required", 1, true)).toBeTruthy()

        writePackage(
            bad_dir,
            "app",
            [=[
        b.findSystemLibrary("foo.so")
]=]
        )
        local dot_ok, dot_err, dot_log = capturePrint(function()
            package.install({ dir = bad_dir })
        end)
        expect(dot_ok).toBe(false)
        expect(tostring(dot_err)).toBe("install failed")
        expect(string.find(dot_log, "invalid name (cannot have special characters)", 1, true)).toBeTruthy()
    end)

    test("running", function()
        local dir = `{TEMP_DIR}/pkg-running`
        writePackage(
            dir,
            "app",
            [=[
        local host = nil
        for i = 1, 12 do
            local f, line, src = debug.info(i, "fls")
            if not f then
                break
            end
            if line >= 0 and type(src) == "string" and string.find(src, "init.luau", 1, true) then
                host = f
                break
            end
        end
        if type(host) ~= "function" then
            error("host missing")
        end
        local ran, failure = pcall(host)
        if ran or not string.find(tostring(failure), "build is already running", 1, true) then
            error(tostring(failure))
        end
]=]
        )
        local result = package.install({ dir = dir })
        expect(result.root).toBe("app")
    end)

    test("export", function()
        local root = `{TEMP_DIR}/pkg-export`
        writePackage(
            `{root}/deps/sample`,
            "sample",
            [=[
        local file = b.self():path("note.txt")
        local meta = { label = "sample", file = file }
        b.export("bin", file)
        b.export("note")
        b.export("meta", meta)
        b.export("bin", file)
]=]
        )
        fs.makeDir(`{root}/deps/sample`, true)
        fs.writeFile(`{root}/deps/sample/note.txt`, "sample")
        writePackage(
            root,
            "app",
            [=[
        b.dependency({ path = "deps/sample" })
]=]
        )

        local dup_ok, dup_err, dup_log = capturePrint(function()
            package.install({ dir = root })
        end)
        expect(dup_ok).toBe(false)
        expect(tostring(dup_err)).toBe("install failed")
        expect(string.find(dup_log, "export already set", 1, true)).toBeTruthy()

        writePackage(
            `{root}/deps/sample`,
            "sample",
            [=[
        local file = b.self():path("note.txt")
        local meta = { label = "sample", file = file }
        b.export("bin", file)
        b.export("note")
        b.export("meta", meta)
        b.export("gap", 0 / 0)
        b.export("point", vector.create(0 / 0, 0, 0))
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        local sample = b.dependency({ path = "deps/sample" })
        sample:get("missing")
]=]
        )
        local missing_ok, missing_err, missing_log = capturePrint(function()
            package.install({ dir = root })
        end)
        expect(missing_ok).toBe(false)
        expect(tostring(missing_err)).toBe("install failed")
        expect(string.find(missing_log, "unknown export missing", 1, true)).toBeTruthy()

        writePackage(
            root,
            "app",
            [=[
        local sample = b.dependency({ path = "deps/sample" })
        local note = sample:get("note")
        local meta = sample:get("meta")
        local bin = sample:get("bin")
        local gap = sample:get("gap")
        local point = sample:get("point")
        if type(meta) ~= "table" or meta.kind ~= "export" then
            if note ~= nil then
                error("nil export")
            end
            if meta.label ~= "sample" or meta.file ~= bin then
                error("export identity")
            end
            if gap == gap or typeof(point) ~= "vector" or point.x == point.x then
                error("nan export")
            end
            b.install(meta.file, { name = "nested.txt" })
        end
]=]
        )
        local result = package.install({ dir = root })
        expect(result.root).toBe("app")
        expect(fs.readFile(`{root}/.zune/out/nested.txt`)).toBe("sample")

        writePackage(
            `{root}/deps/self`,
            "self",
            [=[
        b.self():get("bin")
]=]
        )
        local get_ok, get_err, get_log = capturePrint(function()
            package.install({ dir = `{root}/deps/self` })
        end)
        expect(get_ok).toBe(false)
        expect(tostring(get_err)).toBe("install failed")
        expect(string.find(get_log, "attempt to call missing method 'get'", 1, true)).toBeTruthy()

        writePackage(
            `{root}/deps/fn`,
            "fn",
            [=[
        b.export("fn", function() end)
]=]
        )
        local fn_ok, fn_err, fn_log = capturePrint(function()
            package.install({ dir = `{root}/deps/fn` })
        end)
        expect(fn_ok).toBe(false)
        expect(tostring(fn_err)).toBe("install failed")
        expect(string.find(fn_log, "export value is not writable", 1, true)).toBeTruthy()

        writePackage(
            `{root}/deps/job`,
            "job",
            [=[
        b.export("job", coroutine.create(function() end))
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        local job_pkg = b.dependency({ path = "deps/job" })
        local job = job_pkg:get("job")
        if type(job) ~= "table" or job.kind ~= "export" then
            if type(job) ~= "thread" then
                error("thread export")
            end
        end
]=]
        )
        local thread_result = package.install({ dir = root })
        expect(thread_result.root).toBe("app")
    end)

    test("option", function()
        local root = `{TEMP_DIR}/pkg-option`
        writePackage(
            `{root}/deps/sample`,
            "sample",
            [=[
        local version = b.option("version", "library release")
        local scale = b.option("scale", "unit scale")
        local missing = b.option("missing", "optional")
        local gone = b.option("gone", "not a value")
        local here = b.option("here", "not a node")
        if version ~= "5.5" then
            error("version")
        end
        if missing ~= nil or gone ~= nil or here ~= nil then
            error("missing")
        end
        if typeof(scale) ~= "vector" or scale.x ~= 1 then
            error("scale")
        end
        b.export("version", version)
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        if b.option("version", "root") ~= nil then
            error("root option")
        end
        local sample = b.dependency({
            path = "deps/sample",
            options = {
                version = "5.5",
                scale = vector.create(1, 0, 0),
            },
        })
        local version = sample:get("version")
        if type(version) ~= "table" and version ~= "5.5" then
            error("passed version")
        end
]=]
        )
        local result = package.install({ dir = root })
        expect(result.root).toBe("app")

        writePackage(
            `{root}/deps/nan`,
            "nan",
            [=[
        local gap = b.option("gap", "missing number")
        local tilt = b.option("tilt", "missing vector")
        if type(gap) ~= "number" or gap == gap then
            error("nan option")
        end
        if typeof(tilt) ~= "vector" or tilt.x == tilt.x then
            error("nan vector option")
        end
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        b.dependency({
            path = "deps/nan",
            options = {
                gap = 0 / 0,
                tilt = vector.create(0 / 0, 0, 0),
            },
        })
]=]
        )
        local nan = package.install({ dir = root })
        expect(nan.root).toBe("app")

        writePackage(
            root,
            "app",
            [=[
        b.dependency({
            path = "deps/sample",
            options = {
                version = "5.5",
                scale = vector.create(1, 0, 0),
                extra = true,
                gone = function() end,
                here = b.self(),
            },
        })
]=]
        )
        local unread = package.install({ dir = root })
        expect(unread.root).toBe("app")

        local user = `{TEMP_DIR}/pkg-user-option`
        writePackage(
            `{user}/deps/sample`,
            "sample",
            [=[
        if b.option("version", "library release") ~= nil then
            error("child option")
        end
]=]
        )
        writePackage(
            user,
            "app",
            [=[
        b.dependency({ path = "deps/sample" })
        local version = b.option("version", "library release")
        local scale = b.option("scale", "unit scale")
        local release = b.option("release", "ship it")
        local tilt = b.option("tilt", "tilt")
        local note = b.option("note", "note")
        local missing = b.option("missing", "optional")
        if version ~= "5.5" then
            error("version")
        end
        if scale ~= 0.0015 then
            error("scale")
        end
        if release ~= false then
            error("release")
        end
        if typeof(tilt) ~= "vector" or tilt.x ~= 1 or tilt.y ~= 0 or tilt.z ~= 0 then
            error("tilt")
        end
        if note ~= "" then
            error("note")
        end
        if missing ~= nil then
            error("missing")
        end
]=]
        )
        local given = package.install({
            dir = user,
            options = {
                version = "5.5",
                scale = 0.0015,
                release = false,
                tilt = vector.create(1, 0, 0),
                note = "",
            },
        })
        expect(given.root).toBe("app")
    end)

    test("module", function()
        local dir = `{TEMP_DIR}/pkg-module`
        writePackage(
            dir,
            "app",
            [=[
        local bin = b.self():path("src/init.luau")
        b.module(b.self():path("settings.luau"), {
            version = "5.5",
            bin = bin,
            scale = vector.create(1, 0, 0),
        })
        b.module(b.self():path("cfg/settings.luau"), {
            here = b.self(),
            file = b.self():path("src/init.luau"),
            nested = b.self():path("src"):path("init.luau"),
        })
]=]
        )
        fs.makeDir(`{dir}/src`, true)
        fs.writeFile(`{dir}/src/init.luau`, "return nil\n")
        local writes = 0
        local fs_write = fs.writeFile
        fs.writeFile = function(path: string, content: string | buffer)
            if string.find(path, "settings.luau", 1, true) then
                writes += 1
            end
            fs_write(path, content)
        end
        local ok, err = pcall(function()
            package.install({ dir = dir })
            local text = fs.readFile(`{dir}/settings.luau`)
            expect(string.sub(text, 1, 7)).toBe("return ")
            expect(string.find(text, '"5.5"', 1, true)).toBeTruthy()
            expect(string.find(text, "vector.create(1, 0, 0)", 1, true)).toBeTruthy()
            expect(string.find(text, "./src/init.luau", 1, true)).toBeTruthy()
            local nested = fs.readFile(`{dir}/cfg/settings.luau`)
            expect(string.find(nested, "../src/init.luau", 1, true)).toBeTruthy()
            expect(string.find(nested, 'here = "../"', 1, true)).toBeTruthy()
            expect(string.find(nested, real(dir), 1, true)).toBe(nil)
            expect(writes).toBe(2)
            package.install({ dir = dir })
            expect(writes).toBe(2)
        end)
        fs.writeFile = fs_write
        if not ok then
            error(err)
        end

        local bad = `{TEMP_DIR}/pkg-module-nan`
        writePackage(
            bad,
            "app",
            [=[
        b.module(b.self():path("settings.luau"), 0 / 0)
]=]
        )
        expect(function()
            package.install({ dir = bad })
        end).toThrow("invalid number value (cannot be inf or nan)")
    end)

    test("copy", function()
        local dir = `{TEMP_DIR}/pkg-copy`
        fs.makeDir(`{dir}/lib`, true)
        fs.writeFile(`{dir}/lib/note.txt`, "one")
        writePackage(
            dir,
            "app",
            [=[
        local beside = b.copy(b.self():path("lib/note.txt"))
        local nested = b.copy(b.self():path("lib/note.txt"), { dir = "lib/../other" })
        local named = b.copy(b.self():path("lib/note.txt"), {
            dir = b.self():path("extra"),
            name = "samplelib",
        })
        b.bind({
            luau = {
                aliases = {
                    beside = beside,
                    nested = nested,
                    named = named,
                },
            },
        })
        b.install(beside)
        b.install(named)
]=]
        )
        local copied = package.install({ dir = dir })
        expect(fs.readFile(`{dir}/note.txt`)).toBe("one")
        expect(fs.readFile(`{dir}/other/note.txt`)).toBe("one")
        expect(fs.readFile(`{dir}/extra/samplelib`)).toBe("one")
        expect(copied.aliases.beside).toBe("./note.txt")
        expect(copied.aliases.nested).toBe("./other/note.txt")
        expect(copied.aliases.named).toBe("./extra/samplelib")
        expect(fs.readFile(`{dir}/.zune/out/note.txt`)).toBe("one")
        expect(fs.readFile(`{dir}/.zune/out/samplelib`)).toBe("one")
        fs.writeFile(`{dir}/note.txt`, "kept")
        package.install({ dir = dir })
        expect(fs.readFile(`{dir}/note.txt`)).toBe("kept")
        writePackage(
            dir,
            "app",
            [=[
        b.copy(b.self():path("lib/note.txt"), { override = true })
]=]
        )
        package.install({ dir = dir })
        expect(fs.readFile(`{dir}/note.txt`)).toBe("one")

        writePackage(
            dir,
            "app",
            [=[
        b.copy(b.self():path("lib/note.txt"), { dir = "../out" })
]=]
        )
        local leave_ok, leave_err, leave_log = capturePrint(function()
            package.install({ dir = dir })
        end)
        expect(leave_ok).toBe(false)
        expect(tostring(leave_err)).toBe("install failed")
        expect(string.find(leave_log, "path leaves the package", 1, true)).toBeTruthy()

        writePackage(
            dir,
            "app",
            [=[
        b.copy(b.self():path("lib/note.txt"), { name = "same.txt" })
        b.copy(b.self():path("lib/note.txt"), { dir = "lib/../.", name = "same.txt" })
]=]
        )
        local clash_ok, clash_err, clash_log = capturePrint(function()
            package.install({ dir = dir })
        end)
        expect(clash_ok).toBe(false)
        expect(tostring(clash_err)).toBe("install failed")
        expect(string.find(clash_log, "copy path already used", 1, true)).toBeTruthy()
        local marks = 0
        for _ in string.gmatch(clash_log, "copy path already used") do
            marks += 1
        end
        expect(marks >= 2).toBe(true)
        expect(string.find(clash_log, "package.luau", 1, true)).toBeTruthy()
    end)

    test("install", function()
        local root = `{TEMP_DIR}/pkg-install`
        fs.makeDir(`{root}/deps/sample/lib`, true)
        fs.writeFile(`{root}/deps/sample/lib/libsample.so`, "libsample")
        fs.writeFile(`{root}/mine.txt`, "mine")
        writePackage(
            `{root}/deps/sample`,
            "sample",
            [=[
        local bin = b.self():path("lib/libsample.so")
        b.export("target_name", b.switch({
            ["x86_64-linux"] = "samplelib.so",
            ["x86_64-macos"] = "samplelib.dylib",
            ["aarch64-macos"] = "samplelib.dylib",
            ["x86_64-windows"] = "samplelib.dll",
            default = "samplelib.so",
        }))
        b.export("bin", bin)
        b.install(bin, { name = "libsample.so.0" })
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        local sample = b.dependency({ path = "deps/sample" })
        b.install(sample:get("bin"), { name = "libsample.so.0" })
        b.install(b.self():path("mine.txt"))
        b.copy(sample:get("bin"), { name = sample:get("target_name") })
        b.install(sample:get("bin"), { name = sample:get("target_name") })
]=]
        )
        package.install({ dir = root })
        expect(fs.readFile(`{root}/.zune/out/libsample.so.0`)).toBe("libsample")
        expect(fs.readFile(`{root}/.zune/out/mine.txt`)).toBe("mine")
        expect(fs.stat(`{root}/deps/sample/.zune/out/libsample.so.0`).kind).toBe("none")
        local names = {
            ["x86_64-linux"] = "samplelib.so",
            ["x86_64-macos"] = "samplelib.dylib",
            ["aarch64-macos"] = "samplelib.dylib",
            ["x86_64-windows"] = "samplelib.dll",
        }
        local file_name = names[package.hostTarget()] or "samplelib.so"
        expect(fs.readFile(`{root}/{file_name}`)).toBe("libsample")
        expect(fs.readFile(`{root}/.zune/out/{file_name}`)).toBe("libsample")

        local sample_only = `{TEMP_DIR}/pkg-install-sample`
        fs.makeDir(`{sample_only}/lib`, true)
        fs.writeFile(`{sample_only}/lib/libsample.so`, "libsample")
        writePackage(
            sample_only,
            "sample",
            [=[
        b.install(b.self():path("lib/libsample.so"), { name = "samplelib" })
]=]
        )
        package.install({ dir = sample_only, out = "build/sample" })
        expect(fs.readFile(`{sample_only}/build/samplelib`)).toBe("libsample")
        expect(fs.stat(`{sample_only}/.zune/out/samplelib`).kind).toBe("none")

        writePackage(
            root,
            "app",
            [=[
        local sample = b.dependency({ path = "deps/sample" })
        b.install(sample:get("bin"), { name = "libsample.so.0" })
        b.install(b.self():path("mine.txt"), { name = "libsample.so.0" })
]=]
        )
        local clash_ok, clash_err, clash_log = capturePrint(function()
            package.install({ dir = root })
        end)
        expect(clash_ok).toBe(false)
        expect(tostring(clash_err)).toBe("install failed")
        expect(string.find(clash_log, "install path already used", 1, true)).toBeTruthy()
        local marks = 0
        for _ in string.gmatch(clash_log, "install path already used") do
            marks += 1
        end
        expect(marks >= 2).toBe(true)
        expect(string.find(clash_log, "package.luau", 1, true)).toBeTruthy()
    end)

    test("changed", function()
        local root = `{TEMP_DIR}/pkg-changed`
        writePackage(`{root}/deps/extra`, "extra", "")
        writePackage(
            `{root}/deps/sample`,
            "sample",
            [=[
        b.export("flag", false)
]=]
        )
        writePackage(
            root,
            "app",
            [=[
        local sample = b.dependency({ path = "deps/sample" })
        if sample:get("flag") then
            b.dependency({ path = "deps/extra" })
        end
]=]
        )
        expect(function()
            package.install({ dir = root })
        end).toThrow("build changed")
    end)

    test("missing entry", function()
        local dir = `{TEMP_DIR}/pkg-missing-entry`
        writePackage(
            dir,
            "app",
            [=[
        b.entry(b.self():path("missing.luau"))
]=]
        )
        local ok, err = pcall(function()
            package.build({ dir = dir })
        end)
        expect(ok).toBe(false)
        local message = tostring(err)
        expect(string.find(message, "unresolved", 1, true)).toBeTruthy()
        expect(string.find(message, "missing.luau", 1, true)).toBeTruthy()
        expect(string.find(message, "b.entry", 1, true)).toBeTruthy()
    end)

    test("build out", function()
        if not runtime.getStd() then
            error("SkipTest", 0)
        end
        local dir = `{TEMP_DIR}/pkg-build-out`
        fs.makeDir(`{dir}/src`, true)
        fs.makeDir(`{dir}/glob`, true)
        fs.writeFile(
            `{dir}/main.luau`,
            [=[
local scripts = table.concat(zune.fs.embeddedScripts(), "\n")
local files = table.concat(zune.fs.embeddedFiles(), "\n")
print(scripts)
print("---")
print(files)
local extra = require("./src/extra")
if extra ~= "ok" then
    error(tostring(extra))
end
]=]
        )
        fs.writeFile(
            `{dir}/src/extra.luau`,
            'local more = require("../glob/more")\nif more ~= "more-marker" then\n    error(tostring(more))\nend\nreturn "ok"\n'
        )
        fs.writeFile(`{dir}/glob/more.luau`, 'return "more-marker"\n')
        fs.writeFile(`{dir}/asset.txt`, "asset")
        writePackage(
            dir,
            "app",
            [=[
        b.entry(b.self():path("main.luau"))
        b.embedScript(b.self():path("src/extra.luau"))
        b.embedScript(b.self():glob("glob/**/*.luau"))
        b.embedFile(b.self():path("asset.txt"))
]=]
        )
        local out = package.build({
            dir = dir,
            out = "out/app",
            debug = true,
        })
        expect(string.find(out, "/out/app", 1, true)).toBeTruthy()
        expect(fs.stat(out).kind).toBe("file")
        expect(fs.stat(`{dir}/.zune/out`).kind).toBe("none")
        local ran = zune.process.run(out, {}, {
            stdout = "pipe",
            stderr = "pipe",
        })
        expect(ran.ok).toBe(true)
        local out_text = if ran.stdout then buffer.tostring(ran.stdout) else ""
        local err_text = if ran.stderr then buffer.tostring(ran.stderr) else ""
        local text = out_text .. err_text
        expect(string.find(text, "main.luau", 1, true)).toBeTruthy()
        expect(string.find(text, "src/extra.luau", 1, true)).toBeTruthy()
        expect(string.find(text, "glob/more.luau", 1, true)).toBeTruthy()
        expect(string.find(text, "asset.txt", 1, true)).toBeTruthy()
        expect(string.find(text, dir, 1, true)).toBe(nil)
    end)

    test("build target", function()
        local dir = `{TEMP_DIR}/pkg-build-target`
        local host = package.hostTarget()
        local arch = string.match(host, "^([^%-]+)")
        local cross = if arch == "aarch64" then "x86_64-windows" else "aarch64-linux"
        writePackage(
            dir,
            "app",
            [=[
        b.runtime()
]=]
        )
        local cross_ok, cross_err = pcall(function()
            package.install({ dir = dir, target = cross })
        end)
        expect(cross_ok).toBe(false)
        expect(string.find(tostring(cross_err), `runtime for {cross} is not available`, 1, true)).toBeTruthy()

        local build_ok, build_err = pcall(function()
            package.build({ dir = dir, target = cross })
        end)
        expect(build_ok).toBe(false)
        expect(string.find(tostring(build_err), `runtime for {cross} is not available`, 1, true)).toBeTruthy()

        local other: string? = nil
        if string.sub(host, -4) == "-gnu" then
            other = `{string.sub(host, 1, -5)}-musl`
        elseif string.sub(host, -5) == "-musl" then
            other = `{string.sub(host, 1, -6)}-gnu`
        end
        if other then
            local abi_ok, abi_err = pcall(function()
                package.build({ dir = dir, target = other })
            end)
            expect(abi_ok).toBe(false)
            expect(string.find(tostring(abi_err), `runtime for {other} is not available`, 1, true)).toBeTruthy()
        end

        expect(function()
            package.build({ dir = dir, target = cross, zune_bin = "" })
        end).toThrow("zune bin is required")
        expect(function()
            package.build({ dir = dir, target = cross, zune_bin = `{dir}/missing` })
        end).toThrow(`zune bin must be a file ({dir}/missing)`)

        if not runtime.getStd() then
            return
        end
        fs.writeFile(`{dir}/main.luau`, 'print("target-bin")\n')
        writePackage(
            dir,
            "app",
            [=[
        b.entry(b.self():path("main.luau"))
        b.module(b.self():path("where.luau"), {
            bin = b.runtime(),
        })
]=]
        )
        local exe = zune.process.getExePath()
        local out = package.build({
            dir = dir,
            target = "aarch64-linux-musl",
            zune_bin = exe,
        })
        expect(fs.stat(out).kind).toBe("file")
        local where = fs.readFile(`{dir}/where.luau`)
        local rel = string.match(where, 'bin = "(.-)"')
        expect(rel).toBeTruthy()
        local resolved = fs.path.resolve(dir, rel :: string)
        expect(fs.realPathFileAlloc(io.cwd(), resolved)).toBe(fs.realPathFileAlloc(io.cwd(), exe))
        local ran = zune.process.run(out, {}, {
            stdout = "pipe",
            stderr = "pipe",
        })
        local out_text = if ran.stdout then buffer.tostring(ran.stdout) else ""
        local err_text = if ran.stderr then buffer.tostring(ran.stderr) else ""
        expect(ran.ok).toBe(true)
        expect(`{out_text}{err_text}`).toBe("target-bin\n")
    end)
end)

return nil
