const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

pub var COMMAND_THREAD: ?*VM.lua.State = null;

pub fn isAllowed(L: *VM.lua.State) bool {
    return COMMAND_THREAD == L;
}

pub const Command = struct {
    name: []const u8,
    execute: *const fn (allocator: std.mem.Allocator, args: []const [:0]const u8) anyerror!void,
    aliases: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    template: ?[]const u8 = null,
    flags: ?Flags = null,
    category: Category = .General,

    pub const Category = enum { General, Display };

    const Flags = struct {
        display: []const u8,
        pub fn construct(flags: anytype) Flags {
            var content: []const u8 = "";

            var padding_len: comptime_int = 0;
            for (flags) |flag| {
                padding_len = @max(flag[0].len, padding_len);
            }

            for (flags) |flag| {
                const padding: [padding_len + 2 - flag[0].len]u8 = @splat(' ');
                content = content ++ "  " ++ flag[0] ++ padding ++ flag[1] ++ "\n";
            }

            return .{ .display = content };
        }
    };

    pub const Options = struct {
        name: []const u8,
        aliases: []const []const u8 = &.{},
        description: ?[]const u8 = null,
        template: ?[]const u8 = null,
        flags: ?Flags = null,
        category: Category = .General,
    };

    const Forward = struct {
        args: []const [:0]const u8,
    };
    fn lua_cmdForward(L: *VM.lua.State) !i32 {
        if (!isAllowed(L))
            return L.Zerror("API can only be used in command context");
        try L.Zchecktype(1, .Table);

        const f = L.tolightuserdata(?Forward, VM.lua.upvalueindex(1)) orelse @panic("unreachable");
        if (f.* != null)
            return L.Zerror("command forward already set");

        const allocator = Scheduler.fromState(L).allocator();

        var forward_args: std.ArrayList([:0]const u8) = .empty;
        errdefer forward_args.deinit(allocator);
        errdefer for (forward_args.items) |item| allocator.free(item);

        try forward_args.append(allocator, Zune.State.bin_arg);

        var iter: Scripting.ArrayIterator = .{ .L = L, .idx = -1 };
        while (try iter.next()) |t| switch (t) {
            .String => {
                const copy = try allocator.dupeSentinel(u8, L.tostring(-1).?, 0);
                errdefer allocator.free(copy);
                try forward_args.append(allocator, copy);
            },
            else => return L.Zerrorf("argument is not a string (got {s})", .{VM.lapi.typename(t)}),
        };

        const copy_args = try forward_args.toOwnedSlice(allocator);

        f.* = .{
            .args = copy_args,
        };

        return 0;
    }

    pub fn executeScript(
        source: []const u8,
        path: [:0]const u8,
        allocator: std.mem.Allocator,
        args: []const [:0]const u8,
    ) !void {
        Zune.State.args = args;

        var forward: ?Forward = null;
        defer if (forward) |f| {
            for (f.args[1..]) |item|
                allocator.free(item);
            allocator.free(f.args);
        };

        {
            var L = try luau.VM.lstate.Lnewstate();
            defer L.deinit();
            var scheduler = try Scheduler.init(allocator);
            defer scheduler.deinit();

            scheduler.setup(L);

            try Zune.initState(L, allocator);
            defer Zune.deinitState(L, allocator);

            try Engine.prep(L);
            try Zune.openZune(L, .{ .limbo = false });

            L.pushlightuserdata(&forward);
            try L.pushcclosure(Scripting.toCFn(lua_cmdForward), "zune_cmdForward", 1);
            try L.rawsetglobal("cmdForward");

            L.setsafeenv(VM.lua.GLOBALSINDEX, true);

            const ML = try L.newthread();

            COMMAND_THREAD = ML;
            defer COMMAND_THREAD = null;

            try ML.Lsandboxthread();

            ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

            Engine.loadModule(ML, path, source, .{}) catch |err| switch (err) {
                error.Syntax => {
                    std.debug.print("Syntax: {s}\n", .{ML.tostring(-1) orelse "unknown"});
                    return err;
                },
            };

            Engine.runAsync(ML, &scheduler, .{}) catch std.process.exit(1);
        }

        if (forward) |f|
            try Zune.cli.start(f.args);
    }
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
    Execution.DebugCmd,

    @import("help.zig").Command,
    @import("info.zig").Command,
};

pub const CommandMap = initCommands(Commands);

test {
    _ = Execution;
    _ = @import("help.zig");
    _ = @import("info.zig");
}
