const std = @import("std");

const Zune = @import("zune");

const Commands = @import("commands/lib.zig");

const CommandMap = Commands.CommandMap;

pub fn start(args: [][:0]u8) !void {
    if (args.len < 2) {
        const command = CommandMap.get("help") orelse @panic("Help command missing.");
        return command.execute(Zune.DEFAULT_ALLOCATOR, &.{});
    }

    if (CommandMap.get(args[1])) |command|
        return command.execute(Zune.DEFAULT_ALLOCATOR, args[2..]);

    std.debug.print("unknown command, try 'help' or '-h'\n", .{});
    std.process.exit(1);
}

test {
    _ = Commands;
}
