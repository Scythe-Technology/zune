const std = @import("std");
const lcompress = @import("lcompress");

pub fn adaptToOldInterface(r: *std.Io.Writer) std.Io.AnyWriter {
    return .{ .context = r, .writeFn = derpWrite };
}

fn derpWrite(context: *const anyopaque, buffer: []const u8) anyerror!usize {
    const w: *std.Io.Writer = @ptrCast(@alignCast(@constCast(context)));
    return w.write(buffer);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try std.fs.File.stderr().writeAll("Usage: <FilePath> <FilePath>\n");
        std.process.exit(1);
    }

    const file = try std.fs.openFileAbsolute(args[1], .{
        .mode = .read_only,
    });
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&read_buffer);

    const reader = &file_reader.interface;
    const old_reader = reader.adaptToOldInterface();

    const compressed_file = try std.fs.createFileAbsolute(args[2], .{});
    defer compressed_file.close();

    var write_buffer: [4096]u8 = undefined;
    var file_writer = compressed_file.writer(&write_buffer);

    const writer = &file_writer.interface;
    const old_writer = adaptToOldInterface(writer);

    try lcompress.gzip.compress(old_reader, old_writer, .{});
}
