const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;

const GpioLine = Zune.objects.GpioLine;

const VM = luau.VM;

pub const LIB_NAME = "gpio";

pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.os.tag) {
        .linux => .Limited,
        else => null,
    };
}

const max_chips = 256;
const name_len = 32;

fn chipIndex(name: []const u8) ?u32 {
    const prefix = "gpiochip";
    if (!std.mem.startsWith(u8, name, prefix))
        return null;
    const digits = name[prefix.len..];
    if (digits.len == 0)
        return null;
    if (digits.len > 1 and digits[0] == '0')
        return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

const linux = if (builtin.os.tag == .linux) struct {
    const open_file: std.Io.Dir.OpenFileOptions = .{ .allow_directory = false };

    const ChipInfo = extern struct {
        name: [name_len]u8,
        label: [name_len]u8,
        lines: u32,
    };

    const LineAttribute = extern struct {
        id: u32,
        padding: u32,
        value: u64 align(8),
    };

    const LineConfigAttribute = extern struct {
        attr: LineAttribute,
        mask: u64 align(8),
    };

    const LineConfig = extern struct {
        flags: u64 align(8),
        num_attrs: u32,
        padding: [5]u32,
        attrs: [10]LineConfigAttribute,
    };

    const LineRequest = extern struct {
        offsets: [64]u32,
        consumer: [name_len]u8,
        config: LineConfig,
        num_lines: u32,
        event_buffer_size: u32,
        padding: [5]u32,
        fd: i32,
    };

    const LineInfo = extern struct {
        name: [name_len]u8,
        consumer: [name_len]u8,
        offset: u32,
        num_attrs: u32,
        flags: u64 align(8),
        attrs: [10]LineAttribute,
        padding: [4]u32,
    };

    const get_chipinfo = std.os.linux.IOCTL.IOR(0xB4, 0x01, ChipInfo);
    const get_lineinfo = std.os.linux.IOCTL.IOWR(0xB4, 0x05, LineInfo);
    const get_line = std.os.linux.IOCTL.IOWR(0xB4, 0x07, LineRequest);

    const flag_used: u64 = 1 << 0;
    const flag_active_low: u64 = 1 << 1;
    const flag_input: u64 = 1 << 2;
    const flag_output: u64 = 1 << 3;
    const attr_output_values: u32 = 2;

    comptime {
        std.debug.assert(@sizeOf(ChipInfo) == 68);
        std.debug.assert(@sizeOf(LineInfo) == 256);
        std.debug.assert(@sizeOf(LineRequest) == 592);
        std.debug.assert(@sizeOf(LineConfig) == 272);
        std.debug.assert(@offsetOf(LineRequest, "fd") == 588);
        std.debug.assert(@offsetOf(LineInfo, "flags") == 72);
    }

    fn ioctl(fd: i32, code: u32, arg: *anyopaque) !void {
        while (true) {
            const rc = std.os.linux.ioctl(fd, code, @intFromPtr(arg));
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .BUSY => return error.LineBusy,
                .NODEV, .NXIO, .NOTTY, .NOSYS, .OPNOTSUPP => return error.GpioUnsupported,
                .INVAL => return error.InvalidRequest,
                .ACCES, .PERM => return error.PermissionDenied,
                .NOMEM => return error.SystemResources,
                .FAULT => unreachable,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn handleError(L: *VM.lua.State, err: anyerror) anyerror {
        return switch (err) {
            error.RaiseLuauError => err,
            error.UnknownChip => L.Zerror("unknown chip"),
            error.GpioUnsupported => L.Zerror("gpio unsupported"),
            error.PermissionDenied, error.AccessDenied => L.Zerror("permission denied"),
            error.LineBusy, error.FileBusy => L.Zerror("line busy"),
            error.InvalidRequest => L.Zerror("invalid request"),
            error.NoDevice, error.IsDir => L.Zerror("gpio unsupported"),
            error.TooManyChips => L.Zerror("too many chips"),
            else => err,
        };
    }

    fn cString(buf: *const [name_len]u8) []const u8 {
        const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..n];
    }

    fn whole(L: *VM.lua.State, idx: i32) !?u32 {
        switch (L.typeOf(idx)) {
            .Number => {
                const n = L.tointeger(idx).?;
                if (n < 0)
                    return error.NotWhole;
                return @intCast(n);
            },
            else => return error.UnknownType,
        }
    }

    fn readChipArg(L: *VM.lua.State, idx: i32) !u32 {
        switch (L.typeOf(idx)) {
            .Number => {
                const index = L.tointeger(idx).?;
                if (index < 0)
                    return L.Zerror("unknown chip");
                return @intCast(index);
            },
            .String => {
                const name = L.Lcheckstring(idx);
                return chipIndex(name) orelse return L.Zerror("unknown chip");
            },
            else => return L.Zerror("unknown chip"),
        }
    }

    fn chipPath(index: u32) ![64]u8 {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/dev/gpiochip{d}", .{index}) catch return error.UnknownChip;

        var out: [64]u8 = @splat(0);
        @memcpy(out[0..path.len], path);

        return out;
    }

    fn chipPathSlice(buf: *[64]u8) []const u8 {
        const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..n];
    }

    fn openChip(index: u32) !std.Io.File {
        var path = try chipPath(index);
        const file = std.Io.Dir.openFileAbsolute(Zune.io(), chipPathSlice(&path), open_file) catch |err| switch (err) {
            error.FileNotFound => return error.UnknownChip,
            error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
            error.NoDevice, error.IsDir => return error.GpioUnsupported,
            else => return err,
        };
        errdefer file.close(Zune.io());

        const stat = try file.stat(Zune.io());
        if (stat.kind != .character_device)
            return error.GpioUnsupported;

        return file;
    }

    fn readChipInfo(file: std.Io.File) !ChipInfo {
        var info: ChipInfo = std.mem.zeroes(ChipInfo);
        try ioctl(file.handle, get_chipinfo, &info);

        return info;
    }

    fn chipNodeIndex(dev: std.Io.Dir, entry: std.Io.Dir.Entry) ?u32 {
        const index = chipIndex(entry.name) orelse return null;
        switch (entry.kind) {
            .character_device => return index,
            .unknown, .sym_link => {
                const stat = dev.statFile(Zune.io(), entry.name, .{}) catch return index;
                if (stat.kind != .character_device) return null;
                return index;
            },
            else => return null,
        }
    }

    fn usable(index: u32) bool {
        const file = openChip(index) catch return false;
        defer file.close(Zune.io());

        _ = readChipInfo(file) catch return false;

        return true;
    }

    fn collectChips(allocator: std.mem.Allocator) ![]u32 {
        var dev = std.Io.Dir.openDirAbsolute(Zune.io(), "/dev", .{ .iterate = true }) catch return error.GpioUnsupported;
        defer dev.close(Zune.io());

        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(allocator);

        var it = dev.iterate();
        while (try it.next(Zune.io())) |entry| {
            const index = chipNodeIndex(dev, entry) orelse continue;
            if (list.items.len == max_chips)
                return error.TooManyChips;
            try list.append(allocator, index);
        }

        std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
        return list.toOwnedSlice(allocator);
    }

    pub threadlocal var chip_present: ?bool = null;

    fn present() bool {
        if (chip_present) |p|
            return p;
        var dev = std.Io.Dir.openDirAbsolute(Zune.io(), "/dev", .{ .iterate = true }) catch return false;
        defer dev.close(Zune.io());

        var it = dev.iterate();
        while (it.next(Zune.io()) catch return false) |entry| {
            const index = chipNodeIndex(dev, entry) orelse continue;
            if (usable(index)) {
                chip_present = true;
                return true;
            }
        }

        chip_present = false;
        return false;
    }

    fn pushChip(L: *VM.lua.State, info: ChipInfo) !void {
        try L.Zpushvalue(.{
            .name = cString(&info.name),
            .label = cString(&info.label),
            .lines = info.lines,
        });
    }

    fn directionName(flags: u64) []const u8 {
        if ((flags & flag_input) != 0)
            return "in";
        if ((flags & flag_output) != 0)
            return "out";
        return "unknown";
    }

    fn chips(L: *VM.lua.State) !i32 {
        const allocator = Scheduler.fromState(L).allocator();

        const indexes = collectChips(allocator) catch |err| return handleError(L, err);
        defer allocator.free(indexes);

        if (indexes.len == 0)
            return L.Zerror("gpio unsupported");

        try L.createtable(@intCast(indexes.len), 0);

        var pushed: i32 = 0;
        for (indexes) |index| {
            const file = openChip(index) catch |err| switch (err) {
                error.UnknownChip, error.GpioUnsupported, error.PermissionDenied => continue,
                else => return handleError(L, err),
            };
            defer file.close(Zune.io());

            const info = readChipInfo(file) catch |err| switch (err) {
                error.GpioUnsupported, error.PermissionDenied => continue,
                else => return handleError(L, err),
            };

            pushed += 1;

            try pushChip(L, info);
            try L.rawseti(-2, pushed);
        }

        if (pushed == 0)
            return L.Zerror("gpio unsupported");

        return 1;
    }

    fn chip(L: *VM.lua.State) !i32 {
        const index = try readChipArg(L, 1);
        if (!present())
            return L.Zerror("gpio unsupported");

        const file = openChip(index) catch |err| return handleError(L, err);
        defer file.close(Zune.io());

        const info = readChipInfo(file) catch |err| return handleError(L, err);

        try pushChip(L, info);

        return 1;
    }

    fn line(L: *VM.lua.State) !i32 {
        const index = try readChipArg(L, 1);
        const offset = whole(L, 2) catch return L.Zerror("offset out of range");
        if (!present())
            return L.Zerror("gpio unsupported");

        const file = openChip(index) catch |err| return handleError(L, err);
        defer file.close(Zune.io());

        const chip_info = readChipInfo(file) catch |err| return handleError(L, err);
        if (offset.? >= chip_info.lines)
            return L.Zerror("offset out of range");

        var info: LineInfo = std.mem.zeroes(LineInfo);
        info.offset = offset.?;
        ioctl(file.handle, get_lineinfo, &info) catch |err| return handleError(L, err);

        try L.Zpushvalue(.{
            .offset = info.offset,
            .name = cString(&info.name),
            .consumer = cString(&info.consumer),
            .used = (info.flags & flag_used) != 0,
            .direction = directionName(info.flags),
            .active_low = (info.flags & flag_active_low) != 0,
        });
        return 1;
    }

    fn readRequest(L: *VM.lua.State) !struct { u32, u32, bool, [name_len]u8, bool } {
        if (!L.istable(1))
            return L.Zerror("expected table");

        const chip_type = try L.getfield(1, "chip");
        if (chip_type.isnoneornil())
            return L.Zerror("missing field 'chip'");

        const index = try readChipArg(L, -1);
        L.pop(1);

        const offset_type = try L.getfield(1, "offset");
        const offset = if (offset_type.isnoneornil())
            null
        else
            whole(L, -1) catch return L.Zerror("offset out of range");
        L.pop(1);

        const direction_type = try L.getfield(1, "direction");
        if (direction_type != .String)
            return L.Zerror("invalid direction");

        const direction = L.tolstring(-1).?;
        const output = if (std.mem.eql(u8, direction, "out"))
            true
        else if (std.mem.eql(u8, direction, "in"))
            false
        else
            return L.Zerror("invalid direction");
        L.pop(1);

        var consumer: [name_len]u8 = @splat(0);
        const consumer_type = try L.getfield(1, "consumer");
        if (consumer_type.isnoneornil() or consumer_type != .String)
            return L.Zerror("invalid consumer")
        else {
            const text = L.tolstring(-1).?;
            if (text.len == 0 or text.len >= consumer.len)
                return L.Zerror("invalid consumer");
            @memcpy(consumer[0..text.len], text);
        }
        L.pop(1);

        var initial = false;
        const initial_type = try L.getfield(1, "initial");
        if (!initial_type.isnoneornil()) {
            if (!L.isboolean(-1))
                return L.Zerror("invalid field 'initial'");
            initial = L.toboolean(-1);
            if (!output)
                return L.Zerror("initial requires output");
        }
        L.pop(1);

        return .{ index, offset.?, output, consumer, initial };
    }

    fn request(L: *VM.lua.State) !i32 {
        const index, const offset, const output, const consumer, const initial = try readRequest(L);
        if (!present())
            return L.Zerror("gpio unsupported");

        const file = openChip(index) catch |err| return handleError(L, err);
        defer file.close(Zune.io());

        const chip_info = readChipInfo(file) catch |err| return handleError(L, err);
        if (offset >= chip_info.lines)
            return L.Zerror("offset out of range");

        var req: LineRequest = std.mem.zeroes(LineRequest);
        req.offsets[0] = offset;
        req.num_lines = 1;
        req.consumer = consumer;
        req.config.flags = if (output) flag_output else flag_input;
        if (output) {
            req.config.num_attrs = 1;
            req.config.attrs[0].attr.id = attr_output_values;
            req.config.attrs[0].attr.value = if (initial) 1 else 0;
            req.config.attrs[0].mask = 1;
        }

        ioctl(file.handle, get_line, &req) catch |err| return handleError(L, err);
        if (req.fd < 0)
            return L.Zerror("gpio unsupported");
        errdefer _ = std.os.linux.close(req.fd);

        _ = try GpioLine.create(L, req.fd, output);

        return 1;
    }
} else struct {};

pub fn lua_available(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    L.pushboolean(linux.present());
    return 1;
}

pub fn lua_chips(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    return linux.chips(L);
}

pub fn lua_chip(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    return linux.chip(L);
}

pub fn lua_line(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    return linux.line(L);
}

pub fn lua_request(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .linux => {},
        else => return error.UnsupportedPlatform,
    }
    return linux.request(L);
}

pub fn __setup(L: *VM.lua.State) !void {
    _ = L;
    linux.chip_present = null;
}

test "gpio chip index" {
    try std.testing.expectEqual(@as(?u32, 0), chipIndex("gpiochip0"));
    try std.testing.expectEqual(@as(?u32, 12), chipIndex("gpiochip12"));
    try std.testing.expect(chipIndex("gpiochip") == null);
    try std.testing.expect(chipIndex("gpiochip01") == null);
    try std.testing.expect(chipIndex("../gpiochip0") == null);
    try std.testing.expect(chipIndex("gpiochip0/../null") == null);
    try std.testing.expect(chipIndex("/dev/gpiochip0") == null);
}
