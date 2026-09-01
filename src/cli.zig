const std = @import("std");

const Zune = @import("zune");

const Commands = @import("commands/lib.zig");

const CommandMap = Commands.CommandMap;

pub fn start(args: []const [:0]const u8) !void {
    if (args.len < 2) {
        const command = comptime CommandMap.get("help") orelse unreachable;
        return command.execute(Zune.DEFAULT_ALLOCATOR, &.{});
    }

    if (CommandMap.get(args[1])) |command|
        return command.execute(Zune.DEFAULT_ALLOCATOR, args[2..]);

    Zune.quitMsg("<red>error<clear>: unknown command, try 'help' or '-h'\n", .{});
}

test {
    _ = Commands;
}
