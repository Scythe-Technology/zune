const xev = @import("xev");
const std = @import("std");
const luau = @import("luau");
const json = @import("json");
const mimalloc = @import("mimalloc");
const builtin = @import("builtin");

pub const toml = @import("libraries/toml.zig");
pub const glob = @import("libraries/glob.zig");

pub const cli = @import("cli.zig");

pub const corelib = @import("core/standard/lib.zig");
pub const objects = @import("core/objects/lib.zig");

pub const DEFAULT_ALLOCATOR = if (builtin.link_libc)
    std.heap.c_allocator
else if (!builtin.single_threaded)
    std.heap.smp_allocator
else
    std.heap.page_allocator;

pub const Runtime = struct {
    pub const Engine = @import("core/runtime/engine.zig");
    pub const Scheduler = @import("core/runtime/scheduler.zig");
    pub const Profiler = @import("core/runtime/profiler.zig");
    pub const Debugger = @import("core/runtime/debugger.zig");
};

pub const Resolvers = struct {
    pub const File = @import("core/resolvers/file.zig");
    pub const Fmt = @import("core/resolvers/fmt.zig");
    pub const Config = @import("core/resolvers/config.zig");
    pub const Require = @import("core/resolvers/require.zig");
    pub const Navigator = @import("core/resolvers/navigator.zig");
    pub const Bundle = @import("core/resolvers/bundle.zig");
};

pub const Utils = struct {
    pub const Lists = @import("core/utils/lists.zig");
    pub const EnumMap = @import("core/utils/enum_map.zig");
    pub const MethodMap = @import("core/utils/method_map.zig");
    pub const LuaHelper = @import("core/utils/luahelper.zig");
};

pub const debug = struct {
    pub const print = @import("core/utils/print.zig").print;
    pub const writerPrint = @import("core/utils/print.zig").writerPrint;
};

pub const tagged = @import("tagged.zig");
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

pub const VERSION = "zune " ++ info.version ++ "+" ++ std.fmt.comptimePrint("{d}.{d}", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor });

pub var FEATURES: struct {
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
    ffi: bool = true,
} = .{};

pub const ZuneState = struct {
    ENV_MAP: std.process.EnvMap = undefined,
    RUN_MODE: RunMode = .Run,
    CONFIG_CACHE: std.StringArrayHashMapUnmanaged(Resolvers.Config) = .empty,
    MAIN_THREAD_ID: ?std.Thread.Id = null,
    LUAU_OPTIONS: LuauOptions = .{},
    FORMAT: FormatOptions = .{},
    USE_DETAILED_ERROR: bool = true,
    BUNDLE: ?Resolvers.Bundle.Map = null,
    WORKSPACE: Workspace = .{},

    pub const LuauOptions = struct {
        DEBUG_LEVEL: u2 = 2,
        OPTIMIZATION_LEVEL: u2 = 1,
        COVERAGE_LEVEL: u2 = 0,
        CODEGEN: bool = true,
        JIT_ENABLED: bool = true,
    };

    pub const FormatOptions = struct {
        MAX_DEPTH: u8 = 4,
        USE_COLOR: bool = true,
        TABLE_ADDRESS: bool = true,
        RECURSIVE_TABLE: bool = false,
        BUFFER_MAX_DISPLAY: u15 = 48,
    };

    pub const Workspace = struct {
        run_path: ?[]const u8 = null,
        test_path: ?[]const u8 = null,
        scripts: std.StringHashMapUnmanaged([]const u8) = .empty,
    };
};

pub var STATE: ZuneState = .{};

pub fn init() !void {
    const allocator = DEFAULT_ALLOCATOR;

    STATE.ENV_MAP = try std.process.getEnvMap(allocator);

    switch (comptime builtin.os.tag) {
        .linux => try xev.Dynamic.detect(), // multiple backends
        else => {},
    }
}

pub fn loadConfiguration(dir: std.fs.Dir) void {
    const allocator = DEFAULT_ALLOCATOR;
    const config_content = dir.readFileAlloc(allocator, "zune.toml", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return std.debug.print("failed to read 'zune.toml': {}\n", .{err}),
    };
    defer allocator.free(config_content);

    var zune_config = toml.parse(allocator, config_content) catch |err| {
        return std.debug.print("failed to parse 'zune.toml': {}\n", .{err});
    };
    defer zune_config.deinit(allocator);

    if (toml.checkTable(zune_config, "runtime")) |config| {
        if (toml.checkTable(config, "debug")) |debug_config| {
            if (toml.checkBool(debug_config, "detailed_error")) |enabled|
                STATE.USE_DETAILED_ERROR = enabled;
        }
        if (toml.checkTable(config, "luau")) |luau_config| {
            if (toml.checkTable(luau_config, "fflags")) |fflags_config| {
                var iter = fflags_config.table.iterator();
                while (iter.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .boolean => luau.FFlags.SetByName(bool, entry.key_ptr.*, entry.value_ptr.*.boolean) catch |err| {
                            std.debug.print("[zune.toml] FFlag ({s}): {}\n", .{ entry.key_ptr.*, err });
                        },
                        .integer => luau.FFlags.SetByName(i32, entry.key_ptr.*, @truncate(entry.value_ptr.*.integer)) catch |err| {
                            std.debug.print("[zune.toml] FFlag ({s}): {}\n", .{ entry.key_ptr.*, err });
                        },
                        else => |t| std.debug.print("[zune.toml] Unsupported type for FFlags: {s}\n", .{@tagName(t)}),
                    }
                }
            }
            if (toml.checkTable(luau_config, "options")) |compiling| {
                if (toml.checkInteger(compiling, "debug_level")) |debug_level|
                    STATE.LUAU_OPTIONS.DEBUG_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @bitCast(debug_level))))));
                if (toml.checkInteger(compiling, "optimization_level")) |opt_level|
                    STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @bitCast(opt_level))))));
                if (toml.checkBool(compiling, "native_code_gen")) |enabled|
                    STATE.LUAU_OPTIONS.CODEGEN = enabled;
            }
        }
    }

    if (toml.checkTable(zune_config, "workspace")) |config| {
        if (toml.checkString(config, "cwd")) |path| {
            if (comptime builtin.target.os.tag != .wasi) {
                const cwd = dir.openDir(path, .{}) catch |err| {
                    std.debug.panic("[zune.toml] Failed to open cwd (\"{s}\"): {}\n", .{ path, err });
                };
                cwd.setAsCwd() catch |err| {
                    std.debug.panic("[zune.toml] Failed to set cwd to (\"{s}\"): {}\n", .{ path, err });
                };
            }
        }
        if (toml.checkString(config, "run_path")) |path| {
            STATE.WORKSPACE.run_path = DEFAULT_ALLOCATOR.dupe(u8, path) catch |err| {
                std.debug.panic("[zune.toml] {}\n", .{err});
            };
        }
        if (toml.checkString(config, "test_path")) |path| {
            STATE.WORKSPACE.test_path = DEFAULT_ALLOCATOR.dupe(u8, path) catch |err| {
                std.debug.panic("[zune.toml] {}\n", .{err});
            };
        }
        if (toml.checkTable(config, "scripts")) |scripts| {
            var iter = scripts.table.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;
                if (value != .string)
                    std.debug.panic("[zune.toml] 'scripts.{s}' must be a string\n", .{key});
                const script_path = value.string;
                if (script_path.len == 0)
                    std.debug.panic("[zune.toml] 'scripts.{s}' cannot be empty\n", .{key});
                if (std.mem.indexOfNone(u8, key, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+#&$!@")) |_| {
                    std.debug.panic("[zune.toml] 'scripts.{s}' contains invalid characters\n", .{key});
                }
                if (STATE.WORKSPACE.scripts.contains(key)) {
                    std.debug.panic("[zune.toml] Duplicate script key '{s}' found\n", .{key});
                }
                const key_copy = DEFAULT_ALLOCATOR.dupe(u8, key) catch |err| {
                    std.debug.panic("[zune.toml] Failed to copy script key '{s}': {}\n", .{ key, err });
                };
                const value_copy = DEFAULT_ALLOCATOR.dupe(u8, script_path) catch |err| {
                    std.debug.panic("[zune.toml] Failed to copy script path '{s}': {}\n", .{ script_path, err });
                };
                STATE.WORKSPACE.scripts.put(allocator, key_copy, value_copy) catch |err| {
                    std.debug.panic("[zune.toml] Failed to add script '{s}': {}\n", .{ key, err });
                };
            }
        }
    }

    if (toml.checkTable(zune_config, "resolvers")) |resolvers_config| {
        if (toml.checkTable(resolvers_config, "formatter")) |fmt_config| {
            if (toml.checkInteger(fmt_config, "max_depth")) |depth|
                STATE.FORMAT.MAX_DEPTH = @truncate(@as(u64, @bitCast(depth)));
            if (toml.checkBool(fmt_config, "use_color")) |enabled|
                STATE.FORMAT.USE_COLOR = enabled;
            if (toml.checkBool(fmt_config, "table_address")) |enabled|
                STATE.FORMAT.TABLE_ADDRESS = enabled;
            if (toml.checkBool(fmt_config, "recursive_table")) |enabled|
                STATE.FORMAT.RECURSIVE_TABLE = enabled;
            if (toml.checkInteger(fmt_config, "buffer_max_display")) |max|
                STATE.FORMAT.BUFFER_MAX_DISPLAY = @truncate(@as(u64, @bitCast(max)));
        }
    }

    if (toml.checkTable(zune_config, "features")) |config| {
        if (toml.checkTable(config, "builtin")) |builtin_config| {
            inline for (@typeInfo(@TypeOf(FEATURES)).@"struct".fields) |field| {
                if (toml.checkBool(builtin_config, field.name)) |enabled|
                    @field(FEATURES, field.name) = enabled;
            }
        }
    }
}

pub fn openZune(L: *VM.lua.State, args: []const []const u8, flags: Flags) !void {
    try Resolvers.Require.load(L);

    try objects.load(L);

    try L.createtable(0, 0);
    try L.Zpushvalue(.{
        .__index = struct {
            fn inner(l: *VM.lua.State) !i32 {
                _ = try l.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
                l.pushvalue(2);
                _ = l.rawget(-2);
                return 1;
            }
        }.inner,
        .__metatable = "This metatable is locked",
    });
    L.setreadonly(-1, true);
    _ = try L.setmetatable(-2);
    L.setreadonly(-1, true);
    try L.setglobal("zune");

    try L.Zpushfunction(Resolvers.Fmt.print, "zune_fmt_print");
    try L.setglobal("print");

    try L.Zsetglobal("_VERSION", VERSION);

    if (!flags.limbo) {
        if (FEATURES.fs)
            try corelib.fs.loadLib(L);
        if (FEATURES.task)
            try corelib.task.loadLib(L);
        if (FEATURES.luau)
            try corelib.luau.loadLib(L);
        if (FEATURES.serde)
            try corelib.serde.loadLib(L);
        if (FEATURES.io)
            try corelib.io.loadLib(L);
        if (FEATURES.crypto)
            try corelib.crypto.loadLib(L);
        if (FEATURES.regex)
            try corelib.regex.loadLib(L);
        if (FEATURES.net and comptime corelib.net.PlatformSupported())
            try corelib.net.loadLib(L);
        if (FEATURES.datetime and comptime corelib.datetime.PlatformSupported())
            try corelib.datetime.loadLib(L);
        if (FEATURES.process and comptime corelib.process.PlatformSupported())
            try corelib.process.loadLib(L, args);
        if (FEATURES.ffi and comptime corelib.ffi.PlatformSupported())
            try corelib.ffi.loadLib(L);
        if (FEATURES.sqlite)
            try corelib.sqlite.loadLib(L);
        if (FEATURES.require)
            try corelib.require.loadLib(L);
        if (FEATURES.random)
            try corelib.random.loadLib(L);
        if (FEATURES.thread and comptime corelib.thread.PlatformSupported())
            try corelib.thread.loadLib(L);

        try corelib.testing.loadLib(L, STATE.RUN_MODE == .Test);

        if (STATE.BUNDLE) |b| {
            try L.Zpushvalue(.{
                .optimize = STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
                .debug = STATE.LUAU_OPTIONS.DEBUG_LEVEL,
                .mode = @tagName(b.mode.compiled),
            });
            try Utils.LuaHelper.registerModule(L, "compiled");
        }
    }
}

pub fn main() !void {
    switch (comptime builtin.os.tag) {
        .windows => {
            const handle = struct {
                fn handler(dwCtrlType: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
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
                fn handler(_: c_int) callconv(.c) void {
                    shutdown();
                }
            }.handler;
            std.posix.sigaction(std.posix.SIG.INT, &.{
                .handler = .{ .handler = handle },
                .mask = std.posix.empty_sigset,
                .flags = 0,
            }, null);
        },
        else => {},
    }

    try init();

    const allocator = DEFAULT_ALLOCATOR;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (try Resolvers.Bundle.get(allocator)) |b| {
        STATE.BUNDLE = b;

        var L = try luau.init(&allocator);
        defer L.deinit();
        var scheduler = try Runtime.Scheduler.init(allocator, L);
        defer scheduler.deinit();

        try Resolvers.Require.init(L);
        defer Resolvers.Require.deinit(L);

        try Runtime.Scheduler.SCHEDULERS.append(&scheduler);

        try Runtime.Engine.prepAsync(L, &scheduler);
        try openZune(L, args, .{ .limbo = b.mode.limbo });

        L.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const ML = try L.newthread();

        try ML.Lsandboxthread();

        try Runtime.Engine.setLuaFileContext(ML, .{
            .source = if (b.mode.compiled == .debug) b.entry.data else null,
            .main = true,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        switch (b.mode.compiled) {
            .debug => Runtime.Engine.loadModule(ML, b.entry.name, b.entry.data, null) catch |err| switch (err) {
                error.Syntax => unreachable, // should not happen
                else => return err,
            },
            .release => {
                ML.load(b.entry.name, b.entry.data, 0) catch unreachable; // should not error
                Runtime.Engine.loadNative(ML);
            },
        }

        Runtime.Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch std.process.exit(1);
        return;
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
            } else |err| Runtime.Engine.logError(ML, err, false);
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
    std.testing.refAllDecls(Runtime);
    std.testing.refAllDecls(Resolvers);
    std.testing.refAllDecls(Utils);
    std.testing.refAllDecls(@This());
}
