const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const File = Zune.objects.File;
const ProcessChild = Zune.objects.ProcessChild;

const Parser = @import("../utils/parser.zig");

const VM = luau.VM;

const process = std.process;

const native_os = builtin.os.tag;

pub const LIB_NAME = "process";

pub var SIGINT_LUA: ?LuaSigHandler = null;

const LuaSigHandler = struct {
    state: *VM.lua.State,
    ref: Scripting.Reference,
};

const ProcessArgsError = error{
    InvalidArgType,
    NotArray,
};

const ProcessEnvError = error{
    InvalidKeyType,
    InvalidValueType,
};

fn getProcessArgs(L: *VM.lua.State, allocator: std.mem.Allocator, array: *std.ArrayList([]const u8), idx: i32) !void {
    try L.Zchecktype(idx, .Table);
    var iter: Scripting.ArrayIterator = .{ .L = L, .idx = idx };
    while (try iter.next()) |i| switch (i) {
        .String => try array.append(allocator, L.tostring(-1).?),
        else => return L.Zerrorf("invalid process argument type (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-1))}),
    };
}

fn writeProcessEnvMap(L: *VM.lua.State, envMap: *std.process.Environ.Map, idx: i32) !void {
    try L.Zchecktype(idx, .Table);
    var iter: Scripting.TableIterator = .{ .L = L, .idx = idx };
    while (iter.next()) |t| switch (t) {
        .String => {
            if (L.typeOf(-1) != .String)
                return L.Zerrorf("invalid process environment value type (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-1))});
            try envMap.put(L.tostring(-2).?, L.tostring(-1).?);
        },
        else => return L.Zerrorf("invalid process environment key type (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-2))}),
    };
}

const ProcessOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?process.Environ.Map = null,
    joined: ?[]const u8 = null,
    args: std.ArrayList([]const u8),
    stdin: Behavior = .pipe,
    stdout: Behavior = .pipe,
    stderr: Behavior = .pipe,

    pub const Behavior = enum { inherit, pipe, ignore };

    pub fn init(L: *VM.lua.State, allocator: std.mem.Allocator) !ProcessOptions {
        const cmd = try L.Zcheckvalue([:0]const u8, 1, null);

        var shell: ?[]const u8 = null;
        var shell_inline: ?[]const u8 = "-c";

        var options: ProcessOptions = .{
            .args = .empty,
        };
        errdefer options.args.deinit(allocator);

        if (!L.typeOf(3).isnoneornil()) {
            try L.Zchecktype(3, .Table);

            options.cwd = try L.Zcheckfield(?[]const u8, 3, "cwd");
            L.pop(1);

            if (Scripting.maybeKnownType(L.rawgetfield(3, "env"))) |@"type"| {
                if (@"type" != .Table)
                    return L.Zerrorf("invalid environment (table expected, got {s})", .{VM.lapi.typename(@"type")});
                options.env = std.process.Environ.Map.init(allocator);
                try writeProcessEnvMap(L, &options.env.?, -1);
            }
            L.pop(1);

            const Map = std.StaticStringMap(Behavior).initComptime(.{
                .{ "inherit", .inherit },
                .{ "pipe", .pipe },
                .{ "ignore", .ignore },
            });

            switch (L.rawgetfield(3, "stdin")) {
                .None, .Nil => {},
                .String => {
                    const option = L.tostring(-1) orelse unreachable;
                    options.stdin = Map.get(option) orelse return L.Zerrorf("invalid stdin option (inherit/pipe/ignore expected, got {s})", .{option});
                },
                else => return L.Zerrorf("invalid stdin option (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-1))}),
            }
            L.pop(1);

            switch (L.rawgetfield(3, "stdout")) {
                .None, .Nil => {},
                .String => {
                    const option = L.tostring(-1) orelse unreachable;
                    options.stdout = Map.get(option) orelse return L.Zerrorf("invalid stdout option (inherit/pipe/ignore expected, got {s})", .{option});
                },
                else => return L.Zerrorf("invalid stdout option (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-1))}),
            }
            L.pop(1);

            switch (L.rawgetfield(3, "stderr")) {
                .None, .Nil => {},
                .String => {
                    const option = L.tostring(-1) orelse unreachable;
                    options.stderr = Map.get(option) orelse return L.Zerrorf("invalid stderr option (inherit/pipe/ignore expected, got {s})", .{option});
                },
                else => return L.Zerrorf("invalid stderr option (string expected, got {s})", .{VM.lapi.typename(L.typeOf(-1))}),
            }
            L.pop(1);

            switch (L.rawgetfield(3, "shell")) {
                .None, .Nil => {},
                .String => blk: {
                    const shellOption = L.tostring(-1) orelse unreachable;

                    switch (std.StaticStringMap(enum { shell, bash, powershell, powershell_core, cmd }).initComptime(.{
                        .{ "sh", .shell },
                        .{ "/bin/sh", .shell },
                        .{ "bash", .bash },
                        .{ "powershell", .powershell },
                        .{ "ps", .powershell },
                        .{ "pwsh", .powershell_core },
                        .{ "powershell-core", .powershell_core },
                        .{ "cmd", .cmd },
                    }).get(shellOption) orelse {
                        shell = shellOption;
                        shell_inline = null;
                        break :blk;
                    }) {
                        .shell => shell = "/bin/sh",
                        .bash => shell = "bash",
                        .powershell => shell = "powershell",
                        .powershell_core => shell = "pwsh",
                        .cmd => {
                            shell = "cmd";
                            shell_inline = "/c";
                        },
                    }
                },
                .Boolean => {
                    if (L.toboolean(-1)) {
                        switch (native_os) {
                            .windows => shell = "powershell",
                            .macos, .linux => shell = "/bin/sh",
                            else => shell = "/bin/sh",
                        }
                    }
                },
                else => |t| return L.Zerrorf("invalid shell (string or boolean expected, got {s})", .{VM.lapi.typename(t)}),
            }
            L.pop(1);
        }

        try options.args.append(allocator, cmd);

        if (L.typeOf(2) == .Table)
            try getProcessArgs(L, allocator, &options.args, 2);

        if (shell) |s| {
            const joined = try std.mem.join(allocator, " ", options.args.items);
            errdefer allocator.free(joined);
            options.joined = joined;
            options.args.clearRetainingCapacity();
            try options.args.append(allocator, s);
            if (shell_inline) |inline_cmd|
                try options.args.append(allocator, inline_cmd);
            try options.args.append(allocator, joined);
        }

        return options;
    }

    fn deinit(self: *ProcessOptions, allocator: std.mem.Allocator) void {
        if (self.env) |*env|
            env.deinit();
        if (self.joined) |mem|
            allocator.free(mem);
        self.args.deinit(allocator);
    }
};

const AsyncRunContext = struct {
    op: zio.ev.ProcessWait,
    stdout_read: zio.ev.FileReadStreaming,
    stderr_read: zio.ev.FileReadStreaming,
    ref: Scheduler.ThreadRef,
    state: packed struct {
        executing: bool = true,
        stderr: bool = false,
        stdout: bool = false,
    } = .{},
    result: union(enum) {
        none: void,
        exited: zio.ev.ProcessWait.ExitStatus,
        error_code: u8,
    } = .none,

    stdout_writer: std.ArrayList(u8) = .empty,
    stderr_writer: std.ArrayList(u8) = .empty,

    iovec: [2]zio.os.iovec = undefined,
    stdout_read_buffer: [4096]u8 = undefined,
    stderr_read_buffer: [4096]u8 = undefined,

    stdout: ?std.Io.File,
    stderr: ?std.Io.File,

    pub fn cleanup(self: *AsyncRunContext, allocator: std.mem.Allocator) void {
        defer allocator.destroy(self);
        defer self.ref.deref();
        defer self.stdout_writer.deinit(allocator);
        defer self.stderr_writer.deinit(allocator);
    }

    pub inline fn active(self: *AsyncRunContext) bool {
        return self.state.stdout or self.state.stderr or self.state.executing;
    }

    pub fn resumeResult(self: *AsyncRunContext) !void {
        const L = self.ref.value;
        const scheduler = Scheduler.fromState(L);
        defer self.cleanup(scheduler.allocator());

        if (L.status() != .Yield)
            return;

        switch (self.result) {
            .none => unreachable,
            .exited => |res| if (res.signal) |sig|
                try L.Zpushvalue(.{
                    .code = sig,
                    .ok = false,
                    .kind = "signal",
                })
            else
                try L.Zpushvalue(.{
                    .code = res.code,
                    .ok = res.code == 0,
                    .kind = "exited",
                }),
            .error_code => |err| try L.Zpushvalue(.{
                .code = err,
                .ok = false,
                .kind = "error",
            }),
        }

        if (self.stdout != null) {
            try L.Zpushbuffer(self.stdout_writer.items);
            try L.rawsetfield(-2, "stdout");
        }
        if (self.stderr != null) {
            try L.Zpushbuffer(self.stderr_writer.items);
            try L.rawsetfield(-2, "stderr");
        }

        _ = Scheduler.resumeState(L, null, 1) catch {};
    }

    pub fn complete(_: *zio.ev.Loop, completion: *zio.ev.Completion) void {
        const wait: *zio.ev.ProcessWait = @alignCast(@fieldParentPtr("c", completion));
        const self: *AsyncRunContext = @alignCast(@fieldParentPtr("op", wait));

        self.state.executing = false;

        defer if (!self.active())
            self.resumeResult() catch |e| std.debug.panic("{}", .{e});

        self.result = .{
            .exited = wait.getResult() catch |err| {
                self.result = switch (err) {
                    error.Canceled => .{ .error_code = 0 },
                    error.ProcessNotFound => .{ .error_code = 1 },
                    error.SystemResources => .{ .error_code = 2 },
                    error.Unexpected => .{ .error_code = 3 },
                };
                return;
            },
        };
    }

    pub fn stdoutComplete(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
        const read: *zio.ev.FileReadStreaming = @alignCast(@fieldParentPtr("c", completion));
        const self: *AsyncRunContext = @alignCast(@fieldParentPtr("stdout_read", read));

        defer if (!self.active())
            self.resumeResult() catch |e| std.debug.panic("{}", .{e});

        const bytes = read.getResult() catch 0;
        if (bytes == 0) {
            self.state.stdout = false;
            self.stdout.?.close(Zune.io());
            return;
        }
        const scheduler = Scheduler.fromState(self.ref.value);
        const allocator = scheduler.allocator();

        const free_space = Scripting.MAX_LUAU_SIZE - self.stdout_writer.items.len;
        const buffer = self.stdout_read_buffer[0..@min(bytes, free_space)];
        if (buffer.len > 0)
            self.stdout_writer.appendSlice(allocator, buffer) catch |e| std.debug.panic("{}", .{e});
        if (free_space - buffer.len == 0) {
            self.state.stdout = false;
            self.stdout.?.close(Zune.io());
            return;
        }

        read.buffer = .fromSlice(&self.stdout_read_buffer, self.iovec[0..1]);
        loop.add(&read.c);

        return;
    }

    pub fn stderrComplete(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
        const read: *zio.ev.FileReadStreaming = @alignCast(@fieldParentPtr("c", completion));
        const self: *AsyncRunContext = @alignCast(@fieldParentPtr("stderr_read", read));

        defer if (!self.active())
            self.resumeResult() catch |e| std.debug.panic("{}", .{e});

        const bytes = read.getResult() catch 0;
        if (bytes == 0) {
            self.state.stderr = false;
            self.stderr.?.close(Zune.io());
            return;
        }

        const scheduler = Scheduler.fromState(self.ref.value);
        const allocator = scheduler.allocator();

        const free_space = Scripting.MAX_LUAU_SIZE - self.stderr_writer.items.len;
        const buffer = self.stderr_read_buffer[0..@min(bytes, free_space)];
        if (buffer.len > 0)
            self.stderr_writer.appendSlice(allocator, buffer) catch |e| std.debug.panic("{}", .{e});
        if (free_space - buffer.len == 0) {
            self.state.stderr = false;
            self.stderr.?.close(Zune.io());
            return;
        }

        read.buffer = .fromSlice(&self.stderr_read_buffer, self.iovec[1..2]);
        loop.add(&read.c);

        return;
    }
};

pub fn lua_getExePath(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .macos, .driverkit, .ios, .tvos, .visionos, .watchos => {}, // Darwin
        .freebsd, .openbsd, .netbsd, .dragonfly => {}, // BSD
        .illumos => {},
        .haiku => {},
        .windows, .linux => {},
        else => return error.UnsupportedPlatform,
    }

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try std.process.executablePath(Zune.io(), &buf)];
    try L.pushlstring(path);
    return 1;
}

pub fn lua_openExeFile(L: *VM.lua.State) !i32 {
    var mode: std.Io.Dir.OpenFileOptions.Mode = .read_only;

    const Options = struct {
        mode: ?[:0]const u8 = null,
        follow_symlinks: bool = true,
        allow_directory: bool = true,
        nonblocking: bool = true,
        path_only: bool = false,
        allow_ctty: bool = false,
        resolve_beneath: bool = false,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 1, null) orelse .{};
    if (opts.mode) |m| {
        const has_read = std.mem.indexOfScalar(u8, m, 'r');
        const has_write = std.mem.indexOfScalar(u8, m, 'w');
        if (has_read != null and has_write != null) {
            mode = .read_write;
        } else if (has_read != null) {
            mode = .read_only;
        } else if (has_write != null) {
            mode = .write_only;
        } else return L.Zerror("invalid mode");
    }

    const file = try std.process.openExecutable(Zune.io(), .{
        .mode = mode,
        .follow_symlinks = opts.follow_symlinks,
        .allow_directory = opts.allow_directory,
        .path_only = opts.path_only,
        .allow_ctty = opts.allow_ctty,
        .resolve_beneath = opts.resolve_beneath,
    });
    errdefer file.close(Zune.io());

    _ = try File.create(L, file, .File, .{
        .read = mode == .read_only or mode == .read_write,
        .write = mode == .write_only or mode == .read_write,
        .pollable = false,
    });

    return 1;
}

pub fn lua_run(L: *VM.lua.State) !i32 {
    if (comptime !std.process.can_spawn)
        return L.Zerror("unsupported platform");
    if (!L.isyieldable())
        return L.Zyielderror();
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    var options = try ProcessOptions.init(L, allocator);
    defer options.deinit(allocator);

    var child = try process.spawn(Zune.io(), .{
        .argv = options.args.items,
        .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = if (options.env != null) &options.env.? else &Zune.State.env_map,
        .expand_arg0 = .no_expand,
        .stdin = if (options.stdin == .inherit) .inherit else .ignore,
        .stdout = switch (options.stdout) {
            .inherit => .inherit,
            .pipe => .pipe,
            .ignore => .ignore,
        },
        .stderr = switch (options.stderr) {
            .inherit => .inherit,
            .pipe => .pipe,
            .ignore => .ignore,
        },
        .create_no_window = if (comptime builtin.os.tag != .windows) false else blk: {
            if (options.stdin == .inherit and Zune.standard.libraries.io.terminal.isStdInTty())
                break :blk false;
            if (options.stdout == .inherit and Zune.standard.libraries.io.terminal.isStdOutTty())
                break :blk false;
            if (options.stderr == .inherit and Zune.standard.libraries.io.terminal.isStdErrTty())
                break :blk false;
            break :blk true;
        },
    });
    errdefer child.kill(Zune.io());

    if (comptime builtin.os.tag != .windows) {
        if (child.stdin) |*f| jmp: {
            zio.os.posix.setNonblocking(f.handle) catch break :jmp;
            f.flags.nonblocking = true;
        }
        if (child.stdout) |*f| jmp: {
            zio.os.posix.setNonblocking(f.handle) catch break :jmp;
            f.flags.nonblocking = true;
        }
        if (child.stderr) |*f| jmp: {
            zio.os.posix.setNonblocking(f.handle) catch break :jmp;
            f.flags.nonblocking = true;
        }
    }

    const handle = child.id orelse return L.Zerror("already terminated");

    const self = try allocator.create(AsyncRunContext);
    errdefer allocator.destroy(self);

    self.* = .{
        .op = .init(handle),
        .stdout_read = undefined,
        .stderr_read = undefined,
        .stdout = child.stdout,
        .stderr = child.stderr,
        .ref = .init(L),
        .state = .{
            .executing = true,
            .stdout = child.stdout != null,
            .stderr = child.stderr != null,
        },
    };

    self.op.c.callback = AsyncRunContext.complete;
    scheduler.loop.add(&self.op.c);

    if (self.stdout) |stdout| {
        self.stdout_read = .init(stdout.handle, .fromSlice(&self.stdout_read_buffer, self.iovec[0..1]));
        self.stdout_read.c.callback = AsyncRunContext.stdoutComplete;
        scheduler.loop.add(&self.stdout_read.c);
    }
    if (self.stderr) |stderr| {
        self.stderr_read = .init(stderr.handle, .fromSlice(&self.stderr_read_buffer, self.iovec[1..2]));
        self.stderr_read.c.callback = AsyncRunContext.stderrComplete;
        scheduler.loop.add(&self.stderr_read.c);
    }

    return L.yield(0) catch unreachable;
}

pub fn lua_create(L: *VM.lua.State) !i32 {
    if (comptime !std.process.can_spawn)
        return L.Zerror("unsupported platform");
    const allocator = Scheduler.fromState(L).allocator();

    var options = try ProcessOptions.init(L, allocator);
    defer options.deinit(allocator);

    var child = try process.spawn(Zune.io(), .{
        .argv = options.args.items,
        .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = if (options.env != null) &options.env.? else &Zune.State.env_map,
        .expand_arg0 = .no_expand,
        .stdin = switch (options.stdin) {
            .inherit => .inherit,
            .pipe => .pipe,
            .ignore => .ignore,
        },
        .stdout = switch (options.stdout) {
            .inherit => .inherit,
            .pipe => .pipe,
            .ignore => .ignore,
        },
        .stderr = switch (options.stderr) {
            .inherit => .inherit,
            .pipe => .pipe,
            .ignore => .ignore,
        },
    });
    errdefer child.kill(Zune.io());

    if (comptime builtin.os.tag != .windows) {
        if (child.stdin) |f| zio.os.posix.setNonblocking(f.handle) catch {};
        if (child.stdout) |f| zio.os.posix.setNonblocking(f.handle) catch {};
        if (child.stderr) |f| zio.os.posix.setNonblocking(f.handle) catch {};
    }

    if (child.id == null) return L.Zerror("already terminated");

    try ProcessChild.create(L, child);

    return 1;
}

pub fn lua_exit(L: *VM.lua.State) i32 {
    const code = L.Lcheckunsigned(1);
    Engine.stateCleanUp();
    std.process.exit(@truncate(code));
    return 0;
}

const DotEnvError = error{
    InvalidString,
    InvalidCharacter,
};

fn decodeString(L: *VM.lua.State, slice: []const u8) !usize {
    if (slice.len < 2)
        return DotEnvError.InvalidString;
    if (slice[0] == slice[1]) {
        try L.pushstring("");
        return 2;
    }

    const allocator = Scheduler.fromState(L).allocator();

    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    const writer = &allocating.writer;

    const stringQuote: u8 = slice[0];
    var pos: usize = 1;
    var eof: bool = false;
    while (pos <= slice.len) {
        switch (slice[pos]) {
            '\\' => if (stringQuote != '\'') {
                pos += 1;
                if (pos >= slice.len)
                    return DotEnvError.InvalidString;
                switch (slice[pos]) {
                    'n' => try writer.writeByte('\n'),
                    '"', '`', '\'' => |b| try writer.writeByte(b),
                    else => return DotEnvError.InvalidString,
                }
            } else try writer.writeByte('\\'),
            '"', '`', '\'' => |c| if (c == stringQuote) {
                eof = true;
                pos += 1;
                break;
            } else try writer.writeByte(c),
            '\r' => {},
            else => |b| try writer.writeByte(b),
        }
        pos += 1;
    }
    if (eof) {
        try L.pushlstring(allocating.written());
        return pos;
    } else try L.pushstring("");
    return 0;
}

const WHITESPACE = [_]u8{ 32, '\t' };
const DECODE_BREAK = [_]u8{ '#', '\n' };

fn validateWord(slice: []const u8) !void {
    for (slice) |b| switch (b) {
        0...32 => return DotEnvError.InvalidCharacter,
        else => {},
    };
}

fn decodeEnvironment(L: *VM.lua.State, string: []const u8) !void {
    var pos: usize = 0;
    var scan: usize = 0;
    while (pos < string.len) switch (string[pos]) {
        '\n' => {
            pos += 1;
            scan = pos;
        },
        '#' => {
            pos += std.mem.indexOfScalar(u8, string[pos..], '\n') orelse string.len - pos;
            scan = pos;
        },
        '=' => {
            const variableName = Parser.trimSpace(string[scan..pos]);
            pos += 1;
            if (pos >= string.len)
                break;
            try validateWord(variableName);
            pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE);
            try L.pushlstring(variableName);
            errdefer L.pop(1);
            if (string[pos] == '"' or string[pos] == '\'' or string[pos] == '`') {
                const stringEof = try decodeString(L, string[pos..]);
                const remaining_slice = string[pos + stringEof ..];
                const eof = Parser.nextCharacter(remaining_slice, &DECODE_BREAK);
                if (Parser.trimSpace(remaining_slice[0..eof]).len == 0) {
                    try L.rawset(-3);
                    pos += stringEof;
                    pos += eof;
                    continue;
                }
                L.pop(1);
            }
            const eof = Parser.nextCharacter(string[pos..], &DECODE_BREAK);
            try L.pushlstring(Parser.trimSpace(string[pos .. pos + eof]));
            try L.rawset(-3);
            pos += eof;
        },
        else => pos += 1,
    };
}

fn loadEnvironment(L: *VM.lua.State, allocator: std.mem.Allocator, file: []const u8) !void {
    const bytes: []const u8 = std.Io.Dir.cwd().readFileAlloc(Zune.io(), file, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    decodeEnvironment(L, bytes) catch {};
}

pub fn lua_loadEnv(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
    try L.newtable();

    var iterator = Zune.State.env_map.iterator();
    while (iterator.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        defer allocator.free(key);
        try L.pushlstring(entry.value_ptr.*);
        try L.rawsetfield(-2, key);
    }

    try loadEnvironment(L, allocator, ".env");
    if (Zune.State.env_map.get("LUAU_ENV")) |value| {
        if (std.mem.eql(u8, value, "PRODUCTION")) {
            try loadEnvironment(L, allocator, ".env.production");
        } else if (std.mem.eql(u8, value, "DEVELOPMENT")) {
            try loadEnvironment(L, allocator, ".env.development");
        } else if (std.mem.eql(u8, value, "TEST")) {
            try loadEnvironment(L, allocator, ".env.test");
        }
    }
    try loadEnvironment(L, allocator, ".env.local");

    return 1;
}

pub fn lua_onSignal(L: *VM.lua.State) !i32 {
    const sig = try L.Zcheckvalue([:0]const u8, 1, null);
    try L.Zchecktype(2, .Function);

    if (std.mem.eql(u8, sig, "INT")) {
        if (Zune.State.main_thread_id) |id|
            if (id != std.Thread.getCurrentId())
                return L.Zerror("function can only be called in the main thread");

        SIGINT_LUA = .{
            .state = L.mainthread(),
            .ref = .init(L, 2),
        };
    } else return L.Zerrorf("unknown signal: {s}", .{sig});

    return 0;
}

pub fn lua_pid(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows => L.pushunsigned(std.os.windows.GetCurrentProcessId()),
        else => L.pushinteger(std.c.getpid()),
    }
    return 1;
}

pub fn lua_custom_args(L: *VM.lua.State) !void {
    try L.Zpushvalue(Zune.State.args);
}
pub fn lua_custom_env(L: *VM.lua.State) !void {
    _ = try lua_loadEnv(L);
}
