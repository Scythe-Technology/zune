--!strict
--!optimize 2

local mem = zune.mem
local serde = zune.serde

local fs = require("@zune/fs")
local io = require("@zune/io")
local tar = require("@zune/archive/tar")
local zip = require("@zune/archive/zip")

export type UnpackOptions = {
    paths: { string }?,
    quiet: boolean?,
    max_size: number?,
}

local DEFAULT_MAX_SIZE = 1024 * 1024 * 1024 * 8

local function guardSize(total: number, opts: UnpackOptions)
    local given = opts.max_size
    local limit = DEFAULT_MAX_SIZE
    if given ~= nil then
        limit = given
    end
    if total > limit then
        error("archive exceeds max_size", 0)
    end
end

local archive = {}

type Parsed = { string } & { disk: string? }

local function canonical(parts: Parsed): { string }
    local names: { string } = {}
    for i = 1, #parts do
        local part = parts[i]
        if part ~= "." then
            local last = names[#names]
            if part == ".." and last ~= nil and last ~= ".." then
                table.remove(names)
            else
                table.insert(names, part)
            end
        end
    end
    return names
end

local function escapes(path: string, parts: Parsed, names: { string }): boolean
    if mem.findPos(path, 0, "\0") then
        return true
    end
    local lead = string.byte(path, 1)
    if lead == 47 or lead == 92 then
        return true
    end
    if parts.disk or names[1] == ".." then
        return true
    end
    return false
end

local function memberName(path: string): string
    local parts = fs.path.parse(path) :: Parsed
    local names = canonical(parts)
    if escapes(path, parts, names) then
        error("archive path escapes", 0)
    end
    return table.concat(names, "/")
end

local function wrapper(paths: { string }): string?
    local root: string? = nil
    for _, path in paths do
        local slash = mem.findPos(path, 0, "/")
        if not slash or slash == 0 then
            return nil
        end
        local head = string.sub(path, 1, slash)
        if root == nil then
            root = head
        elseif root ~= head then
            return nil
        end
    end
    return root
end

local function relative(path: string, strip: string?): string
    local normal = memberName(path)
    if not strip then
        return normal
    end
    if normal == strip then
        return ""
    end
    local prefix = `{strip}/`
    if #normal > #prefix and mem.eqlSlice(normal, 0, prefix, 0, #prefix) then
        return string.sub(normal, #prefix + 1)
    end
    return normal
end

local function writeBytes(path: string, src: buffer, offset: number, count: number)
    local parent = fs.path.dirname(path)
    if parent and parent ~= "" then
        pcall(function()
            io.cwd():createDirPath(parent)
        end)
    end
    local file = io.cwd():createFile(path, { truncate = true })
    local writer = io.createPosWriter(file)
    local err = writer:writeAll(src, offset, count)
    file:close()
    if err then
        error("write failed", 0)
    end
end

local function listed(path: string, files: { string }?): boolean
    if not files then
        return true
    end
    for _, pattern in files do
        local parts = fs.path.parse(pattern) :: Parsed
        local names = canonical(parts)
        local normal = if escapes(pattern, parts, names) then pattern else table.concat(names, "/")
        if mem.findPos(normal, 0, "*") or mem.findPos(normal, 0, "?") or mem.findPos(normal, 0, "[") then
            if fs.path.globMatch(path, normal) or fs.path.globMatch(path, `{normal}/**`) then
                return true
            end
        elseif
            path == normal
            or mem.eqlSlice(path, #normal, "/", 0, 1) and mem.eqlSlice(path, 0, normal, 0, #normal)
        then
            return true
        end
    end
    return false
end

local function readZip(src: buffer): { zip.Entry }
    local entries: { zip.Entry } = {}
    local cursor = zip.iterate(src)
    while true do
        local entry = cursor:next()
        if not entry then
            break
        end
        local path = memberName(entry.path)
        if path == "" then
            continue
        end
        if entry.kind == "file" then
            entry:locate()
        end
        table.insert(entries, entry)
    end
    return entries
end

type ArchiveKind = "tar" | "gzip" | "zip"

function archive.unpack(src: buffer, dest: string, options: UnpackOptions?): number
    local opts = options or {} :: UnpackOptions
    local kind: ArchiveKind = "tar"
    if buffer.len(src) >= 2 and buffer.readu8(src, 0) == 0x1f and buffer.readu8(src, 1) == 0x8b then
        kind = "gzip"
        if buffer.len(src) < 18 then
            error("bad gzip", 0)
        end
        local size = buffer.readu32(src, buffer.len(src) - 4)
        local plain = buffer.create(math.max(size, 1))
        local wrote = serde.gzip.decompress(plain, 0, src, 0)
        src = mem.slice(plain, 0, wrote)
    elseif buffer.len(src) >= 4 and buffer.readu8(src, 0) == 0x50 and buffer.readu8(src, 1) == 0x4b then
        kind = "zip"
    end

    local paths: { string } = {}
    local total = 0
    local zip_entries: { zip.Entry } = {}
    local tar_entries: { tar.Entry } = {}
    if kind == "zip" then
        zip_entries = readZip(src)
        for _, entry in zip_entries do
            if entry.kind == "file" then
                total += entry.size
                table.insert(paths, memberName(entry.path))
            end
        end
    else
        local cursor = tar.iterate(src)
        while true do
            local entry = cursor:next()
            if not entry then
                break
            end
            table.insert(tar_entries, entry)
            if entry.kind == "file" then
                total += entry.size
                table.insert(paths, memberName(entry.path))
            end
        end
    end
    guardSize(total, opts)
    pcall(function()
        io.cwd():createDirPath(dest)
    end)
    local strip = wrapper(paths)
    local function rel(path: string): string
        local normal = memberName(path)
        if not strip then
            return normal
        end
        if normal == strip then
            return ""
        end
        local prefix = `{strip}/`
        if #normal > #prefix and mem.eqlSlice(normal, 0, prefix, 0, #prefix) then
            return string.sub(normal, #prefix + 1)
        end
        return normal
    end

    local matched = 0
    local function accept(path: string): boolean
        if path == "" then
            return false
        end
        return listed(path, opts.paths)
    end

    local function emit(path: string, bytes: buffer, offset: number, count: number)
        if path == "" or path == "." or path == ".." or fs.path.isAbsolute(path) or mem.startsWith(path, "../") then
            error("archive path escapes", 0)
        end
        local out = fs.path.join(dest, path)
        if fs.exists(out) then
            return
        end
        local tmp = `{out}.partial`
        writeBytes(tmp, bytes, offset, count)
        if fs.exists(out) then
            pcall(function()
                io.cwd():deleteFile(tmp)
            end)
            return
        end
        local placed = pcall(function()
            io.cwd():renamePreserve(tmp, io.cwd(), out)
        end)
        if not placed then
            pcall(function()
                io.cwd():deleteFile(tmp)
            end)
            if not fs.exists(out) then
                error("write failed", 0)
            end
        end
    end

    if kind == "zip" then
        for _, entry in zip_entries do
            local path = rel(entry.path)
            if entry.kind == "dir" or not accept(path) then
                continue
            end
            matched += 1
            local bytes = entry:bytes()
            emit(path, bytes, 0, buffer.len(bytes))
        end
    else
        for _, entry in tar_entries do
            local path = rel(entry.path)
            if entry.kind == "dir" or not accept(path) then
                continue
            end
            matched += 1
            local bytes = entry:bytes()
            emit(path, bytes, 0, buffer.len(bytes))
        end
    end

    if not opts.quiet and opts.paths ~= nil and #opts.paths > 0 and matched == 0 then
        error("paths matched nothing", 0)
    end
    return matched
end

local function placeFile(out: string, write: (dest: File) -> ())
    if fs.exists(out) then
        return
    end
    local tmp = `{out}.partial`
    local parent = fs.path.dirname(tmp)
    if parent and parent ~= "" then
        pcall(function()
            io.cwd():createDirPath(parent)
        end)
    end
    local dest_file = io.cwd():createFile(tmp, { truncate = true })
    local copied, copy_err = pcall(write, dest_file)
    dest_file:close()
    if not copied then
        pcall(function()
            io.cwd():deleteFile(tmp)
        end)
        error(tostring(copy_err), 0)
    end
    if fs.exists(out) then
        pcall(function()
            io.cwd():deleteFile(tmp)
        end)
        return
    end
    local placed = pcall(function()
        io.cwd():renamePreserve(tmp, io.cwd(), out)
    end)
    if not placed then
        pcall(function()
            io.cwd():deleteFile(tmp)
        end)
        if not fs.exists(out) then
            error("write failed", 0)
        end
    end
end

local function copyMember(file: File, at: number, count: number, out: string)
    placeFile(out, function(dest_file: File)
        local writer = io.createPosWriter(dest_file)
        local moved, err = io.createPosReader(file, at):pipe(writer, count)
        if err or moved ~= count then
            error(if err then "write failed" else "short read", 0)
        end
    end)
end

local function copyDeflated(file: File, at: number, count: number, size: number, out: string)
    placeFile(out, function(dest_file: File)
        if count == 0 then
            if size ~= 0 then
                error("zip size mismatch", 0)
            end
            return
        end
        local stream = serde.flate.createDecompressor(zune.io.createBufferArray())
        local packed = stream.array
        local reader = io.createPosReader(file, at)
        local writer = io.createPosWriter(dest_file)
        local chunk = buffer.create(65536)
        local scratch = buffer.create(65536)
        local fed = 0
        local produced = 0
        local closed = false
        local need_more = false
        while true do
            local moved = false
            if fed < count and (packed.offset == packed.len or need_more) then
                local want = math.min(65536, count - fed)
                local got, err = reader:read(chunk, 0, want)
                if err or got ~= want then
                    error("zip size mismatch", 0)
                end
                local appended, append_err = packed:append(chunk, 0, got)
                if append_err or appended ~= got then
                    error("zip size mismatch", 0)
                end
                fed += got
                need_more = false
                moved = true
            end
            local n, read_err = stream:read(scratch)
            if read_err then
                error("zip size mismatch", 0)
            end
            if n > 0 then
                if produced + n > size then
                    error("zip size mismatch", 0)
                end
                local failed = writer:writeAll(scratch, 0, n)
                if failed then
                    error("write failed", 0)
                end
                produced += n
                moved = true
            end
            if n == 0 and produced == size and closed then
                return
            end
            if n == 0 and fed == count and not closed then
                local ok = pcall(function()
                    stream:finish()
                end)
                if not ok then
                    error("zip size mismatch", 0)
                end
                closed = true
                moved = true
            elseif n == 0 and fed < count then
                need_more = true
                moved = true
            end
            if not moved then
                error("zip size mismatch", 0)
            end
        end
    end)
end

local function gunzipFile(file: File, count: number, out: string)
    local parent = fs.path.dirname(out)
    if parent and parent ~= "" then
        pcall(function()
            io.cwd():createDirPath(parent)
        end)
    end
    local dest_file = io.cwd():createFile(out, { truncate = true })
    local copied, err = pcall(function()
        local stream = serde.gzip.createDecompressor(zune.io.createBufferArray())
        local packed = stream.array
        local reader = io.createPosReader(file, 0)
        local writer = io.createPosWriter(dest_file)
        local chunk = buffer.create(65536)
        local scratch = buffer.create(65536)
        local amt = 0
        local closed = false
        local need_more = false
        while true do
            local moved = false
            if amt < count and (packed.offset == packed.len or need_more) then
                local want = math.min(65536, count - amt)
                local got, err = reader:read(chunk, 0, want)
                if err or got ~= want then
                    error("short read", 0)
                end
                local appended, append_err = packed:append(chunk, 0, got)
                if append_err or appended ~= got then
                    error("bad gzip", 0)
                end
                amt += got
                need_more = false
                moved = true
            end
            local n, read_err = stream:read(scratch)
            if read_err then
                error("bad gzip", 0)
            end
            if n > 0 then
                local failed = writer:writeAll(scratch, 0, n)
                if failed then
                    error("write failed", 0)
                end
                moved = true
            end
            if n == 0 and closed then
                return
            end
            if n == 0 and amt == count and not closed then
                local ok = pcall(function()
                    stream:finish()
                end)
                if not ok then
                    error("bad gzip", 0)
                end
                closed = true
                moved = true
            elseif n == 0 and amt < count then
                need_more = true
                moved = true
            end
            if not moved then
                error("bad gzip", 0)
            end
        end
    end)
    dest_file:close()
    if not copied then
        pcall(function()
            io.cwd():deleteFile(out)
        end)
        error(tostring(err), 0)
    end
end

local function unpackTarFile(file: File, size: number, dest: string, opts: UnpackOptions): number
    local list = tar.spans(function(offset: number, buf: buffer, count: number)
        if count == 0 then
            return
        end
        local got, err = file:readPositional(offset, buf, 0, count)
        if err or got ~= count then
            error("short read", 0)
        end
    end, size)
    local paths: { string } = {}
    local total = 0
    for _, span in list do
        if span.kind == "file" then
            total += span.size
            table.insert(paths, memberName(span.path))
        end
    end
    guardSize(total, opts)
    pcall(function()
        io.cwd():createDirPath(dest)
    end)
    local strip = wrapper(paths)
    local matched = 0
    for _, span in list do
        local path = relative(span.path, strip)
        if span.kind == "dir" or path == "" or not listed(path, opts.paths) then
            continue
        end
        if path == "." or path == ".." or fs.path.isAbsolute(path) or mem.startsWith(path, "../") then
            error("archive path escapes", 0)
        end
        matched += 1
        copyMember(file, span.at, span.size, fs.path.join(dest, path))
    end
    if not opts.quiet and opts.paths ~= nil and #opts.paths > 0 and matched == 0 then
        error("paths matched nothing", 0)
    end
    return matched
end

local function unpackZipFile(file: File, size: number, dest: string, opts: UnpackOptions): number
    local list = zip.spans(function(offset: number, buf: buffer, count: number)
        if count == 0 then
            return
        end
        local got, err = file:readPositional(offset, buf, 0, count)
        if err or got ~= count then
            error("short read", 0)
        end
    end, size)
    local paths: { string } = {}
    local total = 0
    for _, span in list do
        if span.kind == "file" then
            total += span.size
            table.insert(paths, memberName(span.path))
        end
    end
    guardSize(total, opts)
    pcall(function()
        io.cwd():createDirPath(dest)
    end)
    local strip = wrapper(paths)
    local matched = 0
    for _, span in list do
        local path = relative(span.path, strip)
        if span.kind == "dir" or path == "" or not listed(path, opts.paths) then
            continue
        end
        if path == "." or path == ".." or fs.path.isAbsolute(path) or mem.startsWith(path, "../") then
            error("archive path escapes", 0)
        end
        matched += 1
        local out = fs.path.join(dest, path)
        if span.method == 0 then
            copyMember(file, span.at, span.count, out)
        elseif span.method == 8 then
            copyDeflated(file, span.at, span.count, span.size, out)
        else
            error("unsupported zip method", 0)
        end
    end
    if not opts.quiet and opts.paths ~= nil and #opts.paths > 0 and matched == 0 then
        error("paths matched nothing", 0)
    end
    return matched
end

function archive.unpackFile(path: string, dest: string, options: UnpackOptions?): number
    local opts = options or {} :: UnpackOptions
    local file = io.cwd():openFile(path, { mode = "r" })
    local size = file:size()
    local magic = buffer.create(4)
    if size >= 2 then
        local got, err = file:readPositional(0, magic, 0, math.min(4, size))
        if err or got < 2 then
            file:close()
            error("short read", 0)
        end
    end
    local gzip = size >= 2 and buffer.readu8(magic, 0) == 0x1f and buffer.readu8(magic, 1) == 0x8b
    local is_zip = size >= 4 and buffer.readu8(magic, 0) == 0x50 and buffer.readu8(magic, 1) == 0x4b
    if gzip then
        local plain = `{dest}.plain.tar`
        local inflated, inflate_err = pcall(gunzipFile, file, size, plain)
        file:close()
        if not inflated then
            pcall(function()
                io.cwd():deleteFile(plain)
            end)
            error(tostring(inflate_err), 0)
        end
        local plain_file = io.cwd():openFile(plain, { mode = "r" })
        local ok, result = pcall(unpackTarFile, plain_file, plain_file:size(), dest, opts)
        plain_file:close()
        pcall(function()
            io.cwd():deleteFile(plain)
        end)
        if not ok then
            error(tostring(result), 0)
        end
        return result
    end
    local ok, result = pcall(if is_zip then unpackZipFile else unpackTarFile, file, size, dest, opts)
    file:close()
    if not ok then
        error(tostring(result), 0)
    end
    return result
end

return archive
