// This code is based on https://gist.github.com/nurpax/4afcb6e4ef3f03f0d282f7c462005f12
const std = @import("std");
const builtin = @import("builtin");

const Status = enum {
    Passed,
    Failed,
    Skipped,
};

const Printer = struct {
    out: *std.Io.Writer,

    inline fn fmt(self: *Printer, comptime format: []const u8, args: anytype) void {
        self.out.print(format, args) catch @panic("OOM");
    }

    fn status(self: *Printer, s: Status, comptime format: []const u8, args: anytype) void {
        self.out.writeAll(switch (s) {
            .Failed => "\x1b[31m",
            .Passed => "\x1b[32m",
            .Skipped => "\x1b[33m",
        }) catch @panic("OOM");
        self.fmt(format, args);
        self.fmt("\x1b[0m", .{});
        self.out.flush() catch @panic("OOM");
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 12 }) = .init;
    const io = std.testing.io;
    const alloc = gpa.allocator();
    const fail_first = blk: {
        if (init.environ_map.get("TEST_FAIL_FIRST")) |e| {
            defer alloc.free(e);
            break :blk std.mem.eql(u8, e, "true");
        }
        break :blk false;
    };

    const stderr = std.Io.File.stderr();
    var buffer: [1024]u8 = undefined;
    var err_writer = stderr.writer(io, &buffer);
    const writer = &err_writer.interface;
    var printer: Printer = .{
        .out = writer,
    };

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var leaked: usize = 0;

    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        std.testing.environ = init.minimal.environ;
        var status = Status.Passed;

        std.debug.print("{s}...\n", .{t.name});

        const result = t.func();

        if (std.testing.allocator_instance.deinit() == .leak) {
            leaked += 1;
            printer.status(.Failed, "[Error] \"{s}\" (Memory Leak)\n", .{t.name});
        }

        if (result) |_|
            passed += 1
        else |err| {
            switch (err) {
                error.SkipZigTest => {
                    skipped += 1;
                    status = .Skipped;
                },
                else => {
                    status = .Failed;
                    failed += 1;
                    printer.status(.Failed, "[Error] \"{s}\": {s}\n", .{ t.name, @errorName(err) });
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    if (fail_first)
                        break;
                },
            }
        }

        printer.fmt("{s} ", .{t.name});
        printer.status(status, "[{s}]\n", .{@tagName(status)});
    }

    const total_tests = passed + failed;
    const status: Status = if (failed == 0)
        .Passed
    else
        .Failed;
    printer.status(status, "\n{d} of {d} test{s} passed\n", .{ passed, total_tests, if (total_tests != 1) "s" else "" });
    if (skipped > 0)
        printer.status(.Skipped, "{d} test{s} skipped\n", .{ skipped, if (skipped != 1) "s" else "" });
    if (leaked > 0)
        printer.status(.Failed, "{d} test{s} leaked\n", .{ leaked, if (leaked != 1) "s" else "" });
    std.process.exit(if (failed == 0 and leaked == 0) 0 else 1);
}
