const std = @import("std");
const luau = @import("luau");
const toml = @import("toml");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Commands = @import("../../commands/lib.zig");

const VM = luau.VM;

const Dir = Zune.objects.Dir;

pub const LIB_NAME = "config";

pub fn pushFromConfiguration(comptime T: type, value: *T, L: *VM.lua.State) !void {
    const ti = @typeInfo(T);
    std.debug.assert(ti == .@"struct");
    try L.createtable(0, ti.@"struct".field_names.len);
    inline for (ti.@"struct".field_names, ti.@"struct".field_types) |field_name, field_type| {
        const field_ti = @typeInfo(field_type);
        switch (field_ti) {
            .@"struct" => if (field_type == Zune.ZuneState.Options.StringMap) {
                try L.createtable(0, @field(value, field_name).size);
                var iter = @field(value, field_name).iterator();
                while (iter.next()) |entry| {
                    try L.pushlstring(entry.value_ptr.*);
                    try L.rawsetfield(-2, entry.key_ptr.*);
                }
            } else try pushFromConfiguration(field_type, &@field(value, field_name), L),
            .int => |int| if (int.signedness == .unsigned)
                L.pushunsigned(@truncate(@field(value, field_name)))
            else
                L.pushinteger(@truncate(@field(value, field_name))),
            .bool => L.pushboolean(@field(value, field_name)),
            .optional => |opt| {
                switch (@typeInfo(opt.child)) {
                    .pointer => |ptr| {
                        comptime std.debug.assert(ptr.size == .slice);
                        comptime std.debug.assert(ptr.child == u8);
                        if (@field(value, field_name)) |str| {
                            try L.pushlstring(str);
                        } else {
                            L.pushnil();
                        }
                    },
                    else => |e| @compileError("unsupported type: " ++ @tagName(e)),
                }
            },
            else => @compileError("unsupported type: " ++ @tagName(field_ti)),
        }
        try L.rawsetfield(-2, field_name);
    }
}

pub fn lua_get(L: *VM.lua.State) !i32 {
    if (!try L.checkstack(4))
        return L.Zerror("stack overflow");

    try pushFromConfiguration(Zune.ZuneState.Options, &Zune.State.options, L);

    return 1;
}

pub fn lua_loadFromFile(L: *VM.lua.State) !i32 {
    if (!Commands.isAllowed(L)) return L.Zerror("API can only be used in command context");

    const dir = Dir.to(L, 1) orelse return L.Zerror("expected directory");
    const file = try L.Zcheckvalue([]const u8, 2, null);

    const allocator = Scheduler.fromState(L).allocator();

    const config_content = try dir.dir.readFileAlloc(Zune.io(), file, allocator, .unlimited);
    defer allocator.free(config_content);

    var zune_config = try toml.parse(allocator, config_content);
    defer zune_config.deinit(allocator);

    Zune.loadConfigurationFromToml(Zune.ZuneState.Options, &Zune.State.options, allocator, zune_config);

    return 0;
}

pub fn lua_loadFromToml(L: *VM.lua.State) !i32 {
    if (!Commands.isAllowed(L)) return L.Zerror("API can only be used in command context");

    const src = try L.Zcheckvalue([]const u8, 1, null);

    const allocator = Scheduler.fromState(L).allocator();

    var zune_config = try toml.parse(allocator, src);
    defer zune_config.deinit(allocator);

    Zune.loadConfigurationFromToml(Zune.ZuneState.Options, &Zune.State.options, allocator, zune_config);

    return 0;
}

pub fn lua_getFromFile(L: *VM.lua.State) !i32 {
    if (!Commands.isAllowed(L)) return L.Zerror("API can only be used in command context");

    const dir = Dir.to(L, 1) orelse return L.Zerror("expected directory");
    const file = try L.Zcheckvalue([]const u8, 2, null);

    const allocator = Scheduler.fromState(L).allocator();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var opts: Zune.ZuneState.Options = .{};

    blk: {
        const config_content = dir.dir.readFileAlloc(Zune.io(), file, arena_allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => break :blk,
            else => break :blk,
        };
        defer arena_allocator.free(config_content);

        var zune_config = toml.parse(arena_allocator, config_content) catch break :blk;
        defer zune_config.deinit(arena_allocator);

        Zune.loadConfigurationFromToml(Zune.ZuneState.Options, &opts, arena_allocator, zune_config);
    }

    try pushFromConfiguration(Zune.ZuneState.Options, &opts, L);

    return 1;
}

pub fn lua_getFromToml(L: *VM.lua.State) !i32 {
    if (!Commands.isAllowed(L)) return L.Zerror("API can only be used in command context");

    const src = try L.Zcheckvalue([]const u8, 1, null);
    const allocator = Scheduler.fromState(L).allocator();

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var opts: Zune.ZuneState.Options = .{};

    blk: {
        var zune_config = toml.parse(arena_allocator, src) catch break :blk;
        defer zune_config.deinit(arena_allocator);

        Zune.loadConfigurationFromToml(Zune.ZuneState.Options, &opts, arena_allocator, zune_config);
    }

    try pushFromConfiguration(Zune.ZuneState.Options, &opts, L);

    return 1;
}
