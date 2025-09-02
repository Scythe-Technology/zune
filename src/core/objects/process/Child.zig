const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;
const Lists = Zune.Utils.Lists;

const tagged = @import("../../../tagged.zig");
const sysfd = @import("../../utils/sysfd.zig");

const File = @import("../filesystem/File.zig");

const VM = luau.VM;

const Child = @This();

const TAG_PROCESS_CHILD = tagged.Tags.get("PROCESS_CHILD").?;
pub fn PlatformSupported() bool {
    return std.process.can_spawn;
}

child: std.process.Child,
dead: bool = false,
code: u32 = 0,

stdin: ?std.fs.File = null,
stdout: ?std.fs.File = null,
stderr: ?std.fs.File = null,

stdin_file: LuaHelper.Ref(void) = .empty,
stdout_file: LuaHelper.Ref(void) = .empty,
stderr_file: LuaHelper.Ref(void) = .empty,

pub const WaitAsyncContext = struct {
    completion: xev.Completion,
    ref: Scheduler.ThreadRef,
    child: xev.Process,
    handle: LuaHelper.Ref(*Child),

    pub fn complete(
        ud: ?*WaitAsyncContext,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Process.WaitError!u32,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);

        defer allocator.destroy(self);
        defer self.ref.deref();
        defer self.child.deinit();
        defer self.handle.deref(L);

        if (L.status() != .Yield)
            return .disarm;

        var code: u32 = r catch |err| switch (@as(anyerror, err)) {
            error.NoSuchProcess => self.handle.value.code, // kqueue
            else => blk: {
                std.debug.print("[Process Wait Error: {}]\n", .{err});
                break :blk 1;
            },
        };

        if (self.handle.value.code != 0)
            code = self.handle.value.code;

        self.handle.value.code = code;
        self.handle.value.dead = true;

        L.Zpushvalue(.{
            .code = code,
            .ok = code == 0,
        }) catch |e| std.debug.panic("{}", .{e});
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

fn lua_kill(self: *Child, L: *VM.lua.State) !i32 {
    if (self.dead) {
        try L.Zpushvalue(.{
            .code = self.code,
            .ok = self.code == 0,
        });
        return 1;
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    var child = try xev.Process.init(self.child.id);
    errdefer child.deinit();

    switch (comptime builtin.os.tag) {
        .windows => std.os.windows.TerminateProcess(self.child.id, 1) catch |err| switch (err) {
            error.AccessDenied => return error.AlreadyTerminated,
            else => return err,
        },
        else => {
            self.code = std.posix.SIG.TERM;
            try std.posix.kill(self.child.id, std.posix.SIG.TERM);
        },
    }

    const wait = try allocator.create(WaitAsyncContext);

    wait.* = .{
        .completion = .init(),
        .child = child,
        .ref = .init(L),
        .handle = .init(L, 1, self),
    };

    child.wait(
        &scheduler.loop,
        &wait.completion,
        WaitAsyncContext,
        wait,
        WaitAsyncContext.complete,
    );

    scheduler.loop.submit() catch {};

    return L.yield(0);
}

fn lua_wait(self: *Child, L: *VM.lua.State) !i32 {
    if (self.dead) {
        try L.Zpushvalue(.{
            .code = self.code,
            .ok = self.code == 0,
        });
        return 1;
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    var child = try xev.Process.init(self.child.id);
    errdefer child.deinit();

    const wait = try allocator.create(WaitAsyncContext);

    wait.* = .{
        .completion = .init(),
        .child = child,
        .ref = .init(L),
        .handle = .init(L, 1, self),
    };

    child.wait(
        &scheduler.loop,
        &wait.completion,
        WaitAsyncContext,
        wait,
        WaitAsyncContext.complete,
    );

    scheduler.loop.submit() catch {};

    return L.yield(0);
}

pub const __namecall = MethodMap.CreateNamecallMap(Child, TAG_PROCESS_CHILD, .{
    .{ "kill", lua_kill },
    .{ "wait", lua_wait },
});

pub const IndexMap = std.StaticStringMap(enum {
    Stdin,
    Stdout,
    Stderr,
}).initComptime(.{
    .{ "stdin", .Stdin },
    .{ "stdout", .Stdout },
    .{ "stderr", .Stderr },
});

pub fn __index(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Userdata);
    const self = L.touserdatatagged(Child, 1, TAG_PROCESS_CHILD) orelse return L.Zerror("invalid userdata");
    const index = L.Lcheckstring(2);

    switch (IndexMap.get(index) orelse return L.Zerrorf("Unknown index: {s}", .{index})) {
        .Stdin => {
            if (self.stdin_file.push(L))
                return 1;
            L.pushnil();
            return 1;
        },
        .Stdout => {
            if (self.stdout_file.push(L))
                return 1;
            L.pushnil();
            return 1;
        },
        .Stderr => {
            if (self.stderr_file.push(L))
                return 1;
            L.pushnil();
            return 1;
        },
    }

    return 1;
}

pub fn __dtor(L: *VM.lua.State, self: *Child) void {
    self.stdin_file.deref(L);
    self.stdout_file.deref(L);
    self.stderr_file.deref(L);
}

pub inline fn load(L: *VM.lua.State) !void {
    _ = try L.Znewmetatable(@typeName(@This()), .{
        .__index = __index,
        .__namecall = __namecall,
        .__metatable = "Metatable is locked",
        .__type = "ProcessChild",
    });
    L.setreadonly(-1, true);
    L.setuserdatametatable(TAG_PROCESS_CHILD);
    L.setuserdatadtor(Child, TAG_PROCESS_CHILD, __dtor);
}

pub fn push(L: *VM.lua.State, child: std.process.Child) !void {
    const self = try L.newuserdatataggedwithmetatable(Child, TAG_PROCESS_CHILD);

    self.* = .{
        .child = child,
    };

    if (child.stdin) |file| {
        try File.push(L, file, .Tty, .writable(.close));
        self.stdin_file = .init(L, -1, undefined);
        self.stdin = file;
        L.pop(1);
    }
    if (child.stdout) |file| {
        try File.push(L, file, .Tty, .readable(.close));
        self.stdout_file = .init(L, -1, undefined);
        self.stdout = file;
        L.pop(1);
    }
    if (child.stderr) |file| {
        try File.push(L, file, .Tty, .readable(.close));
        self.stderr_file = .init(L, -1, undefined);
        self.stderr = file;
        L.pop(1);
    }
}
