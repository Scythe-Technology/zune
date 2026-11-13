const std = @import("std");
const lz4 = @import("lz4");
const zstd = @import("zstd");
const builtin = @import("builtin");
const Flate = @import("../utils/flate.zig");

const Zune = @import("zune");

pub const Image = extern struct {
    magic: [8]u8,
    sections: [4]u8,
    flags: u8,
    reserved: [3]u8,
    size: [8]u8,
    offset: [8]u8,

    pub const magic_bytes = [8]u8{ 0x5b, 0x5a, 0x4c, 0x42, 0x44, 0x30, 0x31, 0x5d }; // "[ZLBD01]"
    pub const enabled: u8 = 1;

    comptime {
        std.debug.assert(@sizeOf(Image) == 32);
    }
};

export var zune_bundle_image: Image = .{
    .magic = Image.magic_bytes,
    .sections = .{ 0, 0, 0, 0 },
    .flags = 0,
    .reserved = .{ 0, 0, 0 },
    .size = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .offset = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

pub const Bundled = struct {
    sections: u32,
    size: u64,
    offset: u64,
};

var cached: ?Bundled = null;

pub fn get() ?Bundled {
    std.mem.doNotOptimizeAway(&zune_bundle_image);

    const image = @as(*volatile Image, &zune_bundle_image).*;
    if (!std.mem.eql(u8, &image.magic, &Image.magic_bytes))
        return null;
    if (image.flags & Image.enabled == 0)
        return null;

    if (cached) |c|
        return c;

    cached = .{
        .sections = std.mem.readInt(u32, &image.sections, .big),
        .size = std.mem.readInt(u64, &image.size, .big),
        .offset = std.mem.readInt(u64, &image.offset, .big),
    };

    return cached;
}

pub const Section = union(enum) {
    script: Script,
    file: File,

    pub const Script = []const u8;
    pub const Compression = enum(u3) { none, zlib, lz4, zstd, gzip, flate };

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

    pub fn writeScript(writer: *std.Io.Writer, name: []const u8, data: []const u8) !void {
        if (name.len > std.math.maxInt(u15))
            return error.NameTooLong;
        if (data.len > std.math.maxInt(u37))
            return error.DataTooLarge;
        try writer.writeInt(u56, @bitCast(Section.Header{
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
        writer: *std.Io.Writer,
        name: []const u8,
        data: []const u8,
        compression: Compression,
    ) !void {
        if (name.len > std.math.maxInt(u15))
            return error.NameTooLong;
        if (data.len > std.math.maxInt(u37))
            return error.DataTooLarge;
        if (compression == .none) {
            try writer.writeInt(u56, @bitCast(Section.Header{
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
            var array: std.ArrayList(u8) = .empty;
            defer array.deinit(allocator);
            switch (compression) {
                .zlib => {
                    const compressed_bytes = try Flate.compress(allocator, data, .zlib, .default);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = compressed_bytes,
                        .pointer_stability = .{},
                    };
                },
                .gzip => {
                    const compressed_bytes = try Flate.compress(allocator, data, .gzip, .default);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = compressed_bytes,
                        .pointer_stability = .{},
                    };
                },
                .flate => {
                    const compressed_bytes = try Flate.compress(allocator, data, .raw, .default);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = compressed_bytes,
                        .pointer_stability = .{},
                    };
                },
                .lz4 => {
                    const compressed_bytes = try lz4.Standard.compress(allocator, data);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = compressed_bytes,
                        .pointer_stability = .{},
                    };
                },
                .zstd => {
                    const compressed_bytes = try zstd.compressAlloc(allocator, data, 3);
                    array = .{
                        .capacity = compressed_bytes.len,
                        .items = @constCast(compressed_bytes),
                        .pointer_stability = .{},
                    };
                },
                else => unreachable,
            }
            const block_size: usize = array.items.len + 5; // 5 bytes for u40
            if (block_size > std.math.maxInt(u37))
                return error.DataTooLarge;
            try writer.writeInt(u56, @bitCast(Section.Header{
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

pub const Features = packed struct(u32) {
    io: bool = true,
    mem: bool = true,
    fmt: bool = true,
    luau: bool = true,
    task: bool = true,
    debug: bool = true,
    ascii: bool = true,
    serde: bool = true,
    regex: bool = true,
    config: bool = true,
    crypto: bool = true,
    random: bool = true,
    require: bool = true,
    testing: bool = true,
    process: bool = true,
    platform: bool = true,
    fs: bool = true,
    c: bool = true,
    gpio: bool = true,
    net: bool = true,
    time: bool = true,
    thread: bool = true,
    _: u10 = 0,

    pub fn write(writer: anytype, features: Features) !void {
        try writer.writeInt(u32, @bitCast(features), .big);
    }

    comptime {
        const runtime_fields = @typeInfo(@TypeOf(Zune.State.options.runtime.features)).@"struct".field_names;
        const packed_fields = @typeInfo(Features).@"struct".field_names;
        std.debug.assert(packed_fields.len == runtime_fields.len + 1);
        std.debug.assert(std.mem.eql(u8, packed_fields[packed_fields.len - 1], "_"));
        for (runtime_fields, 0..) |field_name, index|
            std.debug.assert(std.mem.eql(u8, field_name, packed_fields[index]));

        const library_names = @typeInfo(Zune.standard.libraries).@"struct".decl_names;
        std.debug.assert(library_names.len == runtime_fields.len);
        for (library_names, 0..) |decl_name, index|
            std.debug.assert(std.mem.eql(u8, decl_name, runtime_fields[index]));
    }
};

pub const PackedState = packed struct(u40) {
    mode: Mode,
    luau: Luau,
    format: Format,
    _: u3 = 0, // reserved bits

    pub const Mode = packed struct(u2) {
        compiled: enum(u1) { debug, release },
        limbo: bool = false,
    };

    const Format = packed struct(u29) {
        enabled: bool = true,
        indent: u2 = @backingInt(Zune.Resolvers.Fmt.Indent.FourSpaces),
        use_color: bool = true,
        table_address: bool = true,
        recursive_table: bool = false,
        max_depth: u8 = 4,
        buffer_max_display: u15 = 48,
    };

    const Luau = packed struct(u6) {
        debug_level: u2 = 2,
        optimization_level: u2 = 1,
        default_ncg: bool = true,
        jit_enabled: bool = true,
    };

    pub fn write(writer: *std.Io.Writer, state: PackedState) !void {
        try writer.writeInt(u40, @bitCast(state), .big);
    }
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    mode: PackedState.Mode,
    exe: std.Io.File,
    map: std.hash_map.StringHashMapUnmanaged(Section),
    home_dir: []const u8,
    locators: std.hash_map.StringHashMapUnmanaged(Locator) = .empty,
    owned: std.ArrayList([]const u8) = .empty,
    entry: struct {
        name: [:0]const u8,
        data: Section.Script,
    },

    const Locator = struct {
        offset: u64,
        size: u64,
        loaded: bool = false,
    };

    pub fn deinit(self: *Map) void {
        self.locators.deinit(self.allocator);
        for (self.owned.items) |block|
            self.allocator.free(block);

        self.owned.deinit(self.allocator);

        var names = self.map.keyIterator();
        while (names.next()) |key|
            self.allocator.free(key.*);

        self.allocator.free(self.home_dir);

        self.exe.close(Zune.io());

        self.map.deinit(self.allocator);
        self.allocator.free(self.entry.name);
    }

    fn readExact(self: *Map, offset: u64, buf: []u8) !void {
        const n = try self.exe.readPositionalAll(Zune.io(), buf, offset);
        if (n != buf.len)
            return error.CorruptBundle;
    }

    fn take(self: *Map, offset: u64, size: usize) ![]const u8 {
        if (size == 0)
            return &.{};
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        try self.readExact(offset, bytes);
        try self.owned.append(self.allocator, bytes);
        return bytes;
    }

    fn inflate(self: *Map, file: *const Section.File, container: std.compress.flate.Container) ![]u8 {
        const bytes = try self.allocator.alloc(u8, @intCast(file.size));
        errdefer self.allocator.free(bytes);

        _ = try Flate.decompressInto(bytes, file.data, container);

        return bytes;
    }

    pub fn unpackFile(self: *Map, file: *Section.File) ![]const u8 {
        if (file.compression == .none) return file.data;

        const bytes = switch (file.compression) {
            .none => unreachable,
            .zlib => try self.inflate(file, .zlib),
            .gzip => try self.inflate(file, .gzip),
            .flate => try self.inflate(file, .raw),
            .lz4 => try lz4.Standard.decompress(self.allocator, file.data, file.size),
            .zstd => try zstd.decompressAlloc(self.allocator, file.data),
        };
        errdefer self.allocator.free(bytes);

        try self.owned.append(self.allocator, bytes);

        file.data = bytes;
        file.compression = .none;

        return bytes;
    }

    fn materialize(self: *Map, path: []const u8) !void {
        const locator = self.locators.getPtr(path) orelse return error.CorruptBundle;
        if (locator.loaded) return;

        const section = self.map.getPtr(path) orelse return error.CorruptBundle;
        const bytes = try self.take(locator.offset, @intCast(locator.size));
        switch (section.*) {
            .script => section.script = bytes,
            .file => |*file| {
                if (file.compression == .none) {
                    file.data = bytes;
                    file.size = bytes.len;
                } else {
                    if (bytes.len < 5)
                        return error.CorruptBundle;
                    file.size = std.mem.readVarInt(u40, bytes[0..5], .big);
                    file.data = bytes[5..];
                }
            },
        }
        locator.loaded = true;
    }

    pub fn loadFile(self: *Map, path: []const u8) ![]const u8 {
        const entry = self.map.getEntry(path) orelse return error.FileNotFound;
        if (entry.value_ptr.* != .file) return error.NotFile;

        try self.materialize(path);
        const file = &self.map.getPtr(path).?.file;

        return try self.unpackFile(file);
    }

    pub fn shortResolve(path: []const u8) []const u8 {
        var resolved = path;
        while (std.mem.startsWith(u8, resolved, "./") or std.mem.startsWith(u8, resolved, ".\\"))
            resolved = std.mem.trimStart(u8, resolved[1..], "\\/");
        return resolved;
    }

    pub fn loadFileAlloc(self: *Map, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return try allocator.dupe(u8, try self.load(shortResolve(path)));
    }

    pub fn loadScript(self: *Map, path: []const u8) !Section.Script {
        const entry = self.map.getEntry(path) orelse return error.FileNotFound;
        if (entry.value_ptr.* != .script)
            return error.NotScript;
        try self.materialize(path);
        return self.map.get(path).?.script;
    }

    pub fn loadScriptAlloc(self: *Map, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return try allocator.dupe(u8, try self.loadScript(path));
    }

    pub fn load(self: *Map, path: []const u8) ![]const u8 {
        if (self.map.getPtr(path) == null)
            return error.FileNotFound;
        try self.materialize(path);
        const section = self.map.getPtr(path) orelse return error.CorruptBundle;
        return switch (section.*) {
            .file => |*file| try self.unpackFile(file),
            .script => |script| script,
        };
    }
};

fn applyPacked(state: PackedState, features: Features) void {
    Zune.State.options.runtime.luau.jit_enabled = state.luau.jit_enabled;
    Zune.State.options.runtime.luau.default_ncg = state.luau.default_ncg;
    Zune.State.options.runtime.luau.debug_level = state.luau.debug_level;
    Zune.State.options.runtime.luau.optimization_level = state.luau.optimization_level;

    Zune.State.options.format.enabled = state.format.enabled;
    Zune.State.options.format.indent = @fromBackingInt(state.format.indent);
    Zune.State.options.format.use_color = state.format.use_color;
    Zune.State.options.format.table_address = state.format.table_address;
    Zune.State.options.format.recursive_table = state.format.recursive_table;
    Zune.State.options.format.max_depth = state.format.max_depth;
    Zune.State.options.format.buffer_max_display = state.format.buffer_max_display;

    inline for (@typeInfo(@TypeOf(Zune.State.options.runtime.features)).@"struct".field_names) |field_name|
        @field(Zune.State.options.runtime.features, field_name) = @field(features, field_name);
}

pub fn open(allocator: std.mem.Allocator, bundled: Bundled) !Map {
    if (bundled.offset == 0 or bundled.sections == 0)
        return error.CorruptBundle;

    const file = try std.process.openExecutable(Zune.io(), .{ .mode = .read_only });
    errdefer file.close(Zune.io());

    var map: std.hash_map.StringHashMapUnmanaged(Section) = .empty;
    try map.ensureTotalCapacity(allocator, @intCast(bundled.sections));
    errdefer {
        var names = map.keyIterator();
        while (names.next()) |key|
            allocator.free(key.*);
        map.deinit(allocator);
    }

    var locators: std.hash_map.StringHashMapUnmanaged(Map.Locator) = .empty;
    try locators.ensureTotalCapacity(allocator, @intCast(bundled.sections));
    errdefer locators.deinit(allocator);

    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |block|
            allocator.free(block);
        owned.deinit(allocator);
    }

    const end = bundled.offset + bundled.size;
    var pos: u64 = bundled.offset;

    var prefix: [11]u8 = undefined;
    if (pos + prefix.len > end)
        return error.CorruptBundle;

    const prefix_n = try file.readPositionalAll(Zune.io(), &prefix, pos);
    if (prefix_n != prefix.len)
        return error.CorruptBundle;
    pos += prefix.len;

    const state: PackedState = @bitCast(std.mem.readVarInt(u40, prefix[0..5], .big));
    const features: Features = @bitCast(std.mem.readInt(u32, prefix[5..9], .big));

    const home_len = std.mem.readInt(u16, prefix[9..11], .big);
    if (pos + home_len > end)
        return error.CorruptBundle;

    const home_dir: []const u8 = if (home_len == 0) &.{} else blk: {
        const bytes = try allocator.alloc(u8, @intCast(home_len));
        errdefer allocator.free(bytes);

        const n = try file.readPositionalAll(Zune.io(), bytes, pos);
        if (n != bytes.len)
            return error.CorruptBundle;

        break :blk bytes;
    };
    errdefer if (home_len > 0) allocator.free(home_dir);
    pos += home_len;

    var entry_name: ?[:0]const u8 = null;
    errdefer if (entry_name) |name| allocator.free(name);

    var entry_data: []const u8 = &.{};

    for (0..bundled.sections) |index| {
        var header_bytes: [7]u8 = undefined;
        if (pos + @as(u64, header_bytes.len) > end)
            return error.CorruptBundle;
        const header_n = try file.readPositionalAll(Zune.io(), &header_bytes, pos);
        if (header_n != header_bytes.len)
            return error.CorruptBundle;
        pos += @as(u64, header_bytes.len);

        const header: Section.Header = @bitCast(std.mem.readVarInt(u56, &header_bytes, .big));
        const name_len: u64 = header.name_size;
        const body_len: u64 = header.size;
        if (pos + name_len + 1 > end)
            return error.CorruptBundle;

        const name: []const u8 = if (header.name_size == 0) &.{} else blk: {
            const bytes = try allocator.alloc(u8, @intCast(header.name_size));
            errdefer allocator.free(bytes);

            const n = try file.readPositionalAll(Zune.io(), bytes, pos);
            if (n != bytes.len)
                return error.CorruptBundle;

            break :blk bytes;
        };
        pos += name_len;
        var name_in_map = false;
        errdefer if (!name_in_map and header.name_size > 0) allocator.free(name);

        var nul: [1]u8 = undefined;
        const nul_n = try file.readPositionalAll(Zune.io(), &nul, pos);
        if (nul_n != 1 or nul[0] != 0)
            return error.CorruptBundle;
        pos += 1;

        if (pos + body_len > end)
            return error.CorruptBundle;
        const data_offset = pos;
        pos += body_len;

        if (map.getPtr(name) != null)
            return error.CorruptBundle;

        const section: Section = switch (header.kind) {
            .script => .{ .script = &.{} },
            .file => .{
                .file = .{
                    .data = &.{},
                    .size = 0,
                    .compression = header.compression,
                },
            },
        };
        map.putAssumeCapacity(name, section);
        name_in_map = true;
        locators.putAssumeCapacity(name, .{
            .offset = data_offset,
            .size = header.size,
        });

        if (index == 0) {
            if (header.kind != .script)
                return error.CorruptBundle;
            const data: []const u8 = if (header.size == 0) &.{} else blk: {
                const bytes = try allocator.alloc(u8, @intCast(header.size));
                errdefer allocator.free(bytes);

                const n = try file.readPositionalAll(Zune.io(), bytes, data_offset);
                if (n != bytes.len)
                    return error.CorruptBundle;

                try owned.append(allocator, bytes);

                break :blk bytes;
            };

            map.getPtr(name).?.script = data;
            locators.getPtr(name).?.loaded = true;

            entry_name = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", name }, 0);
            entry_data = data;
        }
    }

    const entry = entry_name orelse return error.CorruptBundle;

    applyPacked(state, features);

    return .{
        .allocator = allocator,
        .mode = state.mode,
        .map = map,
        .entry = .{
            .name = entry,
            .data = entry_data,
        },
        .home_dir = home_dir,
        .exe = file,
        .locators = locators,
        .owned = owned,
    };
}
