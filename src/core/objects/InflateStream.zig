const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

const flate = std.compress.flate;

const BufferArray = Zune.objects.BufferArray;

const VM = luau.VM;

const InflateStream = @This();

pub const OBJECT_TAG = Zune.Tags.get("SERDE_INFLATE").?;

const Snapshot = struct {
    decompress: flate.Decompress,
    seek: usize,
    end: usize,
};

array: Scripting.ValueReference(*BufferArray),
input: std.Io.Reader,
window: [flate.max_window_len]u8 = undefined,
decompress: flate.Decompress,
closed: bool = false,

pub fn lua_direct_array(self: *InflateStream, res: *VM.lobject.TValue) void {
    if (!self.array.valid())
        return res.setnilvalue();
    const udata: *VM.lobject.Udata = @alignCast(@fieldParentPtr("data", @as(*[1]u8, @ptrCast(@alignCast(self.array.value)))));
    res.value.gc = udata.obj2gco();
    res.settype(.Userdata);
}

fn atEnd(self: *InflateStream) bool {
    return std.meta.activeTag(self.decompress.state) == .end;
}

fn bind(self: *InflateStream) void {
    const array = self.array.value;
    const items = array.buf.items;
    self.input.buffer = items;
    self.input.seek = array.offset;
    self.input.end = items.len;
}

fn pump(self: *InflateStream) anyerror!void {
    self.bind();
    defer self.array.value.offset = self.input.seek;
    var steps: usize = 0;
    while (!self.atEnd()) {
        steps += 1;
        if (steps > 8)
            break;
        const window = &self.decompress.reader;
        if (window.bufferedLen() != 0)
            break;
        if (window.buffer.len - window.end < flate.history_len) {
            const discard = @min(window.seek, window.end - flate.history_len);
            if (discard != 0) {
                const keep = window.buffer[discard..window.end];
                std.mem.copyForwards(u8, window.buffer[0..keep.len], keep);
                window.end = keep.len;
                window.seek -= discard;
            }
        }
        const saved: Snapshot = .{
            .decompress = self.decompress,
            .seek = self.input.seek,
            .end = self.input.end,
        };
        var hole: [0]u8 = .{};
        var sink = std.Io.Writer.fixed(&hole);
        if (window.stream(&sink, .unlimited)) |_| {
            const progressed = self.decompress.reader.end != saved.decompress.reader.end or
                self.atEnd() or
                self.input.seek != saved.seek or
                self.decompress.consumed_bits != saved.decompress.consumed_bits or
                std.meta.activeTag(self.decompress.state) != std.meta.activeTag(saved.decompress.state);
            if (!progressed)
                break;
        } else |e| switch (e) {
            error.EndOfStream => break,
            else => {
                const err = if (e == error.ReadFailed) self.decompress.err orelse error.ReadFailed else e;
                self.decompress = saved.decompress;
                self.input.seek = saved.seek;
                self.input.end = saved.end;
                if (err == error.EndOfStream and !self.closed)
                    break;
                return err;
            },
        }
    }
}

pub fn lua_read(self: *InflateStream, L: *VM.lua.State) !i32 {
    const dest = Scripting.getControlledBuffer(L, []u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushunsigned(0);
            return 1;
        },
        else => return err,
    };
    var filled: usize = 0;
    const window = &self.decompress.reader;
    while (filled < dest.len) {
        const ready = window.buffered();
        if (ready.len > 0) {
            const n = @min(dest.len - filled, ready.len);
            @memcpy(dest[filled..][0..n], ready[0..n]);
            window.toss(n);
            filled += n;
            continue;
        }
        if (self.atEnd())
            break;
        const end_before = window.end;
        const in_before = self.array.value.offset;
        self.pump() catch |err| {
            if (filled > 0)
                break;
            switch (err) {
                error.OutOfMemory => return err,
                error.EndOfStream => {
                    L.pushunsigned(0);
                    try L.pushlstring("truncated");
                    return 2;
                },
                else => {
                    L.pushunsigned(0);
                    try L.pushlstring("bad flate");
                    return 2;
                },
            }
        };
        if (window.bufferedLen() == 0 and window.end == end_before and self.input.seek == in_before)
            break;
    }
    L.pushunsigned(@intCast(filled));
    return 1;
}

pub fn lua_finish(self: *InflateStream, L: *VM.lua.State) !i32 {
    self.closed = true;
    const window = &self.decompress.reader;
    while (!self.atEnd()) {
        const end_before = window.end;
        const in_before = self.array.value.offset;
        self.pump() catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.EndOfStream => return L.Zerror("truncated"),
            else => return L.Zerror("bad flate"),
        };
        if (window.end == end_before and self.input.seek == in_before)
            break;
    }
    return 0;
}

pub fn __dtor(L: *VM.lua.State, self: *InflateStream) void {
    self.array.deref(L);
}

fn inputStream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
    return error.EndOfStream;
}

fn inputRebase(_: *std.Io.Reader, _: usize) std.Io.Reader.RebaseError!void {
    return error.EndOfStream;
}

pub fn create(L: *VM.lua.State, container: flate.Container) !i32 {
    const array = BufferArray.to(L, 1) orelse return L.Zerror("expected BufferArray");
    const self = try L.newuserdatataggedwithmetatable(InflateStream, OBJECT_TAG);
    self.* = .{
        .array = .init(L, 1, array),
        .input = .{
            .vtable = &.{
                .stream = inputStream,
                .rebase = inputRebase,
            },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },
        .decompress = undefined,
    };
    self.bind();
    self.decompress = .init(&self.input, container, &self.window);
    return 1;
}
