const std = @import("std");
const luau = @import("luau");
const pcre2 = @import("regex");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Regex = Zune.objects.Regex;

pub const LIB_NAME = "regex";

pub fn lua_create(L: *VM.lua.State) !i32 {
    const flags = L.tolstring(2) orelse "";

    if (flags.len > 2)
        return L.Zerror("too many flags provided");

    var flag: u32 = 0;
    for (flags) |f| switch (f) {
        'i' => flag |= pcre2.Options.CASELESS,
        'm' => flag |= pcre2.Options.MULTILINE,
        'u' => flag |= pcre2.Options.UTF,
        else => return L.Zerrorf("unknown flag: {c}", .{f}),
    };

    var pos: usize = 0;
    const r = try pcre2.compile(try L.Zcheckvalue([]const u8, 1, null), flag, &pos);
    _ = try Regex.create(L, r);
    return 1;
}
