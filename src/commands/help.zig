const std = @import("std");

const Zune = @import("zune");

const command = @import("lib.zig");

fn Execute(_: std.mem.Allocator, _: []const []const u8) !void {
    comptime var CONTENT: []const u8 = "<bold><dim>Z<clear><bold>UNE<clear> - A luau runtime\n" ++
        "\n" ++
        "<bold>usage:<clear> zune <dim><<command>> [...args]<clear>\n" ++
        "\n";
    comptime {
        var flag_size: usize = 0;
        var padding_len: usize = 0;
        for (command.Commands) |cmd| {
            padding_len = @max(cmd.name.len + (if (cmd.template) |t| t.len else 0), padding_len);
            var compact_name: []const u8 = "";
            for (cmd.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, "-")) {
                    if (compact_name.len != 0) {
                        compact_name = compact_name ++ ", ";
                    }
                    compact_name = compact_name ++ alias;
                }
            }
            padding_len = @max(compact_name.len + (if (cmd.template) |t| t.len else 0), padding_len);
            for (cmd.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, "-")) {
                    flag_size += 1;
                    break;
                }
            }
        }
        var flags: [flag_size]command.Command = undefined;

        CONTENT = CONTENT ++ "<bold>Commands:<clear>\n";
        var cmd_index: usize = 0;
        var current_category: command.Command.Categroy = .General;
        for (command.Commands) |cmd| {
            if (current_category != cmd.category) {
                current_category = cmd.category;
                if (current_category == .Display) {
                    CONTENT = CONTENT ++ "\n";
                }
            }
            const pre_padding = " " ** (@divFloor(padding_len, 2) + 4 - cmd.name.len);
            const post_padding = " " ** (@divFloor(padding_len, 2) + 6 - (if (cmd.template) |t| t.len else 0));
            CONTENT = CONTENT ++
                "  <bold>" ++
                (switch (current_category) {
                    .General => "<green>",
                    .Display => "<blue>",
                }) ++
                cmd.name ++ pre_padding ++ "<clear><dim>" ++
                (if (cmd.template) |t| t else "") ++
                post_padding ++
                "<clear>" ++ (if (cmd.description) |desc| " " ++ desc ++ "\n" else "\n");
            // ++ padding ++ "  <clear><dim>" ++ padding ++ "    <clear>" ++ (cmd.description orelse "") ++ "\n";
            for (cmd.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, "-")) {
                    flags[cmd_index] = cmd;
                    cmd_index += 1;
                    break;
                }
            }
        }

        CONTENT = CONTENT ++ "\n<bold>Flags:<clear>\n";
        for (flags) |cmd| {
            var compact_name: []const u8 = "";
            for (cmd.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, "-")) {
                    if (compact_name.len != 0) {
                        compact_name = compact_name ++ ", ";
                    }
                    compact_name = compact_name ++ alias;
                }
            }
            const pre_padding = " " ** (@divFloor(padding_len, 2) + 4 - compact_name.len);
            const post_padding = " " ** (@divFloor(padding_len, 2) + 6 - (if (cmd.template) |t| t.len else 0));
            CONTENT = CONTENT ++
                "  " ++
                compact_name ++ pre_padding ++ "<clear><dim>" ++
                (if (cmd.template) |t| t else "") ++
                post_padding ++
                "<clear>" ++ (if (cmd.description) |desc| " " ++ desc ++ "\n" else "\n");
        }
    }

    Zune.debug.print(CONTENT, .{});
}

pub const Command = command.Command{
    .name = "help",
    .execute = Execute,
    .aliases = &.{
        "-h", "--help",
    },
    .description = "Display help message.",
    .category = .Display,
};
