const std = @import("std");
const xev = @import("xev").Dynamic;
const builtin = @import("builtin");

const LUAU_VERSION = @import("luau").LUAU_VERSION;

const Zune = @import("zune");

const command = @import("lib.zig");

const zune_info = @import("zune-info");

fn Execute(_: std.mem.Allocator, args: []const []const u8) !void {
    Zune.debug.print("<bold>version<clear>:  {s}\n", .{zune_info.version});
    Zune.debug.print("<bold>luau<clear>:     {d}.{d}\n", .{ LUAU_VERSION.major, LUAU_VERSION.minor });
    Zune.debug.print("<bold>async<clear>:    <green>{t}<clear>\n", .{xev.backend});
    Zune.debug.print("<bold>platform<clear>: {t}-{t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag, builtin.abi });
    Zune.debug.print("<bold>threaded<clear>: {} (<green>{}<clear> threads)\n", .{
        !builtin.single_threaded,
        if (builtin.single_threaded) 1 else std.Thread.getCpuCount() catch 1,
    });
    Zune.debug.print("<bold>build<clear>:    {t}\n", .{builtin.mode});

    if (args.len < 1 or !std.mem.eql(u8, args[0], "all"))
        return;

    Zune.debug.print("<bold>libraries<clear>:\n", .{});
    const longest_name: comptime_int = comptime blk: {
        var max = 0;
        for (@typeInfo(Zune.corelib).@"struct".decls) |decl|
            max = @max(max, decl.name.len);
        break :blk max;
    };
    inline for (@typeInfo(Zune.corelib).@"struct".decls) |decl| {
        const lib = @field(Zune.corelib, decl.name);
        const padding = " " ** (longest_name - decl.name.len);
        if (@hasDecl(lib, "PlatformSupported")) {
            if (lib.PlatformSupported())
                Zune.debug.print("  {s}:{s} <green>supported<clear>\n", .{ decl.name, padding })
            else
                Zune.debug.print("  {s}:{s} <red>unsupported<clear>\n", .{ decl.name, padding });
        } else Zune.debug.print("  {s}:{s} <blue>native<clear>\n", .{ decl.name, padding });
    }
}

pub const Command = command.Command{
    .name = "info",
    .execute = Execute,
    .aliases = &.{
        "-V",
        "--version",
        "version",
    },
};
