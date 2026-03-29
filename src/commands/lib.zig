const std = @import("std");

pub const Command = struct {
    name: []const u8,
    execute: *const fn (allocator: std.mem.Allocator, args: []const []const u8) anyerror!void,
    aliases: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    template: ?[]const u8 = null,
    category: Categroy = .General,

    pub const Categroy = enum { General, Display };
};

pub fn initCommands(comptime commands: []const Command) std.StaticStringMap(Command) {
    var count = 0;

    for (commands) |command| {
        count += command.aliases.len;
        count += 1;
    }

    var list: [count]struct { []const u8, Command } = undefined;

    var i = 0;
    for (commands) |command| {
        list[i] = .{ command.name, command };
        i += 1;
        for (command.aliases) |alias| {
            list[i] = .{ alias, command };
            i += 1;
        }
    }

    return std.StaticStringMap(Command).initComptime(list);
}

const Execution = @import("execution.zig");

pub const Commands: []const Command = &.{
    Execution.RunCmd,
    Execution.TestCmd,
    Execution.DebugCmd,
    Execution.EvalCmd,
    @import("setup.zig").Command,
    @import("repl/lib.zig").Command,
    @import("init.zig").Command,
    @import("bundle.zig").Command,

    @import("luau.zig").Command,
    @import("help.zig").Command,
    @import("info.zig").Command,
};

pub const CommandMap = initCommands(Commands);

test {
    _ = Execution;
    _ = @import("setup.zig");
    _ = @import("repl/lib.zig");
    _ = @import("init.zig");
    _ = @import("bundle.zig");
    _ = @import("luau.zig");
    _ = @import("help.zig");
    _ = @import("info.zig");
}
