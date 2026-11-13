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

pub fn lua_setEnabled(L: *VM.lua.State) i32 {
    Zune.State.options.format.enabled = L.toboolean(1);
    return 0;
}

pub fn lua_setIndent(L: *VM.lua.State) !i32 {
    Zune.State.options.format.indent = @fromBackingInt(@truncate(try L.Zcheckvalue(u8, 1, null)));
    return 0;
}

pub fn lua_setMaxDepth(L: *VM.lua.State) !i32 {
    Zune.State.options.format.max_depth = try L.Zcheckvalue(u8, 1, null);
    return 0;
}

pub fn lua_setUseColor(L: *VM.lua.State) i32 {
    Zune.State.options.format.use_color = L.toboolean(1);
    return 0;
}

pub fn lua_setTableAddress(L: *VM.lua.State) i32 {
    Zune.State.options.format.table_address = L.toboolean(1);
    return 0;
}

pub fn lua_setRecursiveTable(L: *VM.lua.State) i32 {
    Zune.State.options.format.recursive_table = L.toboolean(1);
    return 0;
}

pub fn lua_setBufferMaxDisplay(L: *VM.lua.State) !i32 {
    Zune.State.options.format.buffer_max_display = try L.Zcheckvalue(u15, 1, null);
    return 0;
}
