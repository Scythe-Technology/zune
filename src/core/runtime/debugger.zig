const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const Fmt = Zune.Resolvers.Fmt;

const History = @import("../../commands/repl/History.zig");
const Terminal = @import("../../commands/repl/Terminal.zig");

const VM = luau.VM;

pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => true,
        .freebsd => true,
        else => false,
    };
}

const LuaBreakpoint = struct {
    line: i32,
    enabled: bool = false,
    remove: bool = false,
};

const BreakpointState = struct {
    changes: u32 = 0,
    list: std.ArrayListUnmanaged(LuaBreakpoint),
};

pub var ACTIVE = false;

pub var HISTORY: ?*History = null;

pub var BREAKPOINTS = std.StringHashMap(BreakpointState).init(Zune.DEFAULT_ALLOCATOR);
pub var MAPPED_SOURCES = std.StringHashMap([]const u8).init(Zune.DEFAULT_ALLOCATOR);
var CHANGES_COUNT: u32 = 0;

const DEBUG_TAG = "\x1b[0m(dbg) ";
const DEBUG_RESULT_TAG = "\x1b[0m(dbg): ";

var MAIN_MUTEX: std.Thread.Mutex = .{};

pub fn SigInt() void {
    if (HISTORY) |history| {
        history.deinit();
        HISTORY = null;
    }
}

pub fn DebuggerExit() void {
    SigInt();
}

pub fn fileSourceOr(maybeSrc: ?[]const u8) ?[]const u8 {
    const src = maybeSrc orelse return null;
    if (src.len == 0)
        return null;
    if (!std.mem.startsWith(u8, src, "@"))
        return src;
    const rest = src[1..];
    if (rest.len == 0)
        return null;
    return rest;
}

pub fn updateBreakpoints(L: *VM.lua.State) !void {
    if (CHANGES_COUNT == 0)
        return;
    try L.rawcheckstack(1);
    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    {
        var level: i32 = 0;
        while (true) : (level += 1) {
            if (!L.getinfo(level, "sf", &ar))
                return error.NoSource;
            if (ar.what == .lua)
                break;
            L.pop(1);
        }
    }
    defer L.pop(1);

    const path = ar.source orelse "";
    if (!std.mem.startsWith(u8, path, "@"))
        return error.InvalidPath;

    const file_path = path[1..];
    if (file_path.len == 0)
        return error.InvalidPath;

    const abs_path = MAPPED_SOURCES.get(path) orelse if (std.fs.path.isAbsolute(file_path)) blk: {
        try MAPPED_SOURCES.put(path, file_path);
        break :blk file_path;
    } else blk: {
        const real_path = try std.fs.cwd().realpathAlloc(MAPPED_SOURCES.allocator, path[1..]);
        try MAPPED_SOURCES.put(path, real_path);
        break :blk real_path;
    };
    if (BREAKPOINTS.getEntry(abs_path)) |entry| {
        const breakpoints = entry.value_ptr;
        if (breakpoints.changes == 0)
            return; // no changes
        for (breakpoints.list.items) |*bp| {
            if (bp.remove) {
                std.debug.assert(bp.enabled == true); // in cases its disabled, should be removed at the removeBreakpoint call
                const target = L.breakpoint(-1, bp.line, false);
                if (target == -1)
                    @panic("Debugger no target or closest line found");
                if (target != bp.line) {
                    if (getExactBreakpoint(&breakpoints.list, target)) |e|
                        _ = L.breakpoint(-1, target, e[0].enabled); // re-add breakpoint
                }
                CHANGES_COUNT -= 1;
                breakpoints.changes -= 1;
                continue;
            }
            if (bp.enabled == true)
                continue; // already set
            bp.enabled = true;
            const target = L.breakpoint(-1, bp.line, true);
            defer CHANGES_COUNT -= 1;
            defer breakpoints.changes -= 1;
            if (target == -1)
                @panic("Debugger no target or closest line found");
            if (target == bp.line)
                continue;
            const exact = getExactBreakpoint(&breakpoints.list, target);
            if (exact == null or !exact.?[0].enabled)
                _ = L.breakpoint(-1, target, false); // remove breakpoint unwanted
        }
        out: while (true) {
            for (breakpoints.list.items, 0..) |bp, id| {
                if (bp.remove) {
                    _ = breakpoints.list.orderedRemove(id);
                    break;
                }
            }
            break :out;
        }
    }
}

pub fn getExactBreakpoint(breakpoints: *std.ArrayListUnmanaged(LuaBreakpoint), line: i32) ?struct { *LuaBreakpoint, usize } {
    for (breakpoints.items, 0..) |*bp, i| {
        if (bp.line == line)
            return .{ bp, i };
    }
    return null;
}

const BreakpointResult = enum {
    saved,
    exists,
};
pub fn addBreakpoint(path: []const u8, line: i32) !BreakpointResult {
    const allocator = BREAKPOINTS.allocator;
    const key = try allocator.dupe(u8, path);
    errdefer allocator.free(key);
    const breakpoints = list: {
        const entry = BREAKPOINTS.getEntry(key) orelse e: {
            try BREAKPOINTS.put(key, .{
                .changes = 0,
                .list = .empty,
            });
            break :e BREAKPOINTS.getEntry(key) orelse unreachable;
        };
        break :list entry.value_ptr;
    };
    const breakpoint: LuaBreakpoint = .{ .line = line };
    if (getExactBreakpoint(&breakpoints.list, line)) |entry| {
        const bp, _ = entry;
        if (bp.remove)
            bp.remove = false; // re-add breakpoint
        return .exists;
    }
    CHANGES_COUNT += 1;
    breakpoints.changes += 1;
    try breakpoints.list.append(allocator, breakpoint);
    return .saved;
}

pub fn removeBreakpoint(path: []const u8, line: i32) bool {
    const breakpoints = list: {
        const entry = BREAKPOINTS.getEntry(path) orelse return false;
        break :list entry.value_ptr;
    };
    if (getExactBreakpoint(&breakpoints.list, line)) |entry| {
        const bp, const id = entry;
        if (!bp.enabled) {
            _ = breakpoints.list.orderedRemove(id);
        } else {
            bp.remove = true;
            CHANGES_COUNT += 1;
            breakpoints.changes += 1;
        }
        return true;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    Zune.debug.print(DEBUG_TAG ++ fmt, args);
}

pub fn printResult(comptime fmt: []const u8, args: anytype) void {
    Zune.debug.print(DEBUG_RESULT_TAG ++ fmt, args);
}

const COMMAND_MAP = std.StaticStringMap(enum {
    help,
    exit,
    @"break",
    modules,
    line,
    file,
    trace,
    step,
    step_out,
    step_instruction,
    next,
    locals,
    params,
    upvalues,
    globals,
    run,
    restart,
    output_mode,
    exception,
}).initComptime(.{
    .{ "help", .help },
    .{ "exit", .exit },
    .{ "break", .@"break" },
    .{ "modules", .modules },
    .{ "line", .line },
    .{ "file", .file },
    .{ "trace", .trace },

    .{ "s", .step },
    .{ "step", .step },

    .{ "si", .step_instruction },
    .{ "stepi", .step_instruction },
    .{ "stepinsn", .step_instruction },

    .{ "so", .step_out },
    .{ "stepo", .step_out },
    .{ "stepout", .step_out },

    .{ "n", .next },
    .{ "next", .next },

    .{ "run", .run },

    .{ "locals", .locals },
    .{ "params", .params },
    .{ "upvalues", .upvalues },
    .{ "globals", .globals },

    .{ "restart", .restart },
    .{ "output", .output_mode },
    .{ "exception", .exception },
});

const BREAK_COMMAND_MAP = std.StaticStringMap(enum {
    help,
    add,
    remove,
    clear,
    list,
}).initComptime(.{
    .{ "help", .help },
    .{ "+", .add },
    .{ "add", .add },
    .{ "-", .remove },
    .{ "rm", .remove },
    .{ "remove", .remove },
    .{ "clear", .clear },
    .{ "list", .list },
});

const LOCALS_COMMAND_MAP = std.StaticStringMap(enum {
    help,
    list,
}).initComptime(.{
    .{ "help", .help },
    .{ "list", .list },
});

fn tostring(L: *VM.lua.State, idx: i32) []const u8 {
    switch (L.typeOf(idx)) {
        .Nil => L.pushlstring("nil") catch |e| std.debug.panic("{}", .{e}),
        .Boolean => L.pushlstring(if (L.toboolean(idx)) "true" else "false") catch |e| std.debug.panic("{}", .{e}),
        .Number => {
            const number = L.tonumber(idx).?;
            var s: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
            const buf = std.fmt.bufPrint(&s, "{d}", .{number}) catch unreachable; // should be able to fit
            L.pushlstring(buf) catch |e| std.debug.panic("{}", .{e});
        },
        .Vector => {
            const vec = L.tovector(idx).?;
            var s: [(std.fmt.float.bufferSize(.decimal, f64) * VM.lua.config.VECTOR_SIZE) + ((VM.lua.config.VECTOR_SIZE - 1) * 2)]u8 = undefined;
            const buf = if (VM.lua.config.VECTOR_SIZE == 3)
                std.fmt.bufPrint(&s, "{d}, {d}, {d}", .{ vec[0], vec[1], vec[2] }) catch unreachable // should be able to fit
            else
                std.fmt.bufPrint(&s, "{d}, {d}, {d}, {d}", .{ vec[0], vec[1], vec[2], vec[3] }) catch unreachable; // should be able to fit
            L.pushlstring(buf) catch |e| std.debug.panic("{}", .{e});
        },
        .String => L.pushvalue(idx),
        else => {
            const ptr = L.topointer(idx).?;
            const size = comptime res: {
                var large = 0;
                for (VM.ltm.typenames) |name|
                    large = @max(large, name.len);
                break :res large;
            };
            var s: [20 + size]u8 = undefined; // 16 + 2 + 2(extra) + size
            const buf = std.fmt.bufPrint(&s, "{s}: 0x{x:016}", .{ VM.lapi.typename(L.typeOf(idx)), @intFromPtr(ptr) }) catch unreachable; // should be able to fit
            L.pushlstring(buf) catch |e| std.debug.panic("{}", .{e});
        },
    }
    return L.tolstring(-1).?;
}

fn getNextArg(buf: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimLeft(u8, buf, " ");
    const idx = std.mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
    return .{ trimmed[0..idx], trimmed[idx..] };
}

fn toBase64(allocator: std.mem.Allocator, input: []const u8) !struct { []u8, []const u8 } {
    const base64_buf = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(input.len));
    return .{ base64_buf, std.base64.standard.Encoder.encode(base64_buf, input) };
}

fn promptOpBreak(allocator: std.mem.Allocator, break_args: []const u8) !void {
    if (break_args.len <= 0) {
        printResult("<red>usage<clear>: break <<command>>\n", .{});
        printResult("  <dim>try 'break help'<clear>\n", .{});
        return;
    }
    const command_input, const rest = getNextArg(break_args);
    switch (BREAK_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown break command\n", .{});
    }) {
        .help => {
            printResult("Break Commands:\n", .{});
            printResult("  <bold>help<clear>   - Show sub-commands\n", .{});
            printResult("  <bold>add<clear>    - Add a breakpoint\n", .{});
            printResult("  <bold>remove<clear> - Remove a breakpoint\n", .{});
            printResult("  <bold>clear<clear>  - Clear breakpoints\n", .{});
            printResult("  <bold>list<clear>   - List breakpoints\n", .{});
        },
        .add, .remove => |k| {
            if (rest.len <= 0)
                return printResult("<red>usage<clear>: break {s} <<file>>:<<line>>\n", .{command_input});
            const dir = std.fs.cwd();
            var args = std.mem.splitBackwardsScalar(u8, rest, ':');
            const line_str = std.mem.trim(u8, args.first(), " ");
            const file_str = std.mem.trim(u8, args.rest(), " ");
            if (line_str.len == 0 or file_str.len == 0)
                return printResult("<red>usage<clear>: break {s} <<file>>:<<line>>\n", .{command_input});
            const line = std.fmt.parseInt(i32, line_str, 10) catch |err| {
                return printResult("Line Parse Error: {}\n", .{err});
            };
            const file_path = dir.realpathAlloc(allocator, file_str) catch |err| switch (err) {
                error.FileNotFound => return printResult("file not found: {s}\n", .{file_str}),
                else => return printResult("failed to resolve file '{s}': {}\n", .{ file_str, err }),
            };
            defer allocator.free(file_path);

            if (k == .remove) {
                if (removeBreakpoint(file_path, line)) {
                    if (DEBUG.output == .Readable)
                        printResult("Removed breakpoint, line: {}\n", .{line});
                } else {
                    if (DEBUG.output == .Readable)
                        printResult("Breakpoint does not exist.\n", .{});
                }
                if (DEBUG.output == .Json)
                    printResult("{d}\n", .{line});
            } else {
                const result = try addBreakpoint(file_path, line);
                switch (DEBUG.output) {
                    .Readable => {
                        switch (result) {
                            .saved => printResult("Added breakpoint, line: {}.\n", .{line}),
                            .exists => printResult("Breakpoint already exists, line: {}.\n", .{line}),
                        }
                    },
                    .Json => printResult("{d}\n", .{line}),
                }
            }
        },
        .clear => {
            var iter = BREAKPOINTS.iterator();
            var count: usize = 0;
            while (iter.next()) |breakpoints| {
                const bps = breakpoints.value_ptr.list.items;
                var i = bps.len;
                count += i;
                while (i > 0) : (i -= 1)
                    _ = removeBreakpoint(breakpoints.key_ptr.*, bps[i - 1].line);
            }
            switch (DEBUG.output) {
                .Readable => printResult("Cleared all breakpoints.\n", .{}),
                .Json => printResult("{d}\n", .{count}),
            }
        },
        .list => {
            if (DEBUG.output == .Json)
                return;
            if (rest.len <= 0) {
                printResult("Breakpoints:\n", .{});
                var order: usize = 0;
                var iter = BREAKPOINTS.iterator();
                while (iter.next()) |entry| {
                    const file_str = entry.key_ptr.*;
                    const breakpoints = entry.value_ptr;
                    if (breakpoints.list.items.len == 0)
                        continue;
                    printResult("  {d}:\n", .{order});
                    for (breakpoints.list.items, 0..) |bp, i| {
                        printResult("    <dim>{d}:<clear> <bold>{s}:{d}<clear>\n", .{ i, file_str, bp.line });
                    }
                    order += 1;
                }
            } else {
                const file_str = std.mem.trim(u8, rest, " ");
                if (BREAKPOINTS.getEntry(file_str)) |entry| {
                    const breakpoints = entry.value_ptr;
                    if (breakpoints.list.items.len == 0) {
                        printResult("No breakpoints for '{s}'\n", .{file_str});
                        return;
                    }
                    printResult("Breakpoints:\n", .{});
                    for (breakpoints.list.items, 0..) |bp, i|
                        printResult("  <dim>{d}:<clear> <bold>{s}:{d}<clear>\n", .{ i, file_str, bp.line });
                } else {
                    printResult("No breakpoints for '{s}'\n", .{file_str});
                }
            }
        },
    }
}

// 5 stack needed
fn variableJsonDisassemble(allocator: std.mem.Allocator, L: *VM.lua.State, iter: *std.mem.SplitIterator(u8, .scalar), writer: anytype) !bool {
    while (iter.next()) |iter_i| {
        if (L.typeOf(-1) != .Table) {
            printResult("[]\n", .{}); // variable not a table
            return false;
        }
        var order: u32 = 1;
        const id = std.fmt.parseInt(u32, iter_i, 10) catch |err| {
            printResult("Id Parse Error: {}\n", .{err});
            return false;
        };
        out: {
            var i: i32 = L.rawiter(-1, 0);
            while (i >= 0) : (i = L.rawiter(-1, i)) {
                order += 1;
                if (order == id)
                    break :out;
                L.pop(2);
            }
            printResult("[]\n", .{}); // leads no where
            return false;
        }
        L.remove(-2); // remove key
        L.remove(-2); // remove old value (local/ref)
    }
    if (L.typeOf(-1) != .Table) {
        printResult("[]\n", .{}); // variable not a table
        return false;
    }
    var first = false;
    var order: u32 = 1;
    var i: i32 = L.rawiter(-1, 0);
    while (i >= 0) : (i = L.rawiter(-1, i)) {
        order += 1;
        defer L.pop(2);
        if (first)
            try writer.writeByte(',');
        first = true;
        const key_typename = VM.lapi.typename(L.typeOf(-2));
        const value_typename = VM.lapi.typename(L.typeOf(-1));
        const key_str = tostring(L, -2);
        const value = tostring(L, -2);
        defer L.pop(2);

        const key_base64_buf, const base64_key = try toBase64(allocator, key_str);
        defer allocator.free(key_base64_buf);
        const value_base64_buf, const base64_value = try toBase64(allocator, value);
        defer allocator.free(value_base64_buf);

        try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"{s}\",\"value_type\":\"{s}\"}}", .{
            order,
            base64_key,
            base64_value,
            key_typename,
            value_typename,
        });
    }
    return true;
}

fn promptOpLocals(L: *VM.lua.State, allocator: std.mem.Allocator, locals_args: []const u8) !void {
    if (locals_args.len <= 0) {
        printResult("<red>usage<clear>: locals <<command>>\n", .{});
        printResult("  <dim>try 'locals help'<clear>\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(locals_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown locals command\n", .{});
    }) {
        .help => { // locals help
            printResult("Locals Commands:\n", .{});
            printResult("  <bold>help<clear> - Show sub-commands\n", .{});
            printResult("  <bold>list<clear> - List locals and their value (if argument is passed to locals command)\n", .{});
        },
        .list => { // locals list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            switch (DEBUG.output) {
                .Readable => {
                    try L.rawcheckstack(2);
                    var i: i32 = 1;
                    var showed: bool = false;
                    while (true) : (i += 1) {
                        if (L.getlocal(level, i)) |name| {
                            defer L.pop(1);
                            showed = true;
                            printResult(" {d} ->> {s} ({s})\n", .{ i, name, @tagName(L.typeOf(-1)) });
                            if (level_in.len == 0)
                                continue;

                            var allocating: std.Io.Writer.Allocating = .init(allocator);
                            defer allocating.deinit();

                            const writer = &allocating.writer;

                            try Fmt.writeIdx(allocator, L, writer, @intCast(L.gettop()), Zune.STATE.FORMAT.MAX_DEPTH);
                            var iter = std.mem.splitScalar(u8, allocating.written(), '\n');
                            printResult(" | Value: {s}\n", .{iter.first()});
                            while (iter.next()) |line|
                                printResult(" |  {s}\n", .{line});
                        } else break;
                    }
                    if (!showed)
                        printResult("No locals found.\n", .{});
                },
                .Json => {
                    try L.rawcheckstack(6);
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var allocating: std.Io.Writer.Allocating = .init(allocator);
                    defer allocating.deinit();

                    const writer = &allocating.writer;

                    try writer.writeByte('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        const initial_idx = std.fmt.parseInt(u32, first_iter, 10) catch |err| {
                            return printResult("Id Parse Error: {}\n", .{err});
                        };
                        _ = L.getlocal(level, @intCast(initial_idx)) orelse {
                            return printResult("[]\n", .{});
                        };
                        defer L.pop(1);
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var i: i32 = 1;
                        var first = false;
                        while (true) : (i += 1) {
                            if (L.getlocal(level, i)) |name| {
                                defer L.pop(1);
                                if (first)
                                    try writer.writeByte(',');
                                first = true;
                                const typename = VM.lapi.typename(L.typeOf(-1));
                                const value = tostring(L, -1);
                                defer L.pop(1);

                                const value_base64_buf, const base64_value = try toBase64(allocator, value);
                                defer allocator.free(value_base64_buf);
                                try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                    i,
                                    name,
                                    base64_value,
                                    typename,
                                });
                            } else break;
                        }
                    }
                    try writer.writeByte(']');
                    printResult("{s}\n", .{allocating.written()});
                },
            }
        },
    }
}

fn promptOpParams(L: *VM.lua.State, allocator: std.mem.Allocator, params_args: []const u8) !void {
    if (params_args.len <= 0) {
        printResult("<red>usage<clear>: params <<command>>\n", .{});
        printResult("  <dim>try 'params help'<clear>\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(params_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown params command\n", .{});
    }) {
        .help => { // params help
            printResult("Params Commands:\n", .{});
            printResult("  <bold>help<clear> - Show sub-commands\n", .{});
            printResult("  <bold>list<clear> - List params and their value (if argument is passed to params command)\n", .{});
        },
        .list => { // params list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
            switch (DEBUG.output) {
                .Readable => {
                    try L.rawcheckstack(2);
                    if (!L.getinfo(level, "a", &ar))
                        return printResult("no function found.\n", .{}); // nothing
                    var i: i32 = 1;
                    var showed: bool = false;
                    while (true) : (i += 1) {
                        if (L.getargument(level, i)) {
                            defer L.pop(1);
                            showed = true;
                            if (i > ar.nparams)
                                printResult(" {d} ->> vararg: ({s})\n", .{ i, @tagName(L.typeOf(-1)) })
                            else
                                printResult(" {d} ->> ({s})\n", .{ i, @tagName(L.typeOf(-1)) });
                            if (level_in.len == 0)
                                continue;

                            var allocating: std.Io.Writer.Allocating = .init(allocator);
                            defer allocating.deinit();

                            const writer = &allocating.writer;

                            try Fmt.writeIdx(allocator, L, writer, @intCast(L.gettop()), Zune.STATE.FORMAT.MAX_DEPTH);
                            var iter = std.mem.splitScalar(u8, allocating.written(), '\n');
                            printResult(" | Value: {s}\n", .{iter.first()});
                            while (iter.next()) |line|
                                printResult(" |  {s}\n", .{line});
                        } else break;
                    }
                    if (!showed)
                        printResult("No params found.\n", .{});
                },
                .Json => {
                    try L.rawcheckstack(6);
                    if (!L.getinfo(level, "a", &ar))
                        return printResult("[]\n", .{}); // nothing
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var allocating: std.Io.Writer.Allocating = .init(allocator);
                    defer allocating.deinit();

                    const writer = &allocating.writer;

                    try writer.writeByte('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        const initial_idx = std.fmt.parseInt(u32, first_iter, 10) catch |err| {
                            return printResult("Id Parse Error: {}\n", .{err});
                        };
                        if (!L.getargument(level, @intCast(initial_idx)))
                            return printResult("[]\n", .{});
                        defer L.pop(1);
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var i: i32 = 1;
                        var first = false;
                        while (true) : (i += 1) {
                            if (L.getargument(level, i)) {
                                defer L.pop(1);
                                if (first)
                                    try writer.writeByte(',');
                                first = true;
                                const typename = VM.lapi.typename(L.typeOf(-1));
                                const value = tostring(L, -1);
                                defer L.pop(1);

                                const value_base64_buf, const base64_value = try toBase64(allocator, value);
                                defer allocator.free(value_base64_buf);
                                if (i > ar.nparams)
                                    try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                        i,
                                        "var",
                                        base64_value,
                                        typename,
                                    })
                                else
                                    try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                        i,
                                        "param",
                                        base64_value,
                                        typename,
                                    });
                            } else break;
                        }
                    }
                    try writer.writeByte(']');
                    printResult("{s}\n", .{allocating.written()});
                },
            }
        },
    }
}

fn promptOpUpvalues(L: *VM.lua.State, allocator: std.mem.Allocator, params_args: []const u8) !void {
    if (params_args.len <= 0) {
        printResult("<red>usage<clear>: upvalues <<command>>\n", .{});
        printResult("  <dim>try 'upvalues help'<clear>\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(params_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown upvalues command\n", .{});
    }) {
        .help => { // upvalues help
            printResult("Upvalues Commands:\n", .{});
            printResult("  <bold>help<clear> - Show sub-commands\n", .{});
            printResult("  <bold>list<clear> - List upvalues and their value (if argument is passed to upvalues command)\n", .{});
        },
        .list => { // upvalues list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
            switch (DEBUG.output) {
                .Readable => {
                    try L.rawcheckstack(3);
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("no function found.\n", .{}); // nothing
                    defer L.pop(1); // remove function
                    const fn_idx = L.gettop();
                    var i: u32 = 1;
                    var showed: bool = false;
                    while (true) : (i += 1) {
                        if (L.getupvalue(@intCast(fn_idx), i)) |name| {
                            defer L.pop(1);
                            showed = true;
                            printResult(" {d} ->> {s} ({s})\n", .{ i, name, @tagName(L.typeOf(-1)) });
                            if (level_in.len == 0)
                                continue;

                            var allocating: std.Io.Writer.Allocating = .init(allocator);
                            defer allocating.deinit();

                            const writer = &allocating.writer;

                            try Fmt.writeIdx(allocator, L, writer, @intCast(L.gettop()), Zune.STATE.FORMAT.MAX_DEPTH);
                            var iter = std.mem.splitScalar(u8, allocating.written(), '\n');
                            printResult(" | Value: {s}\n", .{iter.first()});
                            while (iter.next()) |line|
                                printResult(" |  {s}\n", .{line});
                        } else break;
                    }
                    if (!showed)
                        printResult("No upvalue found.\n", .{});
                },
                .Json => {
                    try L.rawcheckstack(7);
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("[]\n", .{}); // nothing
                    defer L.pop(1); // remove function
                    const fn_idx = L.gettop();
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var allocating: std.Io.Writer.Allocating = .init(allocator);
                    defer allocating.deinit();

                    const writer = &allocating.writer;

                    try writer.writeByte('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        const initial_idx = std.fmt.parseInt(u32, first_iter, 10) catch |err| {
                            return printResult("Id Parse Error: {}\n", .{err});
                        };
                        _ = L.getupvalue(@intCast(fn_idx), @intCast(initial_idx)) orelse {
                            return printResult("[]\n", .{});
                        };
                        defer L.pop(1);
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var i: u32 = 1;
                        var first = false;
                        while (true) : (i += 1) {
                            if (L.getupvalue(@intCast(fn_idx), i)) |name| {
                                defer L.pop(1);
                                if (first)
                                    try writer.writeByte(',');
                                first = true;
                                const typename = VM.lapi.typename(L.typeOf(-1));
                                const value = tostring(L, -1);
                                defer L.pop(1);

                                const value_base64_buf, const base64_value = try toBase64(allocator, value);
                                defer allocator.free(value_base64_buf);
                                try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                    i,
                                    name,
                                    base64_value,
                                    typename,
                                });
                            } else break;
                        }
                    }
                    try writer.writeByte(']');
                    printResult("{s}\n", .{allocating.written()});
                },
            }
        },
    }
}

fn promptOpGlobals(L: *VM.lua.State, allocator: std.mem.Allocator, globals_args: []const u8) !void {
    if (globals_args.len <= 0) {
        printResult("<red>usage<clear>: globals <<command>>\n", .{});
        printResult("  <dim>try 'globals help'<clear>\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(globals_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown globals command\n", .{});
    }) {
        .help => { // globals help
            printResult("Globals Commands:\n", .{});
            printResult("  <bold>help<clear> - Show sub-commands\n", .{});
            printResult("  <bold>list<clear> - List globals and their value (if argument is passed to globals command)\n", .{});
        },
        .list => { // globals list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
            switch (DEBUG.output) {
                .Readable => {
                    try L.rawcheckstack(4);
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("no function found.\n", .{}); // nothing
                    L.getfenv(-1);
                    defer L.pop(1); // remove env
                    L.remove(-2); // remove function
                    if (L.typeOf(-1) != .Table)
                        return printResult("global is not a table.\n", .{}); // invalid
                    var showed: bool = false;
                    var i: i32 = L.rawiter(-1, 0);
                    while (i >= 0) : (i = L.rawiter(-1, i)) {
                        defer L.pop(2);
                        showed = true;
                        const key = tostring(L, -2);
                        defer L.pop(1);
                        printResult(" {s} ->> ({s})\n", .{ key, @tagName(L.typeOf(-1)) });
                        if (level_in.len == 0)
                            continue;

                        var allocating: std.Io.Writer.Allocating = .init(allocator);
                        defer allocating.deinit();

                        const writer = &allocating.writer;

                        try Fmt.writeIdx(allocator, L, writer, @intCast(L.gettop()), Zune.STATE.FORMAT.MAX_DEPTH);
                        var iter = std.mem.splitScalar(u8, allocating.written(), '\n');
                        printResult(" | Value: {s}\n", .{iter.first()});
                        while (iter.next()) |line|
                            printResult(" |  {s}\n", .{line});
                    }
                    if (!showed)
                        printResult("No globals found.\n", .{});
                },
                .Json => {
                    try L.rawcheckstack(7);
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("[]\n", .{}); // nothing
                    L.getfenv(-1);
                    defer L.pop(1); // remove env
                    L.remove(-2); // remove function
                    if (L.typeOf(-1) != .Table)
                        return printResult("[]\n", .{}); // invalid
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var allocating: std.Io.Writer.Allocating = .init(allocator);
                    defer allocating.deinit();

                    const writer = &allocating.writer;

                    try writer.writeByte('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        iter.reset();
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var order: u32 = 1;
                        var first = false;
                        var i: i32 = L.rawiter(-1, 0);
                        while (i >= 0) : (i = L.rawiter(-1, i)) {
                            defer L.pop(4); // remove str_value, str_key, value, key
                            order += 1;
                            if (first)
                                try writer.writeByte(',');
                            first = true;
                            const key_typename = VM.lapi.typename(L.typeOf(-2));
                            const value_typename = VM.lapi.typename(L.typeOf(-1));
                            const key = tostring(L, -2);
                            const value = tostring(L, -2);

                            const key_base64_buf, const base64_key = try toBase64(allocator, key);
                            defer allocator.free(key_base64_buf);
                            const value_base64_buf, const base64_value = try toBase64(allocator, value);
                            defer allocator.free(value_base64_buf);
                            try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"{s}\",\"value_type\":\"{s}\"}}", .{
                                order,
                                base64_key,
                                base64_value,
                                key_typename,
                                value_typename,
                            });
                        }
                    }
                    try writer.writeByte(']');
                    printResult("{s}\n", .{allocating.written()});
                },
            }
        },
    }
}

const StepMode = enum {
    Step,
    Run,
};

const OutputMode = enum {
    Readable,
    Json,
};

const BreakKind = enum {
    None,
    Breakpoint,
    Stepped,
    HandledException,
    UnhandledException,
};

const DebugState = struct {
    depth: ?usize = null,
    line: ?usize = null,
    step: StepMode = .Step,
    output: OutputMode = .Readable,
    dead: bool = false,
    handled_exception: bool = false,
    unhandled_exception: bool = false,
};
pub var DEBUG: DebugState = .{};

pub fn prompt(L: *VM.lua.State, comptime kind: BreakKind, debug_info: ?*VM.lua.c.lua_Debug) !void {
    const allocator = luau.getallocator(L);

    var stdin = std.fs.File.stdin();
    var buf: [128]u8 = undefined;
    var stdin_reader = stdin.reader(&buf);
    var reader = &stdin_reader.interface;

    const terminal = &(Zune.corelib.io.TERMINAL orelse std.debug.panic("Terminal not initialized", .{}));
    const history = HISTORY orelse std.debug.panic("History not initialized", .{});

    var input_buffer: std.ArrayList(u8) = .empty;
    defer input_buffer.deinit(allocator);

    var position: usize = 0;

    try terminal.setRawMode();
    try terminal.setOutputMode();

    if (DEBUG.output == .Readable) {
        switch (kind) {
            .None => {},
            .Breakpoint, .Stepped => |k| {
                const ar = debug_info orelse std.debug.panic(DEBUG_RESULT_TAG ++ "Debugger crashed, missing debug info for breakpoint", .{});
                if (k == .Breakpoint)
                    printResult("break at line: {d}\n", .{ar.currentline})
                else
                    printResult("step at line: {d}\n", .{ar.currentline});
            },
            .HandledException => printResult("break on handled exception\n", .{}),
            .UnhandledException => printResult("break on unhandled exception\n", .{}),
        }
    } else {
        switch (kind) {
            .None => {},
            .Breakpoint, .Stepped => |k| {
                const ar = debug_info orelse std.debug.panic(DEBUG_RESULT_TAG ++ "Debugger crashed, missing debug info for breakpoint", .{});
                printResult("{{\"break\":{d},\"line\":{d}}}\n", .{ @intFromEnum(k), ar.currentline });
            },
            .HandledException, .UnhandledException => printResult("{{\"break\":{d},\"line\":null}}\n", .{@intFromEnum(kind)}),
        }
    }
    std.debug.print(DEBUG_TAG, .{});

    while (true) {
        switch (try reader.takeByte()) {
            0x1B => {
                if (try reader.takeByte() != '[')
                    continue;
                var currentByte = try reader.takeByte();
                var modifier: Terminal.MODIFIER = .{};
                switch (currentByte) {
                    '1' => {
                        if (try reader.takeByte() != ';')
                            continue;
                        switch (try reader.takeByte()) {
                            '2' => modifier = .init(false, true, false),
                            '3' => modifier = .init(false, false, true),
                            '4' => modifier = .init(false, true, true),
                            '5' => modifier = .init(true, false, false),
                            '6' => modifier = .init(true, false, true),
                            else => continue,
                        }
                        currentByte = try reader.takeByte();
                    },
                    else => {},
                }
                switch (currentByte) {
                    'A' => { // Up Arrow
                        if (history.size() == 0)
                            continue;
                        if (history.isLatest())
                            history.saveTemp(input_buffer.items);
                        if (history.previous()) |line| {
                            input_buffer.clearRetainingCapacity();
                            try input_buffer.appendSlice(allocator, line);
                            position = line.len;

                            try terminal.clearLine();
                            print("{s}", .{input_buffer.items});
                        }
                    },
                    'B' => { // Down Arrow
                        if (history.next()) |line| {
                            input_buffer.clearRetainingCapacity();
                            try input_buffer.appendSlice(allocator, line);
                            position = line.len;

                            try terminal.clearLine();
                            print("{s}", .{input_buffer.items});
                        }
                        if (history.isLatest())
                            history.clearTemp();
                    },
                    'C' => { // Right Arrow
                        const written = input_buffer.items;
                        if (position == written.len)
                            continue;
                        if (modifier.onlyCtrl()) {
                            const slice = written[position..];
                            const front = std.mem.indexOfAny(u8, slice, Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Right, slice.len);
                                position = written.len;
                                continue;
                            };
                            const index = (std.mem.indexOfNone(u8, slice[front..], Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Right, slice.len);
                                position = written.len;
                                continue;
                            }) + front;
                            try terminal.moveCursor(.Right, index);
                            position += index;
                        } else if (modifier.none()) {
                            try terminal.moveCursor(.Right, 1);
                            position += 1;
                        }
                    },
                    'D' => { // Left Arrow
                        if (position == 0)
                            continue;
                        const written = input_buffer.items;
                        if (modifier.onlyCtrl()) {
                            const slice = written[0..position];
                            const back = std.mem.lastIndexOfNone(u8, slice, Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Left, @intCast(position));
                                position = 0;
                                continue;
                            };
                            const index = slice.len - (std.mem.lastIndexOfAny(u8, slice[0..back], Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Left, @intCast(position));
                                position = 0;
                                continue;
                            }) - 1;
                            try terminal.moveCursor(.Left, index);
                            position -= index;
                        } else if (modifier.none()) {
                            try terminal.moveCursor(.Left, 1);
                            position -= 1;
                        }
                    },
                    else => |b| std.debug.print("Unknown escape sequence: {d}\n", .{b}),
                }
            },
            Terminal.NEW_LINE => {
                std.debug.print("\n", .{});
                out: {
                    defer position = 0;
                    defer input_buffer.clearRetainingCapacity();

                    defer history.reset();

                    const written = input_buffer.items;

                    if (written.len == 0)
                        break :out;

                    history.save(written);

                    const command_input, const rest = getNextArg(written);
                    switch (COMMAND_MAP.get(command_input) orelse {
                        break :out printResult("unknown command '{s}'\n", .{command_input});
                    }) {
                        .help => {
                            printResult("Commands:\n", .{});
                            printResult("  <bold>help<clear>      - Display this message\n", .{});
                            printResult("  <bold>exit<clear>      - Terminate debugger\n", .{});
                            printResult("  <bold>break<clear>     - modify Breakpoint\n", .{});
                            printResult("  <bold>modules<clear>   - Loaded modules\n", .{});
                            printResult("  <bold>line<clear>      - Show current line\n", .{});
                            printResult("  <bold>file<clear>      - Show current file\n", .{});
                            printResult("  <bold>trace<clear>     - Show stack trace\n", .{});
                            printResult("  <bold>step<clear>      - Step into\n", .{});
                            printResult("  <bold>stepi<clear>     - Step instruction\n", .{});
                            printResult("  <bold>stepo<clear>     - Step out\n", .{});
                            printResult("  <bold>next<clear>      - Step over\n", .{});
                            printResult("  <bold>run<clear>       - Continue execution\n", .{});
                            printResult("  <bold>locals<clear>    - Local variables\n", .{});
                            printResult("  <bold>params<clear>    - Parameters\n", .{});
                            printResult("  <bold>upvalues<clear>  - Upvalues\n", .{});
                            printResult("  <bold>globals<clear>   - Global variables\n", .{});
                            printResult("  <bold>restart<clear>   - Restart execution\n", .{});
                            printResult("  <bold>exception<clear> - Show current error\n", .{});
                        },
                        .exit => {
                            DebuggerExit();
                            std.process.exit(0);
                        },
                        .line => {
                            if (debug_info) |ar| {
                                if (ar.currentline > 0)
                                    printResult("current line: {d}\n", .{ar.currentline})
                                else
                                    printResult("unknown line (C call)\n", .{});
                                break :out;
                            }
                            printResult("No debug info available\n", .{});
                        },
                        .file => {
                            var source: ?[]const u8 = null;
                            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
                            if (L.getinfo(0, "sn", &ar))
                                source = ar.source;
                            if (source == null or !std.mem.startsWith(u8, source.?, "@")) {
                                switch (DEBUG.output) {
                                    .Readable => printResult("file info not available.\n", .{}),
                                    .Json => printResult("null\n", .{}),
                                }
                                break :out;
                            }
                            const dir = std.fs.cwd();
                            const path = dir.realpathAlloc(allocator, source.?[1..]) catch |err| switch (err) {
                                error.FileNotFound => switch (DEBUG.output) {
                                    .Readable => break :out printResult("current file: {s}\n", .{source.?[1..]}),
                                    .Json => break :out printResult("null\n", .{}),
                                },
                                else => return err,
                            };
                            defer allocator.free(path);
                            switch (DEBUG.output) {
                                .Readable => printResult("current file: {s}\n", .{path}),
                                .Json => printResult("\"{s}\"\n", .{path}),
                            }
                        },
                        .trace => {
                            const args = std.mem.trimLeft(u8, rest, " ");
                            const levels_index = std.mem.indexOf(u8, args, " ") orelse args.len;
                            var levels: u32 = 0;
                            if (levels_index > 0) {
                                levels = std.fmt.parseInt(u32, args[0..levels_index], 10) catch |err| {
                                    break :out printResult("Levels Parse Error: {}\n", .{err});
                                };
                            }
                            var level_depth: u32 = 0;
                            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
                            switch (DEBUG.output) {
                                .Readable => {
                                    while (L.getinfo(@intCast(level_depth), "sln", &ar)) : (level_depth += 1) {
                                        if (level_depth > levels and levels != 0)
                                            break;
                                        if (level_depth == 0) {
                                            if (ar.name) |fn_name| {
                                                printResult("from <bmagenta><<function {s}>><clear> in <bold>{s}:{d}<clear>\n", .{
                                                    fn_name,
                                                    fileSourceOr(ar.source) orelse "???", // source is optional
                                                    ar.currentline orelse ar.linedefined orelse 0,
                                                });
                                            } else {
                                                printResult("in <bold>{s}:{d}<clear>\n", .{
                                                    fileSourceOr(ar.source) orelse "???",
                                                    ar.currentline orelse ar.linedefined orelse 0,
                                                });
                                            }
                                        } else {
                                            if (ar.name) |fn_name| {
                                                printResult("- <dim>{d}:<clear> <bmagenta><<function {s}>><clear> in <bold>{s}:{d}<clear>\n", .{
                                                    level_depth,
                                                    fn_name,
                                                    fileSourceOr(ar.source) orelse "???",
                                                    ar.currentline orelse ar.linedefined orelse 0,
                                                });
                                            } else {
                                                printResult("- <dim>{d}:<clear> <bold>{s}:{d}<clear>\n", .{
                                                    level_depth,
                                                    fileSourceOr(ar.source) orelse "???",
                                                    ar.currentline orelse ar.linedefined orelse 0,
                                                });
                                            }
                                        }
                                    }
                                },
                                .Json => {
                                    var allocating: std.Io.Writer.Allocating = .init(allocator);
                                    defer allocating.deinit();

                                    const writer = &allocating.writer;

                                    try writer.writeByte('[');
                                    while (L.getinfo(@intCast(level_depth), "sln", &ar)) : (level_depth += 1) {
                                        if (level_depth > levels and levels != 0)
                                            break;
                                        if (level_depth > 0)
                                            try writer.writeByte(',');
                                        const src_base64_buf, const base64_src = try toBase64(allocator, ar.short_src.?);
                                        defer allocator.free(src_base64_buf);
                                        if (ar.name) |fn_name|
                                            try writer.print("{{\"name\":\"{s}\",\"src\":\"{s}\",\"line\":{d},\"context\":{d}}}", .{
                                                fn_name,
                                                base64_src,
                                                ar.currentline orelse ar.linedefined orelse 0,
                                                @intFromEnum(ar.what),
                                            })
                                        else
                                            try writer.print("{{\"name\":null,\"src\":\"{s}\",\"line\":{d},\"context\":{d}}}", .{
                                                base64_src,
                                                ar.currentline orelse ar.linedefined orelse 0,
                                                @intFromEnum(ar.what),
                                            });
                                    }
                                    try writer.writeByte(']');
                                    printResult("{s}\n", .{allocating.written()});
                                },
                            }
                        },
                        .@"break" => try promptOpBreak(allocator, rest),
                        .modules => {
                            try L.rawcheckstack(3);
                            _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);
                            defer L.pop(1); // pop table
                            switch (DEBUG.output) {
                                .Readable => {
                                    printResult("<bold>modules<clear>:\n", .{});
                                    var count: usize = 0;
                                    var i: i32 = L.rawiter(-1, 0);
                                    while (i >= 0) : (i = L.rawiter(-1, i)) {
                                        defer L.pop(2);
                                        switch (L.typeOf(-2)) {
                                            .String => printResult("  <dim>{d}:<clear> <bold>@{s}<clear>\n", .{ i, L.tostring(-2).? }),
                                            else => printResult("  <dim>{d}:<clear> <dim><<unknown>><clear>\n", .{i}),
                                        }
                                        count += 1;
                                    }
                                    printResult("<bold>amount<clear>: {d}\n", .{count});
                                    break :out;
                                },
                                .Json => {
                                    var allocating: std.Io.Writer.Allocating = .init(allocator);
                                    defer allocating.deinit();

                                    const writer = &allocating.writer;

                                    try writer.writeByte('[');
                                    var count: usize = 0;
                                    var i: i32 = L.rawiter(-1, 0);
                                    while (i >= 0) : (i = L.rawiter(-1, i)) {
                                        defer L.pop(2);
                                        if (count > 0)
                                            try writer.writeByte(',');
                                        switch (L.typeOf(-2)) {
                                            .String => try writer.print("\"{s}\"", .{L.tostring(-2).?}),
                                            else => try writer.print("\"<unknown>\"", .{}),
                                        }
                                        count += 1;
                                    }
                                    try writer.writeByte(']');
                                    printResult("{s}\n", .{allocating.written()});

                                    break :out;
                                },
                            }
                        },
                        .step => {
                            DEBUG.step = .Step;
                            if (debug_info) |ar|
                                if (ar.currentline > 0) {
                                    DEBUG.line = @intCast(ar.currentline);
                                };

                            try terminal.setNormalMode();
                            break;
                        },
                        .step_out => {
                            DEBUG.step = .Step;
                            const depth = L.stackdepth();
                            if (depth > 0) {
                                DEBUG.depth = depth - 1;
                                try terminal.setNormalMode();
                            }
                            break;
                        },
                        .step_instruction => {
                            DEBUG.step = .Step;
                            try terminal.setNormalMode();
                            break;
                        },
                        .next => {
                            DEBUG.step = .Step;
                            DEBUG.depth = L.stackdepth();
                            if (debug_info) |ar|
                                if (ar.currentline > 0) {
                                    DEBUG.line = @intCast(ar.currentline);
                                };
                            try terminal.setNormalMode();
                            break;
                        },
                        .locals => try promptOpLocals(L, allocator, rest),
                        .params => try promptOpParams(L, allocator, rest),
                        .upvalues => try promptOpUpvalues(L, allocator, rest),
                        .globals => try promptOpGlobals(L, allocator, rest),
                        .run => {
                            DEBUG.step = .Run;
                            try terminal.setNormalMode();
                            break;
                        },
                        .restart => {
                            if (Zune.corelib.thread.THREADS.len > 0) {
                                printResult("<red>cannot restart while threads are running<clear>\n", .{});
                                break :out;
                            }
                            // force a break, ignoring yield status
                            L.curr_status = @intFromEnum(VM.lua.Status.Break);
                            DEBUG.dead = true;
                            Scheduler.KillSchedulers();
                            return;
                        },
                        .output_mode => {
                            const option = std.mem.trimLeft(u8, rest, " ");
                            if (std.mem.eql(u8, option, "json")) {
                                DEBUG.output = .Json;
                                printResult("{{\"mode\":\"json\"}}\n", .{});
                            } else {
                                DEBUG.output = .Readable;
                                printResult("output mode set to readable\n", .{});
                            }
                        },
                        .exception => {
                            const option, const args_rest = getNextArg(rest);
                            const enabled = std.mem.eql(u8, std.mem.trimLeft(u8, args_rest, " "), "true");
                            if (std.mem.eql(u8, option, "UnhandledError")) {
                                DEBUG.unhandled_exception = enabled;
                                switch (DEBUG.output) {
                                    .Readable => printResult("UnhandledError set to {}\n", .{DEBUG.unhandled_exception}),
                                    .Json => printResult("{}\n", .{DEBUG.unhandled_exception}),
                                }
                            } else if (std.mem.eql(u8, option, "HandledError")) {
                                DEBUG.handled_exception = enabled;
                                switch (DEBUG.output) {
                                    .Readable => printResult("HandledError set to {}\n", .{DEBUG.handled_exception}),
                                    .Json => printResult("{}\n", .{DEBUG.handled_exception}),
                                }
                            } else {
                                switch (DEBUG.output) {
                                    .Readable => {
                                        if (kind == .UnhandledException or kind == .HandledException) {
                                            if (L.gettop() > 0) {
                                                try L.rawcheckstack(1);
                                                const err = tostring(L, -1);
                                                defer L.pop(1);
                                                break :out printResult("<red>error<clear>: {s}\n", .{err});
                                            }
                                        }
                                        printResult("no errors found.\n", .{});
                                    },
                                    .Json => {
                                        if (kind == .UnhandledException or kind == .HandledException) {
                                            if (L.gettop() > 0) {
                                                try L.rawcheckstack(1);
                                                const typename = VM.lapi.typename(L.typeOf(-1));
                                                const err = tostring(L, -1);
                                                defer L.pop(1);
                                                const err_base64_buf, const base64_err = try toBase64(allocator, err);
                                                defer allocator.free(err_base64_buf);
                                                break :out printResult("{{\"reason\":\"{s}\",\"type\":\"{s}\",\"kind\":{d}}}\n", .{ base64_err, typename, @intFromEnum(kind) });
                                            }
                                        }
                                        printResult("{{\"reason\":null,\"type\":null,\"kind\":{d}}}\n", .{@intFromEnum(kind)});
                                    },
                                }
                            }
                        },
                    }
                }
                try terminal.clearStyles();
                print("", .{});
            },
            127 => {
                if (position == 0)
                    continue;
                const append = position < input_buffer.items.len;
                std.debug.print("{c}", .{8});
                position -= 1;
                _ = input_buffer.orderedRemove(position);
                try terminal.clearEndToCursor();
                if (append)
                    try terminal.writeAllRetainCursor(input_buffer.items[position..]);
            },
            23 => { // Ctrl+Backspace
                const slice = input_buffer.items[0..position];
                if (slice.len == 0)
                    continue;
                const append = position < input_buffer.items.len;
                const index: usize = blk: {
                    const back = std.mem.lastIndexOfNone(u8, slice, Terminal.NON_LETTER) orelse break :blk position;
                    break :blk slice.len - (std.mem.lastIndexOfAny(u8, slice[0..back], Terminal.NON_LETTER) orelse break :blk position) - 1;
                };
                for (0..index) |_| {
                    std.debug.print("{c}", .{8});
                    position -= 1;
                    _ = input_buffer.orderedRemove(position);
                    try terminal.clearEndToCursor();
                    if (append)
                        try terminal.writeAllRetainCursor(input_buffer.items[position..]);
                }
            },
            3, 4 => { // Ctrl+C, Ctrl+D
                terminal.restoreSettings() catch {};
                terminal.restoreOutputMode() catch {};
                std.process.exit(0);
            },
            else => |b| {
                var byte: u8 = b;
                switch (byte) {
                    22...31 => std.debug.print("Unknown byte: {d}\n", .{byte}),
                    9 => byte = ' ',
                    else => {},
                }
                const append = position < input_buffer.items.len;
                try input_buffer.insert(allocator, position, byte);
                std.debug.print("{c}", .{byte});
                position += 1;
                if (append)
                    try terminal.writeAllRetainCursor(input_buffer.items[position..]);
            },
        }
    }
}

pub fn debugstep(L: *VM.lua.State, ar: *VM.lua.c.lua_Debug) callconv(.c) void {
    MAIN_MUTEX.lock();
    defer MAIN_MUTEX.unlock();
    updateBreakpoints(L) catch |err| switch (err) {
        error.NoSource => {},
        error.InvalidPath => {},
        else => std.debug.panic("Error: {}\n", .{err}),
    };
    if (DEBUG.step == .Run or DEBUG.dead)
        return;
    if (DEBUG.line) |line| {
        if (ar.currentline < 0 or @as(usize, @intCast(ar.currentline)) == line)
            return;
        DEBUG.line = null;
    }
    if (DEBUG.depth) |depth| {
        if (L.stackdepth() > depth)
            return;
        DEBUG.depth = null;
    }
    prompt(L, .Stepped, ar) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}

pub fn debugbreak(L: *VM.lua.State, ar: *VM.lua.c.lua_Debug) callconv(.c) void {
    MAIN_MUTEX.lock();
    defer MAIN_MUTEX.unlock();
    if (DEBUG.dead)
        return;
    prompt(L, .Breakpoint, ar) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}

pub fn luau_panic(L: *VM.lua.State, errcode: i32) void {
    MAIN_MUTEX.lock();
    defer MAIN_MUTEX.unlock();
    if (DEBUG.dead or !DEBUG.unhandled_exception)
        return;
    _ = errcode;
    prompt(L, .UnhandledException, null) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}

pub fn debugprotectederror(L: *VM.lua.State) callconv(.c) void {
    MAIN_MUTEX.lock();
    defer MAIN_MUTEX.unlock();
    if (DEBUG.dead or !DEBUG.handled_exception)
        return;
    prompt(L, .HandledException, null) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}
