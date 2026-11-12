const std = @import("std");
const luau = @import("luau");
const zio = @import("zio");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const Socket = Zune.objects.Socket;

pub const LIB_NAME = "net";
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => .Full,
        .freebsd => .Full,
        else => null,
    };
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

const Async = struct {
    pub const Open = struct {
        op: Op = undefined,
        ref: Scheduler.ThreadRef,

        const Op = zio.ev.NetOpen;

        pub fn callback(loop: *zio.ev.Loop, completion: *zio.ev.Completion) void {
            const op: *Op = @alignCast(@fieldParentPtr("c", completion));
            const self: *Open = @alignCast(@fieldParentPtr("op", op));
            const scheduler: *Scheduler = @alignCast(@fieldParentPtr("loop", loop));

            const L = self.ref.value;

            defer scheduler.allocator().destroy(self);
            defer self.ref.deref();

            const handle = op.getResult() catch |err|
                return Scheduler.resumeStateError(L, null, err) catch {};

            _ = Socket.create(L, .{
                .handle = handle,
                .address = undefined,
            }, .{}) catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeState(L, null, 1) catch {};
        }

        pub fn start(self: *Open, scheduler: *Scheduler) void {
            self.op.c.callback = callback;
            scheduler.loop.add(&self.op.c);
        }
    };
};

pub fn lua_openSocket(L: *VM.lua.State) !i32 {
    if (!L.isyieldable())
        return L.Zyielderror();

    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    const DomainMap = comptime Scripting.createEnumMap(zio.os.net.Domain);
    const TypeMap = comptime Scripting.createEnumMap(zio.os.net.Type);
    const ProtocolMap = comptime Scripting.createEnumMap(zio.os.net.Protocol);

    const domain: zio.os.net.Domain = blk: {
        if (L.typeOf(1) == .Number)
            break :blk @fromBackingInt(@intCast(try L.Zcheckvalue(u32, 1, null)));
        break :blk DomainMap.get(try L.Zcheckvalue([:0]const u8, 1, null)) orelse
            return L.Zerror("invalid domain option");
    };
    const @"type": zio.os.net.Type = blk: {
        if (L.typeOf(2) == .Number)
            break :blk @fromBackingInt(@intCast(try L.Zcheckvalue(u32, 2, null)));
        break :blk TypeMap.get(try L.Zcheckvalue([:0]const u8, 2, null)) orelse
            return L.Zerror("invalid type option");
    };
    const protocol: zio.os.net.Protocol = blk: {
        if (L.typeOf(3) == .Number)
            break :blk @fromBackingInt(@intCast(try L.Zcheckvalue(u32, 3, null)));
        break :blk ProtocolMap.get(try L.Zcheckvalue([:0]const u8, 3, null)) orelse
            return L.Zerror("invalid protocol option");
    };

    const open = try allocator.create(Async.Open);

    open.* = .{
        .ref = .init(L),
    };

    open.op = .init(domain, @"type", protocol, .{
        .nonblocking = true,
    });

    open.start(scheduler);

    return L.yield(0) catch unreachable;
}

pub fn lua_getAddressList(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
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
        try Socket.pushAddress(L, switch (address) {
            .ip4 => .{
                .ip = .initIp4(
                    address.ip4.bytes,
                    address.ip4.port,
                ),
            },
            .ip6 => .{
                .ip = .initIp6(
                    address.ip6.bytes,
                    address.ip6.port,
                    address.ip6.flow,
                    @intCast(address.ip6.scope()),
                ),
            },
        });
        try L.rawseti(-2, @intCast(i));
    }
    return 1;
}

pub const lua_forced_ADDRF = std.posix.AF;
pub const lua_forced_SOCK = std.posix.SOCK;
pub const lua_forced_IPPROTO = std.posix.IPPROTO;
