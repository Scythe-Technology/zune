const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

const flate = std.compress.flate;

const Flate = @import("../utils/flate.zig");

const BufferArray = Zune.objects.BufferArray;

const VM = luau.VM;

const DeflateStream = @This();

pub const OBJECT_TAG = Zune.Tags.get("SERDE_DEFLATE").?;

array: Scripting.ValueReference(*BufferArray),
container: flate.Container,
level: u4,
window: [flate.max_window_len]u8 = undefined,
out_buf: [4096]u8 = undefined,
writer: std.Io.Writer,
compress: flate.Compress,
finished: bool = false,

pub fn lua_direct_array(self: *DeflateStream, res: *VM.lobject.TValue) void {
    if (!self.array.valid())
        return res.setnilvalue();
    const udata: *VM.lobject.Udata = @alignCast(@fieldParentPtr("data", @as(*[1]u8, @ptrCast(@alignCast(self.array.value)))));
    res.value.gc = udata.obj2gco();
    res.settype(.Userdata);
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *DeflateStream = @alignCast(@fieldParentPtr("writer", w));
    self.emit(w.buffered()) catch return error.WriteFailed;
    _ = w.consumeAll();
    if (data.len == 0)
        return 0;
    const n = std.Io.Writer.countSplat(data, splat);
    for (data[0 .. data.len - 1]) |bytes|
        self.emit(bytes) catch return error.WriteFailed;
    const pattern = data[data.len - 1];
    for (0..splat) |_|
        self.emit(pattern) catch return error.WriteFailed;
    return n;
}

fn emit(self: *DeflateStream, bytes: []const u8) !void {
    if (bytes.len == 0)
        return;
    const array = self.array.value;
    try array.writeAt(array.buf.items.len, bytes);
}

fn sync(self: *DeflateStream) !void {
    const pending = self.writer.buffered();
    if (pending.len == 0)
        return;
    try self.emit(pending);
    _ = self.writer.consumeAll();
}

fn reset(self: *DeflateStream) !void {
    _ = self.writer.consumeAll();
    self.compress = try flate.Compress.init(&self.writer, &self.window, self.container, Flate.optionsFromLevel(self.level));
    self.finished = false;
    try self.sync();
}

pub fn lua_write(self: *DeflateStream, L: *VM.lua.State) !i32 {
    const buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushunsigned(0);
            return 1;
        },
        else => return err,
    };
    const failed = blk: {
        if (self.finished)
            self.reset() catch |err| break :blk err;
        var reader: std.Io.Reader = .fixed(buf);
        _ = reader.streamRemaining(&self.compress.writer) catch |err| {
            self.finished = true;
            break :blk err;
        };
        self.sync() catch |err| break :blk err;
        L.pushunsigned(@intCast(buf.len));
        return 1;
    };
    L.pushunsigned(0);
    const text: []const u8 = switch (failed) {
        error.WriteFailed, error.LimitExceeded => "limit exceeded",
        else => @errorName(failed),
    };
    try L.pushlstring(text);
    return 2;
}

pub fn lua_finish(self: *DeflateStream, L: *VM.lua.State) !i32 {
    if (!self.finished) {
        self.compress.finish() catch |err| switch (err) {
            error.WriteFailed => {
                self.finished = true;
                return L.Zerror("limit exceeded");
            },
            else => |e| return e,
        };
        self.finished = true;
    }
    self.sync() catch |err| switch (err) {
        error.LimitExceeded => return L.Zerror("limit exceeded"),
        else => |e| return e,
    };
    return 0;
}

pub fn lua_reset(self: *DeflateStream, L: *VM.lua.State) !i32 {
    self.reset() catch |err| switch (err) {
        error.WriteFailed, error.LimitExceeded => return L.Zerror("limit exceeded"),
        else => return err,
    };
    return 0;
}

pub fn lua_swapArray(self: *DeflateStream, L: *VM.lua.State) !i32 {
    const new = BufferArray.to(L, 2) orelse return L.Zerror("expected BufferArray");
    try self.array.swap(L, 2, new);
    if (!self.finished)
        return 0;
    self.reset() catch |err| switch (err) {
        error.WriteFailed, error.LimitExceeded => return L.Zerror("limit exceeded"),
        else => return err,
    };
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *DeflateStream) void {
    self.array.deref(L);
}

pub fn create(L: *VM.lua.State, container: flate.Container) !i32 {
    const array = BufferArray.to(L, 1) orelse return L.Zerror("expected BufferArray");
    const level: u4 = if (L.typeOf(2).isnoneornil()) 6 else blk: {
        const num = try L.Zcheckvalue(i32, 2, null);
        if (num < 1 or num > 9)
            return L.Zerror("options 'level' must be between 1 and 9");
        break :blk @intCast(num);
    };
    const self = try L.newuserdatataggedwithmetatable(DeflateStream, OBJECT_TAG);
    self.* = .{
        .array = .init(L, 1, array),
        .container = container,
        .level = level,
        .writer = .{
            .vtable = &.{
                .drain = drain,
                .flush = std.Io.Writer.defaultFlush,
                .rebase = std.Io.Writer.defaultRebase,
            },
            .buffer = undefined,
        },
        .compress = undefined,
    };
    self.writer.buffer = &self.out_buf;
    self.reset() catch return L.Zerror("limit exceeded");
    return 1;
}
