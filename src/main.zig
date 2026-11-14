const zio = @import("zio");
const std = @import("std");
const luau = @import("luau");
const json = @import("json");
const toml = @import("toml");
const builtin = @import("builtin");

pub const cli = @import("cli.zig");

pub const standard = @import("core/standard/lib.zig");
pub const objects = @import("core/objects/lib.zig");

var DEBUG_ALLOCATOR = switch (builtin.mode) {
    .Debug => std.heap.SafeAllocator.init(std.heap.c_allocator, .{
        .stack_trace_frames = 12,
    }),
    else => @as(void, undefined),
};
pub const DEFAULT_ALLOCATOR = switch (builtin.mode) {
    .Debug => DEBUG_ALLOCATOR.allocator(),
    else => std.heap.c_allocator,
};

const ThreadedIo = struct {
    var backend: std.Io.Threaded = .init_single_threaded;
};

pub fn io() std.Io {
    return ThreadedIo.backend.io();
}

pub const options: std.Options = .{
    .enable_segfault_handler = builtin.mode == .debug,
};

pub const Runtime = @import("core/runtime/lib.zig");
pub const Resolvers = @import("core/resolvers/lib.zig");

pub const Utils = struct {
    pub const Lists = @import("core/utils/lists.zig");
    test {
        _ = Lists;
    }
};

pub const debug = struct {
    pub const print = Runtime.Debug.print;
    pub const writerPrint = Runtime.Debug.writerPrint;
    pub const useColors = Runtime.Debug.useColors;
};

pub const Tags = @import("tagged.zig").Tags;
pub const info = @import("zune-info");

const VM = luau.VM;

pub const Flags = struct {
    limbo: bool = false,
};

pub const PlatformSupportKind = enum {
    Full,
    Limited,
};

pub const VERSION_STR = std.fmt.comptimePrint("{d}.{d}.{d}{s}", .{
    info.version.major,
    info.version.minor,
    info.version.patch,
    if (info.commit_hash) |hash|
        std.fmt.comptimePrint("-dev.{s}", .{hash[0..7]})
    else
        "",
});

pub const VERSION_FULL_STR = std.fmt.comptimePrint("{s}+{d}.{d}", .{
    VERSION_STR,
    luau.LUAU_VERSION.major,
    luau.LUAU_VERSION.minor,
});

pub const ZuneState = struct {
    env_map: std.process.Environ.Map = .init(.failing),
    main_thread_id: ?std.Thread.Id = null,
    bundle: ?Resolvers.Bundle.Map = null,
    bin_arg: [:0]const u8 = &.{},
    args: []const [:0]const u8 = &[_][:0]const u8{},
    options: Options = .{},

    pub const Options = struct {
        workspace: Workspace = .{},
        runtime: @This().Runtime = .{},
        format: Format = .{},

        pub const StringMap = std.hash_map.StringHashMapUnmanaged([]const u8);

        pub const Workspace = struct {
            run_path: ?[]const u8 = null,
            scripts: StringMap = .empty,

            pub fn cwd(value: []const u8) void {
                if (comptime builtin.target.os.tag != .wasi) {
                    const dir = std.Io.Dir.cwd().openDir(io(), value, .{}) catch |err| {
                        quitMsg("<red>configuration error:<clear> failed to open cwd <underline>{s}<clear>: {}\n", .{ value, err });
                    };
                    std.process.setCurrentDir(io(), dir) catch |err| {
                        quitMsg("<red>configuration error:<clear> failed to set cwd to <underline>{s}<clear>: {}\n", .{ value, err });
                    };
                }
            }
        };
        pub const Runtime = struct {
            use_detailed_error: bool = true,
            features: Features = .{},
            luau: Luau = .{},

            pub const Features = struct {
                io: bool = true,
                mem: bool = true,
                fmt: bool = true,
                luau: bool = true,
                task: bool = true,
                debug: bool = true,
                ascii: bool = true,
                serde: bool = true,
                regex: bool = true,
                config: bool = true,
                crypto: bool = true,
                random: bool = true,
                require: bool = true,
                testing: bool = true,
                process: bool = true,
                platform: bool = true,
                fs: bool = true,
                c: bool = true,
                gpio: bool = true,
                net: bool = true,
                time: bool = true,
                thread: bool = true,
            };

            pub const Luau = struct {
                debug_level: u2 = 2,
                optimization_level: u2 = 1,
                coverage_level: u2 = 0,
                default_ncg: bool = true,
                jit_enabled: bool = true,

                pub fn fflags(value: toml.Table) void {
                    var iter = value.table.iterator();
                    while (iter.next()) |entry| {
                        switch (entry.value_ptr.*) {
                            .boolean => luau.FFlags.SetByName(bool, entry.key_ptr.*, entry.value_ptr.*.boolean) catch |err| switch (err) {
                                error.UnknownFlag => debug.print("<blue>configuration warning:<clear> unknown fflag \"{s}\"\n", .{entry.key_ptr.*}),
                            },
                            .integer => luau.FFlags.SetByName(i32, entry.key_ptr.*, @truncate(entry.value_ptr.*.integer)) catch |err| switch (err) {
                                error.UnknownFlag => debug.print("<blue>configuration warning:<clear> unknown fflag \"{s}\"\n", .{entry.key_ptr.*}),
                            },
                            else => |t| debug.print("<blue>configuration warning:<clear> unsupported {s} type for fflag \"{s}\"\n", .{ @tagName(t), entry.key_ptr.* }),
                        }
                    }
                }
            };
        };
        pub const Format = struct {
            enabled: bool = true,
            indent: Resolvers.Fmt.Indent = .FourSpaces,
            max_depth: u8 = 4,
            use_color: bool = true,
            table_address: bool = true,
            recursive_table: bool = false,
            buffer_max_display: u15 = 48,
        };
    };
};

pub var State: ZuneState = .{};

pub fn init(environ: std.process.Environ) !void {
    const allocator = DEFAULT_ALLOCATOR;

    ThreadedIo.backend = .init(DEFAULT_ALLOCATOR, .{});

    State.env_map = try environ.createMap(allocator);

    if (!options.enable_segfault_handler) {
        @import("./core/runtime/crash.zig").init();
    }

    standard.libraries.io.terminal.init(std.Io.File.stdin(), std.Io.File.stdout(), std.Io.File.stderr());
    standard.libraries.io.terminal.setOutputMode() catch debug.print("<blue>setup error<clear> failed to set output codepoint\n", .{});
}

pub fn loadConfigurationFromToml(comptime T: type, target: *T, allocator: std.mem.Allocator, table: toml.Table) void {
    const ti = @typeInfo(T);
    std.debug.assert(ti == .@"struct");
    inline for (ti.@"struct".field_names, ti.@"struct".field_types) |field_name, field_type| {
        const field_ti = @typeInfo(field_type);
        switch (field_ti) {
            .@"struct" => if (table.contains(field_name)) {
                const item = table.table.get(field_name) orelse unreachable;
                if (item != .table)
                    quitMsg("<red>configuration error:<clear> '{s}' must be a table\n", .{field_name});
                if (field_type == ZuneState.Options.StringMap) {
                    var iter = item.table.table.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const value = entry.value_ptr.*;
                        if (value != .string)
                            quitMsg("<red>configuration error:<clear> '{s}.{s}' must be a string\n", .{ field_name, key });
                        const string_value = value.string;
                        if (string_value.len == 0)
                            quitMsg("<red>configuration error:<clear> '{s}.{s}' cannot be empty\n", .{ field_name, key });
                        if (std.mem.indexOfNone(u8, key, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+#&$!@")) |_|
                            quitMsg("<red>configuration error:<clear> '{s}.{s}' contains invalid characters\n", .{ field_name, key });
                        if (@field(target, field_name).contains(key))
                            quitMsg("<red>configuration error:<clear> duplicate key '{s}' found\n", .{key});
                        const key_copy = DEFAULT_ALLOCATOR.dupe(u8, key) catch |err| quitMsg("{}\n", .{err});
                        const value_copy = DEFAULT_ALLOCATOR.dupe(u8, string_value) catch |err| quitMsg("{}\n", .{err});
                        @field(target, field_name).put(allocator, key_copy, value_copy) catch |err| quitMsg("{}\n", .{err});
                    }
                } else loadConfigurationFromToml(field_type, &@field(target, field_name), allocator, item.table);
            },
            .int => |int| if (table.contains(field_name)) {
                const item = table.table.get(field_name) orelse unreachable;
                if (item != .integer)
                    quitMsg("<red>configuration error:<clear> '{s}' must be an integer\n", .{field_name});
                if (int.signedness == .unsigned) switch (int.bits) {
                    2 => @field(target, field_name) = @truncate(@min(2, @as(u64, @bitCast(item.integer)))),
                    else => @field(target, field_name) = @truncate(@as(u64, @bitCast(item.integer))),
                } else @field(target, field_name) = @truncate(item.integer);
            },
            .bool => if (table.contains(field_name)) {
                const item = table.table.get(field_name) orelse unreachable;
                if (item != .boolean)
                    quitMsg("<red>configuration error:<clear> '{s}' must be a boolean\n", .{field_name});
                @field(target, field_name) = item.boolean;
            },
            .optional => |opt| {
                switch (@typeInfo(opt.child)) {
                    .pointer => |ptr| if (table.contains(field_name)) {
                        comptime std.debug.assert(ptr.size == .slice);
                        comptime std.debug.assert(ptr.child == u8);
                        const item = table.table.get(field_name) orelse unreachable;
                        if (item != .string)
                            quitMsg("<red>configuration error:<clear> '{s}' must be a string\n", .{field_name});
                        if (@field(target, field_name)) |existing|
                            allocator.free(existing);
                        @field(target, field_name) = allocator.dupe(u8, item.string) catch |err| quitMsg("{}\n", .{err});
                    },
                    else => |e| @compileError("unsupported type: " ++ @tagName(e)),
                }
            },
            .@"enum" => |enm| {
                if (table.contains(field_name)) {
                    const item = table.table.get(field_name) orelse unreachable;
                    switch (item) {
                        .integer => {
                            @field(target, field_name) = @fromBackingInt(@truncate(@as(u64, @bitCast(item.integer))));
                        },
                        .string => blk: {
                            inline for (enm.field_names, enm.field_values) |enum_field_name, enum_field_value| {
                                if (std.mem.eql(u8, enum_field_name, item.string)) {
                                    @field(target, field_name) = @fromBackingInt(enum_field_value);
                                    break :blk;
                                }
                            }
                            quitMsg("<red>configuration error:<clear> '{s}' must be an valid option\n", .{field_name});
                        },
                        else => quitMsg("<red>configuration error:<clear> '{s}' must be an integer or string\n", .{field_name}),
                    }
                }
            },
            else => @compileError("unsupported type: " ++ @tagName(field_ti)),
        }
    }
    inline for (ti.@"struct".decl_names) |decl_name| {
        const decl_value = @field(T, decl_name);
        const decl_ti = @typeInfo(@TypeOf(decl_value));
        switch (decl_ti) {
            .@"fn" => |func| {
                const arg_type = func.param_types[0] orelse @compileError("function missing argument type");
                switch (@typeInfo(arg_type)) {
                    .@"struct" => {
                        if (arg_type == toml.Table) {
                            if (table.contains(decl_name)) {
                                const item = table.table.get(decl_name) orelse unreachable;
                                if (item != .table)
                                    quitMsg("<red>configuration error:<clear> '{s}' must be a table\n", .{decl_name});
                                @call(.always_inline, decl_value, .{item.table});
                            }
                        }
                    },
                    .pointer => |ptr| if (table.contains(decl_name)) {
                        comptime std.debug.assert(ptr.size == .slice);
                        comptime std.debug.assert(ptr.child == u8);
                        const item = table.table.get(decl_name) orelse unreachable;
                        if (item != .string)
                            quitMsg("<red>configuration error:<clear> '{s}' must be a string\n", .{decl_name});
                        @call(.always_inline, decl_value, .{item.string});
                    },
                    else => @compileError("unsupported type: " ++ @tagName(arg_type)),
                }
            },
            else => {},
        }
    }
}

pub fn loadConfiguration(dir: std.Io.Dir) !void {
    const allocator = DEFAULT_ALLOCATOR;
    const config_content = try dir.readFileAlloc(io(), "zune.toml", allocator, .unlimited);
    defer allocator.free(config_content);

    var zune_config = toml.parse(allocator, config_content) catch return error.ParseFailed;
    defer zune_config.deinit(allocator);

    loadConfigurationFromToml(ZuneState.Options, &State.options, allocator, zune_config);
}

pub fn quitMsg(comptime format: []const u8, args: anytype) noreturn {
    debug.print(format, args);
    std.process.exit(1);
}

pub fn initState(L: *VM.lua.State, allocator: std.mem.Allocator) !void {
    try Resolvers.Require.init(allocator);
    standard.libraries.testing.init();
    if (State.options.runtime.features.c and comptime (standard.libraries.c.PlatformSupported() != null))
        try standard.libraries.c.init(L);
}

pub fn deinitState(L: *VM.lua.State, allocator: std.mem.Allocator) void {
    Resolvers.Require.deinit(allocator);
    if (State.options.runtime.features.c and comptime standard.libraries.c.PlatformSupported() != null)
        standard.libraries.c.deinit(L);
    if (comptime standard.libraries.thread.PlatformSupported() != null) {
        standard.libraries.thread.MUTEX_REGISTRY.deinit(L);
        standard.libraries.thread.HARD_MUTEX_REGISTRY.deinit(L);
        standard.libraries.thread.LANE_REGISTRY.deinit(L);
        standard.libraries.thread.VALUE_REGISTRY.deinit(L);
    }
}

pub fn openZune(L: *VM.lua.State, flags: Flags) !void {
    try Resolvers.Require.load(L);

    if (State.options.format.enabled) {
        try L.Zpushfunction(Runtime.Scripting.toCFn(Resolvers.Fmt.print), "fmt_print");
        try L.rawsetglobal("print");
    }

    try L.Zsetglobal("_VERSION", std.fmt.comptimePrint("zune {s}", .{VERSION_FULL_STR}));
    try L.Zsetglobal("_RUNTIME", .{
        .name = "zune",
        .version = .{
            .display = std.fmt.comptimePrint("{s}", .{VERSION_FULL_STR}),
            .semantic = .{
                .major = info.version.major,
                .minor = info.version.minor,
                .patch = info.version.patch,
                .build = if (info.commit_hash) |hash|
                    std.fmt.comptimePrint("dev.{s}", .{hash[0..7]})
                else
                    null,
            },
        },
    });
    try L.Zsetglobal("_LUAU", .{
        .version = .{
            .display = std.fmt.comptimePrint("{d}.{d}", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor }),
            .major = luau.LUAU_VERSION.major,
            .minor = luau.LUAU_VERSION.minor,
        },
    });

    if (!flags.limbo) {
        inline for (@typeInfo(objects).@"struct".decl_names) |decl| {
            const impl = @field(objects, decl);
            if (@hasDecl(impl, "PlatformSupported")) {
                if (comptime impl.PlatformSupported()) |_|
                    try standard.ResolveObject(impl, L);
            } else try standard.ResolveObject(impl, L);
        }
        try L.createtable(0, @typeInfo(standard.libraries).@"struct".decl_names.len + 1);
        inline for (@typeInfo(standard.libraries).@"struct".decl_names) |decl_name| {
            const lib = @field(standard.libraries, decl_name);
            const enabled = if (comptime @hasField(@TypeOf(State.options.runtime.features), decl_name))
                @field(State.options.runtime.features, decl_name)
            else
                true;
            if (@hasDecl(lib, "PlatformSupported")) {
                if (enabled and comptime lib.PlatformSupported() != null)
                    try standard.loadLibrary(lib, L);
            } else if (enabled)
                try standard.loadLibrary(lib, L);
        }

        if (State.bundle) |b| {
            try L.Zpushvalue(.{
                .optimize = State.options.runtime.luau.optimization_level,
                .debug = State.options.runtime.luau.debug_level,
                .mode = @tagName(b.mode.compiled),
            });
            try L.rawsetfield(-2, "compiled");
        }

        L.pushvalue(-1);
        try L.setreadonly(-1, true);
        try L.rawsetfield(VM.lua.REGISTRYINDEX, "_LIBS");
        try L.rawsetglobal("zune");
    }

    if (comptime builtin.mode == .debug) {
        std.debug.assert(L.rawgetfield(VM.lua.REGISTRYINDEX, "_LIBS") == .Table);
        L.pop(1); // drop: _LIBS
    }
}

pub fn main(i: std.process.Init.Minimal) !void {
    switch (comptime builtin.os.tag) {
        .windows => {
            const WinApi = struct {
                const w = std.os.windows;

                pub extern "kernel32" fn SetConsoleCtrlHandler(
                    HandlerRoutine: ?*const fn (w.DWORD) callconv(.winapi) w.BOOL,
                    Add: w.BOOL,
                ) callconv(.winapi) w.BOOL;

                fn handler(dwCtrlType: w.DWORD) callconv(.winapi) w.BOOL {
                    if (dwCtrlType == 0) { // CTRL_C_EVENT
                        shutdown();
                        return .TRUE;
                    } else return .FALSE;
                }
            };
            _ = WinApi.SetConsoleCtrlHandler(WinApi.handler, .TRUE);
        },
        .linux, .macos => {
            const handle = struct {
                fn handler(_: std.posix.SIG) callconv(.c) void {
                    shutdown();
                }
            }.handler;
            std.posix.sigaction(std.posix.SIG.INT, &.{
                .handler = .{ .handler = handle },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            }, null);
        },
        else => {},
    }
    defer switch (builtin.mode) {
        .Debug => {
            State.env_map.deinit();
            _ = DEBUG_ALLOCATOR.deinit();
        },
        else => {},
    };

    try init(i.environ);

    const allocator = DEFAULT_ALLOCATOR;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const args = try i.args.toSlice(arena.allocator());

    if (args.len > 0) State.bin_arg = args[0];
    State.args = args;

    if (Resolvers.Bundle.get()) |bundled| {
        State.bundle = Resolvers.Bundle.open(allocator, bundled) catch |err| switch (err) {
            error.CorruptBundle => quitMsg("<red>error<clear>: bundled executable is corrupt\n", .{}),
            else => |e| return e,
        };
        defer if (State.bundle) |*bundle| {
            bundle.deinit();
            State.bundle = null;
        };

        const bundle = &State.bundle.?;

        var L = try luau.VM.lstate.Lnewstate();
        defer L.deinit();

        var scheduler = try Runtime.Scheduler.init(allocator);
        defer scheduler.deinit();

        scheduler.setup(L);

        try initState(L, allocator);
        defer deinitState(L, allocator);

        try Runtime.Engine.prep(L);
        try openZune(L, .{ .limbo = bundle.mode.limbo });

        L.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const ML = try L.newthread();

        try ML.Lsandboxthread();

        try Runtime.Engine.setLuaFileContext(ML, .{
            .main = true,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        switch (bundle.mode.compiled) {
            .debug => Runtime.Engine.loadModule(ML, bundle.entry.name, bundle.entry.data, null) catch |err| switch (err) {
                error.Syntax => quitMsg("<red>syntax error<clear>: {s}\n", .{ML.tostring(-1) orelse "unknown"}),
            },
            .release => {
                ML.load(bundle.entry.name, bundle.entry.data, 0) catch
                    quitMsg("<red>error<clear>: {s}\n", .{ML.tostring(-1) orelse "unknown"});
                Runtime.Engine.loadNative(ML);
            },
        }

        Runtime.Engine.runAsync(ML, &scheduler, .{}) catch std.process.exit(1);
        return;
    }

    try cli.start(args);
}

fn shutdown() void {
    if (standard.libraries.process.SIGINT_LUA) |handler| {
        if (Runtime.Scripting.callSyncGlobalFunction(handler.state, handler.ref, @as(void, undefined)) catch |err| std.debug.panic("{}", .{err})) |res| {
            switch (res) {
                .none => return, // User will handle process close.
                .boolean => |v| if (!v) return, // User decided runtime should handle closure
                .number => return,
            }
        }
    }
    Runtime.Debugger.SigInt();
    Runtime.Engine.stateCleanUp();
    std.process.exit(0);
}

test {
    _ = cli;

    _ = toml;

    _ = Runtime;
    _ = Resolvers;
    _ = Utils;

    _ = objects;
    _ = standard;
}
