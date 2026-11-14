--!strict
--- @description Run tests in lua/luau file, similar to run.

local process = zune.process

_G.cmdForward({ "run", unpack(process.args, 2) })
