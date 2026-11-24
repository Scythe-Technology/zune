--!strict

local fs = require("@zune/fs")
local io = require("@zune/io")
local ansi = require("@zune/ansi").auto()
local fetch = require("@zune/package/fetch")
local tar = require("@zune/archive/tar")
local package = require("@zune/package")
local slot = require("@zune/package/slot")
local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local TEMP_DIR = zune.process.env.TEMP_PATH or error("TEMP_PATH environment variable is not set")
local JUNK = `{string.rep("B", 43)}=`

local function writePackage(dir: string, name: string, build: string)
    fs.makeDir(dir, true)
    fs.writeFile(
        `{dir}/package.luau`,
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

local function capture(): (package.Reporter, { string })
    local lines: { string } = {}
    local reporter: package.Reporter = {
        message = function(_: package.Reporter, text: string, _: string?)
            table.insert(lines, text)
        end,
        confirm = function(_: package.Reporter, _: string, _: string?): boolean
            return true
        end,
        progress = function(_: package.Reporter, _: string, _: number, _: number?, _: number?, _: number?) end,
    }
    return reporter, lines
end

local function shown(lines: { string }): string
    return table.concat(lines, "\n")
end

local function cacheFile(name: string): string
    return fs.path.join(slot.cacheRoot(), "pkg", name)
end

local function pinProject(dir: string): (string, string)
    local cache_dir = `{dir}-cache`
    fs.makeDir(cache_dir, true)
    slot.setCacheRoot(cache_dir)
    local store = `{dir}-src`
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
    })
    local file = `{store}/blob.tar`
    fs.writeFile(file, blob)
    local hash = fetch.hashBuffer(blob)
    local url = `file://{fs.realPathFileAlloc(io.cwd(), file)}`
    writePackage(dir, "app", `        b.dependency(\{ url = "{url}", hash = "{hash}" \})`)
    package.install({ dir = dir })
    local real = fs.realPathFileAlloc(io.cwd(), dir)
    local packed = cacheFile(`sample-1.0.0-{hash}.tar`)
    local plain = cacheFile(`P_-{hash}.tar`)
    local legacy = cacheFile(`{hash}.tar`)
    local junk_tar = cacheFile(`P_-{JUNK}.tar`)
    testing.defer(function()
        pcall(fs.deleteFile, packed)
        pcall(fs.deleteFile, plain)
        pcall(fs.deleteFile, legacy)
        pcall(fs.deleteFile, junk_tar)
        slot.setCacheRoot(nil)
    end)
    return real, hash
end

local function installed(real: string, hash: string): string
    return fs.path.join(real, ".zune", "pkg", `sample-1.0.0-{hash}`)
end

describe("mode", function()
    test("idle", function()
        local dir = `{TEMP_DIR}/pkg-clean-idle`
        writePackage(dir, "app", "")
        local reporter, lines = capture()
        package.clean({ dir = dir, reporter = reporter })
        expect(shown(lines)).toBe("Nothing else to do")
    end)

    test("missing", function()
        local dir = `{TEMP_DIR}/pkg-clean-missing`
        fs.makeDir(dir, true)
        expect(function()
            package.clean({ dir = dir })
        end).toThrow("package.luau is missing")
    end)

    test("unused", function()
        local dir = `{TEMP_DIR}/pkg-clean-unused`
        local real, hash = pinProject(dir)
        local junk_name = `old-1.0.0-{JUNK}`
        fs.makeDir(fs.path.join(real, ".zune", "pkg", junk_name), true)
        fs.makeDir(fs.path.join(real, ".zune", "artifacts"), true)
        fs.writeFile(fs.path.join(real, ".zune", "artifacts", "note.txt"), "x")
        fs.makeDir(fs.path.join(real, ".zune", "std"), true)
        local reporter, lines = capture()
        package.clean({ dir = dir, reporter = reporter })
        expect(fs.stat(fs.path.join(real, ".zune", "pkg", junk_name)).kind).toBe("none")
        expect(fs.stat(fs.path.join(real, ".zune", "artifacts")).kind).toBe("none")
        expect(fs.stat(fs.path.join(real, ".zune", "std")).kind).toBe("directory")
        expect(fs.stat(installed(real, hash)).kind).toBe("directory")
        expect(fs.stat(cacheFile(`sample-1.0.0-{hash}.tar`)).kind).toBe("file")
        expect(shown(lines)).toBe(table.concat({
            `{ansi.bold}cleaning dependencies...{ansi.reset}`,
            `{ansi.dim}  {junk_name}{ansi.reset}`,
            `{ansi.dim}  artifacts{ansi.reset}`,
            `{ansi.bold}clean finished{ansi.reset}`,
        }, "\n"))
    end)

    test("cache", function()
        local dir = `{TEMP_DIR}/pkg-clean-cache`
        local real, hash = pinProject(dir)
        local extra = cacheFile(`P_-{JUNK}.tar`)
        fs.writeFile(extra, "nope")
        local reporter, lines = capture()
        package.clean({
            dir = dir,
            reporter = reporter,
            cache = 1,
        })
        expect(fs.stat(cacheFile(`sample-1.0.0-{hash}.tar`)).kind).toBe("none")
        expect(fs.stat(extra).kind).toBe("file")
        expect(fs.stat(installed(real, hash)).kind).toBe("directory")
        expect(shown(lines)).toBe(table.concat({
            `{ansi.bold}cleaning cache...{ansi.reset}`,
            `{ansi.dim}  sample-1.0.0-{hash}.tar{ansi.reset}`,
            `{ansi.bold}clean finished{ansi.reset}`,
        }, "\n"))
    end)

    test("cache system", function()
        local dir = `{TEMP_DIR}/pkg-clean-system`
        local real, hash = pinProject(dir)
        local extra = cacheFile(`P_-{JUNK}.tar`)
        fs.writeFile(extra, "nope")
        local reporter, lines = capture()
        package.clean({
            dir = dir,
            reporter = reporter,
            cache = 2,
        })
        expect(fs.stat(cacheFile(`sample-1.0.0-{hash}.tar`)).kind).toBe("none")
        expect(fs.stat(extra).kind).toBe("none")
        expect(fs.stat(installed(real, hash)).kind).toBe("directory")
        expect(shown(lines)).toBe(table.concat({
            `{ansi.bold}cleaning cache...{ansi.reset}`,
            `{ansi.dim}  P_-{JUNK}.tar{ansi.reset}`,
            `{ansi.dim}  sample-1.0.0-{hash}.tar{ansi.reset}`,
            `{ansi.bold}clean finished{ansi.reset}`,
        }, "\n"))
    end)

    test("both", function()
        local dir = `{TEMP_DIR}/pkg-clean-both`
        local real, hash = pinProject(dir)
        local junk_name = `old-1.0.0-{JUNK}`
        fs.makeDir(fs.path.join(real, ".zune", "pkg", junk_name), true)
        local extra = cacheFile(`P_-{JUNK}.tar`)
        fs.writeFile(extra, "nope")
        local reporter, lines = capture()
        package.clean({
            dir = dir,
            reporter = reporter,
            cache = 1,
            unused = true,
        })
        expect(fs.stat(fs.path.join(real, ".zune", "pkg", junk_name)).kind).toBe("none")
        expect(fs.stat(cacheFile(`sample-1.0.0-{hash}.tar`)).kind).toBe("none")
        expect(fs.stat(extra).kind).toBe("file")
        expect(fs.stat(installed(real, hash)).kind).toBe("directory")
        expect(shown(lines)).toBe(table.concat({
            `{ansi.bold}cleaning dependencies...{ansi.reset}`,
            `{ansi.dim}  {junk_name}{ansi.reset}`,
            `{ansi.bold}clean finished{ansi.reset}`,
            `{ansi.bold}cleaning cache...{ansi.reset}`,
            `{ansi.dim}  sample-1.0.0-{hash}.tar{ansi.reset}`,
            `{ansi.bold}clean finished{ansi.reset}`,
        }, "\n"))
    end)

    test("env", function()
        local dir = `{TEMP_DIR}/pkg-clean-env`
        fs.makeDir(`{dir}/.zune/pkg`, true)
        fs.makeDir(`{dir}/.zune/std`, true)
        fs.writeFile(`{dir}/.zune/note`, "x")
        local reporter, lines = capture()
        package.clean({
            dir = dir,
            reporter = reporter,
            env = true,
        })
        expect(fs.stat(`{dir}/.zune`).kind).toBe("none")
        expect(shown(lines)).toBe(table.concat({
            `{ansi.bold}cleaning .zune...{ansi.reset}`,
            `{ansi.dim}  note{ansi.reset}`,
            `{ansi.dim}  pkg{ansi.reset}`,
            `{ansi.dim}  std{ansi.reset}`,
            `{ansi.bold}clean finished{ansi.reset}`,
        }, "\n"))
    end)

    test("reset", function()
        local dir = `{TEMP_DIR}/pkg-clean-reset`
        local real, hash = pinProject(dir)
        fs.deleteDir(installed(real, hash), true)
        local reporter, lines = capture()
        package.clean({
            dir = dir,
            reporter = reporter,
            reset = true,
        })
        expect(
            string.find(fs.readFile(fs.path.join(installed(real, hash), "package.luau")), 'name = "sample"', 1, true)
        ).toBeTruthy()
        expect(shown(lines)).toBe(`{ansi.bold}clean finished{ansi.reset}`)
    end)

    test("reset missing", function()
        local dir = `{TEMP_DIR}/pkg-clean-reset-missing`
        local real, hash = pinProject(dir)
        pcall(fs.deleteFile, cacheFile(`sample-1.0.0-{hash}.tar`))
        pcall(fs.deleteFile, cacheFile(`P_-{hash}.tar`))
        pcall(fs.deleteFile, cacheFile(`{hash}.tar`))
        local reporter, lines = capture()
        package.clean({
            dir = dir,
            reporter = reporter,
            reset = true,
        })
        expect(fs.stat(installed(real, hash)).kind).toBe("none")
        expect(shown(lines)).toBe(table.concat({
            `{ansi.bold}missing dependencies:{ansi.reset}`,
            "",
            `{ansi.dim}  sample-1.0.0-{hash}{ansi.reset}`,
            "",
            `{ansi.bold}download with {ansi.green}install{ansi.reset_color} command{ansi.reset}`,
        }, "\n"))
    end)
end)

return nil
