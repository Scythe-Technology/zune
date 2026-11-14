const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const File = Zune.objects.File;
const Dir = Zune.objects.Dir;
const BufferArray = Zune.objects.BufferArray;

pub const terminal = @import("./terminal.zig");

const mem = @import("../mem.zig");

const VM = luau.VM;

pub const LIB_NAME = "io";

const Async = struct {
    pub const PipeCreate = struct {
        op: Op = undefined,
        ref: Scheduler.ThreadRef,

        const Op = zio.ev.PipeCreate;

        pub fn callback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
            const op: *Op = @alignCast(@fieldParentPtr("c", completion));
            const self: *PipeCreate = @alignCast(@fieldParentPtr("op", op));
            const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));

            const L = self.ref.value;

            defer scheduler.allocator().destroy(self);
            defer self.ref.deref();

            const handle = op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            const read_file: std.Io.File = .{ .handle = handle[0], .flags = .{ .nonblocking = true } };
            const write_file: std.Io.File = .{ .handle = handle[1], .flags = .{ .nonblocking = true } };

            _ = File.create(L, read_file, .Pipe, .{
                .read = true,
                .write = false,
                .owned = true,
                .pollable = true,
            }) catch |e| {
                read_file.close(Zune.io());
                write_file.close(Zune.io());
                return Scheduler.resumeStateError(L, null, e) catch {};
            };
            _ = File.create(L, write_file, .Pipe, .{
                .read = false,
                .write = true,
                .owned = true,
                .pollable = true,
            }) catch |e| {
                write_file.close(Zune.io());
                return Scheduler.resumeStateError(L, null, e) catch {};
            };
            _ = Scheduler.resumeState(L, null, 2) catch {};
        }

        pub fn start(self: *PipeCreate, scheduler: *Scheduler) void {
            self.op.c.callback = callback;
            scheduler.loop.add(&self.op.c);
        }
    };
};

pub fn lua_createBufferArray(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const Options = struct {
        limit: u53 = std.math.maxInt(u53),
        size: u64 = 0,
    };

    const opts: Options = try L.Zcheckvalue(?Options, 1, null) orelse .{};

    if (opts.size > opts.limit)
        return L.Zerror("size cannot be larger than limit");

    const self = try L.newuserdatataggedwithmetatable(BufferArray, BufferArray.OBJECT_TAG);

    const ref_table: Scripting.ReferenceTable = try .init(L, true);

    const array_list: std.ArrayList(u8) = if (opts.size > 0) try .initCapacity(allocator, opts.size) else .empty;

    self.* = .{
        .alloc = allocator,
        .buf = array_list,
        .limit = opts.limit,
        .ref_table = ref_table,
    };

    return 1;
}

pub fn lua_createPipe(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    var pipe_create: zio.ev.PipeCreate = .init();

    if (!L.isyieldable()) {
        zio.ev.executeBlocking(&pipe_create.c, allocator);

        const handle = try pipe_create.getResult();

        {
            const read_file: std.Io.File = .{ .handle = handle[0], .flags = .{ .nonblocking = true } };
            errdefer read_file.close(Zune.io());
            _ = try File.create(L, read_file, .Pipe, .{
                .read = true,
                .write = false,
                .owned = true,
                .pollable = true,
            });
        }
        {
            const write_file: std.Io.File = .{ .handle = handle[1], .flags = .{ .nonblocking = true } };
            errdefer write_file.close(Zune.io());
            _ = try File.create(L, write_file, .Pipe, .{
                .read = false,
                .write = true,
                .owned = true,
                .pollable = true,
            });
        }

        return 2;
    }

    const async = try allocator.create(Async.PipeCreate);

    async.* = .{
        .ref = .init(L),
        .op = pipe_create,
    };

    async.start(scheduler);

    return L.yield(0) catch unreachable;
}

threadlocal var cwd_ref: Scripting.Reference = .empty;

pub fn cachedCwdRegistryId() ?i32 {
    if (!cwd_ref.valid())
        return null;
    return cwd_ref.id;
}

pub fn lua_cwd(L: *VM.lua.State) !i32 {
    if (cwd_ref.valid()) {
        cwd_ref.push(L);
    } else {
        _ = try Dir.create(L, std.Io.Dir.cwd(), .{
            .owned = false,
        });
        cwd_ref = .init(L, -1);
    }
    return 1;
}

pub fn lua_custom_stdin(L: *VM.lua.State) !void {
    const stdin = std.Io.File.stdin();
    _ = try File.create(L, stdin, .Pipe, .{ .read = true, .owned = false, .pollable = true });
}

pub fn lua_custom_stdout(L: *VM.lua.State) !void {
    const stdout = std.Io.File.stdout();
    _ = try File.create(L, stdout, .Pipe, .{ .write = true, .owned = false, .pollable = true });
}

pub fn lua_custom_stderr(L: *VM.lua.State) !void {
    const stderr = std.Io.File.stderr();
    _ = try File.create(L, stderr, .Pipe, .{ .write = true, .owned = false, .pollable = true });
}

pub fn __setup(_: *VM.lua.State) !void {
    cwd_ref = .empty;
}

pub const lua_terminal = if (terminal.SupportedPlatform()) struct {
    pub fn lua_enableRawMode(L: *VM.lua.State) !i32 {
        L.pushboolean(if (terminal.setRawMode()) true else |_| false);
        return 1;
    }

    pub fn lua_restoreMode(L: *VM.lua.State) !i32 {
        L.pushboolean(if (terminal.restoreSettings()) true else |_| false);
        return 1;
    }

    pub fn lua_getSize(L: *VM.lua.State) !i32 {
        const x, const y = try terminal.getSize();
        L.pushinteger(x);
        L.pushinteger(y);
        return 2;
    }

    pub fn lua_getCurrentMode(L: *VM.lua.State) !i32 {
        try switch (terminal.state.mode) {
            .Plain => L.pushstring("normal"),
            .Virtual => L.pushstring("raw"),
        };
        return 1;
    }

    pub fn lua_isTty(L: *VM.lua.State) !i32 {
        L.pushboolean(terminal.isStdInTty() and terminal.isStdOutTty() and terminal.isStdErrTty());
        return 1;
    }
} else null;
