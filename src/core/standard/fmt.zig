const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Fmt = Zune.Resolvers.Fmt;

const mem = @import("./mem.zig");

const VM = luau.VM;

pub const LIB_NAME = "fmt";

pub const lua_format = Fmt.args;

pub fn lua_useColors(L: *VM.lua.State) i32 {
    L.pushboolean(Zune.Runtime.Debug.useColors());
    return 1;
}
