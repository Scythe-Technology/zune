const std = @import("std");
const builtin = @import("builtin");

const Zune = @import("zune");

const command = @import("lib.zig");

const LuauCommandMap = std.hash_map.StringHashMapUnmanaged(LuauCommandEntry);

const LuauCommandEntry = struct {
    content: []const u8,

    pub const DESCRIPTION_TAG = "--- @description ";
    pub const EXAMPLE_TAG = "--- @example ";

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

fn scanLuauCommands(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    map: *LuauCommandMap,
) !void {
    var iter = dir.iterate();
    while (try iter.next(Zune.io())) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub_dir = try dir.openDir(Zune.io(), entry.name, .{ .iterate = true });
                defer sub_dir.close(Zune.io());

                const new_path = std.fs.path.join(allocator, &.{ path, entry.name }) catch continue;
                defer allocator.free(new_path);

                scanLuauCommands(allocator, sub_dir, new_path, map) catch {};
            },
            .file => {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".luau"))
                    continue;
                var handled: bool = false;
                const new_path = std.fs.path.join(allocator, &.{ path, std.fs.path.stem(entry.name) }) catch continue;
                defer if (!handled) allocator.free(new_path);
                if (new_path.len > 16)
                    continue;

                if (comptime builtin.os.tag == .windows)
                    std.mem.replaceScalar(u8, new_path, '\\', '/');

                if (std.mem.indexOfNone(u8, new_path, "._/$#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") != null)
                    continue;

                const contents = dir.readFileAlloc(Zune.io(), entry.name, allocator, .limited(32 * 1024)) catch continue;
                errdefer allocator.free(contents);

                try map.put(allocator, new_path, .{
                    .content = contents,
                });
                handled = true;
            },
            else => {},
        }
    }
}

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var map: LuauCommandMap = .empty;
    defer map.deinit(allocator);
    defer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
    }

    jmp: {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = std.process.executableDirPath(Zune.io(), &buf) catch break :jmp;
        const exe_dir = buf[0..len];

        const cmds_dir = std.fs.path.join(allocator, &.{ exe_dir, "lib", "cmd" }) catch break :jmp;
        defer allocator.free(cmds_dir);

        const dir = std.Io.Dir.openDirAbsolute(Zune.io(), cmds_dir, .{ .iterate = true }) catch break :jmp;
        defer dir.close(Zune.io());

        scanLuauCommands(allocator, dir, "", &map) catch break :jmp;
    }

    const requested_command = if (args.len > 0) args[0] else null;
    if (requested_command) |cmd_name| {
        if (command.CommandMap.get(cmd_name)) |cmd| {
            Zune.debug.print("<bold>usage:<clear> zune {s} {s}\n", .{ cmd.name, cmd.template orelse "" });
            if (cmd.description) |desc| {
                Zune.debug.print("<bold>description:<clear> {s}\n", .{desc});
            }
            if (cmd.aliases.len > 0) {
                Zune.debug.print("<bold>aliases:<clear>\n", .{});
                for (cmd.aliases) |alias| {
                    Zune.debug.print("  {s}\n", .{alias});
                }
            }
            if (cmd.flags) |flags| {
                Zune.debug.print("<bold>flags:<clear>\n", .{});
                Zune.debug.print("{s}\n", .{flags.display});
            }
        } else if (map.getEntry(cmd_name)) |entry| {
            Zune.debug.print("<bold>usage:<clear> zune {s}\n", .{entry.key_ptr.*});
            const content = entry.value_ptr.*.content;
            if (std.mem.indexOf(u8, content, LuauCommandEntry.EXAMPLE_TAG)) |start| {
                Zune.debug.print("<bold>example:<clear> {s}\n", .{
                    content[start + LuauCommandEntry.EXAMPLE_TAG.len ..],
                });
            }
            if (std.mem.indexOf(u8, content, LuauCommandEntry.DESCRIPTION_TAG) != null) {
                Zune.debug.print("<bold>description:<clear> ", .{});
                var i: usize = 0;
                while (i < content.len) {
                    if (std.mem.indexOf(u8, content[i..], LuauCommandEntry.DESCRIPTION_TAG)) |desc_start| {
                        const desc_src = content[i + desc_start + LuauCommandEntry.DESCRIPTION_TAG.len ..];
                        const next_line_start = std.mem.indexOfScalar(u8, desc_src, '\n') orelse desc_src.len;
                        const desc_line = desc_src[0..next_line_start];
                        Zune.debug.print("{s}\n", .{desc_line});
                        i += desc_start + LuauCommandEntry.DESCRIPTION_TAG.len + next_line_start;
                    } else break;
                }
            }
        } else {
            Zune.debug.print("<red>error:<clear> unknown command '{s}'\n", .{cmd_name});
        }
        return;
    }
    comptime var CONTENT: []const u8 = "<bold>usage:<clear> zune <dim><<command>> [...args]<clear>\n" ++
        "\n";

    comptime var flag_size: comptime_int = 0;
    comptime var padding_len: comptime_int = 18;
    comptime for (command.Commands) |cmd| {
        padding_len = @max(cmd.name.len, (if (cmd.template) |t| t.len else 0) + 3, padding_len);
        var compact_name: []const u8 = "";
        for (cmd.aliases) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) {
                if (compact_name.len != 0) {
                    compact_name = compact_name ++ ", ";
                }
                compact_name = compact_name ++ alias;
            }
        }
        padding_len = @max(compact_name.len, (if (cmd.template) |t| t.len else 0) + 3, padding_len);
        for (cmd.aliases) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) {
                flag_size += 1;
                break;
            }
        }
    };
    comptime var flags: [flag_size]command.Command = undefined;

    const template_aligned_index = @divCeil(padding_len * 4, 5);

    CONTENT = CONTENT ++ "<bold>commands:<clear>\n";
    comptime var cmd_index: usize = 0;
    comptime var current_category: command.Command.Category = .General;
    comptime for (command.Commands) |cmd| {
        if (current_category != cmd.category) {
            current_category = cmd.category;
            if (current_category == .Display) {
                CONTENT = CONTENT ++ "\n";
            }
        }
        var buf_space: [padding_len * 2]u8 = @splat(' ');
        if (cmd.template) |t|
            @memcpy(buf_space[template_aligned_index .. template_aligned_index + t.len], t);
        CONTENT = CONTENT ++
            "  <bold>" ++
            (switch (current_category) {
                .General => "<green>",
                .Display => "<yellow>",
            }) ++
            cmd.name ++ "<clear><dim>" ++ buf_space[cmd.name.len..] ++ "<clear>" ++
            (if (cmd.description) |desc| desc ++ "\n" else "\n");
        for (cmd.aliases) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) {
                flags[cmd_index] = cmd;
                cmd_index += 1;
                break;
            }
        }
    };

    CONTENT = CONTENT ++ "\n";

    Zune.debug.print(CONTENT, .{});

    const padding: [padding_len * 2]u8 = @splat(' ');
    var iter = map.iterator();
    while (iter.next()) |entry| {
        Zune.debug.print("  <bold><blue>{s}<clear>{s}", .{ entry.key_ptr.*, padding[0 .. (padding_len * 2) - entry.key_ptr.*.len] });
        if (std.mem.indexOf(u8, entry.value_ptr.*.content, LuauCommandEntry.DESCRIPTION_TAG)) |desc_start| {
            const desc_line = entry.value_ptr.*.content[desc_start + LuauCommandEntry.DESCRIPTION_TAG.len ..];
            const desc_end = std.mem.indexOf(u8, desc_line, "\n") orelse desc_line.len;
            const desc = desc_line[0..desc_end];
            if (desc.len > 58) {
                Zune.debug.print("{s}...\n", .{desc[0..58]});
            } else {
                Zune.debug.print("{s}\n", .{desc[0..]});
            }
        } else Zune.debug.print("\n", .{});
    }

    if (map.count() > 0)
        Zune.debug.print("\n", .{});

    comptime var FLAGS_CONTENT: []const u8 = "<bold>flags:<clear>\n";
    comptime for (flags) |cmd| {
        var compact_name: []const u8 = "";
        for (cmd.aliases) |alias| {
            if (std.mem.startsWith(u8, alias, "-")) {
                if (compact_name.len != 0) {
                    compact_name = compact_name ++ ", ";
                }
                compact_name = compact_name ++ alias;
            }
        }
        var buf_space: [padding_len * 2]u8 = @splat(' ');
        if (cmd.template) |t|
            @memcpy(buf_space[template_aligned_index .. template_aligned_index + t.len], t);
        FLAGS_CONTENT = FLAGS_CONTENT ++
            "  " ++
            compact_name ++ "<clear><dim>" ++ buf_space[compact_name.len..] ++ "<clear>" ++
            (if (cmd.description) |desc| desc ++ "\n" else "\n");
    };

    Zune.debug.print(FLAGS_CONTENT, .{});
}

pub const Command: command.Command = .{
    .name = "help",
    .execute = Execute,
    .aliases = &.{
        "-h", "--help",
    },
    .description = "Display help message.",
    .category = .Display,
};
