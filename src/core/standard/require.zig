const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;

const VM = luau.VM;

pub const LIB_NAME = "require";

const LuaContext = struct {
    allocator: std.mem.Allocator,
    contents: ?[]const u8,
    accessed: bool = false,

    pub fn getConfig(self: *LuaContext, _: []const u8, err: ?*?[]const u8) !Zune.Resolvers.Config {
        if (self.accessed)
            return error.NotPresent;
        self.accessed = true;
        return Zune.Resolvers.Config.parse(self.allocator, self.contents orelse return error.NotPresent, err);
    }
    pub fn freeConfig(self: *LuaContext, config: *Zune.Resolvers.Config) void {
        config.deinit(self.allocator);
    }
    pub fn resolvePathAlloc(_: *LuaContext, a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
        return std.fs.path.resolve(a, &.{ from, to });
    }
};

fn lua_navigate(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const path = try L.Zcheckvalue([]const u8, 1, null);
    const from = try L.Zcheckvalue(?[]const u8, 2, null);
    const config = try L.Zcheckvalue(?[]const u8, 3, null);

    var context: LuaContext = .{
        .contents = config,
        .allocator = allocator,
    };

    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    {
        var level: i32 = 1;
        while (true) : (level += 1) {
            if (!L.getinfo(level, "s", &ar))
                return L.Zerror("could not get source");
            if (ar.what == .lua)
                break;
        }
    }

    const src = from orelse blk: {
        const ctx = ar.source orelse return error.BadContext;
        if (std.mem.startsWith(u8, ctx, "@")) {
            break :blk ctx[1..];
        } else break :blk ctx;
    };

    var err_msg: ?[]const u8 = null;
    defer if (err_msg) |msg| allocator.free(msg);
    const script_path = Zune.Resolvers.Navigator.navigate(allocator, &context, src, path, &err_msg) catch |err| switch (err) {
        error.SyntaxError, error.AliasNotFound, error.AliasPathNotSupported, error.AliasJumpFail => return L.Zerrorf("{s}", .{err_msg.?}),
        error.PathUnsupported => return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix"),
        else => return err,
    };
    defer allocator.free(script_path);

    try L.pushlstring(script_path);

    return 1;
}

fn lua_getCached(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const resolved_path = try L.Zcheckvalue([]const u8, 1, null);
    _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);

    for (Zune.Resolvers.File.POSSIBLE_EXTENSIONS) |ext| {
        const path = try std.mem.concatWithSentinel(allocator, u8, &.{ resolved_path, ext }, 0);
        defer allocator.free(path);
        if (!L.rawgetfield(-1, path).isnoneornil())
            return 1;
        L.pop(1);
    }

    L.pushnil();
    return 1;
}

pub fn loadLib(L: *VM.lua.State) !void {
    try L.Zpushvalue(.{
        .navigate = lua_navigate,
        .getCached = lua_getCached,
    });
    L.setreadonly(-1, true);
    try LuaHelper.registerModule(L, LIB_NAME);
}

test "require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/require/init.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
