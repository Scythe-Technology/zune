const std = @import("std");

const Zune = @import("zune");

const command = @import("lib.zig");

fn Execute(_: std.mem.Allocator, _: []const []const u8) !void {
    Zune.debug.print("<bold><dim>Z<clear><bold>UNE<clear> - A luau runtime\n" ++
        "\n" ++
        "<bold>Usage:<clear> zune <dim><<command>> [...args]<clear>\n" ++
        "\n" ++
        "<bold>Commands:<clear>\n" ++
        "  <bold><green>run      <clear><dim>./script.luau    <clear>Execute lua/luau file.\n" ++
        "  <bold><green>test     <clear><dim>./test.luau      <clear>Run tests in lua/luau file, similar to run.\n" ++
        "  <bold><green>debug    <clear><dim>./script.luau    <clear>Debug lua/luau file.\n" ++
        "  <bold><green>setup    <clear><dim>[editor]         <clear>Setup environment for luau-lsp with editor of your choice.\n" ++
        "  <bold><green>repl                      <clear>Start REPL session.\n" ++
        "  <bold><green>init                      <clear>Create initial files & configs for zune.\n" ++
        "  <bold><green>bundle                    <clear>Bundle lua/luau scripts, files with zune as standalone executable.\n" ++
        "\n" ++
        "  <bold><blue>luau     <clear><dim>[args...]        <clear>Display info from luau.\n" ++
        "  <bold><blue>help                      <clear>Display help message.\n" ++
        "\n" ++
        "<bold>Flags:<clear>\n" ++
        "  -e, --eval     <clear><dim>[luau]     <clear>Evaluate luau code.\n" ++
        "  -V, --version             <clear>Display version.\n" ++
        "  -h, --help                <clear>Display help message.\n" ++
        "", .{});
}

pub const Command = command.Command{
    .name = "help",
    .execute = Execute,
    .aliases = &.{
        "-h", "--help",
    },
};
