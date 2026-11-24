--!strict
--!optimize 2

local mem = zune.mem
local ascii = zune.ascii
local process = zune.process

local fs = require("@zune/fs")
local io = require("@zune/io")
local spec = require("@zune/spec")
local SemanticVersion = require("@zune/SemanticVersion")

local LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

local slot = {}

local function byteAt(text: string, index: number): number
    return string.byte(text, index + 1) :: number
end

local function digitRun(text: string, from: number, limit: number): number?
    if from >= limit or not ascii.isDigit(byteAt(text, from)) then
        return nil
    end
    local at = from + 1
    while at < limit and ascii.isDigit(byteAt(text, at)) do
        at += 1
    end
    return at
end

local function versionHyphen(text: string, limit: number): number?
    local at = 0
    while at < limit do
        local hyphen = mem.findPos(text, at, "-", limit - at)
        if not hyphen then
            return nil
        end
        local major_end = digitRun(text, hyphen + 1, limit)
        if major_end and major_end < limit and byteAt(text, major_end) == 46 then
            local minor_end = digitRun(text, major_end + 1, limit)
            if minor_end and minor_end < limit and byteAt(text, minor_end) == 46 then
                if digitRun(text, minor_end + 1, limit) then
                    return hyphen
                end
            end
        end
        at = hyphen + 1
    end
    return nil
end

function slot.ensureDir(path: string)
    local path_stat = fs.stat(path)
    if path_stat.kind ~= "none" then
        if path_stat.kind ~= "directory" then
            error("not a directory", 0)
        end
        return
    end
    io.cwd():createDirPath(path)
end

function slot.rooted(path: string): boolean
    return mem.eqlSlice(path, 0, "/", 0, 1) or mem.eqlSlice(path, 0, "\\", 0, 1)
end

function slot.noEscapes(path: string, phrase: string): string
    local slashed = (string.gsub(path, "\\", "/"))
    local parts: { string } = {}
    for piece in string.gmatch(slashed, "[^/]+") do
        if piece == ".." then
            error(phrase, 0)
        end
        if piece ~= "." then
            table.insert(parts, piece)
        end
    end
    return table.concat(parts, "/")
end

local forced_cache: string? = nil

local unsetSpec = spec.union(spec.none, spec.literal(""))
function slot.setCacheRoot(dir: string?)
    if unsetSpec(dir) then
        forced_cache = nil
        return
    end
    forced_cache = dir
end

local textSpec = spec.intersection(spec.string, spec.minLength(1))
function slot.cacheRoot(): string
    if forced_cache then
        return forced_cache
    end
    if zune.platform.os == "windows" then
        local base = process.env.LOCALAPPDATA
        if not textSpec(base) then
            error("LOCALAPPDATA is not set", 0)
        end
        return fs.path.join(base :: string, "zune")
    elseif zune.platform.os == "macos" then
        local home = process.env.HOME
        if not textSpec(home) then
            error("HOME is not set", 0)
        end
        return fs.path.join(home :: string, "Library", "Caches", "zune")
    end
    local xdg = process.env.XDG_CACHE_HOME
    if textSpec(xdg) then
        return fs.path.join(xdg :: string, "zune")
    end
    local home = process.env.HOME
    if not textSpec(home) then
        error("HOME is not set", 0)
    end
    return fs.path.join(home :: string, ".cache", "zune")
end

function slot.cachePkgDir(): string
    return fs.path.join(slot.cacheRoot(), "pkg")
end

function slot.packedPath(stem: string): string
    return fs.path.join(slot.cachePkgDir(), `{stem}.tar`)
end

function slot.unnamedSlot(hash: string): string
    return `P_-{hash}`
end

function slot.namedSlot(name: string, version: string, hash: string): string
    return `{name}-{version}-{hash}`
end

function slot.namedHead(head: string, limit: number): boolean
    local hyphen = versionHyphen(head, limit)
    if not hyphen or hyphen < 1 then
        return false
    end
    if mem.findNonePos(head, 0, LETTERS, hyphen) then
        return false
    end
    return SemanticVersion.parse(string.sub(head, hyphen + 2, limit)) ~= nil
end

function slot.findSlot(root: string, hash: string): string?
    local dir = fs.path.join(root, ".zune", "pkg")
    if fs.stat(dir).kind ~= "directory" then
        return nil
    end
    local plain_name = slot.unnamedSlot(hash)
    local suffix = `-{hash}`
    local named: string? = nil
    local plain: string? = nil
    for _, entry in fs.entries(dir) do
        if entry.kind ~= "directory" then
            continue
        end
        if entry.name == plain_name then
            plain = fs.path.join(dir, entry.name)
        elseif
            #suffix > 0
            and #entry.name > #suffix
            and mem.eqlSlice(entry.name, #entry.name - #suffix, suffix, 0, #suffix)
        then
            if slot.namedHead(entry.name, #entry.name - #suffix) then
                named = fs.path.join(dir, entry.name)
            end
        end
    end
    if named then
        return named
    end
    return plain
end

function slot.findArchive(hash: string): string?
    local dir = slot.cachePkgDir()
    if fs.stat(dir).kind ~= "directory" then
        return nil
    end
    local plain_name = `{slot.unnamedSlot(hash)}.tar`
    local legacy_name = `{hash}.tar`
    local suffix = `-{hash}.tar`
    local named: string? = nil
    local plain: string? = nil
    local legacy: string? = nil
    for _, entry in fs.entries(dir) do
        if entry.kind ~= "file" then
            continue
        end
        if entry.name == plain_name then
            plain = fs.path.join(dir, entry.name)
        elseif entry.name == legacy_name then
            legacy = fs.path.join(dir, entry.name)
        elseif
            #suffix > 0
            and #entry.name > #suffix
            and mem.eqlSlice(entry.name, #entry.name - #suffix, suffix, 0, #suffix)
            and slot.namedHead(entry.name, #entry.name - #suffix)
        then
            named = fs.path.join(dir, entry.name)
        end
    end
    if named then
        return named
    end
    if plain then
        return plain
    end
    return legacy
end

return slot
