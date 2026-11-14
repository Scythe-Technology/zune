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

    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const len = try std.process.executableDirPath(Zune.io(), buf[1..]);

    const name = args[1];
    const cmd_dir = std.fs.path.sep_str ++ "lib" ++ std.fs.path.sep_str ++ "cmd" ++ std.fs.path.sep_str;
    if (buf.len - 1 - len > cmd_dir.len + name.len + 5) jmp: {
        buf[0] = '@';
        var writer: std.Io.Writer = .fixed(buf[0..]);
        writer.end = 1 + len;
        _ = writer.write(cmd_dir) catch {};
        _ = writer.write(name) catch {};
        _ = writer.write(".luau") catch {};
        _ = writer.writeByte(0) catch {};

        const target = buf[0 .. writer.end - 1 :0];
        const contents: []u8 = blk: {
            const file = std.Io.Dir.openFileAbsolute(Zune.io(), target[1..], .{}) catch break :jmp;
            defer file.close(Zune.io());

            var reader = file.reader(Zune.io(), &.{});
            break :blk reader.interface.allocRemainingAlignedSentinel(Zune.DEFAULT_ALLOCATOR, .unlimited, .of(u8), null) catch |err| switch (err) {
                error.ReadFailed => return reader.err.?,
                error.OutOfMemory, error.StreamTooLong => |e| return e,
            };
        };
        defer Zune.DEFAULT_ALLOCATOR.free(contents);

        return Commands.Command.executeScript(contents, target, Zune.DEFAULT_ALLOCATOR, args[1..]);
    }

    Zune.quitMsg("<red>error<clear>: unknown command, try 'help' or '-h'\n", .{});
}

test {
    _ = Commands;
}
