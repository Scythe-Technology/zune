const std = @import("std");

const Zune = @import("zune");

const command = @import("lib.zig");

const INIT_CONFIG_FILE =
    \\# Zune Configuration
    \\
    \\# Debug settings
    \\#  This affects the way Zune handles errors and debug information.
    \\[runtime.debug]
    \\detailed_error = true
    \\
    \\# Compiling settings
    \\#  This affects all required files and the main file.
    \\[runtime.luau.options]
    \\debug_level = 2
    \\optimization_level = 1
    \\native_code_gen = true
    \\
    \\# Formatter settings
    \\#  This affects the output of the formatter while printing.
    \\[resolvers.formatter]
    \\max_depth = 4
    \\use_color = true
    \\table_address = true
    \\recursive_Table = false
    \\buffer_max_display = 48
    \\
    \\# FFlag settings for Luau
    \\#  You can use `zune luau list-fflags` to list all available FFlags.
    \\#[runtime.luau.fflags]
    \\#DebugCodegenOptSize = false
    \\
    \\# Features settings
    \\#  This affects the features that are enabled in Zune.
    \\#  mainly builtin libraries and features.
    \\#[features.builtin]
    \\#fs = true
    \\#io = true
    \\#net = true
    \\#process = true
    \\#task = true
    \\#luau = true
    \\#serde = true
    \\#crypto = true
    \\#datetime = true
    \\#regex = true
    \\#sqlite = true
    \\#require = true
    \\#random = true
    \\#thread = true
    \\#c = true
;

fn Execute(_: std.mem.Allocator, args: []const []const u8) !void {
    const config_file = std.Io.Dir.cwd().createFile(Zune.io(), "zune.toml", .{
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("zune configuration file, 'zune.toml' already exists.\n", .{});
            return;
        },
        else => return err,
    };
    defer config_file.close(Zune.io());

    try config_file.writeStreamingAll(Zune.io(), INIT_CONFIG_FILE);

    if (args.len > 0 and std.mem.eql(u8, args[0], "bare"))
        return;

    try std.Io.Dir.cwd().createDirPath(Zune.io(), "src");

    if (args.len > 0 and std.mem.eql(u8, args[0], "module")) {
        try std.Io.Dir.cwd().createDirPath(Zune.io(), "tests");
        blk: {
            const file = std.Io.Dir.cwd().createFile(Zune.io(), "src/init.luau", .{
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => break :blk,
                else => return err,
            };
            defer file.close(Zune.io());

            try file.writeStreamingAll(Zune.io(), 
                \\local io = zune.io
                \\
                \\local module = {}
                \\
                \\function module.hello()
                \\    io.stdout:write("Hello, World!\n")
                \\end
                \\
                \\return module
            );
        }
        blk: {
            const file = std.Io.Dir.cwd().createFile(Zune.io(), "tests/init.luau", .{
                .exclusive = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => break :blk,
                else => return err,
            };
            defer file.close(Zune.io());

            try file.writeStreamingAll(Zune.io(), 
                \\local testing = zune.testing
                \\
                \\local test = testing.test
                \\
                \\local module = require("./src")
                \\
                \\test("module.hello", function()
                \\    module.hello()
                \\end)
            );
        }
    } else {
        const file = std.Io.Dir.cwd().createFile(Zune.io(), "src/main.luau", .{
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        defer file.close(Zune.io());

        try file.writeStreamingAll(Zune.io(), 
            \\local io = zune.io
            \\
            \\local function main()
            \\    io.stdout:write("Hello, World!")
            \\end
            \\
            \\main()
            \\
        );
    }
}

pub const Command = command.Command{
    .name = "init",
    .execute = Execute,
    .description = "Create initial files & configs for zune.",
};
