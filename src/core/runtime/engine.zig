const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

pub inline fn loadAndCompileModule(L: *VM.lua.State, moduleName: [:0]const u8, content: []const u8, cOpts: ?luau.CompileOptions) !void {
    const compileOptions = cOpts orelse luau.CompileOptions{
        .debugLevel = Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL,
        .optimizationLevel = Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
        .coverageLevel = Zune.STATE.LUAU_OPTIONS.COVERAGE_LEVEL,
        .typeInfoLevel = 1,
    };

    luau.Compiler.Compiler.compileLoad(L, moduleName, content, compileOptions, 0) catch return error.Syntax;
}

pub fn loadNative(L: *VM.lua.State) void {
    if (luau.CodeGen.Supported() and Zune.STATE.LUAU_OPTIONS.CODEGEN and Zune.STATE.LUAU_OPTIONS.JIT_ENABLED)
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
    if (luau.CodeGen.Supported() and Zune.STATE.LUAU_OPTIONS.JIT_ENABLED)
        luau.CodeGen.Create(L);

    try L.Lopenlibs();
}

pub fn prepAsync(L: *VM.lua.State, sched: *Scheduler) !void {
    const GL = L.mainthread();

    GL.setthreaddata(*Scheduler, sched);

    try prep(L);
}

pub fn stateCleanUp() void {
    if (comptime !@import("../../commands/repl/Terminal.zig").SupportedPlatform())
        return;
    if (Zune.corelib.io.TERMINAL) |*terminal| {
        if (terminal.stdout_istty and terminal.stdin_istty) {
            terminal.restoreSettings() catch Zune.debug.print("[Zune] Failed to restore terminal settings\n", .{});
            terminal.restoreOutputMode() catch Zune.debug.print("[Zune] Failed to restore terminal output mode\n", .{});
        }
    }
}

const RunOptions = struct {
    cleanUp: bool,
    mode: Zune.RunMode = .Run,
};

pub fn runAsync(L: *VM.lua.State, sched: *Scheduler, comptime options: RunOptions) !void {
    defer if (options.cleanUp) stateCleanUp();
    if (comptime Zune.corelib.thread.PlatformSupported())
        Zune.corelib.thread.THREADS = .{};
    try sched.deferThread(L, null, 0);
    sched.run(options.mode);
    const threadlib = Zune.corelib.thread;
    if (comptime Zune.corelib.thread.PlatformSupported()) {
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
}

pub fn run(L: *VM.lua.State) !void {
    defer stateCleanUp();
    _ = try L.pcall(0, 0, 0).check();
}

test "Run Basic" {
    const allocator = std.testing.allocator;
    const L = try luau.init(&allocator);
    defer L.deinit();
    if (luau.CodeGen.Supported())
        luau.CodeGen.Create(L);
    try L.Lopenlibs();
    try loadModule(L, "test", "tostring(\"Hello, World!\")\n", null);
    try run(L);
}

test "Run Basic Syntax Error" {
    const allocator = std.testing.allocator;
    const L = try luau.init(&allocator);
    defer L.deinit();
    if (luau.CodeGen.Supported())
        luau.CodeGen.Create(L);
    try L.Lopenlibs();
    try std.testing.expectError(error.Syntax, loadModule(L, "test", "print('Hello, World!'\n", null));
    try std.testing.expectEqualStrings("[string \"test\"]:2: Expected ')' (to close '(' at line 1), got <eof>", L.tostring(-1) orelse "UnknownError");
}
