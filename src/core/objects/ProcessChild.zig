const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const File = Zune.objects.File;

const VM = luau.VM;

const Child = @This();

pub const OBJECT_TAG = Zune.Tags.get("PROCESS_CHILD").?;
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return if (std.process.can_spawn) .Full else null;
}

child: std.process.Child,
status: union(enum) {
    none,
    exited: zio.ev.ProcessWait.ExitStatus,
    error_code: u8,
} = .none,
ref: Scripting.CountedReference = .{},

stdin: ?std.Io.File = null,
stdout: ?std.Io.File = null,
stderr: ?std.Io.File = null,

stdin_file: Scripting.ValueReference(*VM.lstate.GCObject) = .empty,
stdout_file: Scripting.ValueReference(*VM.lstate.GCObject) = .empty,
stderr_file: Scripting.ValueReference(*VM.lstate.GCObject) = .empty,

pub fn lua_direct_stdin(self: *Child, res: *VM.lobject.TValue) void {
    if (!self.stdin_file.valid())
        return res.setnilvalue();
    res.value.gc = self.stdin_file.value;
    res.settype(.Userdata);
}

pub fn lua_direct_stdout(self: *Child, res: *VM.lobject.TValue) void {
    if (!self.stdout_file.valid())
        return res.setnilvalue();
    res.value.gc = self.stdout_file.value;
    res.settype(.Userdata);
}

pub fn lua_direct_stderr(self: *Child, res: *VM.lobject.TValue) void {
    if (!self.stderr_file.valid())
        return res.setnilvalue();
    res.value.gc = self.stderr_file.value;
    res.settype(.Userdata);
}

pub fn lua_direct_pid(self: *Child, res: *VM.lobject.TValue) void {
    res.setnvalue(@floatFromInt(switch (comptime builtin.os.tag) {
        .windows => @intFromPtr(self.child.id),
        .wasi => 0,
        else => self.child.id orelse 0,
    }));
}

pub fn pushStatus(self: *Child, L: *VM.lua.State) !void {
    switch (self.status) {
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
}

fn asyncCallback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
    const async: *Scheduler.Async = Scheduler.Async.fromCompletion(completion);
    const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));
    defer async.deinit(scheduler);

    const L = async.ref.value;

    const proc: *Child = @ptrCast(@alignCast(completion.userdata));

    proc.ref.deref(L);

    switch (async.op) {
        .process_wait => |*e| {
            if (L.status() != .Yield)
                return;

            if (proc.status == .none) jmp: {
                proc.status = .{
                    .exited = e.op.getResult() catch |err| {
                        proc.status = switch (err) {
                            error.Canceled => .{ .error_code = 0 },
                            error.ProcessNotFound => .{ .error_code = 1 },
                            error.SystemResources => .{ .error_code = 2 },
                            error.Unexpected => .{ .error_code = 3 },
                        };
                        break :jmp;
                    },
                };
            }

            proc.pushStatus(L) catch |err| std.debug.panic("{}", .{err});
            _ = Scheduler.resumeState(L, null, 1) catch {};
        },
        else => unreachable,
    }
}

fn startAsync(self: *Child, async: *Scheduler.Async, L: *VM.lua.State, scheduler: *Scheduler) void {
    self.ref.ref(L, 1);

    const common: *Scheduler.Async.Operation.Common = @ptrCast(@alignCast(&async.op));

    common.op.c.userdata = @ptrCast(@alignCast(self));
    common.op.c.callback = asyncCallback;

    scheduler.loop.add(&common.op.c);
}

pub fn lua_kill(self: *Child, L: *VM.lua.State) !i32 {
    if (self.status != .none) {
        try self.pushStatus(L);
        return 1;
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const handle = self.child.id orelse unreachable;

    switch (comptime builtin.os.tag) {
        .windows => switch (std.os.windows.ntdll.NtTerminateProcess(handle, @fromBackingInt(1))) {
            .SUCCESS => {},
            .ACCESS_DENIED => return error.AlreadyTerminated,
            else => return error.Unexpected,
        },
        else => {
            self.status = .{ .exited = .{ .code = 0, .signal = @backingInt(std.posix.SIG.TERM) } };
            try std.posix.kill(handle, std.posix.SIG.TERM);
        },
    }

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .process_wait = .{
                .op = .init(handle),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_wait(self: *Child, L: *VM.lua.State) !i32 {
    if (self.status != .none) {
        try self.pushStatus(L);
        return 1;
    }
    if (!L.isyieldable())
        return L.Zyielderror();

    const scheduler = Scheduler.fromState(L);

    const async = try scheduler.createAsync();

    async.* = .{
        .ref = .init(L),
        .op = .{
            .process_wait = .{
                .op = .init(self.child.id.?),
            },
        },
    };

    self.startAsync(async, L, scheduler);

    return L.yield(0);
}

pub fn __dtor(L: *VM.lua.State, self: *Child) void {
    self.stdin_file.deref(L);
    self.stdout_file.deref(L);
    self.stderr_file.deref(L);
}

pub fn create(L: *VM.lua.State, child: std.process.Child) !void {
    const self = try L.newuserdatataggedwithmetatable(Child, OBJECT_TAG);

    self.* = .{
        .child = child,
    };

    if (child.stdin) |file| {
        _ = try File.create(L, file, .Pipe, .{ .write = true });
        self.stdin_file = .init(L, -1, VM.lapi.index2addr(L, -1).gcvalue());
        self.stdin = file;
        L.pop(1);
    }
    if (child.stdout) |file| {
        _ = try File.create(L, file, .Pipe, .{ .read = true });
        self.stdout_file = .init(L, -1, VM.lapi.index2addr(L, -1).gcvalue());
        self.stdout = file;
        L.pop(1);
    }
    if (child.stderr) |file| {
        _ = try File.create(L, file, .Pipe, .{ .read = true });
        self.stderr_file = .init(L, -1, VM.lapi.index2addr(L, -1).gcvalue());
        self.stderr = file;
        L.pop(1);
    }
}
