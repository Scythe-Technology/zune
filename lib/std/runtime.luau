--!strict
--!optimize 2

local process = zune.process

local fs = require("@zune/fs")

local runtime = {}

function runtime.getStdPath(): string
    local exe_dir = fs.path.dirname(process.getExePath())
    if not exe_dir then
        error("runtime path is missing", 0)
    end
    return fs.path.join(exe_dir, "lib", "std")
end

function runtime.getStd(): string?
    local exe_dir = fs.path.dirname(process.getExePath())
    if not exe_dir then
        return nil
    end
    local path = fs.path.join(exe_dir, "lib", "std")
    if fs.stat(path).kind ~= "directory" then
        return nil
    end
    return path
end

return runtime
