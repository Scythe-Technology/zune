const std = @import("std");

const command = @import("lib.zig");

const INIT_CONFIG_FILE =
    \\# Zune Configuration
    \\
    \\# Debug settings
    \\#  This affects the way Zune handles errors and debug information.
    \\[runtime.debug]
    \\detailedError = true
    \\
    \\# Compiling settings
    \\#  This affects all required files and the main file.
    \\[runtime.luau.options]
    \\debugLevel = 2
    \\optimizationLevel = 1
    \\nativeCodeGen = true
    \\
    \\# Formatter settings
    \\#  This affects the output of the formatter while printing.
    \\[resolvers.formatter]
    \\maxDepth = 4
    \\useColor = true
    \\showTableAddress = true
    \\showRecursiveTable = false
    \\displayBufferContentsMax = 48
    \\
    \\# FFlag settings for Luau
    \\#  You can use `zune luau list-fflags` to list all available FFlags.
    \\#[runtime.luau.fflags]
    \\#DebugCodegenOptSize = false
;

fn Execute(_: std.mem.Allocator, args: []const []const u8) !void {
    const config_file = std.fs.cwd().createFile("zune.toml", .{
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("zune configuration file, 'zune.toml' already exists.\n", .{});
            return;
        },
        else => return err,
    };
    defer config_file.close();

    try config_file.writeAll(INIT_CONFIG_FILE);

    try std.fs.cwd().makePath("src");

    if (args.len > 0 and std.mem.eql(u8, args[0], "module")) {
        const file = std.fs.cwd().createFile("src/init.luau", .{
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        defer file.close();

        try file.writeAll(
            \\local stdio = zune.stdio
            \\
            \\local module = {}
            \\
            \\function module.hello()
            \\    stdio.stdout:write("Hello, World!")
            \\end
            \\
            \\if zune.testing.running then
            \\    local testing = zune.testing
            \\
            \\    local test = testing.test
            \\
            \\    test("module.hello", function()
            \\        module.hello()
            \\    end)
            \\end
            \\
            \\return module
        );
    } else {
        const file = std.fs.cwd().createFile("src/main.luau", .{
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        defer file.close();

        try file.writeAll(
            \\local stdio = zune.stdio
            \\
            \\local function main()
            \\    stdio.stdout:write("Hello, World!")
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
};
