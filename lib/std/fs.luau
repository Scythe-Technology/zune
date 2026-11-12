--!strict
--!optimize 2

local io = require("./io")

local fs = setmetatable({}, { __index = zune.fs })

function fs.readFile(path: string): string
    local file = io.cwd():openFile(path, { mode = "r" })
    local reader = io.createReader(file, { positional = true })
    local buf = reader:readRemainingAlloc()
    file:close()
    return buffer.tostring(buf)
end

function fs.readFileBytes(path: string): buffer
    local file = io.cwd():openFile(path, { mode = "r" })
    local reader = io.createReader(file, { positional = true })
    local buf = reader:readRemainingAlloc()
    file:close()
    return buf
end

function fs.writeFile(path: string, content: string | buffer)
    local file = io.cwd():createFile(path, {
        truncate = true,
        nonblocking = true,
    })
    local writer = io.createWriter(file, { positional = true })
    writer:writeAll(content)
    file:close()
end

function fs.entries(path: string): { DirectoryEntry }
    local dir = io.cwd():openDir(path, { iterate = true })
    local entries = dir:entries()
    dir:close()
    return entries
end

type SafeDescriptorStat =
    | {
        kind: "none",
    }
    | {
        kind: DescriptorKind,
        mode: number,
        block_size: number,
        changed_at: number,
        modified_at: number,
        accessed_at: number,
        size: number,
    }

function fs.statFile(dir: Dir, path: string): SafeDescriptorStat
    local ok, result = pcall(function()
        return dir:statFile(path, { follow_symlinks = true })
    end)
    if not ok then
        if (result :: any) == "FileNotFound" or (result :: any) == "NotDir" then
            return { kind = "none" }
        end
        error(result)
    end
    return result
end

function fs.stat(path: string)
    return fs.statFile(io.cwd(), path)
end

function fs.realPathFileAlloc(dir: Dir, path: string)
    local b = buffer.create(fs.path.max_path_bytes)
    local amt = dir:realPathFile(path, b)
    return buffer.readstring(b, 0, amt)
end

function fs.realPathAlloc(fd: Dir | File)
    local b = buffer.create(fs.path.max_path_bytes)
    local amt = fd:realPath(b)
    return buffer.readstring(b, 0, amt)
end

@deprecated
function fs.realPath(path: string)
    return fs.realPathFileAlloc(io.cwd(), path)
end

type CreateFileOptions = {
    read: boolean?,
    exclusive: boolean?,
    truncate: boolean?,
    mode: number?,
}
function fs.createFile(path: string, opts: CreateFileOptions?)
    local options = opts or {} :: CreateFileOptions
    local create_opts: { [string]: any } = {
        read = if options.read == nil then true else options.read,
        exclusive = options.exclusive == true,
        truncate = if options.truncate == nil then true else options.truncate,
    }
    if options.mode ~= nil then
        create_opts.permissions = options.mode
    end
    return io.cwd():createFile(path, create_opts)
end

type OpenFileOptions = {
    mode: string?,
}
function fs.openFile(path: string, opts: OpenFileOptions?)
    local options = opts or {} :: OpenFileOptions
    return io.cwd():openFile(path, {
        mode = options.mode,
    })
end

function fs.deleteFile(path: string)
    io.cwd():deleteFile(path)
end

function fs.makeDir(path: string, recursive: boolean?)
    if recursive then
        io.cwd():createDirPath(path)
    else
        io.cwd():createDir(path)
    end
end

function fs.deleteDir(path: string, recursive: boolean?)
    if recursive then
        io.cwd():deleteTree(path)
    else
        io.cwd():deleteDir(path)
    end
end

function fs.move(src: string, dest: string, overwrite: boolean?)
    local dir = io.cwd()
    if overwrite then
        dir:rename(src, dir, dest)
    else
        dir:renamePreserve(src, dir, dest)
    end
end

local function copyDirectory(src_dir: any, src: string, dest_dir: any, dest: string, overwrite: boolean?)
    for _, entry in src_dir:entries(src) do
        if entry.kind == "directory" then
            local sub_src_dir = src_dir:openDir(entry.name, {
                iterate = true,
            })
            if fs.statFile(dest_dir, entry.name).kind ~= "directory" then
                dest_dir:createDir(entry.name)
            else
                if not overwrite then
                    sub_src_dir:close()
                    error("PathAlreadyExists", 0)
                end
            end
            local sub_dest_dir = dest_dir:openDir(entry.name)
            copyDirectory(sub_src_dir, entry.name, sub_dest_dir, entry.name, overwrite)
        else
            src_dir:copyFile(entry.name, dest_dir, entry.name, {
                replace = overwrite,
            })
        end
    end
end

function fs.copy(src: string, dest: string, overwrite: boolean?)
    local dir = io.cwd()
    local stat = fs.statFile(dir, src)
    if stat.kind == "directory" then
        local source_dir = dir:openDir(src, {
            iterate = true,
        })
        if fs.statFile(dir, dest).kind ~= "directory" then
            dir:createDir(dest)
        else
            if not overwrite then
                source_dir:close()
                error("PathAlreadyExists", 0)
            end
        end
        local target_dir = dir:openDir(dest)
        copyDirectory(source_dir, src, target_dir, dest, overwrite)
        return
    end
    dir:copyFile(src, dir, dest, {
        replace = overwrite,
        make_path = true,
    })
end

function fs.symlink(target: string, link: string)
    local dir = io.cwd()
    local absolute = fs.realPathFileAlloc(dir, target)
    dir:symLink(absolute, link, {
        is_directory = fs.statFile(dir, target).kind == "directory",
    })
end

return fs
