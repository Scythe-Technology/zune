const std = @import("std");

pub fn adaptToOldInterface(r: *std.Io.Writer) std.Io.AnyWriter {
    return .{ .context = r, .writeFn = derpWrite };
}

fn derpWrite(context: *const anyopaque, buffer: []const u8) anyerror!usize {
    const w: *std.Io.Writer = @ptrCast(@alignCast(@constCast(context)));
    return w.write(buffer);
}
