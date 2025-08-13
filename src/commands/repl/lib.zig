const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const command = @import("../lib.zig");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const History = @import("History.zig");
const Terminal = @import("Terminal.zig");

const VM = luau.VM;

pub var REPL_STATE: u2 = 0;

var HISTORY: ?*History = null;
var TERMINAL: ?*Terminal = null;

pub fn SigInt() bool {
    if (REPL_STATE == 1) {
        REPL_STATE += 1;
        std.debug.print("\n^C again to exit.\n> ", .{});
        return true;
    }
    std.debug.print("\n", .{});
    if (HISTORY) |history| history.deinit();
    if (TERMINAL) |terminal| {
        terminal.restoreSettings() catch {};
        terminal.restoreOutputMode() catch {};
    }
    return false;
}

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    REPL_STATE = 1;

    var history = try History.init(allocator, ".zune/.history");
    errdefer history.deinit();

    HISTORY = &history;

    var L = try luau.init(&allocator);
    defer L.deinit();

    var scheduler = try Scheduler.init(allocator, L);
    defer scheduler.deinit();

    try Zune.Resolvers.Require.init(L);
    defer Zune.Resolvers.Require.deinit(L);

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Engine.prepAsync(L, &scheduler);
    try Zune.openZune(L, args, .{});

    try Engine.setLuaFileContext(L, .{
        .source = "",
        .main = true,
    });

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    var stdin = std.io.getStdIn();
    var in_reader = stdin.reader();

    const terminal = &(Zune.corelib.io.TERMINAL orelse std.debug.panic("Terminal not initialized", .{}));
    errdefer terminal.restoreSettings() catch {};
    errdefer terminal.restoreOutputMode() catch {};

    try terminal.validateInteractive();

    try terminal.saveSettings();

    TERMINAL = terminal;

    const out = terminal.stdout_writer;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var position: usize = 0;

    try terminal.setRawMode();
    try terminal.setOutputMode();

    switch (L.rawgetfield(luau.VM.lua.GLOBALSINDEX, "_VERSION")) {
        .String => try out.print("{s}\n", .{L.tostring(-1).?}),
        else => try out.writeAll("Unknown Zune version\n"),
    }
    L.pop(1);

    try out.writeAll("> ");
    while (true) {
        const input_byte = try in_reader.readByte();
        if (input_byte != 3 and input_byte != 4 and REPL_STATE == 2) {
            buffer.clearAndFree();
            position = 0;
            REPL_STATE = 1;
        }
        switch (input_byte) {
            0x1B => {
                if (try in_reader.readByte() != '[')
                    continue;
                var currentByte = try in_reader.readByte();
                var modifier: Terminal.MODIFIER = .{};
                switch (currentByte) {
                    '1' => {
                        if (try in_reader.readByte() != ';')
                            continue;
                        switch (try in_reader.readByte()) {
                            '2' => modifier = .init(false, true, false),
                            '3' => modifier = .init(false, false, true),
                            '4' => modifier = .init(false, true, true),
                            '5' => modifier = .init(true, false, false),
                            '6' => modifier = .init(true, false, true),
                            else => continue,
                        }
                        currentByte = try in_reader.readByte();
                    },
                    else => {},
                }
                switch (currentByte) {
                    'A' => { // Up Arrow
                        if (history.size() == 0)
                            continue;
                        if (history.isLatest())
                            history.saveTemp(buffer.items);
                        if (history.previous()) |line| {
                            buffer.clearRetainingCapacity();
                            try buffer.appendSlice(line);
                            position = line.len;

                            try terminal.clearLine();
                            try out.print("> {s}", .{line});
                        }
                    },
                    'B' => { // Down Arrow
                        if (history.next()) |line| {
                            buffer.clearRetainingCapacity();
                            try buffer.appendSlice(line);
                            position = line.len;

                            try terminal.clearLine();
                            try out.print("> {s}", .{buffer.items});
                        }
                        if (history.isLatest())
                            history.clearTemp();
                    },
                    'C' => { // Right Arrow
                        if (position == buffer.items.len)
                            continue;
                        if (modifier.onlyCtrl()) {
                            const slice = buffer.items[position..];
                            const front = std.mem.indexOfAny(u8, slice, Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Right, slice.len);
                                position = buffer.items.len;
                                continue;
                            };
                            const index = (std.mem.indexOfNone(u8, slice[front..], Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Right, slice.len);
                                position = buffer.items.len;
                                continue;
                            }) + front;
                            try terminal.moveCursor(.Right, index);
                            position += index;
                        } else if (modifier.none()) {
                            try terminal.moveCursor(.Right, 1);
                            position += 1;
                        }
                    },
                    'D' => { // Left Arrow
                        if (position == 0)
                            continue;
                        if (modifier.onlyCtrl()) {
                            const slice = buffer.items[0..position];
                            const back = std.mem.lastIndexOfNone(u8, slice, Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Left, @intCast(position));
                                position = 0;
                                continue;
                            };
                            const index = slice.len - (std.mem.lastIndexOfAny(u8, slice[0..back], Terminal.NON_LETTER) orelse {
                                try terminal.moveCursor(.Left, @intCast(position));
                                position = 0;
                                continue;
                            }) - 1;
                            try terminal.moveCursor(.Left, index);
                            position -= index;
                        } else if (modifier.none()) {
                            try terminal.moveCursor(.Left, 1);
                            position -= 1;
                        }
                    },
                    else => {},
                }
            },
            Terminal.NEW_LINE => {
                try terminal.newLine();

                history.save(buffer.items);

                const ML = try L.newthread();

                if (Engine.loadModule(ML, "CLI", buffer.items, null)) {
                    try terminal.setNormalMode();

                    Engine.runAsync(ML, &scheduler, .{ .cleanUp = false }) catch ML.pop(1);

                    try terminal.setRawMode();
                } else |err| switch (err) {
                    error.Syntax => {
                        try out.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
                        ML.pop(1);
                    },
                    else => return err,
                }

                L.pop(1); // drop: thread

                history.reset();

                buffer.clearAndFree();
                position = 0;

                try terminal.clearStyles();
                try out.writeAll("> ");
            },
            127 => { // Backspace
                if (position == 0)
                    continue;
                const append = position < buffer.items.len;
                try out.writeByte(8);
                position -= 1;
                _ = buffer.orderedRemove(position);
                try terminal.clearEndToCursor();
                if (append)
                    try terminal.writeAllRetainCursor(buffer.items[position..]);
            },
            23 => { // Ctrl+Backspace
                const slice = buffer.items[0..position];
                if (slice.len == 0)
                    continue;
                const append = position < buffer.items.len;
                const index: usize = blk: {
                    const back = std.mem.lastIndexOfNone(u8, slice, Terminal.NON_LETTER) orelse break :blk position;
                    break :blk slice.len - (std.mem.lastIndexOfAny(u8, slice[0..back], Terminal.NON_LETTER) orelse break :blk position) - 1;
                };
                for (0..index) |_| {
                    try out.writeByte(8);
                    position -= 1;
                    _ = buffer.orderedRemove(position);
                    try terminal.clearEndToCursor();
                    if (append)
                        try terminal.writeAllRetainCursor(buffer.items[position..]);
                }
            },
            3, 4 => {
                if (REPL_STATE > 0 and SigInt())
                    continue;
                break;
            },
            else => |b| {
                var byte: u8 = b;
                switch (byte) {
                    22...31 => continue,
                    9 => byte = ' ',
                    else => {},
                }
                const append = position < buffer.items.len;
                try buffer.insert(position, byte);
                try out.writeByte(byte);
                position += 1;
                if (append)
                    try terminal.writeAllRetainCursor(buffer.items[position..]);
            },
        }
    }
}

pub const Command = command.Command{
    .name = "repl",
    .execute = Execute,
};
