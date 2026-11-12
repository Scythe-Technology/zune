const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const command = @import("lib.zig");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Debugger = Zune.Runtime.Debugger;
const Profiler = Zune.Runtime.Profiler;

const File = Zune.Resolvers.File;

const VM = luau.VM;

fn getFile(
    allocator: std.mem.Allocator,
    comptime from: enum { Run, Other },
    dir: std.Io.Dir,
    input: []const u8,
) !struct { [:0]u8, []const u8 } {
    var maybe_src: ?[:0]u8 = null;
    errdefer if (maybe_src) |s| allocator.free(s);
    var maybe_content: ?[]const u8 = null;
    errdefer if (maybe_content) |c| allocator.free(c);

    const path = try File.resolve(allocator, Zune.State.env_map, switch (comptime from) {
        .Run => if (Zune.State.options.workspace.run_path) |path| &.{ path, input } else &.{input},
        else => &.{input},
    });
    if (dir.readFileAlloc(Zune.io(), path[1..], allocator, .unlimited) catch null) |content| {
        maybe_content = content;
        maybe_src = path;
    } else {
        defer allocator.free(path);
        const result = File.findLuauFile(dir, path[1..]) catch |err| switch (err) {
            error.RedundantFileExtension => return error.FileNotFound,
            else => return err,
        } orelse return error.FileNotFound;
        var reader = result.val.handle.reader(Zune.io(), &.{});
        maybe_content = try reader.interface.allocRemaining(allocator, .unlimited);
        maybe_src = try std.mem.concatWithSentinel(allocator, u8, &.{ path, result.ext.ext }, 0);
    }

    return .{ maybe_src.?, maybe_content.? };
}

fn splitArgs(args: []const [:0]const u8) struct { []const [:0]const u8, ?[]const [:0]const u8 } {
    var run_args: []const [:0]const u8 = args;
    var flags: ?[]const [:0]const u8 = null;
    blk: {
        for (args, 0..) |arg, ap| {
            if (arg.len <= 1 or arg[0] != '-') {
                if (ap > 0)
                    flags = args[0..ap];
                run_args = args[ap..];
                break :blk;
            }
        }
        flags = args;
        run_args = &[0][:0]const u8{};
        break :blk;
    }
    return .{ run_args, flags };
}

fn cmdRun(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    @branchHint(.likely);
    const run_args, const flags = splitArgs(args);

    if (run_args.len < 1)
        Zune.quitMsg("<red>usage<clear>: run [OPTIONS] <<luau file>>\n", .{});

    Zune.State.args = run_args;

    Zune.loadConfiguration(std.Io.Dir.cwd()) catch |err| switch (err) {
        error.FileNotFound => {},
        error.ParseFailed => Zune.debug.print("<blue>configuration warning:<clear> failed to parse <underline>zune.toml<clear>: {t}\n", .{err}),
        else => Zune.debug.print("<blue>configuration warning:<clear> failed to read <underline>zune.toml<clear>: {t}\n", .{err}),
    };

    var LOAD_FLAGS: Zune.Flags = .{};
    var PROFILER: ?u64 = null;
    if (flags) |f| for (f) |flag| {
        if (flag.len < 2)
            continue;
        switch (flag[0]) {
            '-' => sw: switch (flag[1]) {
                'O' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                    const level: u2 = switch (flag[2]) {
                        '0' => 0,
                        '1' => 1,
                        '2' => 2,
                        else => unreachable,
                    };
                    Zune.State.options.runtime.luau.optimization_level = level;
                } else Zune.quitMsg("<red>error<clear>: invalid optimization level, usage: -O<<N>>\n", .{}),
                'g' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                    const level: u2 = switch (flag[2]) {
                        '0' => 0,
                        '1' => 1,
                        '2' => 2,
                        else => unreachable,
                    };
                    Zune.State.options.runtime.luau.debug_level = level;
                } else Zune.quitMsg("<red>error<clear>: invalid debug level, usage: -g<<N>>\n", .{}),
                'c' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                    const level: u2 = switch (flag[2]) {
                        '0' => 0,
                        '1' => 1,
                        '2' => 2,
                        else => unreachable,
                    };
                    Zune.State.options.runtime.luau.coverage_level = level;
                } else Zune.quitMsg("<red>error<clear>: invalid coverage level, usage: -c<<N>>\n", .{}),
                '-' => if (std.mem.startsWith(u8, flag, "--profile")) {
                    PROFILER = 10000;
                    if (flag.len > 10 and flag[9] == '=') {
                        const level = try std.fmt.parseInt(u64, flag[10..], 10);
                        PROFILER = level;
                    }
                } else if (std.mem.eql(u8, flag, "--native")) {
                    Zune.State.options.runtime.luau.default_ncg = true;
                } else if (std.mem.eql(u8, flag, "--no-native")) {
                    Zune.State.options.runtime.luau.default_ncg = false;
                } else if (std.mem.eql(u8, flag, "--no-jit")) {
                    Zune.State.options.runtime.luau.jit_enabled = false;
                } else if (std.mem.eql(u8, flag, "--limbo")) {
                    LOAD_FLAGS.limbo = true;
                } else if (std.mem.eql(u8, flag, "--no-fmt")) {
                    Zune.State.options.format.enabled = false;
                } else continue :sw 0,
                else => Zune.quitMsg("<red>error<clear>: unknown flag '{s}'\n", .{flag}),
            },
            else => unreachable,
        }
    };

    const dir = std.Io.Dir.cwd();

    const file_src_path, const file_content = if (Zune.State.options.workspace.scripts.get(run_args[0])) |defined|
        getFile(allocator, .Other, dir, defined) catch |err| switch (err) {
            error.FileNotFound => Zune.quitMsg("<red>error<clear>: file not found '{s}'\n", .{defined}),
            else => return err,
        }
    else
        getFile(allocator, .Run, dir, run_args[0]) catch |err| switch (err) {
            error.FileNotFound => Zune.quitMsg("<red>error<clear>: file not found '{s}'\n", .{run_args[0]}),
            else => return err,
        };
    defer allocator.free(file_src_path);
    defer allocator.free(file_content);

    var L = try luau.VM.lstate.Lnewstate();
    defer L.deinit();
    var scheduler = try Scheduler.init(allocator);
    defer scheduler.deinit();

    scheduler.setup(L);

    try Zune.initState(L, allocator);
    defer Zune.deinitState(L, allocator);

    try Engine.prep(L);
    try Zune.openZune(L, LOAD_FLAGS);

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = try L.newthread();

    try ML.Lsandboxthread();

    try Engine.setLuaFileContext(ML, .{
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    Engine.loadModule(ML, file_src_path, file_content, null) catch |err| switch (err) {
        error.Syntax => Zune.quitMsg("<red>syntax error<clear>: {s}\n", .{ML.tostring(-1) orelse "unknown"}),
    };

    if (PROFILER) |freq|
        try Profiler.start(L, freq);
    defer if (PROFILER != null) {
        Profiler.end();
        Profiler.dump("profile.out");
    };
    Engine.runAsync(ML, &scheduler, .{}) catch std.process.exit(1);
}

fn cmdDebug(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (comptime Debugger.PlatformSupported() == null) {
        Zune.quitMsg("<red>error<clear>: platform not supported\n", .{});
    }

    Debugger.ACTIVE = true;

    const run_args, const flags = splitArgs(args);

    if (run_args.len < 1)
        Zune.quitMsg("<red>usage<clear>: debug [OPTIONS] <<luau file>>\n", .{});

    Zune.loadConfiguration(std.Io.Dir.cwd()) catch |err| switch (err) {
        error.FileNotFound => {},
        error.ParseFailed => Zune.debug.print("<blue>configuration warning:<clear> failed to parse <underline>zune.toml<clear>: {t}\n", .{err}),
        else => Zune.debug.print("<blue>configuration warning:<clear> failed to read <underline>zune.toml<clear>: {t}\n", .{err}),
    };

    var LOAD_FLAGS: Zune.Flags = .{};
    var ALWAYS_DEBUG = true;
    var IPC_PORT: ?u16 = null;

    if (flags) |f| for (f) |flag| {
        if (flag.len < 2)
            continue;
        switch (flag[0]) {
            '-' => sw: switch (flag[1]) {
                'O' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                    const level: u2 = switch (flag[2]) {
                        '0' => 0,
                        '1' => 1,
                        '2' => 2,
                        else => unreachable,
                    };
                    Zune.State.options.runtime.luau.optimization_level = level;
                } else Zune.quitMsg("<red>error<clear>: invalid optimization level, usage: -O<<N>>\n", .{}),
                'c' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                    const level: u2 = switch (flag[2]) {
                        '0' => 0,
                        '1' => 1,
                        '2' => 2,
                        else => unreachable,
                    };
                    Zune.State.options.runtime.luau.coverage_level = level;
                } else Zune.quitMsg("<red>error<clear>: invalid coverage level, usage: -c<<N>>\n", .{}),
                '-' => if (std.mem.eql(u8, flag, "--once")) {
                    ALWAYS_DEBUG = false;
                } else if (std.mem.eql(u8, flag, "--limbo")) {
                    LOAD_FLAGS.limbo = true;
                } else if (std.mem.eql(u8, flag, "--no-fmt")) {
                    Zune.State.options.format.enabled = false;
                } else if (std.mem.startsWith(u8, flag, "--ipc-port=")) {
                    const port = flag[11..];
                    if (port.len == 0)
                        Zune.quitMsg("<red>error<clear>: invalid port number\n", .{});
                    IPC_PORT = try std.fmt.parseInt(u16, port, 10);
                } else continue :sw 0,
                else => Zune.quitMsg("<red>error<clear>: unknown flag '{s}'\n", .{flag}),
            },
            else => unreachable,
        }
    };

    Zune.State.options.runtime.luau.debug_level = 2;
    Zune.State.options.runtime.luau.default_ncg = false;
    Zune.State.options.runtime.luau.jit_enabled = false;

    const dir = std.Io.Dir.cwd();
    const module = run_args[0];

    const file_src_path, const file_content = getFile(allocator, .Other, dir, module) catch |err| switch (err) {
        error.FileNotFound => Zune.quitMsg("<red>error<clear>: file not found '{s}'\n", .{module}),
        else => return err,
    };
    defer allocator.free(file_src_path);
    defer allocator.free(file_content);

    const stdin = std.Io.File.stdin();
    var reader_buffer: [128]u8 = undefined;
    if (IPC_PORT) |port| {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        const stream = try address.connect(Zune.io(), .{ .mode = .stream });
        Debugger.COMM = .{ .stream = stream };
        var write_buf: [128]u8 = undefined;
        var stream_writer = stream.writer(Zune.io(), &write_buf);
        try stream_writer.interface.writeAll("zune/" ++ Zune.VERSION_STR ++ "\n");
        try stream_writer.interface.writeAll(std.fmt.comptimePrint("luau/{d}.{d}\n", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor }));
        try stream_writer.interface.flush();
    } else {
        Debugger.COMM = .{
            .io = stdin.reader(Zune.io(), &reader_buffer),
        };
    }
    defer switch (Debugger.COMM) {
        .stream => |s| s.close(Zune.io()),
        .io => {},
    };

    while (true) {
        defer Debugger.DEBUG.dead = false;

        Debugger.reloadBreakpoints();

        var L = try luau.VM.lstate.Lnewstate();
        defer L.deinit();

        L.singlestep(true);

        var scheduler = try Scheduler.init(allocator);
        defer scheduler.deinit();

        scheduler.setup(L);

        try Zune.initState(L, allocator);
        defer Zune.deinitState(L, allocator);

        const callbacks = L.callbacks();

        callbacks.*.debugbreak = Debugger.debugbreak;
        callbacks.*.debugstep = Debugger.debugstep;
        callbacks.*.debugprotectederror = Debugger.debugprotectederror;

        try Engine.prep(L);
        try Zune.openZune(L, LOAD_FLAGS);

        L.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const terminal = Zune.standard.libraries.io.terminal;
        errdefer terminal.restoreSettings() catch {};
        errdefer terminal.restoreOutputMode() catch {};

        try terminal.saveSettings();

        const ML = try L.newthread();

        try ML.Lsandboxthread();

        try Engine.setLuaFileContext(ML, .{
            .main = true,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        Engine.loadModule(ML, file_src_path, file_content, null) catch |err| switch (err) {
            error.Syntax => Zune.quitMsg("<red>syntax error<clear>: {s}\n", .{ML.tostring(-1) orelse "unknown"}),
        };

        try Debugger.prompt(ML, .None, null);
        Engine.runAsync(ML, &scheduler, .{}) catch {}; // Soft continue

        Debugger.printResult("execution finished\n", .{});
        if (!ALWAYS_DEBUG)
            break;
    }

    Debugger.DebuggerExit();
}

pub const RunCmd: command.Command = .{
    .name = "run",
    .execute = cmdRun,
    .description = "Execute lua/luau file.",
    .template = "./script.luau",
    .flags = .construct(&.{
        .{ "-O<N>", "Set optimization level (0-2)" },
        .{ "-g<N>", "Set debug level (0-2)" },
        .{ "-c<N>", "Set coverage level (0-2)" },
        .{ "--profile[=N]", "Enable profiling, optional frequency in Hz" },
        .{ "--native", "Enable native code generation (NCG)" },
        .{ "--no-native", "Disable native code generation (NCG)" },
        .{ "--no-jit", "Disable JIT compilation" },
        .{ "--limbo", "Enable limbo mode" },
        .{ "--no-fmt", "Disable formatting" },
    }),
};

pub const DebugCmd: command.Command = .{
    .name = "debug",
    .execute = cmdDebug,
    .description = "Debug lua/luau file.",
    .template = "./script.luau",
    .flags = .construct(&.{
        .{ "-O<N>", "Set optimization level (0-2)" },
        .{ "-c<N>", "Set coverage level (0-2)" },
        .{ "--once", "Run the script only once" },
        .{ "--limbo", "Enable limbo mode" },
        .{ "--no-fmt", "Disable formatting" },
        .{ "--ipc-port=<N>", "Set IPC port number" },
    }),
};

test cmdRun {
    const allocator = std.testing.allocator;
    try cmdRun(allocator, &.{"test/cli/run"});
}
