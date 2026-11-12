--!strict
local process = zune.process

_G.cmdForward({ "eval", unpack(process.args, 2) })
