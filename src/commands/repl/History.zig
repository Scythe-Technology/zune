const std = @import("std");

const History = @This();

allocator: std.mem.Allocator,
list: std.ArrayList([]const u8),
temp_buffer: ?[]const u8 = null,
file: ?[]const u8,
position: usize,
enabled: bool = true,

pub const MAX_HISTORY_SIZE: u16 = 200;

pub fn init(allocator: std.mem.Allocator, comptime location: []const u8) !History {
    var file_path: ?[]const u8 = null;
    if (std.process.getEnvVarOwned(allocator, "HOME") catch null) |path| {
        file_path = try std.fs.path.resolve(allocator, &.{ path, location });
    } else if (std.process.getEnvVarOwned(allocator, "USERPROFILE") catch null) |path| {
        file_path = try std.fs.path.resolve(allocator, &.{ path, location });
    }
    var history_data: std.ArrayList([]const u8) = .empty;
    errdefer history_data.deinit(allocator);
    if (file_path) |path| {
        errdefer allocator.free(path);
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return .{
                    .allocator = allocator,
                    .file = file_path,
                    .list = history_data,
                    .position = history_data.items.len,
                };
            } else return err;
        };
        var buffer: [1024]u8 = undefined;
        var reader = file.reader(&buffer);

        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();

        while (true) {
            allocating.clearRetainingCapacity();
            const amt = reader.interface.streamDelimiter(&allocating.writer, '\n') catch |err| {
                if (err == error.EndOfStream)
                    break
                else
                    return err;
            };
            if (amt == 0)
                break;
            const line = allocating.written();
            if (std.mem.trim(u8, line, " \r").len == 0)
                continue;
            try history_data.append(allocator, std.mem.trim(u8, line, "\r"));
            if (history_data.items.len > MAX_HISTORY_SIZE)
                allocator.free(history_data.orderedRemove(1));
        }
    }
    return .{
        .allocator = allocator,
        .file = file_path,
        .list = history_data,
        .position = history_data.items.len,
    };
}

pub fn reset(self: *History) void {
    self.position = self.list.items.len;
}

pub fn save(self: *History, line: []const u8) void {
    if (std.mem.trim(u8, line, " ").len == 0)
        return;
    if (self.list.items.len > 0)
        if (std.mem.eql(u8, self.list.items[self.list.items.len - 1], line))
            return;
    const line_copy = self.allocator.dupe(u8, line) catch return;
    self.list.append(self.allocator, line_copy) catch {
        self.allocator.free(line_copy);
        return;
    };
    if (self.list.items.len > MAX_HISTORY_SIZE)
        self.allocator.free(self.list.orderedRemove(1));
}

pub fn saveTemp(self: *History, line: []const u8) void {
    if (self.temp_buffer != null)
        self.clearTemp();
    const line_copy = self.allocator.dupe(u8, line) catch return;
    self.temp_buffer = line_copy;
}

pub fn next(self: *History) ?[]const u8 {
    if (self.position < self.list.items.len)
        self.position += 1;
    if (self.list.items.len == self.position)
        return self.temp_buffer;
    return self.current();
}
pub fn previous(self: *History) ?[]const u8 {
    if (self.position > 0)
        self.position -= 1;
    return self.current();
}

pub fn current(self: *History) ?[]const u8 {
    if (self.position >= self.list.items.len and self.position < 0)
        return null
    else
        return self.list.items[self.position];
}

pub fn getTemp(self: *History) ?[]const u8 {
    return self.temp_buffer;
}
pub fn clearTemp(self: *History) void {
    if (self.temp_buffer) |buf|
        self.allocator.free(buf);
    self.temp_buffer = null;
}

pub fn isLatest(self: *History) bool {
    if (self.list.items.len == 0)
        return true;
    return self.position >= self.list.items.len;
}

pub fn size(self: *History) usize {
    return self.list.items.len;
}

pub fn deinit(self: *History) void {
    if (!self.enabled)
        return;
    if (self.file) |path| {
        defer self.allocator.free(path);
        defer {
            for (self.list.items) |item|
                self.allocator.free(item);
            self.list.deinit(self.allocator);
        }

        const location = std.fs.path.dirname(path) orelse return;

        std.fs.cwd().makePath(location) catch |err| {
            std.debug.print("MkDirError: {}\n", .{err});
            return;
        };

        const history_file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer history_file.close();

        var buffer: [1024]u8 = undefined;
        var file_writer = history_file.writer(&buffer);
        const writer = &file_writer.interface;
        for (self.list.items) |data| {
            writer.writeAll(data) catch break;
            writer.writeByte('\n') catch break;
        }
    }
}
