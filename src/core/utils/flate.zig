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

pub fn compressBound(container: flate.Container, source_len: usize) usize {
    const zlib_bound = source_len + (source_len >> 12) + (source_len >> 14) + (source_len >> 25) + 13;
    return switch (container) {
        .raw, .zlib => zlib_bound,
        .gzip => zlib_bound + 12,
    };
}

pub fn compressInto(
    dest: []u8,
    input: []const u8,
    container: flate.Container,
    opts: flate.Compress.Options,
) !usize {
    if (dest.len > 8)
        return compressFixed(dest, input, container, opts);
    var tmp: [64]u8 = undefined;
    const n = try compressFixed(&tmp, input, container, opts);
    if (n > dest.len)
        return error.NoSpace;
    @memcpy(dest[0..n], tmp[0..n]);
    return n;
}

fn compressFixed(
    dest: []u8,
    input: []const u8,
    container: flate.Container,
    opts: flate.Compress.Options,
) !usize {
    var writer: std.Io.Writer = .fixed(dest);
    var window: [flate.max_window_len]u8 = undefined;
    var c = flate.Compress.init(&writer, &window, container, opts) catch return error.NoSpace;
    var reader: std.Io.Reader = .fixed(input);
    _ = reader.streamRemaining(&c.writer) catch |err| switch (err) {
        error.WriteFailed => return error.NoSpace,
        else => |e| return e,
    };
    c.finish() catch |err| switch (err) {
        error.WriteFailed => return error.NoSpace,
        else => |e| return e,
    };
    return writer.end;
}

pub fn decompressInto(dest: []u8, input: []const u8, container: flate.Container) !usize {
    var reader: std.Io.Reader = .fixed(input);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&reader, container, &window);
    var writer: std.Io.Writer = .fixed(dest);
    return d.reader.streamRemaining(&writer);
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
