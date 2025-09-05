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
    source: ?[]const u8,
    main: bool = false,
};

const StackInfo = struct {
    what: VM.lua.Debug.Context,
    name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_line: ?u32 = null,
    current_line: ?u32 = null,
};

pub fn setLuaFileContext(L: *VM.lua.State, ctx: FileContext) !void {
    try L.Zpushvalue(.{
        .source = if (Zune.STATE.USE_DETAILED_ERROR or Zune.STATE.RUN_MODE == .Test) ctx.source else null,
        .main = ctx.main,
    });

    try L.rawsetfield(VM.lua.GLOBALSINDEX, "_FILE");
}

pub fn printSpacedPadding(padding: []u8) void {
    @memset(padding, ' ');
    Zune.debug.print("{s}|\n", .{padding});
}

pub fn printPreviewError(padding: []u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    Zune.debug.print("{s}|\n", .{padding});
    _ = std.fmt.bufPrint(padding, "{d}", .{line}) catch |e| std.debug.panic("{}", .{e});
    Zune.debug.print("{s}~ <dim>PreviewError: " ++ fmt ++ "<clear>\n", .{padding} ++ args);
    @memset(padding, ' ');
    Zune.debug.print("{s}|\n", .{padding});
}

pub fn logDetailedDef(L: *VM.lua.State, idx: i32) !void {
    const allocator = luau.getallocator(L);

    std.debug.assert(idx < 0);
    std.debug.assert(L.typeOf(idx) == .Function);

    var stackInfo: ?StackInfo = null;
    defer if (stackInfo) |info| {
        if (info.name) |name|
            allocator.free(name);
        if (info.source) |source|
            allocator.free(source);
    };

    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    if (L.getinfo(idx, "sn", &ar)) {
        var info: StackInfo = .{
            .what = ar.what,
        };
        if (ar.name) |name|
            info.name = try allocator.dupe(u8, name);
        if (ar.linedefined) |line|
            info.source_line = line;
        if (ar.currentline) |line|
            info.current_line = line;
        info.source = try allocator.dupe(u8, ar.source.?);

        stackInfo = info;
    }

    var err_msg: []const u8 = undefined;
    var error_buf: ?[]const u8 = null;
    defer if (error_buf) |buf| allocator.free(buf);
    switch (L.typeOf(-1)) {
        .String, .Number => err_msg = L.tostring(-1).?,
        else => jmp: {
            if (!try L.checkstack(2)) {
                err_msg = "StackOverflow";
                break :jmp;
            }
            const TL = try L.newthread();
            defer L.pop(1); // drop: thread
            defer TL.resetthread() catch {};
            L.xpush(TL, -2);
            error_buf = try allocator.dupe(u8, TL.Ztolstring(1) catch |e| str: {
                switch (e) {
                    error.BadReturnType => break :str try TL.Ztolstringk(1),
                    error.Runtime => break :str try TL.Ztolstringk(1),
                    else => std.debug.panic("{}\n", .{e}),
                }
                return;
            });
            err_msg = error_buf.?;
        },
    }

    if (stackInfo != null and stackInfo.?.what == .lua and stackInfo.?.source_line != null) {
        const info = stackInfo.?;
        if (!try L.checkstack(4)) {
            Zune.debug.print("Failed to show detailed error: StackOverflow\n", .{});
            Zune.debug.print("<red>error<clear>: {s}\n", .{err_msg});
            Zune.debug.print("{s}\n", .{L.debugtrace()});
            return;
        }

        const source_line = info.source_line.?;
        const padding = std.math.log10(source_line) + 1;

        jmp: {
            const source = info.source orelse break :jmp;
            const currentline = info.current_line orelse break :jmp;
            if (source.len < 1 or source[0] != '@')
                break :jmp;
            const strip = try std.fmt.allocPrint(allocator, "{s}:{d}: ", .{
                source[1..],
                currentline,
            });
            defer allocator.free(strip);

            const pos = std.mem.indexOfPosLinear(u8, err_msg, 0, strip);
            if (pos) |p|
                err_msg = err_msg[p + strip.len ..];
        }

        Zune.debug.print("<red>error<clear>: {s}\n", .{err_msg});

        if (Zune.STATE.BUNDLE) |b|
            if (b.mode.compiled == .release)
                return;

        var padding_buf: [12]u8 = undefined;
        if (padding + 1 > padding_buf.len)
            return;
        const padded_string = padding_buf[0 .. padding + 1];

        @memset(padded_string, ' ');

        if (info.source) |src| {
            Zune.debug.print("<bold><underline>{s}:{d}<clear>\n", .{
                if (src.len > 1 and src[0] == '@') src[1..] else src,
                source_line,
            });

            L.getfenv(idx);
            defer L.pop(1); // drop: env
            if (L.typeOf(-1) != .Table) {
                return printPreviewError(padded_string, source_line, "Failed to get function environment", .{});
            }
            defer L.pop(1); // drop: _FILE
            if (L.rawgetfield(-1, "_FILE") != .Table) {
                return printPreviewError(padded_string, source_line, "Failed to get file context", .{});
            }
            defer L.pop(1); // drop: source
            if (L.rawgetfield(-1, "source") != .String) {
                return printPreviewError(padded_string, source_line, "Failed to get file source", .{});
            }
            const content = L.tostring(-1) orelse unreachable;

            var stream = std.io.fixedBufferStream(content);
            const reader = stream.reader();
            if (source_line > 1) for (0..@intCast(source_line - 1)) |_| {
                while (true) {
                    if (reader.readByte() catch |e| {
                        return printPreviewError(padded_string, source_line, "Failed to read line: {}", .{e});
                    } == '\n') break;
                }
            };

            const line_content = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| {
                return printPreviewError(padded_string, source_line, "Failed to read line: {}", .{e});
            } orelse {
                return printPreviewError(padded_string, source_line, "Failed to read line, ended too early", .{});
            };
            defer allocator.free(line_content);

            Zune.debug.print("{s}|\n", .{padded_string});
            _ = std.fmt.bufPrint(padded_string, "{d}", .{source_line}) catch |e| std.debug.panic("{}", .{e});
            if (line_content.len > 128)
                Zune.debug.print("{s}| {s}...\n", .{ padded_string, line_content[0..128] })
            else
                Zune.debug.print("{s}| {s}\n", .{ padded_string, line_content });
            @memset(padded_string, ' ');
            Zune.debug.print("{s}|\n", .{padded_string});
        }
    } else {
        Zune.debug.print("<green>error<clear>: {s}\n", .{err_msg});
        Zune.debug.print("{s}\n", .{L.debugtrace()});
        return;
    }
}

pub fn logFnDef(L: *VM.lua.State, idx: i32) void {
    std.debug.assert(L.typeOf(idx) == .Function);
    logDetailedDef(L, idx) catch |e| std.debug.panic("{}", .{e});
}

pub fn logDetailedError(L: *VM.lua.State) !void {
    const allocator = luau.getallocator(L);

    var list: std.ArrayList(StackInfo) = try .initCapacity(allocator, 4);
    defer list.deinit(allocator);
    defer for (list.items) |item| {
        if (item.name) |name|
            allocator.free(name);
        if (item.source) |source|
            allocator.free(source);
    };

    var level: i32 = 0;
    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    while (L.getinfo(level, "sln", &ar)) : (level += 1) {
        var info: StackInfo = .{
            .what = ar.what,
        };
        if (ar.name) |name|
            info.name = try allocator.dupe(u8, name);
        if (ar.linedefined) |line|
            info.source_line = line;
        if (ar.currentline) |line|
            info.current_line = line;
        info.source = try allocator.dupe(u8, ar.source.?);

        try list.append(allocator, info);
    }

    var err_msg: []const u8 = undefined;
    var error_buf: ?[]const u8 = null;
    defer if (error_buf) |buf| allocator.free(buf);
    switch (L.typeOf(-1)) {
        .String, .Number => err_msg = L.tostring(-1).?,
        else => jmp: {
            if (!try L.checkstack(2)) {
                err_msg = "StackOverflow";
                break :jmp;
            }
            const TL = try L.newthread();
            defer L.pop(1); // drop: thread
            defer TL.resetthread() catch {};
            L.xpush(TL, -2);
            error_buf = try allocator.dupe(u8, TL.Ztolstring(1) catch |e| str: {
                switch (e) {
                    error.BadReturnType => break :str try TL.Ztolstringk(1),
                    error.Runtime => break :str try TL.Ztolstringk(1),
                    else => std.debug.panic("{}\n", .{e}),
                }
                return;
            });
            err_msg = error_buf.?;
        },
    }

    if (list.items.len < 1) {
        Zune.debug.print("<green>error<clear>: {s}\n", .{err_msg});
        if (Zune.STATE.BUNDLE) |b|
            if (b.mode.compiled == .release)
                return;
        Zune.debug.print("{s}\n", .{L.debugtrace()});
        return;
    }

    if (!try L.checkstack(5)) {
        Zune.debug.print("Failed to show detailed error: StackOverflow\n", .{});
        Zune.debug.print("<green>error<clear>: {s}\n", .{err_msg});
        if (Zune.STATE.BUNDLE) |b|
            if (b.mode.compiled == .release)
                return;
        Zune.debug.print("{s}\n", .{L.debugtrace()});
        return;
    }

    var reference_level: ?usize = null;
    jmp: {
        const item = blk: {
            for (list.items, 0..) |item, lvl|
                if (item.what == .lua) {
                    reference_level = lvl;
                    break :blk item;
                };
            break :blk list.items[0];
        };
        const source = item.source orelse break :jmp;
        const currentline = item.current_line orelse break :jmp;
        if (source.len == 0 or source[0] != '@')
            break :jmp;

        const src_len = source[1..].len;
        if (!std.mem.startsWith(u8, err_msg, source[1..]))
            break :jmp;
        var line_buffer: [64]u8 = undefined;
        const line_number = try std.fmt.bufPrint(&line_buffer, ":{d}: ", .{currentline});
        const err_trimmed = err_msg[src_len..];
        if (!std.mem.startsWith(u8, err_trimmed, line_number))
            break :jmp;
        err_msg = err_trimmed[line_number.len..];
    }

    Zune.debug.print("<red>error<clear>: {s}\n", .{err_msg});

    if (Zune.STATE.BUNDLE) |b|
        if (b.mode.compiled == .release)
            return;

    var largest_line: usize = 0;
    for (list.items) |info| {
        if (info.current_line) |line|
            largest_line = @max(largest_line, @as(usize, @intCast(line)));
        if (info.source_line) |line| {
            if (line > 0)
                largest_line = @max(largest_line, @as(usize, @intCast(line)));
        }
    }

    var padding_buf: [12]u8 = undefined;

    const padding = std.math.log10(largest_line) + 1;
    if (padding + 1 > padding_buf.len)
        return;

    const padded_string = padding_buf[0 .. padding + 1];
    @memset(padded_string, ' ');

    for (list.items, 0..) |info, lvl| {
        if (info.current_line == null)
            continue;
        if (info.what != .lua)
            continue;
        if (info.source) |src| blk: {
            const current_line = info.current_line.?;

            Zune.debug.print("<bold><underline>{s}:{d}<clear>\n", .{
                if (src.len > 1 and src[0] == '@') src[1..] else src,
                current_line,
            });

            if (!L.getinfo(@intCast(lvl), "f", &ar)) {
                printPreviewError(padded_string, current_line, "Failed to get function info", .{});
                continue;
            }

            if (L.typeOf(-1) != .Function)
                return error.InternalError;
            L.getfenv(-1);
            defer L.pop(2); // drop: env, func
            if (L.typeOf(-1) != .Table) {
                printPreviewError(padded_string, current_line, "Failed to get function environment", .{});
                continue;
            }
            defer L.pop(1); // drop: _FILE
            if (L.rawgetfield(-1, "_FILE") != .Table) {
                printPreviewError(padded_string, current_line, "Failed to get file context", .{});
                continue;
            }
            defer L.pop(1); // drop: source
            if (L.rawgetfield(-1, "source") != .String) {
                printPreviewError(padded_string, current_line, "Failed to get file source", .{});
                continue;
            }
            const content = L.tostring(-1) orelse unreachable;

            var stream = std.io.fixedBufferStream(content);
            const reader = stream.reader();
            if (current_line > 1) for (0..@intCast(current_line - 1)) |_| {
                while (true) {
                    if (reader.readByte() catch |e| {
                        printPreviewError(padded_string, current_line, "Failed to read line: {}", .{e});
                        break :blk;
                    } == '\n') break;
                }
            };

            const line_content = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| {
                printPreviewError(padded_string, current_line, "Failed to read line: {}", .{e});
                break :blk;
            } orelse {
                printPreviewError(padded_string, current_line, "Failed to read line, ended too early", .{});
                break :blk;
            };
            defer allocator.free(line_content);

            Zune.debug.print("{s}|\n", .{padded_string});
            _ = std.fmt.bufPrint(padded_string, "{d}", .{current_line}) catch |e| std.debug.panic("{}", .{e});
            if (line_content.len > 128)
                Zune.debug.print("{s}| {s}...\n", .{ padded_string, line_content[0..128] })
            else
                Zune.debug.print("{s}| {s}\n", .{ padded_string, line_content });
            @memset(padded_string, ' ');

            if (reference_level != null and reference_level.? == lvl) {
                const front_pos = std.mem.indexOfNonePos(u8, line_content[0..@min(line_content.len, 128)], 0, " \t") orelse 0;
                const end_pos = std.mem.lastIndexOfNone(u8, line_content[0..@min(line_content.len, 128)], " \t\r") orelse front_pos;
                const len = (end_pos - front_pos) + 1;

                var buf: [128]u8 = undefined;
                if (len > buf.len)
                    return Zune.debug.print("{s}|\n", .{padded_string});
                const space_slice = line_content[0..front_pos];

                @memset(buf[0..len], '^');

                Zune.debug.print("{s}| {s}<red>{s}<clear>\n", .{ padded_string, space_slice, buf[0..len] });
            } else {
                Zune.debug.print("{s}|\n", .{padded_string});
            }
        }
    }
}

pub fn logError(L: *VM.lua.State, err: anyerror, forceDetailed: bool) void {
    switch (err) {
        error.Runtime => {
            if (Zune.STATE.USE_DETAILED_ERROR or forceDetailed) {
                logDetailedError(L) catch |e| std.debug.panic("{}", .{e});
            } else {
                switch (L.typeOf(-1)) {
                    .String, .Number => Zune.debug.print("{s}\n", .{L.tostring(-1).?}),
                    else => jmp: {
                        if (!(L.checkstack(2) catch |e| std.debug.panic("{}", .{e}))) {
                            Zune.debug.print("StackOverflow\n", .{});
                        }
                        const TL = L.newthread() catch |e| std.debug.panic("{}", .{e});
                        defer L.pop(1); // drop: thread
                        defer TL.resetthread() catch {};
                        L.xpush(TL, -2);
                        const str = TL.Ztolstring(1) catch |e| str: {
                            switch (e) {
                                error.BadReturnType => break :str TL.Ztolstringk(1) catch |er| std.debug.panic("{}", .{er}),
                                error.Runtime => break :str TL.Ztolstringk(1) catch |er| std.debug.panic("{}", .{er}),
                                else => std.debug.panic("{}\n", .{e}),
                            }
                            break :jmp;
                        };
                        Zune.debug.print("{s}\n", .{str});
                    },
                }
                Zune.debug.print("{s}\n", .{L.debugtrace()});
            }
        },
        else => {
            Zune.debug.print("Error: {}\n", .{err});
        },
    }
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
    sched.deferThread(L, null, 0);
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
