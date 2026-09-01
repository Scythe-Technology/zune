const std = @import("std");

const flate = std.compress.flate;

pub fn compress(
    allocator: std.mem.Allocator,
    input: []const u8,
    container: flate.Container,
    opts: flate.Compress.Options,
) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 16);
    errdefer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &window, container, opts);
    var reader: std.Io.Reader = .fixed(input);
    _ = try reader.streamRemaining(&c.writer);
    try c.finish();
    return out.toOwnedSlice();
}

pub fn decompress(
    allocator: std.mem.Allocator,
    input: []const u8,
    container: flate.Container,
) ![]u8 {
    var reader: std.Io.Reader = .fixed(input);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&reader, container, &window);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 16);
    errdefer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

pub fn decompressInto(dest: []u8, input: []const u8, container: flate.Container) !void {
    var reader: std.Io.Reader = .fixed(input);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&reader, container, &window);
    var writer: std.Io.Writer = .fixed(dest);
    _ = try d.reader.streamRemaining(&writer);
}

pub fn optionsFromLevel(level: u4) flate.Compress.Options {
    return switch (level) {
        1 => .level_1,
        2 => .level_2,
        3 => .level_3,
        4 => .level_4,
        5 => .level_5,
        6 => .level_6,
        7 => .level_7,
        8 => .level_8,
        else => .level_9,
    };
}
