const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Debug = Zune.Runtime.Debug;
const Debugger = Zune.Runtime.Debugger;
const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

pub inline fn loadAndCompileModule(L: *VM.lua.State, moduleName: [:0]const u8, content: []const u8, cOpts: ?luau.CompileOptions) !void {
    const compileOptions = cOpts orelse luau.CompileOptions{
        .debugLevel = Zune.State.options.runtime.luau.debug_level,
        .optimizationLevel = Zune.State.options.runtime.luau.optimization_level,
        .coverageLevel = Zune.State.options.runtime.luau.coverage_level,
        .typeInfoLevel = 1,
    };

    luau.Compiler.Compiler.compileLoad(L, moduleName, content, compileOptions, 0) catch return error.Syntax;
}

pub fn loadNative(L: *VM.lua.State) void {
    if (luau.CodeGen.Supported() and Zune.State.options.runtime.luau.default_ncg and Zune.State.options.runtime.luau.jit_enabled)
        luau.CodeGen.Compile(L, -1);
}

pub fn loadModule(L: *VM.lua.State, name: [:0]const u8, content: []const u8, cOpts: ?luau.CompileOptions) !void {
    var script = content;
    if (std.mem.startsWith(u8, content, "#!")) {
        const pos = std.mem.indexOf(u8, content, "\n") orelse content.len;
        script = content[pos..];
    }
    try loadAndCompileModule(L, name, script, cOpts);
    loadNative(L);
}

const FileContext = struct {
    main: bool = false,
};

pub fn setLuaFileContext(L: *VM.lua.State, ctx: FileContext) !void {
    try L.Zpushvalue(.{
        .main = ctx.main,
    });

    try L.rawsetfield(VM.lua.GLOBALSINDEX, "_FILE");
}

pub fn handleError(state: *VM.lua.State, err: anytype) anyerror {
    Debug.dumpErrorTrace(state, err, false);
    if (comptime Debugger.PlatformSupported()) |_| {
        if (Debugger.ACTIVE) {
            @branchHint(.unpredictable);
            switch (err) {
                error.Runtime => Debugger.luau_panic(state, -2),
                else => {},
            }
        }
    }
    return err;
}

pub fn checkStatus(L: *VM.lua.State) !VM.lua.Status {
    const status = L.status();
    switch (status) {
        .Ok, .Yield, .Break => return status,
        .ErrSyntax, .ErrRun => return error.Runtime,
        .ErrMem => return error.Memory,
        .ErrErr => return error.MsgHandler,
    }
}

pub fn prep(L: *VM.lua.State) !void {
    if (luau.CodeGen.Supported() and Zune.State.options.runtime.luau.jit_enabled)
        luau.CodeGen.Create(L);

    try L.Lopenlibs();
}

pub fn stateCleanUp() void {
    if (comptime !@import("../standard/io/terminal.zig").SupportedPlatform())
        return;
    const terminal = Zune.standard.libraries.io.terminal;
    if (terminal.state.stdout_istty == true and terminal.state.stdin_istty == true) {
        terminal.restoreSettings() catch Zune.debug.print("<blue>warning<clear> failed to restore terminal settings\n", .{});
        terminal.restoreOutputMode() catch Zune.debug.print("<blue>warning<clear> failed to restore terminal output mode\n", .{});
    }
}

const RunOptions = struct {
    clean_up: bool = true,
    consume_tests: bool = true,
};

pub fn runAsync(L: *VM.lua.State, sched: *Scheduler, comptime options: RunOptions) !void {
    defer if (options.clean_up) stateCleanUp();
    if (comptime Zune.standard.libraries.thread.PlatformSupported()) |_|
        Zune.standard.libraries.thread.THREADS = .{};
    try sched.deferThread(.init(L), null, 0);
    sched.run();
    const threadlib = Zune.standard.libraries.thread;
    if (comptime Zune.standard.libraries.thread.PlatformSupported()) |_| {
        var node = threadlib.THREADS.first;
        while (node) |n| {
            node = n.next;
            const runtime = threadlib.Runtime.from(n);
            if (runtime.thread) |t|
                t.join();
            runtime.thread = null;
            if (runtime.owner == .thread)
                runtime.deinit();
        }
    }
    _ = try checkStatus(L);
    if (comptime options.consume_tests) {
        if (Zune.standard.libraries.testing.running()) {
            @branchHint(.unlikely);
            const res = try Zune.standard.libraries.testing.consumeTestingResults(L);
            if (res.failed > 0)
                return error.TestFailed;
        }
    }
}

pub fn run(L: *VM.lua.State) !void {
    defer stateCleanUp();
    _ = try L.pcall(0, 0, 0).check();
}

test "Run Basic" {
    const L = try luau.VM.lstate.Lnewstate();
    defer L.deinit();
    if (luau.CodeGen.Supported())
        luau.CodeGen.Create(L);
    try L.Lopenlibs();
    try loadModule(L, "test", "tostring(\"Hello, World!\")\n", null);
    try run(L);
}

test "Run Basic Syntax Error" {
    const L = try luau.VM.lstate.Lnewstate();
    defer L.deinit();
    if (luau.CodeGen.Supported())
        luau.CodeGen.Create(L);
    try L.Lopenlibs();
    try std.testing.expectError(error.Syntax, loadModule(L, "test", "print('Hello, World!'\n", null));
    try std.testing.expectEqualStrings("[string \"test\"]:2: Expected ')' (to close '(' at line 1), got <eof>", L.tostring(-1) orelse "UnknownError");
}
