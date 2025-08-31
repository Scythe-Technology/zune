const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const VM = luau.VM;

var active = false;

var ticks: u64 = 0;
var currentTicks: u64 = 0;

var samples: u64 = 0;
var frequency: u64 = 10000;

var gcstats: [16]u64 = [_]u64{0} ** 16;

var callbacks: ?*VM.lua.Callbacks = null;

var STACK: std.ArrayList(u8) = .empty;
var DATA: std.StringHashMap(u64) = .init(std.heap.page_allocator);

var thread: ?std.Thread = null;

// This code is based on https://github.com/luau-lang/luau/blob/946a097e93fda5df23c9afaf29b101e168a03bd5/CLI/Profiler.cpp
fn interrupt(lua_state: *VM.lua.State, gc: c_int) !void {
    const L: *VM.lua.State = lua_state;

    const currTicks = ticks;
    const elapsedTicks = currTicks - currentTicks;

    if (elapsedTicks > 0) {
        STACK.clearRetainingCapacity();

        if (gc > 0)
            try STACK.appendSlice(std.heap.page_allocator, "GC,GC,");

        var level: i32 = 0;
        var ar: VM.lua.Debug = .{ .ssbuf = undefined };
        while (L.getinfo(level, "sn", &ar)) : (level += 1) {
            if (STACK.items.len > 0)
                try STACK.append(std.heap.page_allocator, ';');

            try STACK.appendSlice(std.heap.page_allocator, ar.short_src.?);
            try STACK.append(std.heap.page_allocator, ',');

            if (ar.name) |name|
                try STACK.appendSlice(std.heap.page_allocator, name);

            try STACK.append(std.heap.page_allocator, ',');

            var buf: [48]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{ar.linedefined.?}) catch unreachable;
            try STACK.appendSlice(std.heap.page_allocator, slice);
        }

        if (STACK.items.len > 0) {
            if (!DATA.contains(STACK.items))
                try DATA.put(try std.heap.page_allocator.dupe(u8, STACK.items), elapsedTicks)
            else {
                const entry = DATA.getEntry(STACK.items) orelse std.debug.panic("[Profiler] entry key not found", .{});
                entry.value_ptr.* += elapsedTicks;
            }
        }

        if (gc > 0)
            gcstats[@intCast(gc)] += elapsedTicks;
    }

    currentTicks = currTicks;
    if (callbacks) |cb|
        cb.*.interrupt = null;
}

fn lua_interrupt(lua_state: ?*VM.lua.State, gc: c_int) callconv(.c) void {
    const L: *VM.lua.State = @ptrCast(lua_state.?);
    interrupt(L, gc) catch |err| std.debug.panic("{}", .{err});
}

fn loop() void {
    var last = VM.lperf.clock();
    while (active) {
        const now = VM.lperf.clock();
        if (now - last >= 1.0 / @as(f64, @floatFromInt(frequency))) {
            const lticks: u64 = @intFromFloat((now - last) * 1e6);

            ticks += lticks;
            samples += 1;
            if (callbacks) |cb|
                cb.*.interrupt = lua_interrupt;

            last += @as(f64, @floatFromInt(ticks)) * 1e-6;
        } else {
            std.Thread.yield() catch |err| std.debug.print("[Profiler] Failed to yield thread: {}", .{err});
        }
    }
}

pub fn start(L: *VM.lua.State, freq: u64) !void {
    if (comptime builtin.single_threaded)
        return error.UnsupportedPlatform;
    const allocator = luau.getallocator(L);

    active = true;
    frequency = freq;
    callbacks = L.callbacks();

    thread = try std.Thread.spawn(.{ .allocator = allocator }, loop, .{});
}

pub fn end() void {
    active = false;
    if (thread) |t|
        t.join();
    STACK.deinit(std.heap.page_allocator);
}

pub fn dump(path: []const u8) void {
    const data_size = DATA.count();
    var total: u64 = 0;
    {
        const file = std.fs.cwd().createFile(path, .{}) catch |err| std.debug.panic("[Profiler] Failed to create file: {}", .{err});
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var file_writer = file.writer(&buffer);

        const writer = &file_writer.interface;

        var data_iter = DATA.iterator();
        while (data_iter.next()) |entry| {
            writer.print("{d} {s}\n", .{ entry.value_ptr.*, entry.key_ptr.* }) catch |err| std.debug.panic("[Profiler] Failed to write into file: {}", .{err});
            total += entry.value_ptr.*;
            std.heap.page_allocator.free(entry.key_ptr.*);
        }
        writer.flush() catch |err| std.debug.panic("[Profiler] Failed to flush file: {}", .{err});
        DATA.deinit();
    }
    std.debug.print("[Profiler] dump written to {s} (total runtime {d:.3} seconds, {d} samples, {d} stacks)\n", .{
        path,
        @as(f64, @floatFromInt(total)) / 1e6,
        samples,
        data_size,
    });
}
