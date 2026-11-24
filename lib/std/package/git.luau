--!strict
--!optimize 2

local crypto = zune.crypto
local mem = zune.mem

local io = require("@zune/io")
local fetch = require("./fetch")
local uri = require("@zune/net/uri")
local spec = require("@zune/spec")
local tar = require("@zune/archive/tar")
local pack = require("@zune/git/pack")

local git = {}

local function pkt(data: string): string
    return `{string.format("%04x", #data + 4)}{data}`
end

local gitUrlSpec = spec.match("^git%+")
local commitPinSpec = spec.union(spec.match(`^{string.rep("%x", 40)}$`), spec.match(`^{string.rep("%x", 64)}$`))
function git.parse(url: string): (string, string)
    if not gitUrlSpec(url) then
        error("not a git url", 0)
    end
    local ok, parsed = pcall(uri.parse, string.sub(url, 5))
    if not ok then
        error("bad git uri", 0)
    end
    local fragment = parsed.fragment
    if spec.none(fragment) then
        error("git pin must be a commit", 0)
    end
    local oid = string.lower(fragment :: string)
    if not commitPinSpec(oid) then
        error("git pin must be a commit", 0)
    end
    local mark = mem.findPos(url, 4, "#")
    if not mark then
        error("git pin must be a commit", 0)
    end
    local base = string.sub(url, 5, mark)
    if mark < 8 or not mem.eqlSlice(url, mark - 4, ".git", 0, 4) then
        base ..= ".git"
    end
    return base, oid
end

local function treeFiles(by_oid: { [string]: pack.Object }, oid: string, prefix: string, out: { tar.File })
    local object = by_oid[oid]
    local data = if object then object.data else nil
    if not object or object.kind ~= "tree" or not data then
        error("missing tree", 0)
    end
    local bytes: buffer = data
    local at = 0
    while at < buffer.len(bytes) do
        local space = mem.findScalarPos(bytes, at, 32)
        local nul = if space then mem.findScalarPos(bytes, space + 1, 0) else nil
        if not space or not nul then
            error("missing tree", 0)
        end
        local mode_at = at
        local mode_len = space - at
        local name = buffer.readstring(bytes, space + 1, nul - (space + 1))
        local parts = table.create(20)
        for i = 0, 19 do
            parts[i + 1] = string.format("%02x", buffer.readu8(bytes, nul + 1 + i))
        end
        local child = table.concat(parts)
        at = nul + 21
        local path = if prefix == "" then name else `{prefix}/{name}`
        if
            mode_len == 5 and mem.eqlSlice(bytes, mode_at, "40000", 0, 5)
            or mode_len == 6 and mem.eqlSlice(bytes, mode_at, "040000", 0, 6)
        then
            treeFiles(by_oid, child, path, out)
        elseif
            mode_len == 6
            and (mem.eqlSlice(bytes, mode_at, "120000", 0, 6) or mem.eqlSlice(bytes, mode_at, "160000", 0, 6))
        then
            -- symlink/submodule
        else
            local blob = by_oid[child]
            local blob_data = if blob then blob.data else nil
            if not blob or not blob_data then
                error("missing blob", 0)
            end
            table.insert(out, {
                path = path,
                mode = if mode_len == 6 and mem.eqlSlice(bytes, mode_at, "100755", 0, 6) then 493 else 420,
                data = blob_data,
            })
        end
    end
end

function git.archive(url: string, path: string, options: fetch.FetchOptions?): (buffer, string)
    local base, oid = git.parse(url)
    local body = table.concat({
        pkt("command=fetch\n"),
        pkt("agent=git/2.45.1\n"),
        pkt("object-format=sha1\n"),
        "0001",
        pkt("ofs-delta\n"),
        pkt("no-progress\n"),
        pkt("deepen 1\n"),
        pkt(`want {oid}\n`),
        pkt("done\n"),
        "0000",
    })
    local headers = {
        ["User-Agent"] = "git/2.45.1",
        ["Git-Protocol"] = "version=2",
        ["Content-Type"] = "application/x-git-upload-pack-request",
        ["Accept"] = "application/x-git-upload-pack-result",
    }
    local opts = options or {} :: fetch.FetchOptions
    fetch.toFile(`{base}/git-upload-pack`, path, {
        method = "POST",
        headers = headers,
        body = body,
        timeout = opts.timeout,
        hash = false,
        on_progress = opts.on_progress,
        should_stop = opts.should_stop,
    })
    local loaded, result = pcall(fetch.arrayToBuffer, fetch.loadArray(path))
    pcall(function()
        io.cwd():deleteFile(path)
    end)
    if not loaded then
        error(tostring(result), 0)
    end
    local by_oid = pack.parse(pack.sideband(result :: buffer))
    local commit = by_oid[oid]
    local commit_data = if commit then commit.data else nil
    if not commit or commit.kind ~= "commit" or not commit_data then
        error("commit not in pack", 0)
    end
    local tree = string.match(buffer.tostring(commit_data), "^tree (%x+)")
    if not tree then
        error("commit missing tree", 0)
    end
    local files: { tar.File } = {}
    treeFiles(by_oid, tree, "", files)
    local archive = tar.write(files)
    local hasher = crypto.createHash("blake3")
    hasher:update(archive)
    return archive, fetch.encode(hasher)
end

return git
