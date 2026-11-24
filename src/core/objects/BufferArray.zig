const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Stream = Zune.objects.Stream;

const VM = luau.VM;

const hash = std.crypto.hash;

const BufferArray = @This();

pub const OBJECT_TAG = Zune.Tags.get("IO_BUFFERARRAY").?;

alloc: std.mem.Allocator,
buf: std.ArrayList(u8),
limit: usize,
offset: usize = 0,

pub fn lua_direct_len(self: *BufferArray, res: *VM.lobject.TValue) void {
    res.setnvalue(@floatFromInt(self.buf.items.len));
}

pub fn lua_direct_offset(self: *BufferArray, res: *VM.lobject.TValue) void {
    res.setnvalue(@floatFromInt(self.offset));
}

pub fn lua_seekTo(self: *BufferArray, L: *VM.lua.State) !i32 {
    const offset = try L.Zcheckvalue(u53, 2, null);
    self.offset = @min(offset, self.buf.items.len);
    return 0;
}

pub fn lua_grow(self: *BufferArray, L: *VM.lua.State) !i32 {
    const size = try L.Zcheckvalue(u53, 2, null);
    if (size == 0)
        return 0;
    const end = std.math.add(usize, self.buf.items.len, size) catch return L.Zerror("limit exceeded");
    if (end > self.limit)
        return L.Zerror("limit exceeded");
    const old_len = self.buf.items.len;
    try self.buf.resize(self.alloc, end);
    @memset(self.buf.items[old_len..], 0);
    return 0;
}

pub fn lua_append(self: *BufferArray, L: *VM.lua.State) !i32 {
    const buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(@floatFromInt(0));
            return 1;
        },
        else => return err,
    };
    const end = std.math.add(usize, self.buf.items.len, buf.len) catch {
        L.pushnumber(@floatFromInt(0));
        try L.pushlstring("limit exceeded");
        return 2;
    };
    if (end > self.limit) {
        L.pushnumber(@floatFromInt(0));
        try L.pushlstring("limit exceeded");
        return 2;
    }
    try self.buf.appendSlice(self.alloc, buf);
    L.pushnumber(@floatFromInt(buf.len));
    return 1;
}

pub fn lua_read(self: *BufferArray, L: *VM.lua.State) !i32 {
    const buf = Scripting.getControlledBuffer(L, []u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(@floatFromInt(0));
            return 1;
        },
        else => return err,
    };
    const len = @min(buf.len, self.buf.items.len - self.offset);
    std.mem.copyForwards(u8, buf[0..len], self.buf.items[self.offset .. self.offset + len]);
    self.offset += len;
    L.pushnumber(@floatFromInt(len));
    return 1;
}

pub fn lua_readPositional(self: *BufferArray, L: *VM.lua.State) !i32 {
    const offset = try L.Zcheckvalue(u53, 2, null);
    const buf = Scripting.getControlledBuffer(L, []u8, 3) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(@floatFromInt(0));
            return 1;
        },
        else => return err,
    };
    if (offset > self.buf.items.len) {
        L.pushnumber(@floatFromInt(0));
        try L.pushlstring("out of bounds");
        return 2;
    }
    const len = @min(buf.len, self.buf.items.len - offset);
    std.mem.copyForwards(u8, buf[0..len], self.buf.items[offset .. offset + len]);
    L.pushnumber(@floatFromInt(len));
    return 1;
}

pub fn writeAt(self: *BufferArray, offset: usize, bytes: []const u8) !void {
    if (bytes.len == 0)
        return;
    const end = std.math.add(usize, offset, bytes.len) catch return error.LimitExceeded;
    if (end > self.limit)
        return error.LimitExceeded;

    if (end > self.buf.items.len) {
        const old_len = self.buf.items.len;
        try self.buf.resize(self.alloc, end);
        if (offset > old_len)
            @memset(self.buf.items[old_len..offset], 0);
    }
    std.mem.copyForwards(u8, self.buf.items[offset..end], bytes);
}

pub fn write(self: *BufferArray, bytes: []const u8) !usize {
    try self.writeAt(self.offset, bytes);
    self.offset += bytes.len;
    return bytes.len;
}

pub fn lua_write(self: *BufferArray, L: *VM.lua.State) !i32 {
    const buf = Scripting.getControlledBuffer(L, []const u8, 2) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(@floatFromInt(0));
            return 1;
        },
        else => return err,
    };
    const n = self.write(buf) catch |err| switch (err) {
        error.LimitExceeded => {
            L.pushnumber(@floatFromInt(0));
            try L.pushlstring("limit exceeded");
            return 2;
        },
        else => {
            L.pushnumber(@floatFromInt(0));
            try L.pushlstring(@errorName(err));
            return 2;
        },
    };
    L.pushnumber(@floatFromInt(n));
    return 1;
}

pub fn lua_writePositional(self: *BufferArray, L: *VM.lua.State) !i32 {
    const offset_raw = try L.Zcheckvalue(u53, 2, null);
    if (offset_raw > @as(u53, @truncate(self.limit))) {
        L.pushnumber(@floatFromInt(0));
        try L.pushlstring("out of bounds");
        return 2;
    }
    const offset: usize = @intCast(offset_raw);
    const buf = Scripting.getControlledBuffer(L, []const u8, 3) catch |err| switch (err) {
        error.NoSpace => {
            L.pushnumber(@floatFromInt(0));
            return 1;
        },
        else => return err,
    };
    self.writeAt(offset, buf) catch |err| switch (err) {
        error.LimitExceeded => {
            L.pushnumber(@floatFromInt(0));
            try L.pushlstring("limit exceeded");
            return 2;
        },
        else => {
            L.pushnumber(@floatFromInt(0));
            try L.pushlstring(@errorName(err));
            return 2;
        },
    };
    L.pushnumber(@floatFromInt(buf.len));
    return 1;
}

pub fn dropFront(self: *BufferArray, n: usize) void {
    const len = self.buf.items.len;
    const drop = @min(n, len);
    if (drop == 0)
        return;
    if (drop < len)
        std.mem.copyForwards(u8, self.buf.items[0 .. len - drop], self.buf.items[drop..len]);
    self.buf.shrinkRetainingCapacity(len - drop);
    self.offset = @min(self.offset, self.buf.items.len);
}

pub fn lua_dropFront(self: *BufferArray, L: *VM.lua.State) !i32 {
    const n = try L.Zcheckvalue(u53, 2, null);
    self.dropFront(@min(n, self.buf.items.len));
    return 0;
}

pub fn lua_clear(self: *BufferArray, L: *VM.lua.State) !i32 {
    _ = L;
    self.offset = 0;
    self.buf.clearAndFree(self.alloc);
    return 0;
}

pub fn lua_dupe(self: *BufferArray, L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const copy = try L.newuserdatataggedwithmetatable(BufferArray, BufferArray.OBJECT_TAG);

    const array_list: std.ArrayList(u8) = try self.buf.clone(allocator);

    copy.* = .{
        .alloc = allocator,
        .buf = array_list,
        .limit = self.limit,
    };

    return 1;
}

pub fn __dtor(L: *VM.lua.State, self: *BufferArray) void {
    _ = L;
    self.buf.deinit(self.alloc);
}

pub fn to(L: *VM.lua.State, idx: i32) ?*BufferArray {
    return L.touserdatatagged(BufferArray, idx, OBJECT_TAG);
}
