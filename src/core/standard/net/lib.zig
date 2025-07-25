const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;

const VM = luau.VM;

const Socket = @import("../../objects/network/Socket.zig");

pub const LIB_NAME = "net";
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn createSocket(domain: u32, flags: u32, protocol: u32) !std.posix.socket_t {
    return switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").socket(domain, flags, protocol),
        else => try std.posix.socket(domain, flags, protocol),
    };
}

fn lua_createSocket(L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();
    const domain = L.Lcheckunsigned(1);
    const flags = L.Lcheckunsigned(2);
    const protocol = L.Lcheckunsigned(3);

    const socket = try createSocket(domain, flags, protocol);

    _ = try Socket.push(L, socket, .created);

    return 1;
}

fn lua_getAddressList(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const name = L.Lcheckstring(1);
    const port = L.Lcheckunsigned(2);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const list = try std.net.getAddressList(allocator, name, @intCast(port));
    defer list.deinit();
    if (list.addrs.len > std.math.maxInt(i32))
        return L.Zerror("AddressListTooLarge");
    try L.createtable(@intCast(list.addrs.len), 0);
    for (list.addrs, 1..) |address, i| {
        var buf: [Socket.LONGEST_ADDRESS]u8 = undefined;
        try L.Zpushvalue(.{
            .family = address.any.family,
            .port = address.getPort(),
            .address = Socket.AddressToString(&buf, address),
        });
        try L.rawseti(-2, @intCast(i));
    }
    return 1;
}

fn ImportConstants(L: *VM.lua.State, namespace: anytype, comptime name: [:0]const u8) !void {
    try L.createtable(0, @typeInfo(namespace).@"struct".decls.len);

    inline for (@typeInfo(namespace).@"struct".decls) |field|
        try L.Zsetfield(-1, field.name, @as(i32, @field(namespace, field.name)));

    L.setreadonly(-1, true);
    try L.rawsetfield(-2, name);
}

pub fn loadLib(L: *VM.lua.State) !void {
    try L.createtable(0, 8);

    try L.Zsetfieldfn(-1, "createSocket", lua_createSocket);
    try L.Zsetfieldfn(-1, "getAddressList", lua_getAddressList);

    try ImportConstants(L, std.posix.AF, "ADDRF");
    try ImportConstants(L, std.posix.SOCK, "SOCKF");
    try ImportConstants(L, std.posix.IPPROTO, "IPPROTO");
    try ImportConstants(L, std.posix.SO, "SOCKOPT");
    try ImportConstants(L, std.posix.SOL, "SOCKOPTLV");

    {
        try @import("http/lib.zig").load(L);
        try L.rawsetfield(-2, "http");
    }

    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = @import("http/request.zig");
}
test {
    _ = @import("http/response.zig");
}
test {
    _ = @import("http/websocket.zig");
}

test "net" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/net/init.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
