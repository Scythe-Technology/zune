const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const argon2 = std.crypto.pwhash.argon2;
const bcrypt = std.crypto.pwhash.bcrypt;

const AlgorithmUnion = union(enum) {
    argon2: argon2.Mode,
    bcrypt: void,
};

const DEFAULT_ALGO: AlgorithmUnion = .{ .argon2 = .argon2id };
const AlgorithmMap = std.StaticStringMap(AlgorithmUnion).initComptime(.{
    .{ "argon2d", AlgorithmUnion{ .argon2 = .argon2d } },
    .{ "argon2i", AlgorithmUnion{ .argon2 = .argon2i } },
    .{ "argon2id", DEFAULT_ALGO },
    .{ "bcrypt", .bcrypt },
});

pub fn lua_hash(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const password = try L.Zcheckvalue([]const u8, 1, null);

    var algorithm = DEFAULT_ALGO;
    var cost: u32 = 65536;
    var cost2: u32 = 2;
    var threads: u24 = 1;

    switch (L.typeOf(2)) {
        .Table => {
            if (try L.Zcheckfield(?[:0]const u8, 2, "algorithm")) |option|
                algorithm = AlgorithmMap.get(option) orelse return L.Zerror("invalid algorithm kind");
            L.pop(1);
            switch (algorithm) {
                .argon2 => {
                    cost = try L.Zcheckfield(?u32, 2, "memory_cost") orelse cost;
                    cost2 = try L.Zcheckfield(?u32, 2, "time_cost") orelse cost2;
                    threads = try L.Zcheckfield(?u24, 2, "threads") orelse threads;
                    L.pop(3);
                },
                .bcrypt => {
                    cost = 4;
                    cost = try L.Zcheckfield(?u32, 2, "cost") orelse cost;
                    if (cost < 4 or cost > 31)
                        return L.Zerror("invalid cost (Must be between 4 to 31)");
                    L.pop(1);
                },
            }
        },
        .None, .Nil => {},
        else => try L.Zchecktype(2, .Table),
    }

    var buf: [128]u8 = undefined;
    switch (algorithm) {
        .argon2 => |mode| {
            const hash = try argon2.strHash(password, .{
                .allocator = allocator,
                .params = .{ .m = cost, .t = cost2, .p = threads },
                .mode = mode,
            }, &buf);
            L.pushlstring(hash);
        },
        .bcrypt => {
            const hash = try bcrypt.strHash(password, .{
                .allocator = allocator,
                .params = .{ .rounds_log = @intCast(cost), .silently_truncate_password = false },
                .encoding = .phc,
            }, &buf);
            L.pushlstring(hash);
        },
    }
    return 1;
}

const TAG_BCRYPT: u32 = @bitCast([4]u8{ '$', 'b', 'c', 'r' });

pub fn lua_verify(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const password = try L.Zcheckvalue([]const u8, 1, null);
    const hash = try L.Zcheckvalue([]const u8, 2, null);

    if (hash.len < 8)
        return L.Zerror("InvalidHash (Must be PHC encoded)");

    if (@as(u32, @bitCast(hash[0..4].*)) == TAG_BCRYPT)
        L.pushboolean(if (bcrypt.strVerify(
            hash,
            password,
            .{
                .allocator = allocator,
                .silently_truncate_password = false,
            },
        )) true else |_| false)
    else
        L.pushboolean(if (argon2.strVerify(
            hash,
            password,
            .{ .allocator = allocator },
        )) true else |_| false);

    return 1;
}
