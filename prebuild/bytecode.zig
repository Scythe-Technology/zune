const std = @import("std");
const luau = @import("luau");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 3) {
        std.debug.print("Usage: <FilePath> <FilePath>\n", .{});
        std.process.exit(1);
    }

    const luau_file = try std.Io.Dir.openFileAbsolute(io, args[1], .{
        .mode = .read_only,
    });
    defer luau_file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = luau_file.reader(io, &read_buffer);

    const luau_source = try file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(luau_source);

    const luau_bytecode = try luau.compile(allocator, luau_source, luau.CompileOptions{
        .debugLevel = 1,
        .optimizationLevel = 2,
    });
    defer allocator.free(luau_bytecode);

    const luau_bytecode_path = try std.Io.Dir.createFileAbsolute(io, args[2], .{});
    defer luau_bytecode_path.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = luau_bytecode_path.writer(io, &write_buffer);

    try file_writer.interface.writeAll(luau_bytecode);
    try file_writer.interface.flush();
}
