const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const command = @import("lib.zig");

const USAGE = "usage: luau <list-fflags | version>\n";
fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        return std.debug.print(USAGE, .{});
    }

    if (std.mem.eql(u8, args[0], "list-fflags")) {
        var long_name: usize = 0;

        const bool_flags = luau.FFlags.Get(bool);
        const int_flags = luau.FFlags.Get(i32);

        {
            var iter = bool_flags.iterator();
            while (iter.next()) |flag|
                long_name = @max(long_name, std.mem.span(flag.name).len);
            var iter2 = int_flags.iterator();
            while (iter2.next()) |flag|
                long_name = @max(long_name, std.mem.span(flag.name).len);
        }

        {
            inline for (&[_]type{ bool, i32 }) |t| {
                const flags = luau.FFlags.Get(t);
                var iter = flags.iterator();
                while (iter.next()) |flag| {
                    const name = std.mem.span(flag.name);
                    const pad_size = (long_name - name.len) + 2;

                    var padding = try allocator.alloc(u8, pad_size);
                    defer allocator.free(padding);

                    for (0..pad_size) |i|
                        padding[i] = '.';

                    if (t == bool) {
                        if (flag.value) Zune.debug.print(
                            "<bold>{s} <dim>{s}<clear> = (<bold><yellow>bool<clear>) <bold><green>true<clear>\n",
                            .{
                                name,
                                padding,
                            },
                        ) else Zune.debug.print(
                            "<bold>{s} <dim>{s}<clear> = (<bold><yellow>bool<clear>) <bold><red>false<clear>\n",
                            .{
                                name,
                                padding,
                            },
                        );
                    } else {
                        Zune.debug.print(
                            "<bold>{s} <dim>{s}<clear> = (<bold><bcyan>int<clear>)  <bold><yellow>{d}<clear>\n",
                            .{
                                name,
                                padding,
                                flag.value,
                            },
                        );
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, args[0], "version")) {
        std.debug.print("{}.{}\n", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor });
    } else {
        return std.debug.print(USAGE, .{});
    }
}

pub const Command = command.Command{
    .name = "luau",
    .execute = Execute,
};
