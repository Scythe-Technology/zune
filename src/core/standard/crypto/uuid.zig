const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const UUID = u128;

fn format(uuid: UUID, buf: []u8) void {
    std.debug.assert(buf.len >= 36);
    _ = std.fmt.bufPrint(buf, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>12}", .{
        @byteSwap(@as(u32, @intCast(uuid & 0xFFFFFFFF))),
        @byteSwap(@as(u16, @intCast((uuid >> 32) & 0xFFFF))),
        @byteSwap(@as(u16, @intCast((uuid >> 48) & 0xFFFF))),
        @as(u8, @intCast((uuid >> 64) & 0xFF)),
        @as(u8, @intCast((uuid >> 72) & 0xFF)),
        @byteSwap(@as(u48, @intCast((uuid >> 80) & 0xFFFFFFFFFFFF))),
    }) catch unreachable;
}

pub fn lua_v4(L: *VM.lua.State) !i32 {
    var uuid: u128 = std.crypto.random.int(UUID);

    uuid &= 0xFFFFFFFFFFFFFF3FFF0FFFFFFFFFFFFF;
    uuid |= 0x00000000000000800040000000000000;

    var buf: [36]u8 = undefined;

    format(uuid, buf[0..]);

    try L.pushlstring(buf[0..]);

    return 1;
}

pub fn lua_v7(L: *VM.lua.State) !i32 {
    const ms = @as(u48, @truncate(@as(u64, @intCast(std.time.milliTimestamp())) & 0xFFFFFFFFFFFF));

    var uuid: UUID = @as(UUID, @intCast(std.crypto.random.int(u80))) << 48;

    uuid |= @as(UUID, @intCast(@byteSwap(ms)));
    uuid &= 0xFFFFFFFFFFFFFF3FFF0FFFFFFFFFFFFF;
    uuid |= 0x00000000000000800070000000000000;

    var buf: [36]u8 = undefined;

    format(uuid, buf[0..]);

    try L.pushlstring(buf[0..]);

    return 1;
}
