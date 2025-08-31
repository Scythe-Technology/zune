const std = @import("std");
const luau = @import("luau");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try std.fs.File.stderr().writeAll("Usage: <FilePath> <FilePath>\n");
        std.process.exit(1);
    }

    const luau_file = try std.fs.openFileAbsolute(args[1], .{
        .mode = .read_only,
    });
    defer luau_file.close();

    const luau_source = try luau_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(luau_source);

    const luau_bytecode = try luau.compile(allocator, luau_source, luau.CompileOptions{
        .debugLevel = 1,
        .optimizationLevel = 2,
    });

    const luau_bytecode_path = try std.fs.createFileAbsolute(args[2], .{});
    defer luau_bytecode_path.close();

    try luau_bytecode_path.writeAll(luau_bytecode);
}
