const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 3) {
        std.debug.print("Usage: <FilePath> <FilePath>\n", .{});
        std.process.exit(1);
    }

    const file = try std.Io.Dir.openFileAbsolute(io, args[1], .{
        .mode = .read_only,
    });
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);

    const compressed_file = try std.Io.Dir.createFileAbsolute(io, args[2], .{});
    defer compressed_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = compressed_file.writer(io, &write_buffer);
    const writer = &file_writer.interface;

    var compress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compression = try std.compress.flate.Compress.init(writer, &compress_buffer, .gzip, .best);

    _ = try file_reader.interface.streamRemaining(&compression.writer);
    try compression.finish();
    try writer.flush();
}
