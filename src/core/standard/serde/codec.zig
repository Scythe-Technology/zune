const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

const Flate = @import("../../utils/flate.zig");

const VM = luau.VM;

inline fn isOutOfBounds(offset: u32, len: usize, access: usize) bool {
    return access + offset > len;
}

pub fn sourceWindow(L: *VM.lua.State) ![]const u8 {
    const src = try Scripting.getReadable(L, 3);
    const src_offset = try L.Zcheckvalue(u32, 4, null);
    const count = try L.Zcheckvalue(?u32, 5, null);

    if (isOutOfBounds(src_offset, src.len, count orelse 0))
        return L.Zerror("access out of bounds");

    const n: usize = if (count) |c| c else src.len - src_offset;

    return src[src_offset..][0..n];
}

pub fn destTail(L: *VM.lua.State) ![]u8 {
    const dest = try Scripting.getWritable(L, 1);
    const dest_offset = try L.Zcheckvalue(u32, 2, null);
    if (dest_offset > dest.len)
        return L.Zerror("access out of bounds");
    return dest[dest_offset..];
}

fn flateLevel(L: *VM.lua.State) !u4 {
    if (L.typeOf(6).isnoneornil())
        return 6;
    const num = try L.Zcheckvalue(i32, 6, null);
    if (num < 1 or num > 9)
        return L.Zerror("options 'level' must be between 1 and 9");
    return @intCast(num);
}

pub fn calcSize(L: *VM.lua.State, container: std.compress.flate.Container) !i32 {
    const len = try L.Zcheckvalue(u32, 1, null);
    const bound = Flate.compressBound(container, len);
    if (bound > std.math.maxInt(u32))
        return L.Zerror("no space");
    L.pushunsigned(@intCast(bound));
    return 1;
}

pub fn compress(L: *VM.lua.State, container: std.compress.flate.Container) !i32 {
    const src = try sourceWindow(L);
    const dest = try destTail(L);
    const level = try flateLevel(L);
    const n = Flate.compressInto(dest, src, container, Flate.optionsFromLevel(level)) catch |err| switch (err) {
        error.NoSpace => return L.Zerror("no space"),
        else => return err,
    };
    L.pushunsigned(@intCast(n));
    return 1;
}

pub fn decompress(L: *VM.lua.State, container: std.compress.flate.Container) !i32 {
    const src = try sourceWindow(L);
    const dest = try destTail(L);
    const n = Flate.decompressInto(dest, src, container) catch |err| switch (err) {
        error.WriteFailed => return L.Zerror("no space"),
        else => return err,
    };
    L.pushunsigned(@intCast(n));
    return 1;
}
