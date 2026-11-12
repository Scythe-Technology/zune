const std = @import("std");
const zio = @import("zio");
const builtin = @import("builtin");

const LUAU_VERSION = @import("luau").LUAU_VERSION;

const Zune = @import("zune");

const command = @import("lib.zig");

const zune_info = @import("zune-info");

const PixelState = enum {
    empty,
    gray,
    white,
    gray_outline,
};

const zune_logo_pixel = [_][17]PixelState{
    .{ .gray, .gray, .gray, .empty, .white, .empty, .empty, .white, .empty, .white, .empty, .empty, .white, .empty, .white, .white, .white },
    .{ .empty, .empty, .gray_outline, .empty, .white, .empty, .empty, .white, .empty, .white, .white, .empty, .white, .empty, .white, .empty, .empty },
    .{ .empty, .gray_outline, .empty, .empty, .white, .empty, .empty, .white, .empty, .white, .empty, .white, .white, .empty, .white, .white, .white },
    .{ .gray_outline, .empty, .empty, .empty, .white, .empty, .empty, .white, .empty, .white, .empty, .empty, .white, .empty, .white, .empty, .empty },
    .{ .gray, .gray, .gray, .empty, .empty, .white, .white, .empty, .empty, .white, .empty, .empty, .white, .empty, .white, .white, .white },
};

fn Execute(_: std.mem.Allocator, args: []const []const u8) !void {
    if (Zune.debug.useColors()) {
        comptime var pixel_buffer: []const u8 = "";
        comptime for (zune_logo_pixel) |row| {
            var i = 0;
            while (i < row.len) : (i += 1) {
                const pixel = row[i];
                pixel_buffer = pixel_buffer ++ switch (pixel) {
                    .gray => "\x1b[48;2;119;118;123m  ",
                    .gray_outline => "\x1b[38;2;119;118;123m░░",
                    .white => "\x1b[48;2;255;255;255m  ",
                    .empty => "\x1b[0m  ",
                };
                var extra = 0;
                while (row.len > i + extra + 1 and row[i + extra + 1] == pixel) : (extra += 1) {
                    pixel_buffer = pixel_buffer ++ switch (pixel) {
                        .gray => "  ",
                        .gray_outline => "░░",
                        .white => "  ",
                        .empty => "  ",
                    };
                }
                i += extra;
            }
            pixel_buffer = pixel_buffer ++ "\x1b[0m\n";
        };
        Zune.debug.print("\n{s}\n          A luau runtime\n", .{pixel_buffer});
    }

    Zune.debug.print("<bold>version<clear>:  {s}\n", .{Zune.VERSION_STR});
    Zune.debug.print("<bold>luau<clear>:     {d}.{d}\n", .{ LUAU_VERSION.major, LUAU_VERSION.minor });
    switch (zio.ev.backend) {
        .linux => {
            var loop: zio.ev.Loop = undefined;
            try loop.init(.{});
            defer loop.deinit();
            const engine = loop.backend.selectedEngine();
            Zune.debug.print("<bold>async<clear>:    <green>{t}<clear>\n", .{engine});
        },
        else => |e| Zune.debug.print("<bold>async<clear>:    <green>{t}<clear>\n", .{e}),
    }
    Zune.debug.print("<bold>platform<clear>: {t}-{t}-{t}\n", .{ builtin.cpu.arch, builtin.os.tag, builtin.abi });
    Zune.debug.print("<bold>threaded<clear>: {} (<green>{}<clear> threads)\n", .{
        !builtin.single_threaded,
        if (builtin.single_threaded) 1 else std.Thread.getCpuCount() catch 1,
    });
    blk: {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = std.process.executableDirPath(Zune.io(), buf[0..]) catch {
            Zune.debug.print("<bold>library<clear>: <red>(unable to get path)<clear>\n", .{});
            break :blk;
        };

        const lib_dir = std.fs.path.sep_str ++ "lib" ++ std.fs.path.sep_str;
        if (buf.len - len > lib_dir.len) jmp: {
            var writer: std.Io.Writer = .fixed(buf[0..]);
            writer.end = len;
            _ = writer.write(lib_dir) catch {};

            const dir = std.Io.Dir.openDirAbsolute(Zune.io(), writer.buffered(), .{}) catch {
                Zune.debug.print("<bold>library<clear>:  (<red>missing: {s}<clear>)\n", .{writer.buffered()});
                break :jmp;
            };
            defer dir.close(Zune.io());

            const cmds_exists = res: {
                const test_dir = dir.openDir(Zune.io(), "cmd", .{}) catch break :res false;
                defer test_dir.close(Zune.io());
                break :res true;
            };

            const std_exists = res: {
                const test_dir = dir.openDir(Zune.io(), "std", .{}) catch break :res false;
                defer test_dir.close(Zune.io());
                break :res true;
            };

            if (!cmds_exists or !std_exists) {
                Zune.debug.print("<bold>library<clear>:  (<yellow>{s}<clear>)\n", .{writer.buffered()});
                if (!cmds_exists) Zune.debug.print("  <yellow>warning<clear>: cmd directory missing\n", .{});
                if (!std_exists) Zune.debug.print("  <yellow>warning<clear>: std directory missing\n", .{});
            } else Zune.debug.print("<bold>library<clear>:  (<green>{s}<clear>)\n", .{writer.buffered()});
        }
    }
    Zune.debug.print("<bold>build<clear>:    {t}\n", .{builtin.mode});

    if (args.len < 1 or !std.mem.eql(u8, args[0], "all"))
        return;

    Zune.debug.print("<bold>libraries<clear>:\n", .{});
    const longest_name: comptime_int = comptime blk: {
        var max = 0;
        for (@typeInfo(Zune.standard.libraries).@"struct".decl_names) |decl_name|
            max = @max(max, decl_name.len);
        break :blk max;
    };
    inline for (@typeInfo(Zune.standard.libraries).@"struct".decl_names) |decl_name| {
        const lib = @field(Zune.standard.libraries, decl_name);
        const padding: [longest_name - decl_name.len]u8 = @splat(' ');
        if (@hasDecl(lib, "PlatformSupported")) {
            if (lib.PlatformSupported()) |kind| switch (kind) {
                .Full => Zune.debug.print("  {s}:{s} <green>supported<clear>\n", .{ decl_name, padding }),
                .Limited => Zune.debug.print("  {s}:{s} <yellow>limited support<clear>\n", .{ decl_name, padding }),
            } else Zune.debug.print("  {s}:{s} <red>unsupported<clear>\n", .{ decl_name, padding });
        } else Zune.debug.print("  {s}:{s} <blue>native<clear>\n", .{ decl_name, padding });
    }
}

pub const Command: command.Command = .{
    .name = "info",
    .execute = Execute,
    .aliases = &.{
        "--version",
        "version",
    },
    .description = "Display runtime information.",
    .template = "[all]",
    .category = .Display,
};
