const std = @import("std");
const lz4 = @import("lz4");
const zstd = @import("zstd");

const Zune = @import("zune");

pub const TAG = "\x5b\x4b\x1bBUNDLE\x1d\x4d\x5d";

pub const SEED: u64 = 0x62756E646C65; // "bundle"

pub const ExeHeader = packed struct(u64) {
    sections: u20, // ~1M sections
    size: u37, // ~128 GiB of data
    _: u7 = 0, // reserved bits

    pub fn maxValue(comptime field: enum { sections, size }) comptime_int {
        return std.math.maxInt(@typeInfo(ExeHeader).@"struct".fields[@intFromEnum(field)].type);
    }

    pub fn write(writer: anytype, header: ExeHeader) !void {
        try writer.writeInt(u64, @bitCast(header), .big);
    }
};

pub const Section = union(enum) {
    script: Script,
    file: File,

    pub const Script = []const u8;
    pub const Compression = enum(u3) { none, zlib, lz4, zstd };

    pub const File = struct {
        data: []const u8,
        size: u64, // decompressed size
        compression: Compression,
    };

    pub const Header = packed struct(u56) {
        kind: enum(u1) { script, file }, // type of section
        compression: Compression,
        name_size: u15,
        size: u37,
    };

    pub fn writeScript(writer: anytype, name: []const u8, data: []const u8) !void {
        if (name.len > std.math.maxInt(u15))
            return error.NameTooLong;
        if (data.len > std.math.maxInt(u37))
            return error.DataTooLarge;
        try writer.writeInt(u56, @bitCast(Header{
            .kind = .script,
            .compression = .none,
            .name_size = @intCast(name.len),
            .size = @intCast(data.len),
        }), .big);
        try writer.writeAll(name);
        try writer.writeByte(0);
        try writer.writeAll(data);
    }

    pub fn writeFile(
        allocator: std.mem.Allocator,
        writer: anytype,
        name: []const u8,
        data: []const u8,
        compression: Compression,
    ) !void {
        if (name.len > std.math.maxInt(u15))
            return error.NameTooLong;
        if (data.len > std.math.maxInt(u37))
            return error.DataTooLarge;
        if (compression == .none) {
            try writer.writeInt(u56, @bitCast(Header{
                .kind = .file,
                .compression = .none,
                .name_size = @intCast(name.len),
                .size = @intCast(data.len),
            }), .big);
            try writer.writeAll(name);
            try writer.writeByte(0);
            try writer.writeAll(data);
        } else {
            if (data.len > std.math.maxInt(u40)) // ~1.1TB
                return error.DataTooLarge;
            var array: std.ArrayListUnmanaged(u8) = .empty;
            defer array.deinit(allocator);
            switch (compression) {
                .zlib => {
                    var reader = std.io.fixedBufferStream(data);
                    try std.compress.zlib.compress(reader.reader(), array.writer(allocator), .{
                        .level = .default,
                    });
                },
                .lz4 => {
                    const compressed_bytes = try lz4.Standard.compress(allocator, data);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = compressed_bytes,
                    };
                },
                .zstd => {
                    const compressed_bytes = try zstd.compressAlloc(allocator, data, 3);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = @constCast(compressed_bytes),
                    };
                },
                else => unreachable,
            }
            const block_size: usize = array.items.len + 5; // 5 bytes for u40
            if (block_size > std.math.maxInt(u37))
                return error.DataTooLarge;
            try writer.writeInt(u56, @bitCast(Header{
                .kind = .file,
                .compression = compression,
                .name_size = @intCast(name.len),
                .size = @intCast(block_size),
            }), .big);
            try writer.writeAll(name);
            try writer.writeByte(0);
            try writer.writeInt(u40, @intCast(data.len), .big);
            try writer.writeAll(array.items);
        }
    }
};

pub const Features = packed struct(u16) {
    fs: bool = true,
    io: bool = true,
    net: bool = true,
    process: bool = true,
    task: bool = true,
    luau: bool = true,
    serde: bool = true,
    crypto: bool = true,
    datetime: bool = true,
    regex: bool = true,
    sqlite: bool = true,
    require: bool = true,
    random: bool = true,
    thread: bool = true,
    ffi: bool = true,
    _: u1 = 0, // reserved bit

    pub fn write(writer: anytype, features: Features) !void {
        try writer.writeInt(u16, @bitCast(features), .big);
    }

    comptime {
        std.debug.assert(@typeInfo(@TypeOf(Zune.FEATURES)).@"struct".fields.len == @typeInfo(Features).@"struct".fields.len - 1);
        for (@typeInfo(@TypeOf(Zune.FEATURES)).@"struct".fields) |field| {
            std.debug.assert(@hasField(Features, field.name));
        }
    }
};

pub const PackedState = packed struct(u40) {
    mode: Mode,
    luau: Luau,
    format: Format,
    _: u6 = 0, // reserved bits

    pub const Mode = packed struct(u2) {
        compiled: enum(u1) { debug, release },
        limbo: bool = false,
    };

    const Format = packed struct(u26) {
        use_color: bool = true,
        table_address: bool = true,
        recursive_table: bool = false,
        max_depth: u8 = 4,
        buffer_max_display: u15 = 48,
    };

    const Luau = packed struct(u6) {
        debug_level: u2 = 2,
        optimization_level: u2 = 1,
        codegen: bool = true,
        jit_enabled: bool = true,
    };

    pub fn write(writer: anytype, state: PackedState) !void {
        try writer.writeInt(u40, @bitCast(state), .big);
    }
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    mode: PackedState.Mode,
    map: std.StringHashMapUnmanaged(Section),
    entry: struct {
        name: [:0]const u8,
        data: Section.Script,
    },
    home_dir: []const u8,
    allocated: []const u8,

    pub fn deinit(self: *Map) void {
        self.map.deinit(self.allocator);
        self.allocator.free(self.entry.name);
        self.allocator.free(self.allocated);
    }

    fn unpackFile(self: *Map, file: *Section.File) ![]const u8 {
        if (file.compression == .none)
            return file.data;
        defer file.compression = .none;
        switch (file.compression) {
            .zlib => {
                const decompressed_bytes = try self.allocator.alloc(u8, file.size);

                var writer = std.io.fixedBufferStream(decompressed_bytes);
                var reader = std.io.fixedBufferStream(file.data);

                try std.compress.zlib.decompress(reader.reader(), writer.writer());
                file.data = decompressed_bytes;
                return decompressed_bytes;
            },
            .lz4 => {
                const decompressed_bytes = try lz4.Standard.decompress(self.allocator, file.data, file.size);
                file.data = decompressed_bytes;
                return decompressed_bytes;
            },
            .zstd => {
                const decompressed_bytes = try zstd.decompressAlloc(self.allocator, file.data);
                file.data = decompressed_bytes;
                return decompressed_bytes;
            },
            else => unreachable,
        }
    }

    pub fn loadFile(self: *Map, path: []const u8) ![]const u8 {
        const entry = self.map.getEntry(path) orelse return error.FileNotFound;
        const section = entry.value_ptr;
        if (section.* != .file)
            return error.NotFile;
        const file = &section.file;
        return try self.unpackFile(file);
    }

    pub fn loadFileAlloc(self: *Map, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return try allocator.dupe(u8, try self.load(path));
    }

    pub fn loadScript(self: *const Map, path: []const u8) !Section.Script {
        const entry = self.map.getEntry(path) orelse return error.FileNotFound;
        const section = entry.value_ptr;
        if (section.* != .script)
            return error.NotScript;
        return section.script;
    }

    pub fn loadScriptAlloc(self: *const Map, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return try allocator.dupe(u8, try self.loadScript(path));
    }

    pub fn load(self: *Map, path: []const u8) ![]const u8 {
        const entry = self.map.getEntry(path) orelse return error.FileNotFound;
        const section = entry.value_ptr;
        return switch (section.*) {
            .file => try self.unpackFile(&section.file),
            .script => |s| s,
        };
    }
};

pub fn loadBundle(allocator: std.mem.Allocator, exe_header: ExeHeader, bundle: []const u8) !Map {
    var map: std.StringHashMapUnmanaged(Section) = .empty;
    try map.ensureTotalCapacity(allocator, @intCast(exe_header.sections));
    errdefer map.deinit(allocator);

    const state: PackedState = @bitCast(std.mem.readVarInt(u40, bundle[0..@divExact(@bitSizeOf(PackedState), 8)], .big));
    var pos: usize = @divExact(@bitSizeOf(PackedState), 8);

    const features: Features = @bitCast(std.mem.readVarInt(u16, bundle[pos..][0..2], .big));
    pos += 2;

    const home_dir_len = std.mem.readInt(u16, bundle[pos..][0..2], .big);
    pos += 2;
    const home_dir = bundle[pos..][0..home_dir_len];
    pos += home_dir_len;

    var entry: ?struct {
        name: [:0]const u8,
        data: Section.Script,
    } = null;

    for (0..exe_header.sections) |_| {
        const header: Section.Header = @bitCast(std.mem.readVarInt(u56, bundle[pos..][0..@divExact(@bitSizeOf(Section.Header), 8)], .big));
        pos += @divExact(@bitSizeOf(Section.Header), 8);
        const name = bundle[pos..][0..header.name_size :0];
        pos += header.name_size + 1;
        const data = bundle[pos..][0..header.size];
        pos += header.size;
        const section: Section = switch (header.kind) {
            .file => .{
                .file = switch (header.compression) {
                    .none => .{
                        .data = data,
                        .size = 0,
                        .compression = .none,
                    },
                    else => .{
                        .data = data[5..],
                        .size = std.mem.readVarInt(u40, data[0..5], .big),
                        .compression = header.compression,
                    },
                },
            },
            .script => .{
                .script = data,
            },
        };
        if (entry == null) {
            entry = .{
                .name = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", name }, 0),
                .data = data,
            };
        }
        map.putAssumeCapacity(name, section);
    }

    Zune.STATE.LUAU_OPTIONS.JIT_ENABLED = state.luau.jit_enabled;
    Zune.STATE.LUAU_OPTIONS.CODEGEN = state.luau.codegen;
    Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL = state.luau.debug_level;
    Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = state.luau.optimization_level;

    Zune.STATE.FORMAT.USE_COLOR = state.format.use_color;
    Zune.STATE.FORMAT.TABLE_ADDRESS = state.format.table_address;
    Zune.STATE.FORMAT.RECURSIVE_TABLE = state.format.recursive_table;
    Zune.STATE.FORMAT.MAX_DEPTH = state.format.max_depth;
    Zune.STATE.FORMAT.BUFFER_MAX_DISPLAY = state.format.buffer_max_display;

    inline for (@typeInfo(@TypeOf(Zune.FEATURES)).@"struct".fields) |field| {
        @field(Zune.FEATURES, field.name) = @field(features, field.name);
    }

    return .{
        .allocator = allocator,
        .mode = state.mode,
        .map = map,
        .entry = .{
            .name = entry.?.name,
            .data = entry.?.data,
        },
        .home_dir = home_dir,
        .allocated = bundle,
    };
}

pub fn getFromFile(allocator: std.mem.Allocator, exe: std.fs.File) !?Map {
    const HEADER_SIZE = @sizeOf(ExeHeader) + @sizeOf(u64) + TAG.len;

    const end = try exe.getEndPos();
    if (end < HEADER_SIZE)
        return null;
    try exe.seekFromEnd(-@as(i64, @intCast(HEADER_SIZE)));

    var header_bytes: [HEADER_SIZE]u8 = undefined;
    const amt = try exe.readAll(&header_bytes);
    std.debug.assert(amt == HEADER_SIZE);
    if (!std.mem.eql(u8, header_bytes[@sizeOf(ExeHeader) + @sizeOf(u64) ..], TAG))
        return null;

    const header: ExeHeader = @bitCast(std.mem.readVarInt(u64, header_bytes[0..8], .big));
    const hash: u64 = std.mem.readVarInt(u64, header_bytes[@sizeOf(ExeHeader)..][0..8], .big);

    if (end - HEADER_SIZE <= header.size)
        return error.CorruptBundle;

    try exe.seekBy(-@as(i64, @intCast(header.size + HEADER_SIZE)));

    const allocated = try allocator.alloc(u8, header.size);
    const amt_read = try exe.readAll(allocated);
    std.debug.assert(amt_read == header.size);

    if (std.hash.XxHash3.hash(SEED, allocated) != hash)
        return error.CorruptBundle;

    return try loadBundle(allocator, header, allocated);
}

pub fn get(allocator: std.mem.Allocator) !?Map {
    const exe = try std.fs.openSelfExe(.{ .mode = .read_only });
    defer exe.close();

    return try getFromFile(allocator, exe);
}
