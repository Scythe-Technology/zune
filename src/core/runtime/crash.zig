const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Runtime = Zune.Runtime;

const VM = luau.VM;

const SegfaultCase = enum {
    GeneralProtection,
    SegmentViolation,
    IllegalInstruction,
    BusError,
    FloatingPointException,

    // Windows
    UnalignedMemoryAccess,
    StackOverflow,
};

fn dumpLuauStackTrace(L: *VM.lua.State, stderr: *std.Io.Writer) !void {
    const allocator = luau.getallocator(L);

    var list = try Runtime.Debug.getStackTrace(L, allocator);
    defer list.deinit(allocator);
    defer Runtime.Debug.freeStackTrace(allocator, list.items);

    try Runtime.Debug.dumpStackTrace(stderr, list.items, 1);
}

fn dumpSegfaultInfo(case: SegfaultCase, addr: usize, stderr: *std.Io.Writer) !void {
    try Runtime.Debug.writerPrint(stderr, "<red>fatal exception<clear>: ", .{});
    _ = try switch (case) {
        .GeneralProtection => Runtime.Debug.writerPrint(stderr, "General protection exception (no address available)\n", .{}),
        .SegmentViolation => Runtime.Debug.writerPrint(stderr, "Segmentation fault at address 0x{x}\n", .{addr}),
        .IllegalInstruction => Runtime.Debug.writerPrint(stderr, "Illegal instruction at address 0x{x}\n", .{addr}),
        .BusError => Runtime.Debug.writerPrint(stderr, "Bus error at address 0x{x}\n", .{addr}),
        .FloatingPointException => Runtime.Debug.writerPrint(stderr, "Arithmetic exception at address 0x{x}\n", .{addr}),
        .StackOverflow => Runtime.Debug.writerPrint(stderr, "Stack overflow\n", .{}),
        .UnalignedMemoryAccess => Runtime.Debug.writerPrint(stderr, "Unaligned memory access\n", .{}),
    };

    if (Zune.corelib.c.CALLING_STATE) |L| {
        jmp: {
            if (Zune.STATE.BUNDLE) |b|
                if (b.mode.compiled == .release)
                    break :jmp;
            try dumpLuauStackTrace(L, stderr);
        }
        try Runtime.Debug.writerPrint(stderr, "<yellow>cause<clear>: This is most likely caused by the loaded external module.\n\n", .{});
    } else {
        if (Runtime.Scheduler.RUNNING_STATE) |L| {
            jmp: {
                if (Zune.STATE.BUNDLE) |b|
                    if (b.mode.compiled == .release)
                        break :jmp;
                try dumpLuauStackTrace(L, stderr);
            }
        }
        try Runtime.Debug.writerPrint(stderr, "<yellow>cause<clear>: This is most likely a bug in zune. Please report this to the developers.\n\n", .{});
    }

    try Runtime.Debug.writerPrint(stderr, "- Report this issue at <green><bold><underline>https://zune.sh/issues<clear> if you find this to be a bug in zune.\n", .{});
}

// Based on Zig, lib/std/debug.zig
var windows_segfault_handle: ?std.os.windows.HANDLE = null;
fn attachSegfaultHandler() void {
    if (comptime builtin.os.tag == .windows) {
        windows_segfault_handle = std.os.windows.kernel32.AddVectoredExceptionHandler(0, handleSegfaultWindows);
        return;
    }
    const act = std.posix.Sigaction{
        .handler = .{ .sigaction = handleSegfaultPosix },
        .mask = std.posix.sigemptyset(),
        .flags = (std.posix.SA.SIGINFO | std.posix.SA.RESTART | std.posix.SA.RESETHAND),
    };
    std.debug.updateSegfaultHandler(&act);
}

fn resetSegfaultHandler() void {
    if (builtin.os.tag == .windows) {
        if (windows_segfault_handle) |handle| {
            std.debug.assert(std.os.windows.kernel32.RemoveVectoredExceptionHandler(handle) != 0);
            windows_segfault_handle = null;
        }
        return;
    }
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.debug.updateSegfaultHandler(&act);
}

fn waitForOtherThreadToFinishPanicking() void {
    if (panicking.fetchSub(1, .seq_cst) != 1) {
        // Another thread is panicking, wait for the last one to finish
        // and call abort()
        if (builtin.single_threaded) unreachable;

        // Sleep forever without hammering the CPU
        var futex = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&futex, 0);
        unreachable;
    }
}

var panicking = std.atomic.Value(u8).init(0);
threadlocal var panic_stage: usize = 0;
fn handleSegfaultPosix(sig: i32, info: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) noreturn {
    // Reset to the default handler so that if a segfault happens in this handler it will crash
    // the process. Also when this handler returns, the original instruction will be repeated
    // and the resulting segfault will crash the process rather than continually dump stack traces.
    resetSegfaultHandler();

    const addr = switch (builtin.os.tag) {
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .freebsd, .macos => @intFromPtr(info.addr),
        .netbsd => @intFromPtr(info.info.reason.fault.addr),
        .openbsd => @intFromPtr(info.data.fault.addr),
        .solaris, .illumos => @intFromPtr(info.reason.fault.addr),
        else => unreachable,
    };

    const code = if (builtin.os.tag == .netbsd) info.info.code else info.code;
    nosuspend switch (panic_stage) {
        0 => {
            panic_stage = 1;
            _ = panicking.fetchAdd(1, .seq_cst);

            {
                const stderr = std.debug.lockStderrWriter(&.{});
                defer std.debug.unlockStderrWriter();

                const case: SegfaultCase = switch (sig) {
                    std.posix.SIG.SEGV => if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux and code == 128) // SI_KERNEL
                        // x86_64 doesn't have a full 64-bit virtual address space.
                        // Addresses outside of that address space are non-canonical
                        // and the CPU won't provide the faulting address to us.
                        // This happens when accessing memory addresses such as 0xaaaaaaaaaaaaaaaa
                        // but can also happen when no addressable memory is involved;
                        // for example when reading/writing model-specific registers
                        // by executing `rdmsr` or `wrmsr` in user-space (unprivileged mode).
                        .GeneralProtection
                    else
                        .SegmentViolation,
                    std.posix.SIG.ILL => .IllegalInstruction,
                    std.posix.SIG.BUS => .BusError,
                    std.posix.SIG.FPE => .FloatingPointException,
                    else => unreachable,
                };

                dumpSegfaultInfo(case, addr, stderr) catch std.posix.abort();
            }

            waitForOtherThreadToFinishPanicking();
        },
        1 => {
            panic_stage = 2;
            std.fs.File.stderr().writeAll("aborting due to recursive panic\n") catch {};
        },
        else => {},
    };

    // We cannot allow the signal handler to return because when it runs the original instruction
    // again, the memory may be mapped and undefined behavior would occur rather than repeating
    // the segfault. So we simply abort here.
    std.posix.abort();
}

fn handleSegfaultWindows(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const case: SegfaultCase = switch (info.ExceptionRecord.ExceptionCode) {
        std.os.windows.EXCEPTION_DATATYPE_MISALIGNMENT => .UnalignedMemoryAccess,
        std.os.windows.EXCEPTION_ACCESS_VIOLATION => .SegmentViolation,
        std.os.windows.EXCEPTION_ILLEGAL_INSTRUCTION => .IllegalInstruction,
        std.os.windows.EXCEPTION_STACK_OVERFLOW => .StackOverflow,
        else => return std.os.windows.EXCEPTION_CONTINUE_SEARCH,
    };

    // For backends that cannot handle the language features used by this segfault handler, we have a simpler one,
    switch (builtin.zig_backend) {
        .stage2_x86_64 => if (builtin.target.ofmt == .coff) @trap(),
        else => {},
    }

    comptime std.debug.assert(std.os.windows.CONTEXT != void);
    nosuspend switch (panic_stage) {
        0 => {
            panic_stage = 1;
            _ = panicking.fetchAdd(1, .seq_cst);

            {
                const stderr = std.debug.lockStderrWriter(&.{});
                defer std.debug.unlockStderrWriter();

                const addr: usize = switch (case) {
                    .UnalignedMemoryAccess => 0,
                    .SegmentViolation => info.ExceptionRecord.ExceptionInformation[1],
                    .IllegalInstruction => info.ContextRecord.getRegs().ip,
                    .StackOverflow => 0,
                    else => unreachable,
                };

                dumpSegfaultInfo(case, addr, stderr) catch std.posix.abort();
            }

            waitForOtherThreadToFinishPanicking();
        },
        1 => {
            panic_stage = 2;
            std.fs.File.stderr().writeAll("aborting due to recursive panic\n") catch {};
        },
        else => {},
    };
    std.posix.abort();
}

pub fn init() void {
    switch (comptime builtin.os.tag) {
        .windows, .macos, .linux => attachSegfaultHandler(),
        else => @compileError("TODO"),
    }
}
