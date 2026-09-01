const xev = @import("xev");
const std = @import("std");
const luau = @import("luau");
const json = @import("json");
const toml = @import("toml");
const builtin = @import("builtin");

pub const glob = @import("libraries/glob.zig");

pub const cli = @import("cli.zig");

pub const corelib = @import("core/standard/lib.zig");
pub const objects = @import("core/objects/lib.zig");

const mimalloc = @import("mimalloc");

var DEBUG_ALLOCATOR = switch (builtin.mode) {
    .Debug => std.heap.DebugAllocator(.{}).init,
    else => @as(void, undefined),
};
pub const DEFAULT_ALLOCATOR = switch (builtin.mode) {
    .Debug => DEBUG_ALLOCATOR.allocator(),
    else => mimalloc.basic_allocator,
};

const ThreadedIo = struct {
    var backend: std.Io.Threaded = .init_single_threaded;
    var upgraded: bool = false;

    pub inline fn upgrade() void {
        if (!upgraded) {
            @branchHint(.unlikely);
            backend = .init(DEFAULT_ALLOCATOR, .{});
            upgraded = true;
        }
    }
};

pub fn io() std.Io {
    return ThreadedIo.backend.io();
}

pub const options: std.Options = .{
    .enable_segfault_handler = builtin.mode == .Debug,
};

pub const Runtime = struct {
    pub const Engine = @import("core/runtime/engine.zig");
    pub const Scheduler = @import("core/runtime/scheduler.zig");
    pub const Profiler = @import("core/runtime/profiler.zig");
    pub const Debugger = @import("core/runtime/debugger.zig");
    pub const Debug = @import("core/runtime/debug.zig");
    test {
        _ = Engine;
        _ = Scheduler;
        _ = Profiler;
        _ = Debugger;
    }
};

pub const Resolvers = struct {
    pub const File = @import("core/resolvers/file.zig");
    pub const Fmt = @import("core/resolvers/fmt.zig");
    pub const Config = @import("core/resolvers/config.zig");
    pub const Require = @import("core/resolvers/require.zig");
    pub const Navigator = @import("core/resolvers/navigator.zig");
    pub const Bundle = @import("core/resolvers/bundle.zig");
    test {
        _ = File;
        _ = Fmt;
        _ = Config;
        _ = Require;
        _ = Navigator;
        _ = Bundle;
    }
};

pub const Utils = struct {
    pub const Lists = @import("core/utils/lists.zig");
    pub const EnumMap = @import("core/utils/enum_map.zig");
    pub const MethodMap = @import("core/utils/method_map.zig");
    pub const LuaHelper = @import("core/utils/luahelper.zig");
    test {
        _ = Lists;
        _ = EnumMap;
        _ = MethodMap;
        _ = LuaHelper;
    }
};

pub const debug = struct {
    pub const print = Runtime.Debug.print;
    pub const writerPrint = Runtime.Debug.writerPrint;
};

pub const Tags = @import("tagged.zig").Tags;
pub const info = @import("zune-info");

const VM = luau.VM;

pub const RunMode = enum {
    Run,
    Test,
    Debug,
};

pub const Flags = struct {
    limbo: bool = false,
};

pub const VERSION_STR = std.fmt.comptimePrint("{d}.{d}.{d}{s}", .{
    info.version.major,
    info.version.minor,
    info.version.patch,
    if (info.commit_hash) |hash| std.fmt.comptimePrint("-dev.{s}", .{hash[0..7]}) else "",
});

pub const VERSION_FULL_STR = std.fmt.comptimePrint("{s}+{d}.{d}", .{
    VERSION_STR,
    luau.LUAU_VERSION.major,
    luau.LUAU_VERSION.minor,
});

pub const ZuneState = struct {
    env_map: std.process.Environ.Map = undefined,
    run_mode: RunMode = .Run,
    config_cache: std.array_hash_map.String(Resolvers.Config) = .empty,
    main_thread_id: ?std.Thread.Id = null,
    bundle: ?Resolvers.Bundle.Map = null,
    options: Options = .{},

    pub const Options = struct {
        workspace: Workspace = .{},
        runtime: @This().Runtime = .{},
        format: Format = .{},

        pub const StringMap = std.hash_map.StringHashMapUnmanaged([]const u8);

        pub const Workspace = struct {
            run_path: ?[]const u8 = null,
            test_path: ?[]const u8 = null,
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
                fs: bool = true,
                io: bool = true,
                net: bool = true,
                process: bool = true,
                task: bool = true,
                luau: bool = true,
                serde: bool = true,
                crypto: bool = true,
                datetime: bool = true,
                regex: bool = true,
                sqlite: bool = true,
                require: bool = true,
                random: bool = true,
                thread: bool = true,
                c: bool = true,
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

    ThreadedIo.upgrade();

    State.env_map = try environ.createMap(allocator);

    if (!options.enable_segfault_handler) {
        @import("./core/runtime/crash.zig").init();
    }

    switch (comptime builtin.os.tag) {
        .linux => {
            const backend = State.env_map.get("ZUNE_ASYNC_BACKEND");
            if (backend) |perferred| {
                @branchHint(.unlikely);
                var success = false;
                if (std.mem.eql(u8, perferred, "epoll")) {
                    success = xev.Dynamic.prefer(.epoll);
                } else if (std.mem.eql(u8, perferred, "io_uring")) {
                    success = xev.Dynamic.prefer(.io_uring);
                } else {
                    try xev.Dynamic.detect();
                    debug.print("<blue>configuration warning:<clear> unknown async backend '{s}', falling back to default '{t}'.\n", .{ perferred, xev.Dynamic.backend });
                    success = true;
                }
                if (!success) {
                    try xev.Dynamic.detect();
                    debug.print("<blue>configuration warning:<clear> failed to initialize preferred async backend '{s}', falling back to default '{t}'.\n", .{ perferred, xev.Dynamic.backend });
                }
            } else try xev.Dynamic.detect();
        }, // multiple backends
        else => {},
    }
}

pub fn loadConfigurationFromToml(comptime T: type, target: *T, allocator: std.mem.Allocator, table: toml.Table) void {
    const ti = @typeInfo(T);
    std.debug.assert(ti == .@"struct");
    inline for (ti.@"struct".fields) |field| {
        const field_type = @TypeOf(@field(target, field.name));
        const field_ti = @typeInfo(field_type);
        switch (field_ti) {
            .@"struct" => if (table.contains(field.name)) {
                const item = table.table.get(field.name) orelse unreachable;
                if (item != .table)
                    quitMsg("<red>configuration error:<clear> '{s}' must be a table\n", .{field.name});
                if (field_type == ZuneState.Options.StringMap) {
                    var iter = item.table.table.iterator();
                    while (iter.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const value = entry.value_ptr.*;
                        if (value != .string)
                            quitMsg("<red>configuration error:<clear> '{s}.{s}' must be a string\n", .{ field.name, key });
                        const string_value = value.string;
                        if (string_value.len == 0)
                            quitMsg("<red>configuration error:<clear> '{s}.{s}' cannot be empty\n", .{ field.name, key });
                        if (std.mem.indexOfNone(u8, key, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+#&$!@")) |_|
                            quitMsg("<red>configuration error:<clear> '{s}.{s}' contains invalid characters\n", .{ field.name, key });
                        if (@field(target, field.name).contains(key))
                            quitMsg("<red>configuration error:<clear> duplicate key '{s}' found\n", .{key});
                        const key_copy = DEFAULT_ALLOCATOR.dupe(u8, key) catch |err| quitMsg("{}\n", .{err});
                        const value_copy = DEFAULT_ALLOCATOR.dupe(u8, string_value) catch |err| quitMsg("{}\n", .{err});
                        @field(target, field.name).put(allocator, key_copy, value_copy) catch |err| quitMsg("{}\n", .{err});
                    }
                } else loadConfigurationFromToml(field_type, &@field(target, field.name), allocator, item.table);
            },
            .int => |int| if (table.contains(field.name)) {
                const item = table.table.get(field.name) orelse unreachable;
                if (item != .integer)
                    quitMsg("<red>configuration error:<clear> '{s}' must be an integer\n", .{field.name});
                if (int.signedness == .unsigned) switch (int.bits) {
                    2 => @field(target, field.name) = @truncate(@min(2, @as(u64, @bitCast(item.integer)))),
                    else => @field(target, field.name) = @truncate(@as(u64, @bitCast(item.integer))),
                } else @field(target, field.name) = @truncate(item.integer);
            },
            .bool => if (table.contains(field.name)) {
                const item = table.table.get(field.name) orelse unreachable;
                if (item != .boolean)
                    quitMsg("<red>configuration error:<clear> '{s}' must be a boolean\n", .{field.name});
                @field(target, field.name) = item.boolean;
            },
            .optional => |opt| {
                switch (@typeInfo(opt.child)) {
                    .pointer => |ptr| if (table.contains(field.name)) {
                        comptime std.debug.assert(ptr.size == .slice);
                        comptime std.debug.assert(ptr.child == u8);
                        const item = table.table.get(field.name) orelse unreachable;
                        if (item != .string)
                            quitMsg("<red>configuration error:<clear> '{s}' must be a string\n", .{field.name});
                        if (@field(target, field.name)) |existing|
                            allocator.free(existing);
                        @field(target, field.name) = allocator.dupe(u8, item.string) catch |err| quitMsg("{}\n", .{err});
                    },
                    else => |e| @compileError("unsupported type: " ++ @tagName(e)),
                }
            },
            else => @compileError("unsupported type: " ++ @tagName(field_ti)),
        }
    }
    inline for (ti.@"struct".decls) |decl| {
        const decl_value = @field(T, decl.name);
        const decl_ti = @typeInfo(@TypeOf(decl_value));
        switch (decl_ti) {
            .@"fn" => |func| {
                const arg_type = func.params[0].type orelse @compileError("function missing argument type");
                switch (@typeInfo(arg_type)) {
                    .@"struct" => {
                        if (arg_type == toml.Table) {
                            if (table.contains(decl.name)) {
                                const item = table.table.get(decl.name) orelse unreachable;
                                if (item != .table)
                                    quitMsg("<red>configuration error:<clear> '{s}' must be a table\n", .{decl.name});
                                @call(.always_inline, decl_value, .{item.table});
                            }
                        }
                    },
                    .pointer => |ptr| if (table.contains(decl.name)) {
                        comptime std.debug.assert(ptr.size == .slice);
                        comptime std.debug.assert(ptr.child == u8);
                        const item = table.table.get(decl.name) orelse unreachable;
                        if (item != .string)
                            quitMsg("<red>configuration error:<clear> '{s}' must be a string\n", .{decl.name});
                        @call(.always_inline, decl_value, .{item.string});
                    },
                    else => @compileError("unsupported type: " ++ @tagName(arg_type)),
                }
            },
            else => {},
        }
    }
}

pub fn loadConfiguration(dir: std.Io.Dir) void {
    const allocator = DEFAULT_ALLOCATOR;
    const config_content = dir.readFileAlloc(io(), "zune.toml", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return debug.print("<blue>configuration warning:<clear> failed to read <underline>zune.toml<clear>: {t}\n", .{err}),
    };
    defer allocator.free(config_content);

    var zune_config = toml.parse(allocator, config_content) catch |err| {
        return debug.print("<blue>configuration warning:<clear> failed to parse <underline>zune.toml<clear>: {t}\n", .{err});
    };
    defer zune_config.deinit(allocator);

    loadConfigurationFromToml(ZuneState.Options, &State.options, allocator, zune_config);
}

pub fn quitMsg(comptime format: []const u8, args: anytype) noreturn {
    debug.print(format, args);
    std.process.exit(1);
}

pub fn initState(L: *VM.lua.State, allocator: std.mem.Allocator) !void {
    try Resolvers.Require.init(allocator);
    if (State.options.runtime.features.c and comptime corelib.c.PlatformSupported())
        try corelib.c.init(L);
}

pub fn deinitState(L: *VM.lua.State, allocator: std.mem.Allocator) void {
    Resolvers.Require.deinit(allocator);
    if (State.options.runtime.features.c and comptime corelib.c.PlatformSupported())
        corelib.c.deinit(L);
}

pub fn openZune(L: *VM.lua.State, args: []const []const u8, flags: Flags) !void {
    if (State.main_thread_id == null) {
        @branchHint(.unlikely);
        State.main_thread_id = std.Thread.getCurrentId();
    }

    try Resolvers.Require.load(L);

    try objects.load(L);

    try L.createtable(0, @typeInfo(corelib).@"struct".decls.len + 1);
    L.pushvalue(-1);
    try L.rawsetfield(VM.lua.REGISTRYINDEX, "_LIBS");
    try L.rawsetglobal("zune");

    if (State.options.format.enabled) {
        try L.Zpushfunction(Resolvers.Fmt.print, "fmt_print");
        try L.rawsetglobal("print");
    }

    try L.Zsetglobal("_VERSION", std.fmt.comptimePrint("zune {s}", .{VERSION_FULL_STR}));

    if (!flags.limbo) {
        inline for (@typeInfo(corelib).@"struct".decls) |decl| {
            comptime if (std.mem.eql(u8, decl.name, "process") or std.mem.eql(u8, decl.name, "testing"))
                continue;
            const lib = @field(corelib, decl.name);
            const enabled = if (comptime @hasField(@TypeOf(State.options.runtime.features), decl.name))
                @field(State.options.runtime.features, decl.name)
            else
                true;
            if (@hasDecl(lib, "PlatformSupported")) {
                if (enabled and comptime lib.PlatformSupported())
                    try lib.loadLib(L);
            } else if (enabled)
                try lib.loadLib(L);
        }
        if (State.options.runtime.features.process and comptime corelib.process.PlatformSupported())
            try corelib.process.loadLib(L, args);

        try corelib.testing.loadLib(L, State.run_mode == .Test);

        if (State.bundle) |b| {
            try L.Zpushvalue(.{
                .optimize = State.options.runtime.luau.optimization_level,
                .debug = State.options.runtime.luau.debug_level,
                .mode = @tagName(b.mode.compiled),
            });
            try Utils.LuaHelper.registerModule(L, "compiled");
        }
    }

    std.debug.assert(L.rawgetfield(VM.lua.REGISTRYINDEX, "_LIBS") == .Table);
    L.setreadonly(-1, true);
    L.pop(1); // drop: _LIBS
}

pub fn main(i: std.process.Init.Minimal) !void {
    switch (comptime builtin.os.tag) {
        .windows => {
            const handle = struct {
                fn handler(dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
                    if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
                        shutdown();
                        return std.os.windows.TRUE;
                    } else return std.os.windows.FALSE;
                }
            }.handler;
            try std.os.windows.SetConsoleCtrlHandler(handle, true);
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

    try init(i.environ);

    const allocator = DEFAULT_ALLOCATOR;
    const args = try i.args.toSlice(allocator);
    defer allocator.free(args);

    if (comptime Resolvers.Bundle.PlatformSupported()) {
        if (try Resolvers.Bundle.get(allocator)) |b| {
            State.bundle = b;

            var L = try luau.VM.lstate.Lnewstate();
            defer L.deinit();
            var scheduler = try Runtime.Scheduler.init(allocator);
            defer scheduler.deinit();

            scheduler.setup(L);

            try initState(L, allocator);
            defer deinitState(L, allocator);

            try Runtime.Scheduler.SCHEDULERS.append(DEFAULT_ALLOCATOR, &scheduler);

            try Runtime.Engine.prep(L);
            try openZune(L, args, .{ .limbo = b.mode.limbo });

            L.setsafeenv(VM.lua.GLOBALSINDEX, true);

            const ML = try L.newthread();

            try ML.Lsandboxthread();

            try Runtime.Engine.setLuaFileContext(ML, .{
                .main = true,
            });

            ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

            switch (b.mode.compiled) {
                .debug => Runtime.Engine.loadModule(ML, b.entry.name, b.entry.data, null) catch |err| switch (err) {
                    error.Syntax => unreachable, // should not happen
                },
                .release => {
                    ML.load(b.entry.name, b.entry.data, 0) catch unreachable; // should not error
                    Runtime.Engine.loadNative(ML);
                },
            }

            Runtime.Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch std.process.exit(1);
            return;
        }
    }

    try cli.start(args);
}

fn shutdown() void {
    const Repl = @import("commands/repl/lib.zig");

    if (Repl.REPL_STATE > 0) {
        if (Repl.SigInt())
            return;
    } else if (corelib.process.SIGINT_LUA) |handler| {
        const L = handler.state;
        if (L.rawgeti(luau.VM.lua.REGISTRYINDEX, handler.ref) == .Function) {
            const ML = L.newthread() catch |err| std.debug.panic("{}", .{err});
            L.xpush(ML, -2);
            if (ML.pcall(0, 0, 0).check()) |_| {
                L.pop(2); // drop: thread, function
                return; // User will handle process close.
            } else |err| Runtime.Debug.dumpErrorTrace(ML, err, false);
            L.pop(1); // drop: thread
        }
        L.pop(1); // drop: ?function
    }
    Runtime.Debugger.SigInt();
    Runtime.Scheduler.KillSchedulers();
    Runtime.Engine.stateCleanUp();
    std.process.exit(0);
}

test "Zune" {
    const TestRunner = @import("./core/utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("zune.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
}

test {
    _ = cli;

    _ = toml;
    _ = glob;

    _ = Runtime;
    _ = Resolvers;
    _ = Utils;

    _ = objects;
    _ = corelib;
}
