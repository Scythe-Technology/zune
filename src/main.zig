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

var FEATURES: struct {
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
    CONFIG_CACHE: std.StringArrayHashMap(Resolvers.Config) = .init(DEFAULT_ALLOCATOR),
    MAIN_THREAD_ID: ?std.Thread.Id = null,
    LUAU_OPTIONS: LuauOptions = .{},
    FORMAT: FormatOptions = .{},
    USE_DETAILED_ERROR: bool = true,

    pub const LuauOptions = struct {
        DEBUG_LEVEL: u2 = 2,
        OPTIMIZATION_LEVEL: u2 = 1,
        CODEGEN: bool = true,
        JIT_ENABLED: bool = true,
    };

    pub const FormatOptions = struct {
        MAX_DEPTH: u8 = 4,
        USE_COLOR: bool = true,
        SHOW_TABLE_ADDRESS: bool = true,
        SHOW_RECURSIVE_TABLE: bool = false,
        DISPLAY_BUFFER_CONTENTS_MAX: usize = 48,
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
        else => return std.debug.print("Failed to read zune.toml: {}\n", .{err}),
    };
    defer allocator.free(config_content);

    var zconfig = toml.parse(allocator, config_content) catch |err| {
        return std.debug.print("Failed to parse zune.toml: {}\n", .{err});
    };
    defer zconfig.deinit(allocator);

    if (toml.checkOptionTable(zconfig, "runtime")) |runtime_config| {
        if (toml.checkOptionString(runtime_config, "cwd")) |path| {
            if (comptime builtin.target.os.tag != .wasi) {
                const cwd = dir.openDir(path, .{}) catch |err| {
                    std.debug.panic("[zune.toml] Failed to open cwd (\"{s}\"): {}\n", .{ path, err });
                };
                cwd.setAsCwd() catch |err| {
                    std.debug.panic("[zune.toml] Failed to set cwd to (\"{s}\"): {}\n", .{ path, err });
                };
            }
        }
        if (toml.checkOptionTable(runtime_config, "debug")) |debug_config| {
            if (toml.checkOptionBool(debug_config, "detailedError")) |enabled|
                STATE.USE_DETAILED_ERROR = enabled;
        }
        if (toml.checkOptionTable(runtime_config, "luau")) |luau_config| {
            if (toml.checkOptionTable(luau_config, "fflags")) |fflags_config| {
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
            if (toml.checkOptionTable(luau_config, "options")) |compiling| {
                if (toml.checkOptionInteger(compiling, "debugLevel")) |debug_level|
                    STATE.LUAU_OPTIONS.DEBUG_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @bitCast(debug_level))))));
                if (toml.checkOptionInteger(compiling, "optimizationLevel")) |opt_level|
                    STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @bitCast(opt_level))))));
                if (toml.checkOptionBool(compiling, "nativeCodeGen")) |enabled|
                    STATE.LUAU_OPTIONS.CODEGEN = enabled;
            }
        }
    }

    if (toml.checkOptionTable(zconfig, "resolvers")) |resolvers_config| {
        if (toml.checkOptionTable(resolvers_config, "formatter")) |fmt_config| {
            if (toml.checkOptionInteger(fmt_config, "maxDepth")) |depth|
                STATE.FORMAT.MAX_DEPTH = @truncate(@as(u64, @bitCast(depth)));
            if (toml.checkOptionBool(fmt_config, "useColor")) |enabled|
                STATE.FORMAT.USE_COLOR = enabled;
            if (toml.checkOptionBool(fmt_config, "showTableAddress")) |enabled|
                STATE.FORMAT.SHOW_TABLE_ADDRESS = enabled;
            if (toml.checkOptionBool(fmt_config, "showRecursiveTable")) |enabled|
                STATE.FORMAT.SHOW_RECURSIVE_TABLE = enabled;
            if (toml.checkOptionInteger(fmt_config, "displayBufferContentsMax")) |max|
                STATE.FORMAT.DISPLAY_BUFFER_CONTENTS_MAX = @truncate(@as(u64, @bitCast(max)));
        }
    }

    if (toml.checkOptionTable(zconfig, "features")) |features_config| {
        if (toml.checkOptionTable(features_config, "builtins")) |builtins| {
            inline for (@typeInfo(@TypeOf(FEATURES)).@"struct".decls) |decl| {
                if (toml.checkOptionBool(builtins, decl.name)) |enabled|
                    @field(FEATURES, decl.name) = enabled;
            }
        }
    }
}

pub fn openZune(L: *VM.lua.State, args: []const []const u8, flags: Flags) !void {
    L.Zsetglobalfn("require", @import("core/resolvers/require.zig").zune_require);

    objects.load(L);

    L.createtable(0, 0);
    L.Zpushvalue(.{
        .__index = struct {
            fn inner(l: *VM.lua.State) !i32 {
                _ = l.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
                l.pushvalue(2);
                _ = l.gettable(-2);
                return 1;
            }
        }.inner,
        .__metatable = "This metatable is locked",
    });
    L.setreadonly(-1, true);
    _ = L.setmetatable(-2);
    L.setreadonly(-1, true);
    L.setglobal("zune");

    L.Zpushfunction(Resolvers.Fmt.print, "zune_fmt_print");
    L.setglobal("print");

    L.Zsetglobal("_VERSION", VERSION);

    if (!flags.limbo) {
        if (FEATURES.fs)
            corelib.fs.loadLib(L);
        if (FEATURES.task)
            corelib.task.loadLib(L);
        if (FEATURES.luau)
            corelib.luau.loadLib(L);
        if (FEATURES.serde)
            corelib.serde.loadLib(L);
        if (FEATURES.io)
            corelib.io.loadLib(L);
        if (FEATURES.crypto)
            corelib.crypto.loadLib(L);
        if (FEATURES.regex)
            corelib.regex.loadLib(L);
        if (FEATURES.net and comptime corelib.net.PlatformSupported())
            corelib.net.loadLib(L);
        if (FEATURES.datetime and comptime corelib.datetime.PlatformSupported())
            corelib.datetime.loadLib(L);
        if (FEATURES.process and comptime corelib.process.PlatformSupported())
            try corelib.process.loadLib(L, args);
        if (FEATURES.ffi and comptime corelib.ffi.PlatformSupported())
            corelib.ffi.loadLib(L);
        if (FEATURES.sqlite)
            corelib.sqlite.loadLib(L);
        if (FEATURES.require)
            corelib.require.loadLib(L);
        if (FEATURES.random)
            corelib.random.loadLib(L);
        if (FEATURES.thread and comptime corelib.thread.PlatformSupported())
            corelib.thread.loadLib(L);

        corelib.testing.loadLib(L, STATE.RUN_MODE == .Test);
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

    try cli.start();
}

fn shutdown() void {
    const Repl = @import("commands/repl/lib.zig");

    if (Repl.REPL_STATE > 0) {
        if (Repl.SigInt())
            return;
    } else if (corelib.process.SIGINT_LUA) |handler| {
        const L = handler.state;
        if (L.rawgeti(luau.VM.lua.REGISTRYINDEX, handler.ref) == .Function) {
            const ML = L.newthread();
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
