const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;

const VM = luau.VM;

pub const LIB_NAME = "task";

pub fn lua_wait(L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zerror("attempt to yield across metamethod/C-call boundary");
    const scheduler = Scheduler.fromState(L);
    const time = L.tonumber(1) orelse 0;

    scheduler.sleepThread(L, null, time, 0, true);

    return L.yield(0) catch unreachable; // error is only when context is not yieldable and OOM
}

pub fn lua_cancel(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.fromState(L);

    try L.Zchecktype(1, .Thread);

    const thread = L.tothread(1) orelse return L.Zerror("expected thread");

    scheduler.cancelThread(thread);

    switch (L.costatus(thread)) {
        .Finished, .FinishedErr, .Suspended => {},
        .Normal => return 0,
        .Running => return L.Zerror("cannot close running coroutine"),
    }

    scheduler.policy.remove(thread);

    try thread.resetthread();

    return 0;
}

pub fn lua_spawn(L: *VM.lua.State) !i32 {
    const fn_type = L.typeOf(1);
    if (fn_type != .Function and fn_type != .Thread)
        return L.Zerror("expected function or thread");

    const top = L.gettop();
    const args = top - 1;

    const thread = th: {
        if (fn_type == .Function) {
            const TL = try L.newthread();
            L.xpush(TL, 1);
            break :th TL;
        } else {
            L.pushvalue(1);
            break :th L.tothread(1) orelse return L.Zerror("thread failed");
        }
    };

    if (thread.status() != .Yield and L.costatus(thread) != .Suspended) {
        return L.Zerror("cannot resume non-suspended coroutine");
    }

    if (args > 0) {
        try thread.rawcheckstack(args);
        for (0..@intCast(args)) |i|
            L.xpush(thread, @intCast(i + 2));
    }

    _ = Scheduler.resumeState(thread, L, @intCast(args)) catch {};

    return 1;
}

pub fn lua_defer(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.fromState(L);
    const fn_type = L.typeOf(1);
    if (fn_type != .Function and fn_type != .Thread)
        return L.Zerror("expected function or thread");

    const top = L.gettop();
    const args = top - 1;

    const thread = th: {
        if (fn_type == .Function) {
            const TL = try L.newthread();
            L.xpush(TL, 1);
            break :th TL;
        } else {
            L.pushvalue(1);
            break :th L.tothread(1) orelse return L.Zerror("thread failed");
        }
    };

    if (thread.status() != .Yield and L.costatus(thread) != .Suspended) {
        return L.Zerror("cannot resume non-suspended coroutine");
    }

    try thread.rawcheckstack(args + 1);
    if (args > 0) {
        for (0..@intCast(args)) |i|
            L.xpush(thread, @intCast(i + 2));
    }

    try scheduler.deferThread(.init(thread), null, @intCast(args));

    return 1;
}

pub fn lua_delay(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.fromState(L);
    const time = L.Lchecknumber(1);
    const fn_type = L.typeOf(2);
    if (fn_type != .Function and fn_type != .Thread)
        return L.Zerror("expected function or thread");

    const top = L.gettop();
    const args = top - 2;

    const thread = th: {
        if (fn_type == .Function) {
            const TL = try L.newthread();
            L.xpush(TL, 2);
            break :th TL;
        } else {
            L.pushvalue(2);
            break :th L.tothread(2) orelse return L.Zerror("thread failed");
        }
    };

    if (thread.status() != .Yield and L.costatus(thread) != .Suspended) {
        return L.Zerror("cannot resume non-suspended coroutine");
    }

    if (args > 0) {
        try thread.rawcheckstack(args);
        for (0..@intCast(args)) |i|
            L.xpush(thread, @intCast(i + 3));
    }

    scheduler.sleepThread(thread, null, time, @intCast(args), false);

    return 1;
}

pub fn lua_limit(L: *VM.lua.State) !i32 {
    const seconds = L.Lchecknumber(1);
    if (!(seconds > 0))
        return L.Zerror("invalid timeout");

    const fn_type = L.typeOf(2);
    if (fn_type != .Function and fn_type != .Thread)
        return L.Zerror("expected function or thread");

    const args = L.gettop() - 2;
    const thread = th: {
        if (fn_type == .Function) {
            const TL = try L.newthread();
            L.xpush(TL, 2);
            break :th TL;
        } else {
            L.pushvalue(2);
            break :th L.tothread(2) orelse return L.Zerror("thread failed");
        }
    };
    if (thread.status() != .Yield and L.costatus(thread) != .Suspended)
        return L.Zerror("cannot resume non-suspended coroutine");

    if (args > 0) {
        try thread.rawcheckstack(args);
        for (0..args) |i|
            L.xpush(thread, @intCast(i + 3));
    }

    Scheduler.fromState(L).policy.limit(thread, seconds);

    switch (Scheduler.resumeThread(thread, L, @intCast(args))) {
        .Ok, .Yield, .Break => return 1,
        .ErrMem => return error.OutOfMemory,
        else => {
            const msg = thread.tostring(-1) orelse "execution timeout";
            try L.pushlstring(msg);
            return error.RaiseLuauError;
        },
    }

    return 1;
}

pub fn lua_count(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.fromState(L);
    const kind = L.tolstring(1) orelse {
        var total: usize = 0;
        total += scheduler.sleeping.items.len;
        total += scheduler.deferred.count();
        total += scheduler.awaiting;
        total += if (!Scheduler.loopDone(&scheduler.loop)) @as(usize, 1) else @as(usize, 0);
        L.pushnumber(@floatFromInt(total));
        return 1;
    };

    var out: i32 = 0;

    for (kind) |c| {
        if (out > 4)
            return L.Zerror("too many kinds");
        switch (c) {
            's' => {
                out += 1;
                L.pushnumber(@floatFromInt(scheduler.sleeping.items.len));
            },
            'd' => {
                out += 1;
                L.pushnumber(@floatFromInt(scheduler.deferred.count()));
            },
            'w' => {
                out += 1;
                L.pushnumber(@floatFromInt(scheduler.awaiting));
            },
            't' => {
                out += 1;
                L.pushnumber(@floatFromInt(if (!Scheduler.loopDone(&scheduler.loop)) @as(usize, 1) else @as(usize, 0)));
            },
            else => return L.Zerror("invalid kind"),
        }
    }

    return out;
}
