const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;

const VM = luau.VM;

const Socket = @import("../../objects/network/Socket.zig");
const sysfd = @import("../../utils/sysfd.zig");

pub const LIB_NAME = "net";
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => true,
        .freebsd => true,
        else => false,
    };
}

pub fn createSocket(domain: u32, flags: u32, protocol: u32) !std.posix.socket_t {
    return sysfd.socket(domain, flags, protocol);
}

pub fn lookupAddresses(allocator: std.mem.Allocator, name: []const u8, port: u16) ![]std.Io.net.IpAddress {
    const host = try std.Io.net.HostName.init(name);
    var storage: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
    try host.lookup(Zune.io(), &queue, .{ .port = port });

    var list: std.ArrayList(std.Io.net.IpAddress) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        var item: [1]std.Io.net.HostName.LookupResult = undefined;
        const n = queue.getUncancelable(Zune.io(), &item, 0) catch |err| switch (err) {
            error.Closed => break,
        };
        if (n == 0) break;
        switch (item[0]) {
            .address => |address| try list.append(allocator, address),
            .canonical_name => {},
        }
    }
    return list.toOwnedSlice(allocator);
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
    const allocator = Scheduler.fromState(L).allocator;
    const name = L.Lcheckstring(1);
    const port = L.Lcheckunsigned(2);
    if (port > std.math.maxInt(u16))
        return L.Zerror("port out of range");
    const list = try lookupAddresses(allocator, name, @intCast(port));
    defer allocator.free(list);
    if (list.len > std.math.maxInt(i32))
        return L.Zerror("address list too large");
    try L.createtable(@intCast(list.len), 0);
    for (list, 1..) |address, i| {
        var buf: [Socket.LONGEST_ADDRESS]u8 = undefined;
        try L.Zpushvalue(.{
            .family = @as(i32, switch (address) {
                .ip4 => std.posix.AF.INET,
                .ip6 => std.posix.AF.INET6,
            }),
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
        TestRunner.newTestFile("standard/net/init.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
