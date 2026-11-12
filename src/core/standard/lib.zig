const std = @import("std");
const luau = @import("luau");
const Zune = @import("zune");

const VM = luau.VM;

const Scripting = Zune.Runtime.Scripting;

pub const libraries = struct {
    // native libraries
    pub const io = @import("io/lib.zig");
    pub const mem = @import("mem.zig");
    pub const fmt = @import("fmt.zig");
    pub const luau = @import("luau.zig");
    pub const task = @import("task.zig");
    pub const debug = @import("debug.zig");
    pub const ascii = @import("ascii.zig");
    pub const serde = @import("serde/lib.zig");
    pub const regex = @import("regex.zig");
    pub const config = @import("config.zig");
    pub const crypto = @import("crypto/lib.zig");
    pub const random = @import("random.zig");
    pub const require = @import("require.zig");
    pub const testing = @import("testing.zig");
    pub const process = @import("process.zig");
    pub const platform = @import("platform/lib.zig");

    // platform specific libraries
    pub const fs = @import("fs/lib.zig");
    pub const c = @import("c.zig");
    pub const gpio = @import("gpio.zig");
    pub const net = @import("net/lib.zig");
    pub const time = @import("time/lib.zig");
    pub const thread = @import("thread/lib.zig");

    test {
        _ = @This().fs;
        _ = @This().process;
        _ = @This().testing;
        _ = @This().task;
        _ = @This().net;
        _ = @This().luau;
        _ = @This().serde;
        _ = @This().io;
        _ = @This().crypto;
        _ = @This().regex;
        _ = @This().time;
        _ = @This().c;
        _ = @This().require;
        _ = @This().random;
        _ = @This().thread;
        _ = @This().mem;
        _ = @This().platform;
        _ = @This().debug;
        _ = @This().fmt;
        _ = @This().gpio;
        _ = @This().ascii;
    }
};

pub fn ResolveNamespace(comptime namespace: type, L: *VM.lua.State, comptime forced: bool) !void {
    const type_info = @typeInfo(namespace);

    std.debug.assert(type_info == .@"struct");

    if (@hasDecl(namespace, "__setup")) {
        try @call(.always_inline, @field(namespace, "__setup"), .{L});
    }

    comptime if (Zune.info.api_dump) {
        if (@hasDecl(namespace, "LIB_NAME"))
            @compileLog("[LIBRARY] ==== " ++ @field(namespace, "LIB_NAME") ++ " ====")
        else {
            const short_name = @typeName(namespace)[(std.mem.findScalarLast(u8, @typeName(namespace), '.') orelse 0) + 1 ..];
            @compileLog("[NAMEPSACE] ==== " ++ short_name ++ " ====");
        }
    };

    comptime var decl_count: comptime_int = if (forced) type_info.@"struct".decl_names.len else 0;
    comptime if (!forced) {
        for (type_info.@"struct".decl_names) |decl| {
            if (std.mem.startsWith(u8, decl, "lua_")) {
                decl_count += 1;
            }
        }
    };
    try L.createtable(0, decl_count);
    inline for (type_info.@"struct".decl_names) |decl| {
        if (comptime forced) {
            const decl_type_info = @typeInfo(@TypeOf(@field(namespace, decl)));
            if (comptime decl_type_info == .type) {
                comptime if (Zune.info.api_dump) @compileLog("  [+NAMESPACE] " ++ decl);
                try ResolveNamespace(@field(namespace, decl), L, forced);
                try L.rawsetfield(-2, decl);
            } else if (comptime decl_type_info == .@"fn") {
                comptime if (Zune.info.api_dump) @compileLog("  [+FUNCTION] " ++ decl);
                try L.Zsetfieldfn(decl, Scripting.toCFn(@field(namespace, decl)));
            } else {
                comptime if (Zune.info.api_dump) @compileLog("  [+CONSTANT] " ++ decl);
                try L.Zsetfield(decl, @field(namespace, decl));
            }
        } else if (comptime std.mem.startsWith(u8, decl, "lua_")) {
            const force = comptime std.mem.startsWith(u8, decl, "lua_forced_");
            const custom = comptime std.mem.startsWith(u8, decl, "lua_custom_");
            const name: [:0]const u8 = comptime decl[(if (force) 11 else if (custom) 11 else 4).. :0];
            const decl_type_info = @typeInfo(@TypeOf(@field(namespace, decl)));
            if (comptime decl_type_info == .type) {
                comptime if (Zune.info.api_dump) @compileLog("  [NAMESPACE] " ++ name);
                try ResolveNamespace(@field(namespace, decl), L, force);
                try L.rawsetfield(-2, name);
            } else if (comptime decl_type_info == .@"fn") {
                if (comptime custom) {
                    comptime if (Zune.info.api_dump) @compileLog("  [FN RESOLVED] " ++ name);
                    try @call(.always_inline, @field(namespace, decl), .{L});
                    try L.rawsetfield(-2, name);
                } else {
                    comptime if (Zune.info.api_dump) @compileLog("  [FUNCTION] " ++ name);
                    try L.Zsetfieldfn(name, Scripting.toCFn(@field(namespace, decl)));
                }
            } else {
                comptime if (Zune.info.api_dump) @compileLog("  [CONSTANT] " ++ name);
                try L.Zsetfield(name, @field(namespace, decl));
            }
        }
    }
    try L.setreadonly(-1, true);
}

pub fn ResolveObject(comptime object: type, L: *VM.lua.State) !void {
    const type_info = @typeInfo(object);

    std.debug.assert(type_info == .@"struct");

    const TAG: comptime_int = @field(object, "OBJECT_TAG");

    comptime var decl_count: comptime_int = 0;
    comptime {
        for (type_info.@"struct".decl_names) |decl| {
            if (std.mem.startsWith(u8, decl, "lua_")) {
                if (std.mem.eql(u8, decl[4..], "__dtor"))
                    continue;
                decl_count += 1;
            }
        }
    }

    if (@hasDecl(object, "__setup")) {
        try @call(.always_inline, @field(object, "__setup"), .{L});
    }

    const short_name = comptime @typeName(object)[(std.mem.findScalarLast(u8, @typeName(object), '.') orelse 0) + 1 ..];

    comptime if (Zune.info.api_dump) @compileLog("[CLASS] ==== " ++ short_name ++ " ====");

    _ = try L.Znewmetatable(@typeName(object), .{
        .__metatable = "Metatable is locked",
        .__type = short_name,
    });
    try L.createtable(0, decl_count);
    inline for (type_info.@"struct".decl_names) |decl| {
        if (comptime std.mem.startsWith(u8, decl, "lua_") and !std.mem.startsWith(u8, decl, "lua_direct_")) {
            const name: [:0]const u8 = comptime decl[4.. :0];
            comptime if (Zune.info.api_dump) @compileLog("  [METHOD] " ++ name);
            try L.pushcfunction(Scripting.toCFn(struct {
                fn inner(l: *VM.lua.State) !i32 {
                    const ptr = l.touserdatatagged(object, 1, TAG) orelse
                        return l.Zerror("expected ':' calling member function " ++ name);
                    return @call(.always_inline, @field(object, decl), .{ ptr, l });
                }
            }.inner), name);
            try L.rawsetfield(-2, name);
        }
    }
    try L.setreadonly(-1, true);
    try L.rawsetfield(-2, "__index");
    if (@hasDecl(object, "__tostring")) {
        try L.pushcfunction(Scripting.toCFn(@field(object, "__tostring")), "__tostring");
        try L.rawsetfield(-2, "__tostring");
    }
    try L.setreadonly(-1, true);
    L.setuserdatametatable(TAG);
    if (@hasDecl(object, "__dtor")) {
        L.setuserdatadtor(object, TAG, @field(object, "__dtor"));
    }
    inline for (type_info.@"struct".decl_names) |decl| {
        if (comptime std.mem.startsWith(u8, decl, "lua_direct_")) {
            const name: [:0]const u8 = comptime decl[11.. :0];
            comptime if (Zune.info.api_dump) @compileLog("  [DIRECT FIELD] " ++ name);
            try L.registeruserdatadirectfieldget(object, TAG, name, @field(object, decl));
        }
    }
}

pub fn loadLibrary(comptime namespace: type, L: *VM.lua.State) !void {
    // _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    try ResolveNamespace(namespace, L, false);
    try L.rawsetfield(-2, @field(namespace, "LIB_NAME"));
    // L.pop(1);
}

test {
    _ = libraries;
}
