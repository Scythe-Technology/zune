const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Runtime = Zune.Runtime;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Fmt = Zune.Resolvers.Fmt;

const VM = luau.VM;

pub const LIB_NAME = "debug";

pub fn lua_dumpStacktrace(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
    const level = try L.Zcheckvalue(i32, 1, null);
    const limit = try L.Zcheckvalue(?u32, 2, null);

    if (level < 0)
        return L.Zerror("invalid stack level");
    if (limit) |l|
        if (l == 0) {
            try L.pushlstring("");
            return 1;
        };

    var list: std.ArrayList(Runtime.Debug.StackInfo) = try Runtime.Debug.getStackTrace(L, allocator, level, limit);
    defer list.deinit(allocator);
    defer Runtime.Debug.freeStackTrace(allocator, list.items);

    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer allocating.deinit();

    try Runtime.Debug.dumpStackTrace(&allocating.writer, list.items, .first);

    try L.pushlstring(allocating.written());

    return 1;
}
