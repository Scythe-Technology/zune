const std = @import("std");
const tinycc = @import("tinycc");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const tagged = @import("../../tagged.zig");

const VM = luau.VM;

const TAG_FFI_POINTER = tagged.Tags.get("FFI_POINTER").?;
const TAG_FFI_DATATYPE = tagged.Tags.get("FFI_DATATYPE").?;

pub const LIB_NAME = "ffi";
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .macos => true,
        .linux => !builtin.cpu.arch.isAARCH64(),
        .windows => !builtin.cpu.arch.isAARCH64(),
        else => false,
    };
}

const cpu_endian = builtin.cpu.arch.endian();

const Hash = std.crypto.hash.sha3.Sha3_256;

threadlocal var TAGGED_FFI_POINTERS: std.StringArrayHashMapUnmanaged(bool) = .empty;
threadlocal var CACHED_C_COMPILATON: std.StringHashMapUnmanaged(*CallableFunction) = .empty;
pub threadlocal var CACHED_POINTER: struct {
    map: std.AutoHashMapUnmanaged(?*anyopaque, i32) = .empty,
    table: LuaHelper.RefTable = .{ .table_ref = .{ .value = undefined } },
} = .{};

pub const DataType = struct {
    size: usize,
    alignment: u29,
    kind: Kind,

    pub const Types = enum {
        void,
        i8,
        i16,
        i32,
        i64,
        u8,
        u16,
        u32,
        u64,
        f32,
        f64,
        pointer,
        @"struct",

        pub fn asType(comptime self: Types) type {
            switch (self) {
                .void => return void,
                .i8 => return i8,
                .i16 => return i16,
                .i32 => return i32,
                .i64 => return i64,
                .u8 => return u8,
                .u16 => return u16,
                .u32 => return u32,
                .u64 => return u64,
                .f32 => return f32,
                .f64 => return f64,
                .pointer => return *anyopaque,
                .@"struct" => return [*]u8,
            }
        }

        pub fn typeName(comptime self: Types) []const u8 {
            switch (self) {
                .void => return "void",
                .i8 => return "signed char",
                .i16 => return "signed short",
                .i32 => return "signed int",
                .i64 => return "signed long long",
                .u8 => return "unsigned char",
                .u16 => return "unsigned short",
                .u32 => return "unsigned int",
                .u64 => return "unsigned long long",
                .f32 => return "float",
                .f64 => return "double",
                .pointer => return "void*",
                .@"struct" => return "struct",
            }
        }

        pub fn size(self: Types) usize {
            return switch (self) {
                .void => 0,
                .i8 => @sizeOf(i8),
                .i16 => @sizeOf(i16),
                .i32 => @sizeOf(i32),
                .i64 => @sizeOf(i64),
                .u8 => @sizeOf(u8),
                .u16 => @sizeOf(u16),
                .u32 => @sizeOf(u32),
                .u64 => @sizeOf(u64),
                .f32 => @sizeOf(f32),
                .f64 => @sizeOf(f64),
                .pointer => @sizeOf(usize),
                .@"struct" => 0,
            };
        }
    };

    pub const Kind = union(Types) {
        void: void,
        i8: void,
        i16: void,
        i32: void,
        i64: void,
        u8: void,
        u16: void,
        u32: void,
        u64: void,
        f32: void,
        f64: void,
        pointer: LuaPointer.Info,
        @"struct": struct {
            fields: [12]u8 = std.mem.zeroes([12]u8),
            field_len: u8 = 0,
        },
    };
};

pub const DataTypes = struct {
    pub const Types = struct {
        pub const type_void = DataType{ .size = 0, .alignment = 0, .kind = .void };

        pub const type_i8 = DataType{ .size = 1, .alignment = 1, .kind = .i8 };
        pub const type_i16 = DataType{ .size = 2, .alignment = 2, .kind = .i16 };
        pub const type_i32 = DataType{ .size = 4, .alignment = 4, .kind = .i32 };
        pub const type_i64 = DataType{ .size = 8, .alignment = 8, .kind = .i64 };

        pub const type_u8 = DataType{ .size = 1, .alignment = 1, .kind = .u8 };
        pub const type_u16 = DataType{ .size = 2, .alignment = 2, .kind = .u16 };
        pub const type_u32 = DataType{ .size = 4, .alignment = 4, .kind = .u32 };
        pub const type_u64 = DataType{ .size = 8, .alignment = 8, .kind = .u64 };

        pub const type_float = DataType{ .size = 4, .alignment = 4, .kind = .f32 };
        pub const type_double = DataType{ .size = 8, .alignment = 8, .kind = .f64 };
        pub const type_pointer = DataType{ .size = 8, .alignment = 8, .kind = .{ .pointer = .{} } };
    };

    pub const order: []const *const DataType = &.{
        &Types.type_void,  &Types.type_i8,     &Types.type_i16,
        &Types.type_i32,   &Types.type_i64,    &Types.type_u8,
        &Types.type_u16,   &Types.type_u32,    &Types.type_u64,
        &Types.type_float, &Types.type_double, &Types.type_pointer,
    };

    pub fn generateCTypeName(kind: DataType.Types, writer: anytype, id: usize, comptime pointer: bool) !void {
        const suffix = if (pointer) "*" else "";
        switch (kind) {
            .void => try writer.writeAll("void" ++ suffix),
            .i8 => try writer.writeAll("char" ++ suffix),
            .i16 => try writer.writeAll("short" ++ suffix),
            .i32 => try writer.writeAll("int" ++ suffix),
            .i64 => try writer.writeAll("long long" ++ suffix),
            .u8 => try writer.writeAll("unsigned char" ++ suffix),
            .u16 => try writer.writeAll("unsigned short" ++ suffix),
            .u32 => try writer.writeAll("unsigned int" ++ suffix),
            .u64 => try writer.writeAll("unsigned long long" ++ suffix),
            .f32 => try writer.writeAll("float" ++ suffix),
            .f64 => try writer.writeAll("double" ++ suffix),
            .pointer => try writer.writeAll("void*" ++ suffix),
            .@"struct" => try writer.print("struct anon_{d}" ++ suffix, .{id}),
        }
    }
};

fn alignForward(value: usize, alignment: usize) usize {
    return (value + (alignment - 1)) & ~(@as(usize, alignment - 1));
}

pub fn makeStruct(allocator: std.mem.Allocator, fields: []const DataType) !struct { DataType, []usize } {
    var offset: usize = 0;
    var alignment: u29 = 1;
    var offsets = try allocator.alloc(usize, fields.len);

    errdefer allocator.free(offsets);
    for (fields, 0..) |field, i| {
        alignment = @max(alignment, field.alignment);
        offset = alignForward(offset, field.alignment);
        offsets[i] = offset;
        offset += field.size;
    }
    const size = alignForward(offset, alignment);
    var count: u8 = 0;
    var inherit: [12]u8 = std.mem.zeroes([12]u8);
    if (size <= 16) {
        for (fields) |field| {
            if (count >= 12)
                break;
            switch (field.kind) {
                .@"struct" => |info| {
                    if (count + info.field_len > 12)
                        break;
                    for (0..info.field_len) |j| {
                        inherit[count] = info.fields[j];
                        count += 1;
                    }
                },
                else => {
                    inherit[count] = @intFromEnum(field.kind) + 1;
                    count += 1;
                },
            }
        }
    }
    return .{ .{
        .size = size,
        .alignment = alignment,
        .kind = .{
            .@"struct" = .{
                .fields = inherit,
                .field_len = count,
            },
        },
    }, offsets };
}

pub const LuaPointer = struct {
    ptr: ?*anyopaque,
    size: ?usize = null,
    alignment: ?std.mem.Alignment = null,
    local_ref: ?i32 = null,
    retained: bool = false,
    type: PointerType,
    data: Info,
    owner: enum { runtime, user, none },

    pub const Info = struct {
        tag: u32 = 0,
    };

    pub const PointerType = enum {
        allocated,
        static,
    };

    pub fn ptrFromAddress(L: *VM.lua.State) !i32 {
        const buf = L.Lcheckbuffer(1);
        if (buf.len < @sizeOf(usize))
            return error.SmallBuffer;

        const static_ptr: ?*anyopaque = @ptrFromInt(std.mem.bytesToValue(usize, buf[0..@sizeOf(usize)]));

        if (CACHED_POINTER.map.get(static_ptr)) |ref| {
            _ = CACHED_POINTER.table.get(L, ref) orelse @panic("unexpected value");
            return 1;
        }

        const ptr = try L.newuserdatataggedwithmetatable(LuaPointer, TAG_FFI_POINTER);

        ptr.* = .{
            .ptr = static_ptr,
            .owner = .user,
            .type = .static,
            .data = .{},
        };

        try CACHED_POINTER.map.put(Zune.DEFAULT_ALLOCATOR, static_ptr, (try CACHED_POINTER.table.ref(L, -1)).?);

        return 1;
    }

    pub fn allocBlockPtr(L: *VM.lua.State, size: usize, alignment: std.mem.Alignment) !*LuaPointer {
        const allocator = luau.getallocator(L);

        const mem: [*]u8 = blk: {
            if (size > 0) {
                const bytes = allocator.rawAlloc(size, alignment, @returnAddress()) orelse return std.mem.Allocator.Error.OutOfMemory;
                @memset(bytes[0..size], 0);
                break :blk bytes;
            }
            break :blk &[0]u8{};
        };

        const ptr = try L.newuserdatataggedwithmetatable(LuaPointer, TAG_FFI_POINTER);

        ptr.* = .{
            .ptr = @ptrCast(@alignCast(mem)),
            .size = size,
            .alignment = alignment,
            .owner = .runtime,
            .type = .allocated,
            .data = .{},
        };

        try CACHED_POINTER.map.put(Zune.DEFAULT_ALLOCATOR, @ptrCast(@alignCast(mem)), (try CACHED_POINTER.table.ref(L, -1)).?);

        try ptr.retain(L);

        return ptr;
    }

    pub fn newStaticPtr(L: *VM.lua.State, static_ptr: ?*anyopaque) !*LuaPointer {
        if (CACHED_POINTER.map.get(static_ptr)) |ref| {
            _ = CACHED_POINTER.table.get(L, ref) orelse @panic("unexpected value");
            return L.touserdatatagged(LuaPointer, -1, TAG_FFI_POINTER) orelse @panic("expected LuaPointer");
        }

        const ptr = try L.newuserdatataggedwithmetatable(LuaPointer, TAG_FFI_POINTER);

        ptr.* = .{
            .ptr = static_ptr,
            .owner = .user,
            .type = .static,
            .data = .{},
        };

        try CACHED_POINTER.map.put(Zune.DEFAULT_ALLOCATOR, static_ptr, (try CACHED_POINTER.table.ref(L, -1)).?);

        return ptr;
    }

    pub fn allocPtr(L: *VM.lua.State) !i32 {
        const ref_ptr = value(L, 1) orelse return error.Failed;
        const allocator = luau.getallocator(L);

        const ptr = try L.newuserdatataggedwithmetatable(LuaPointer, TAG_FFI_POINTER);

        const mem = try allocator.create(*anyopaque);
        mem.* = @ptrCast(@alignCast(ref_ptr.ptr));

        ptr.* = .{
            .ptr = @ptrCast(@alignCast(mem)),
            .size = @sizeOf(*anyopaque),
            .alignment = .@"8",
            .owner = .runtime,
            .type = .allocated,
            .data = .{},
        };

        try CACHED_POINTER.map.put(Zune.DEFAULT_ALLOCATOR, @ptrCast(@alignCast(mem)), (try CACHED_POINTER.table.ref(L, -1)).?);

        try ptr.retain(L);

        return 1;
    }

    pub fn retain(ptr: *LuaPointer, L: *VM.lua.State) !void {
        if (ptr.local_ref != null) {
            ptr.retained = true;
            return;
        }
        const local = try L.ref(-1) orelse return error.Fail;
        ptr.retained = true;
        ptr.local_ref = local;
    }

    pub inline fn is(L: *VM.lua.State, idx: i32) bool {
        return L.getUserdataTag(idx) == TAG_FFI_POINTER;
    }

    pub inline fn value(L: *VM.lua.State, idx: i32) ?*LuaPointer {
        return L.touserdatatagged(LuaPointer, idx, TAG_FFI_POINTER);
    }

    pub fn lua_retain(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        L.pushvalue(1);
        if (ptr.owner == .runtime)
            try ptr.retain(L);
        return 1;
    }

    pub fn lua_release(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        ptr.retained = false;
        if (ptr.owner == .runtime) {
            if (ptr.local_ref) |ref|
                L.unref(ref);
            ptr.local_ref = null;
        }
        L.pushvalue(1);
        return 1;
    }

    pub fn lua_tag(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.owner == .none or ptr.ptr == null)
            return 0;
        const tag = L.tounsigned(2) orelse {
            L.pushunsigned(ptr.data.tag);
            return 1;
        };
        ptr.data.tag = tag;
        L.pushvalue(1);
        return 1;
    }

    pub fn lua_drop(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.owner == .none or ptr.ptr == null)
            return 0;
        if (ptr.type == .static)
            return L.Zerror("cannot drop a static pointer");
        ptr.owner = .user;
        L.pushvalue(1);
        if (ptr.local_ref == null)
            try ptr.retain(L);
        return 1;
    }

    pub fn lua_offset(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        const pos: i32 = try L.Zcheckvalue(i32, 2, null);
        if (ptr.ptr == null) {
            if (pos < 0)
                return L.Zerror("negative offset on null pointer is not allowed");
            _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(@as(usize, @intCast(pos))));
            return 1;
        }
        if (ptr.size) |size|
            if (size < pos)
                return L.Zerror("offset out of bounds");

        const static = try LuaPointer.newStaticPtr(
            L,
            if (pos > 0)
                @as([*]u8, @ptrCast(ptr.ptr)) + @as(u32, @intCast(pos))
            else
                @as([*]u8, @ptrCast(ptr.ptr)) - @abs(pos),
        );

        if (ptr.size) |size|
            static.size = if (pos < 0) size + @abs(pos) else size - @as(usize, @intCast(pos));

        return 1;
    }

    pub fn lua_read(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.owner == .none or ptr.ptr == null)
            return error.NoAddressAvailable;

        const src_offset: usize = @intFromFloat(L.Lchecknumber(2));
        const dest_offset: usize = @intFromFloat(L.Lchecknumber(4));
        var dest_bounds: ?usize = null;
        const dest: [*]u8 = blk: {
            switch (L.typeOf(3)) {
                .Buffer => {
                    const buf = L.tobuffer(3) orelse unreachable;
                    dest_bounds = buf.len;
                    break :blk @ptrCast(@alignCast(buf.ptr));
                },
                .Userdata => {
                    const other = LuaPointer.value(L, 3) orelse return error.Fail;
                    if (other.owner == .none or other.ptr == null)
                        return error.NoAddressAvailable;
                    dest_bounds = other.size;
                    break :blk @ptrCast(@alignCast(ptr.ptr));
                },
                else => return L.Zerror("invalid type (expected buffer or userdata)"),
            }
        };
        const len: usize = @intCast(try L.Zcheckvalue(i32, 5, null));

        if (dest_bounds) |size| if (size < dest_offset + len)
            return L.Zerror("access out of bounds");

        if (ptr.size) |size| if (size < src_offset + len)
            return L.Zerror("access out of bounds");

        const src: [*]u8 = @ptrCast(@alignCast(ptr.ptr));

        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        L.pushvalue(3);
        return 1;
    }

    pub fn lua_write(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.owner == .none or ptr.ptr == null)
            return error.NoAddressAvailable;

        const dest_offset: usize = @intCast(try L.Zcheckvalue(i32, 2, null));
        const src_offset: usize = @intFromFloat(try L.Zcheckvalue(f64, 4, null));
        var src_bounds: ?usize = null;
        const src: [*]u8 = blk: {
            switch (L.typeOf(3)) {
                .Buffer => {
                    const buf = L.tobuffer(3) orelse unreachable;
                    src_bounds = buf.len;
                    break :blk @ptrCast(@alignCast(buf.ptr));
                },
                .Userdata => {
                    const other = LuaPointer.value(L, 3) orelse return error.Fail;
                    if (other.owner == .none or other.ptr == null)
                        return error.NoAddressAvailable;
                    src_bounds = other.size;
                    break :blk @ptrCast(@alignCast(ptr.ptr));
                },
                else => return L.Zerror("invalid type (expected buffer or userdata)"),
            }
        };
        const len: usize = @intCast(try L.Zcheckvalue(i32, 5, null));

        if (ptr.size) |size| if (size < dest_offset + len)
            return L.Zerror("access out of bounds");

        if (src_bounds) |size| if (size < src_offset + len)
            return L.Zerror("access out of bounds");

        const dest: [*]u8 = @ptrCast(@alignCast(ptr.ptr));
        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        return 0;
    }

    pub fn GenerateReadLuaMethod(comptime T: type) fn (ptr: *LuaPointer, L: *VM.lua.State) anyerror!i32 {
        if (comptime @sizeOf(T) == 0)
            @compileError("Cannot read void type");
        const len = @sizeOf(T);
        return struct {
            fn inner(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
                if (ptr.owner == .none or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const pos: usize = @intCast(L.Loptinteger(2, 0));

                if (ptr.size) |size| if (size < len + pos)
                    return L.Zerror("access out of bounds");

                const mem: [*]u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[pos..];

                switch (@typeInfo(T)) {
                    .float => L.pushnumber(@floatCast(std.mem.bytesToValue(T, mem[0..len]))),
                    .int => |i| switch (len) {
                        1...4 => {
                            const push = if (comptime i.signedness == .signed) VM.lua.State.pushinteger else VM.lua.State.pushunsigned;
                            push(L, @intCast(std.mem.bytesToValue(T, mem[0..len])));
                        },
                        8 => try L.Zpushbuffer(mem[0..len]),
                        16 => try L.Zpushbuffer(mem[0..len]),
                        else => return error.Unsupported,
                    },
                    .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.bytesToValue(usize, mem[0..@sizeOf(usize)]))),
                    else => @compileError("Unsupported type"),
                }

                return 1;
            }
        }.inner;
    }

    pub fn GenerateWriteLuaMethod(comptime T: type) fn (ptr: *LuaPointer, L: *VM.lua.State) anyerror!i32 {
        if (comptime @sizeOf(T) == 0)
            @compileError("Cannot write void type");
        const ti = @typeInfo(T);
        const len = @sizeOf(T);
        return struct {
            fn inner(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
                if (ptr.owner == .none or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const pos: usize = @intCast(L.Loptinteger(2, 0));

                if (ptr.size) |size| if (size < len + pos)
                    return L.Zerror("access out of bounds");

                const mem: []u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[pos .. pos + len];

                switch (ti) {
                    .int, .float => try FFITypeConversion(T, mem, L, 3, 0),
                    .pointer => switch (L.typeOf(-1)) {
                        .Userdata => {
                            const lua_ptr = LuaPointer.value(L, -1) orelse return error.Fail;
                            if (lua_ptr.owner == .none)
                                return error.NoAddressAvailable;
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lua_ptr.ptr)));
                            @memcpy(mem[0..@sizeOf(usize)], &bytes);
                        },
                        else => return error.InvalidArgType,
                    },
                    else => @compileError("Unsupported type"),
                }

                return 1;
            }
        }.inner;
    }

    pub fn lua_size(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        const size = L.tonumber(2) orelse {
            if (ptr.owner == .none or ptr.ptr == null)
                return 0;
            if (ptr.size) |size|
                L.pushnumber(@floatFromInt(size))
            else
                L.pushnil();
            return 1;
        };
        if (ptr.owner == .none or ptr.ptr == null)
            return L.Zerror("NoAddressAvailable");
        if (size < 0)
            return L.Zerror("size cannot be negative");

        const len: usize = @intFromFloat(size);

        switch (ptr.type) {
            .allocated => return L.Zerror("cannot set size of a known size pointer"),
            .static => {},
        }

        ptr.size = len;

        return 0;
    }

    pub fn lua_alignment(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        const alignment = L.tonumber(2) orelse {
            if (ptr.owner == .none or ptr.ptr == null)
                return 0;
            if (ptr.alignment) |alignment|
                L.pushnumber(@floatFromInt(alignment.toByteUnits()))
            else
                L.pushnil();
            return 1;
        };
        if (ptr.owner == .none or ptr.ptr == null)
            return error.NoAddressAvailable;
        if (alignment < 0)
            return L.Zerror("alignment cannot be negative");

        const len: usize = @intFromFloat(alignment);

        switch (ptr.type) {
            .allocated => return L.Zerror("alignment is already known"),
            .static => {
                if (ptr.alignment) |_|
                    return L.Zerror("alignment is already set");
            },
        }

        ptr.alignment = .fromByteUnits(len);

        return 0;
    }

    pub fn lua_span(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.owner == .none or ptr.ptr == null)
            return 0;
        const src_offset: usize = @intCast(L.Loptinteger(2, 0));

        const target: [*c]u8 = @ptrCast(@alignCast(ptr.ptr));

        const bytes: [:0]const u8 = std.mem.span(target[src_offset..]);

        if (ptr.size == null)
            ptr.size = bytes.len;

        const buf = try L.newbuffer(bytes.len + 1);
        @memcpy(buf[0..bytes.len], bytes);
        buf[bytes.len] = 0;

        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaPointer, TAG_FFI_POINTER, .{
        .{ "retain", lua_retain },
        .{ "release", lua_release },
        .{ "tag", lua_tag },
        .{ "drop", lua_drop },
        .{ "offset", lua_offset },
        .{ "read", lua_read },
        .{ "write", lua_write },
        .{ "readi8", GenerateReadLuaMethod(i8) },
        .{ "readu8", GenerateReadLuaMethod(u8) },
        .{ "readi16", GenerateReadLuaMethod(i16) },
        .{ "readu16", GenerateReadLuaMethod(u16) },
        .{ "readi32", GenerateReadLuaMethod(i32) },
        .{ "readu32", GenerateReadLuaMethod(u32) },
        .{ "readi64", GenerateReadLuaMethod(i64) },
        .{ "readu64", GenerateReadLuaMethod(u64) },
        .{ "readf32", GenerateReadLuaMethod(f32) },
        .{ "readf64", GenerateReadLuaMethod(f64) },
        .{ "readptr", GenerateReadLuaMethod(*anyopaque) },
        .{ "writei8", GenerateWriteLuaMethod(i8) },
        .{ "writeu8", GenerateWriteLuaMethod(u8) },
        .{ "writei16", GenerateWriteLuaMethod(i16) },
        .{ "writeu16", GenerateWriteLuaMethod(u16) },
        .{ "writei32", GenerateWriteLuaMethod(i32) },
        .{ "writeu32", GenerateWriteLuaMethod(u32) },
        .{ "writei64", GenerateWriteLuaMethod(i64) },
        .{ "writeu64", GenerateWriteLuaMethod(u64) },
        .{ "writef32", GenerateWriteLuaMethod(f32) },
        .{ "writef64", GenerateWriteLuaMethod(f64) },
        .{ "writeptr", GenerateWriteLuaMethod(*anyopaque) },
        .{ "size", lua_size },
        .{ "alignment", lua_alignment },
        .{ "span", lua_span },
    });

    pub fn __tostring(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = value(L, 1) orelse return error.Failed;

        const allocator = luau.getallocator(L);

        const str = try std.fmt.allocPrint(allocator, "<pointer: 0x{x}>", .{@as(usize, @intFromPtr(ptr.ptr))});
        defer allocator.free(str);

        try L.pushlstring(str);

        return 1;
    }

    pub fn __dtor(L: *VM.lua.State, ptr: *LuaPointer) void {
        _ = CACHED_POINTER.map.remove(ptr.ptr);

        if (ptr.owner != .runtime)
            return;
        switch (ptr.type) {
            .allocated => {
                if (ptr.retained)
                    return;
                if ((ptr.size orelse 1) == 0)
                    return;
                const allocator = luau.getallocator(L);
                ptr.owner = .none;
                allocator.rawFree(
                    @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0 .. ptr.size orelse 8],
                    ptr.alignment orelse .@"1",
                    @returnAddress(),
                );
            },
            .static => {},
        }
    }
};

const LuaHandle = struct {
    lib: std.DynLib,
    open: bool,

    pub fn lua_getSymbol(self: *LuaHandle, L: *VM.lua.State) !i32 {
        const symbol = try L.Zcheckvalue([:0]const u8, 2, null);
        const sym_ptr = self.lib.lookup(*anyopaque, symbol) orelse {
            L.pushnil();
            return 1;
        };
        _ = try LuaPointer.newStaticPtr(L, sym_ptr);
        return 1;
    }

    pub const __namecall = MethodMap.CreateNamecallMap(LuaHandle, null, .{
        .{ "getSymbol", lua_getSymbol },
    });

    pub fn __dtor(ptr: *LuaHandle) void {
        if (ptr.open)
            ptr.lib.close();
        ptr.open = false;
    }
};

const FunctionSymbol = struct {
    returns: DataType,
    args: []const DataType,
};

const CompiledSymbol = struct {
    type: FunctionSymbol,
    state: *tinycc.TCCState,

    pub fn free(self: CompiledSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.type.args);
        self.state.deinit();
    }
};

const CallableFunction = struct {
    pointers: ?[]*allowzero anyopaque,
    references: usize,
    sym: CompiledSymbol,

    hash: ?[]const u8,

    pub fn deinit(self: *CallableFunction) void {
        const allocator = Zune.DEFAULT_ALLOCATOR;
        self.sym.free(allocator);
        if (self.hash) |hash| {
            _ = CACHED_C_COMPILATON.fetchRemove(hash);
            allocator.free(hash);
        }
        if (self.pointers) |ptrs|
            allocator.free(ptrs);
        allocator.destroy(self);
    }

    pub fn unref(self: *CallableFunction) void {
        self.references -= 1;
        if (self.references == 0)
            self.deinit();
    }

    pub fn ref(self: *CallableFunction) void {
        self.references += 1;
    }

    pub fn getSymbol(self: *CallableFunction) *const anyopaque {
        return self.sym.state.get_symbol("symbol_call").?; // checked at compilation
    }
};

fn hashFunctionSignature(out: *[Hash.digest_length]u8, returns: DataType, args: []const DataType) void {
    const size_len = @sizeOf(usize) + 5;
    var buffer: [size_len]u8 = undefined;

    var hash = Hash.init(.{});

    switch (returns.kind) {
        inline else => |_, T| std.mem.writeInt(u8, buffer[0..1], @intFromEnum(T), .little),
    }
    if (returns.kind == .pointer)
        std.mem.writeInt(u32, buffer[1..5], returns.kind.pointer.tag, .little)
    else
        std.mem.writeInt(u32, buffer[1..5], 0, .little);
    std.mem.writeInt(usize, buffer[5..size_len], returns.size, .little);
    hash.update(&buffer);

    switch (returns.kind) {
        .@"struct" => |info| {
            hash.update(&info.fields);
            hash.update(&[_]u8{info.field_len});
        },
        else => {},
    }

    for (args) |arg| {
        switch (arg.kind) {
            inline else => |_, T| std.mem.writeInt(u8, buffer[0..1], @intFromEnum(T), .little),
        }
        if (arg.kind == .pointer)
            std.mem.writeInt(u32, buffer[1..5], arg.kind.pointer.tag, .little)
        else
            std.mem.writeInt(u32, buffer[1..5], 0, .little);
        std.mem.writeInt(usize, buffer[5..size_len], arg.size, .little);
        hash.update(&buffer);

        switch (arg.kind) {
            .@"struct" => |info| {
                hash.update(&info.fields);
                hash.update(&[_]u8{info.field_len});
            },
            else => {},
        }
    }
    hash.final(out);
}

fn compileCallableFunction(returns: DataType, args: []const DataType) !CallableFunction {
    const allocator = Zune.DEFAULT_ALLOCATOR;
    const state = try tinycc.new();
    errdefer state.deinit();

    state.set_output_type(tinycc.TCC_OUTPUT_MEMORY);
    state.set_options("-std=c11 -nostdlib -Wl,--export-all-symbols");

    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();

    const pointer_count = try dynamicLoadImport(&source, state, returns, args);

    const pointers: ?[]*allowzero anyopaque = if (pointer_count > 0) try allocator.alloc(*allowzero anyopaque, pointer_count) else null;
    errdefer if (pointers) |arr| allocator.free(arr);

    if (pointer_count > 0) {
        try generateExported(&source, "arg_pointers[]", "void*", &.{});
        _ = state.add_symbol("arg_pointers", @ptrCast(@alignCast(pointers.?.ptr)));
    }

    try source.append('\n');
    try generateSourceFromSymbol(&source, returns, args);

    state.compileStringOnce(allocator, source.items) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };

    _ = state.get_symbol("symbol_call") orelse return error.BadCompilation;

    return .{
        .sym = .{
            .state = state,
            .type = .{
                .returns = returns,
                .args = try allocator.dupe(DataType, args),
            },
        },
        .pointers = pointers,
        .references = 0,
        .hash = null,
    };
}

fn fetchCallableFunction(returns: DataType, args: []const DataType) !*CallableFunction {
    const allocator = Zune.DEFAULT_ALLOCATOR;
    var hash: [Hash.digest_length]u8 = undefined;
    hashFunctionSignature(&hash, returns, args);

    if (CACHED_C_COMPILATON.getEntry(&hash)) |entry| {
        entry.value_ptr.*.ref();
        return entry.value_ptr.*;
    }

    var code = compileCallableFunction(returns, args) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };
    errdefer code.deinit();

    const code_ptr = try allocator.create(CallableFunction);
    errdefer allocator.destroy(code_ptr);

    const hash_key = try allocator.dupe(u8, &hash);
    errdefer allocator.free(hash_key);

    code.hash = hash_key;
    code_ptr.* = code;

    try CACHED_C_COMPILATON.put(allocator, hash_key, code_ptr);

    code_ptr.ref();

    return code_ptr;
}

const LuaClosure = struct {
    allocator: std.mem.Allocator,
    callinfo: *CallInfo,
    sym: CompiledSymbol,

    callable: *anyopaque,

    pub const CallInfo = struct {
        ref: ?i32,
        args: c_uint,
        type: FunctionSymbol,
        thread: *VM.lua.State,
    };

    pub fn __dtor(self: *LuaClosure) void {
        self.allocator.destroy(self.callinfo);
        self.sym.free(self.allocator);
    }
};

const LuaDataType = struct {
    type: DataType,
    offsets: ?[]usize = null,
    fields_map: ?std.StringArrayHashMap(DataType) = null,

    pub fn lua_newTag(self: *LuaDataType, L: *VM.lua.State) !i32 {
        if (self.type.kind != .pointer)
            return L.Zerror("'tag' is only available for pointers");
        if (self.type.kind.pointer.tag != 0)
            return L.Zerror("Cannot create tagged pointer from tagged pointer");

        const unique = try L.Zcheckvalue([]const u8, 2, null);

        const result = try TAGGED_FFI_POINTERS.getOrPut(Zune.DEFAULT_ALLOCATOR, unique);
        result.value_ptr.* = true;

        if (result.index + 1 > std.math.maxInt(u32))
            return error.MaximumTagExceeded;

        const datatype = try L.newuserdatataggedwithmetatable(LuaDataType, TAG_FFI_DATATYPE);

        datatype.* = .{
            .type = .{
                .size = 8,
                .alignment = 8,
                .kind = .{ .pointer = .{ .tag = @intCast(result.index + 1) } },
            },
        };

        return 1;
    }

    pub fn lua_offset(self: *LuaDataType, L: *VM.lua.State) !i32 {
        if (self.type.kind != .@"struct")
            return L.Zerror("'offset' is only available for structs");
        const field = try L.Zcheckvalue([]const u8, 2, null);
        const order = self.fields_map.?.getIndex(field) orelse return L.Zerrorf("Unknown field: {s}", .{field});
        L.pushinteger(@intCast(self.offsets.?[order]));
        return 1;
    }

    pub fn lua_new(self: *LuaDataType, L: *VM.lua.State) !i32 {
        if (self.type.kind != .@"struct")
            return L.Zerror("'new' is only available for structs");
        try L.Zchecktype(2, .Table);
        const allocator = luau.getallocator(L);

        const fields_map = self.fields_map.?;
        const offsets = self.offsets.?;

        const mem = try allocator.alloc(u8, self.type.size);
        defer allocator.free(mem);

        @memset(mem, 0);

        for (fields_map.keys(), fields_map.values(), 0..) |field, field_value, order| {
            defer L.pop(1);
            try L.pushlstring(field);
            if (L.rawget(2).isnoneornil())
                return error.MissingField;
            const pos = offsets[order];
            const field_type = field_value;
            switch (field_type.kind) {
                .void => return error.InvalidArgType,
                .pointer => switch (L.typeOf(-1)) {
                    .Userdata => {
                        const lua_ptr = LuaPointer.value(L, -1) orelse return error.Failed;
                        if (lua_ptr.owner == .none)
                            return error.NoAddressAvailable;
                        if (lua_ptr.data.tag != field_type.kind.pointer.tag)
                            return error.PointerTagMismatch;
                        var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lua_ptr.ptr)));
                        @memcpy(mem[pos .. pos + @sizeOf(usize)], &bytes);
                    },
                    else => return error.InvalidArgType,
                },
                .@"struct" => {
                    if (L.typeOf(-1) != .Buffer)
                        return error.InvalidArgType;
                    const value = L.tobuffer(-1) orelse unreachable;
                    if (value.len != field_type.size)
                        return error.InvalidArgType;
                    @memcpy(mem[pos .. pos + field_type.size], value);
                },
                inline else => |_, T| try FFITypeConversion(T.asType(), mem, L, -1, pos),
            }
        }

        try L.Zpushbuffer(mem);

        return 1;
    }

    pub fn lua_size(self: *LuaDataType, L: *VM.lua.State) !i32 {
        L.pushinteger(@intCast(self.type.size));
        return 1;
    }

    pub fn lua_alignment(self: *LuaDataType, L: *VM.lua.State) !i32 {
        L.pushinteger(@intCast(self.type.alignment));
        return 1;
    }

    pub fn lua_tag(self: *LuaDataType, L: *VM.lua.State) !i32 {
        if (self.type.kind != .pointer)
            return 0;
        L.pushinteger(@intCast(self.type.kind.pointer.tag));
        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaDataType, TAG_FFI_DATATYPE, .{
        .{ "offset", lua_offset },
        .{ "new", lua_new },
        .{ "newTag", lua_newTag },
        .{ "size", lua_size },
        .{ "alignment", lua_alignment },
        .{ "tag", lua_tag },
    });

    pub fn __dtor(_: *VM.lua.State, self: *LuaDataType) void {
        if (self.fields_map == null)
            return;
        const fields_map = &self.fields_map.?;
        const allocator = fields_map.allocator;
        var iter = fields_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
        fields_map.deinit();
        if (self.offsets) |offsets|
            allocator.free(offsets);
    }
};

const FFITypeSize = std.meta.fields(DataType).len;
fn convertToFFIType(number: i32) !DataType {
    if (number < 0 or @as(u32, @intCast(number)) > FFITypeSize)
        return error.InvalidReturnType;
    return @enumFromInt(number);
}

fn isFFIType(L: *VM.lua.State, idx: i32) bool {
    switch (L.typeOf(idx)) {
        .Userdata => {
            _ = L.touserdatatagged(LuaDataType, idx, TAG_FFI_DATATYPE) orelse return false;
            return true;
        },
        else => return false,
    }
}

fn toFFIType(L: *VM.lua.State, idx: i32) !DataType {
    switch (L.typeOf(idx)) {
        .Userdata => return (L.touserdatatagged(LuaDataType, idx, TAG_FFI_DATATYPE) orelse return error.InvalidFFIType).*.type,
        else => return error.InvalidType,
    }
}

pub fn FFITypeConversion(
    comptime T: type,
    mem: []u8,
    L: *VM.lua.State,
    index: comptime_int,
    offset: usize,
) !void {
    const ti = @typeInfo(T);
    if (ti != .int and ti != .float)
        @compileError("Unsupported type");
    const size = @sizeOf(T);
    switch (L.typeOf(index)) {
        .Number => switch (@typeInfo(T)) {
            .int => |i| {
                if (i.bits > 32) {
                    const value = L.tonumber(-1).?;
                    if (i.signedness == .unsigned) {
                        var bytes: [size]u8 = @bitCast(@as(
                            T,
                            @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(value))))),
                        ));
                        @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
                    } else {
                        var bytes: [size]u8 = @bitCast(@as(T, @truncate(@as(i64, @intFromFloat(value)))));
                        @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
                    }
                } else {
                    const value = if (i.signedness == .signed) L.tointeger(-1).? else L.tounsigned(-1).?;
                    var bytes: [size]u8 = @bitCast(@as(T, @truncate(value)));
                    @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
                }
            },
            .float => {
                const value = L.tonumber(-1).?;
                var bytes: [size]u8 = @bitCast(@as(T, @floatCast(value)));
                @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
            },
            else => @compileError("Unsupported type"),
        },
        .Boolean => {
            const value = L.toboolean(index);
            var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, if (value) 1 else 0));
            @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
        },
        .Buffer => {
            const buf = L.tobuffer(-1) orelse unreachable;
            if (buf.len < @sizeOf(T))
                return error.SmallBuffer;
            @memcpy(mem[offset .. offset + @sizeOf(T)], buf[0..@sizeOf(T)]);
        },
        else => return error.InvalidArgType,
    }
}

const ffi_c_interface = struct {
    fn FFIArgumentLoad(comptime T: type) fn (L: *VM.lua.State, index: i32) callconv(.C) T {
        const ti = @typeInfo(T);
        if (ti != .int and ti != .float)
            @compileError("Unsupported type");
        const size = @sizeOf(T);
        return struct {
            fn inner(L: *VM.lua.State, index: i32) callconv(.C) T {
                switch (L.typeOf(index)) {
                    .Number => switch (@typeInfo(T)) {
                        .int => |i| {
                            if (i.bits > 32) {
                                const value = L.tonumber(index).?;
                                if (i.signedness == .unsigned)
                                    return @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(value)))))
                                else
                                    return @truncate(@as(i64, @intFromFloat(value)));
                            } else {
                                const value = if (i.signedness == .signed) L.tointeger(index).? else L.tounsigned(index).?;
                                return @truncate(value);
                            }
                        },
                        .float => return @floatCast(L.tonumber(index).?),
                        else => @compileError("Unsupported type"),
                    },
                    .Boolean => {
                        return @as(T, if (L.toboolean(index) == true) 1 else 0);
                    },
                    .Buffer => {
                        const lua_buf = L.tobuffer(index).?;
                        if (lua_buf.len < size)
                            return L.LerrorL("buffer too small", .{}) catch |e| std.debug.panic("{}", .{e});
                        return std.mem.bytesToValue(T, lua_buf[0..size]);
                    },
                    .Proto, .UpVal, .Deadkey => unreachable,
                    inline else => |e| L.LerrorL("invalid argument type (got {s})", .{comptime VM.lapi.typename(e)}) catch |err| std.debug.panic("{}", .{err}),
                }
            }
        }.inner;
    }

    fn FFIArgumentPush(comptime T: type) fn (L: *VM.lua.State, value: T) callconv(.C) void {
        const ti = @typeInfo(T);
        if (ti != .int and ti != .float)
            @compileError("Unsupported type");
        const isFloat = ti == .float;
        const size = @sizeOf(T);
        return struct {
            fn inner(L: *VM.lua.State, value: T) callconv(.C) void {
                switch (size) {
                    1...4 => {
                        if (isFloat)
                            L.pushnumber(@floatCast(value))
                        else
                            L.pushinteger(@intCast(value));
                    },
                    8 => {
                        if (isFloat)
                            L.pushnumber(value)
                        else
                            L.Zpushbuffer(&@as([8]u8, @bitCast(value))) catch |e| std.debug.panic("{}", .{e});
                    },
                    else => @compileError("Unsupported size"),
                }
            }
        }.inner;
    }

    pub const checki8 = FFIArgumentLoad(i8);
    pub const checku8 = FFIArgumentLoad(u8);
    pub const checki16 = FFIArgumentLoad(i16);
    pub const checku16 = FFIArgumentLoad(u16);
    pub const checki32 = FFIArgumentLoad(i32);
    pub const checku32 = FFIArgumentLoad(u32);
    pub const checki64 = FFIArgumentLoad(i64);
    pub const checku64 = FFIArgumentLoad(u64);
    pub const checkf32 = FFIArgumentLoad(f32);
    pub const checkf64 = FFIArgumentLoad(f64);

    pub const pushi8 = FFIArgumentPush(i8);
    pub const pushu8 = FFIArgumentPush(u8);
    pub const pushi16 = FFIArgumentPush(i16);
    pub const pushu16 = FFIArgumentPush(u16);
    pub const pushi32 = FFIArgumentPush(i32);
    pub const pushu32 = FFIArgumentPush(u32);
    pub const pushi64 = FFIArgumentPush(i64);
    pub const pushu64 = FFIArgumentPush(u64);
    pub const pushf32 = FFIArgumentPush(f32);
    pub const pushf64 = FFIArgumentPush(f64);

    pub fn pushpointer(L: *VM.lua.State, ptr: ?*anyopaque) callconv(.c) void {
        _ = LuaPointer.newStaticPtr(L, ptr) catch (L.LerrorL("Failed to create pointer", .{}) catch |e| std.debug.panic("{}", .{e}));
    }

    pub fn pushmem(L: *VM.lua.State, ptr: [*c]u8, size: usize) callconv(.c) void {
        L.Zpushbuffer(ptr[0..size]) catch |e| std.debug.panic("{}", .{e});
    }
};

fn getfunctionSymbol(allocator: std.mem.Allocator, L: *VM.lua.State, idx: i32) !FunctionSymbol {
    var symbol: FunctionSymbol = undefined;
    _ = L.rawgetfield(idx, "returns");
    if (!isFFIType(L, -1))
        return L.Zerror("function return type must be a valid ffi type");
    symbol.returns = try toFFIType(L, -1);
    L.pop(1); // drop: returns

    if (L.rawgetfield(idx, "args") != .Table)
        return L.Zerrorf("function args must be a table (got {s})", .{VM.lapi.typename(L.typeOf(-1))});

    const args_len = L.objlen(-1);

    const args = try allocator.alloc(DataType, @intCast(args_len));
    errdefer allocator.free(args);
    symbol.args = args;

    var order: usize = 0;
    var arr_iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = -1 };
    while (try arr_iter.next()) |t| switch (t) {
        .Userdata => {
            if (!isFFIType(L, -1))
                return L.Zerrorf("function arg type must be a valid ffi type (got {s})", .{VM.lapi.typename(L.typeOf(-1))});

            const ffi_type = try toFFIType(L, -1);
            if (ffi_type.size == 0)
                return L.Zerror("function arg type cannot be void");

            args[order] = ffi_type;
            order += 1;
        },
        else => return L.Zerrorf("function arg must be a userdata (got {s})", .{VM.lapi.typename(t)}),
    };
    L.pop(1); // drop: args
    return symbol;
}

fn lua_struct(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);

    const allocator = luau.getallocator(L);

    var struct_map = std.StringArrayHashMap(DataType).init(allocator);
    errdefer struct_map.deinit();
    errdefer {
        var iter = struct_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
    }

    var order: i32 = 1;
    var iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = 1 };
    while (try iter.next()) |t| switch (t) {
        .Table => {
            if (L.rawiter(-1, 0) < 0)
                return L.Zerror("struct field contains no field type");

            if (L.typeOf(-2) != .String)
                return L.Zerrorf("struct field name must be a string (got {s})", .{VM.lapi.typename(L.typeOf(-2))});
            const name = L.tostring(-2) orelse unreachable;

            if (!isFFIType(L, -1))
                return L.Zerror("struct field type must be a valid ffi type");

            if (struct_map.contains(name))
                return L.Zerrorf("struct field '{s}' already exists", .{name});

            {
                const name_copy = try allocator.dupe(u8, name); // Zig owned string to prevent GC from Lua owned strings
                errdefer allocator.free(name_copy);
                try struct_map.put(name_copy, try toFFIType(L, -1));
            }

            L.pop(2);

            if (L.rawiter(-1, 1) >= 0)
                return L.Zerror("struct field contains more than one field type");

            order += 1;
        },
        else => return L.Zerrorf("struct field must be a table (got {s})", .{VM.lapi.typename(t)}),
    };

    const data = try L.newuserdatataggedwithmetatable(LuaDataType, TAG_FFI_DATATYPE);

    const datatype, const offsets = try makeStruct(allocator, struct_map.values());

    data.* = .{
        .type = datatype,
        .offsets = offsets,
        .fields_map = struct_map,
    };

    return 1;
}

fn generateExported(source: *std.ArrayList(u8), name: []const u8, ret_type: []const u8, symbol_args: []const []const u8) !void {
    const writer = source.writer();

    try writer.print((if (builtin.os.tag == .windows) "__declspec(dllimport) " else "extern "), .{});
    try writer.print("{s} {s}", .{ ret_type, name });

    if (symbol_args.len > 0) {
        try source.appendSlice("(");
        for (symbol_args, 0..) |arg, i| {
            if (i != 0)
                try source.appendSlice(", ");
            try writer.print("{s}", .{arg});
        }
        try source.appendSlice(")");
    }

    try source.appendSlice(";\n");
}

fn generateTypeFromSymbol(source: *std.ArrayList(u8), symbol: DataType, order: usize, comptime pointer: bool) !void {
    const writer = source.writer();

    if (order == 0) {
        if (symbol.kind == .@"struct")
            try writer.print("struct anon_ret" ++ if (pointer) "*" else "", .{})
        else
            try DataTypes.generateCTypeName(symbol.kind, writer, 0, pointer);
    } else {
        try DataTypes.generateCTypeName(symbol.kind, writer, order - 1, pointer);
    }
}

fn generateStructTypeFromSymbol(writer: anytype, symbol: DataType, order: usize) !void {
    std.debug.assert(symbol.kind == .@"struct");
    const struct_info = symbol.kind.@"struct";
    try writer.print("struct __attribute__((aligned({d}))) ", .{symbol.alignment});
    if (order == 0)
        try writer.print("anon_ret {{ ", .{})
    else
        try writer.print("anon_{d} {{ ", .{order - 1});

    var filled: usize = 0;
    if (struct_info.field_len > 0) {
        var count: u8 = 0;
        for (struct_info.fields[0..struct_info.field_len]) |field_kind| {
            if (field_kind == 0)
                continue;
            defer count += 1;
            const kind: DataType.Types = @enumFromInt(field_kind - 1);
            try DataTypes.generateCTypeName(kind, writer, 0, false);
            try writer.print(" _{d}; ", .{count});
            filled += kind.size();
        }
    }
    if (filled < symbol.size) {
        try writer.print("unsigned char _[{d}]; ", .{symbol.size - filled});
    }
    try writer.print("}};\n", .{});
}

fn generateTypesFromSymbol(source: *std.ArrayList(u8), symbol_returns: DataType, symbol_args: []const DataType) !void {
    const writer = source.writer();
    if (symbol_returns.kind == .@"struct")
        try generateStructTypeFromSymbol(writer, symbol_returns, 0);

    for (symbol_args, 0..) |arg, i| {
        if (arg.kind != .@"struct")
            continue;

        try generateStructTypeFromSymbol(writer, arg, i + 1);
    }

    try source.appendSlice("typedef ");
    try generateTypeFromSymbol(source, symbol_returns, 0, false);
    try source.appendSlice(" (Fn)(");
    for (symbol_args, 0..) |arg, i| {
        if (i != 0)
            try source.appendSlice(", ");
        try generateTypeFromSymbol(source, arg, i + 1, false);
    }
    try source.appendSlice(");");
    try source.append('\n');
}

fn generateSourceFromSymbol(source: *std.ArrayList(u8), symbol_returns: DataType, symbol_args: []const DataType) !void {
    const writer = source.writer();

    try generateTypesFromSymbol(source, symbol_returns, symbol_args);

    try source.appendSlice("void symbol_call(void* L, Fn* fn) {\n  ");
    if (symbol_returns.size > 0) {
        try generateTypeFromSymbol(source, symbol_returns, 0, false);
        try source.appendSlice(" ret = ");
    }
    try source.appendSlice("fn(");
    if (symbol_args.len > 0) {
        var order: usize = 0;
        for (symbol_args, 0..) |arg, i| {
            if (i != 0)
                try source.append(',');
            switch (arg.kind) {
                .void => return error.VoidParameter,
                .pointer => {
                    defer order += 1;
                    try writer.print("\n    (", .{});
                    try generateTypeFromSymbol(source, arg, i + 1, false);
                    try writer.print(")arg_pointers[{d}]", .{order});
                },
                .@"struct" => {
                    defer order += 1;
                    try writer.print("\n    *((", .{});
                    try generateTypeFromSymbol(source, arg, i + 1, true);
                    try writer.print(")arg_pointers[{d}])", .{order});
                },
                inline else => |_, T| try writer.print("\n    lua_ffi_check{s}(L, {d})", .{ @tagName(T), i + 1 }),
            }
        }
        try source.appendSlice("\n  ");
    }
    try source.appendSlice(");\n");

    switch (symbol_returns.kind) {
        .void => {},
        .@"struct" => try writer.print("  lua_ffi_pushmem(L, (unsigned char*)&ret, {d});\n", .{symbol_returns.size}),
        inline else => |_, T| try writer.print("  lua_ffi_push{s}(L, ret);\n", .{@tagName(T)}),
    }

    try source.appendSlice("}\n");
}

fn dynamicLoadImport(source: *std.ArrayList(u8), state: *tinycc.TCCState, returns: DataType, args: []const DataType) !usize {
    const types_len = @typeInfo(ffi_c_interface).@"struct".decls.len;
    var loaded_fn: [types_len]bool = ([_]bool{false} ** types_len);
    var pointers: usize = 0;
    for (args) |arg| {
        switch (arg.kind) {
            .void => return error.VoidParameter,
            .pointer, .@"struct" => {
                defer pointers += 1;
            },
            inline else => |_, T| {
                const declname = "check" ++ @tagName(T);
                inline for (@typeInfo(ffi_c_interface).@"struct".decls, 0..) |decl, i| {
                    if (std.mem.eql(u8, decl.name, declname)) {
                        const checkfn = @field(ffi_c_interface, decl.name);
                        if (loaded_fn[i])
                            break;
                        loaded_fn[i] = true;
                        try generateExported(source, "lua_ffi_" ++ declname, T.typeName(), &.{ "void*", "unsigned int" });
                        _ = state.add_symbol("lua_ffi_" ++ declname, @ptrCast(@alignCast(&checkfn)));
                        break;
                    }
                }
            },
        }
    }

    switch (returns.kind) {
        .void => {},
        .@"struct" => {
            try generateExported(source, "lua_ffi_pushmem", "void", &.{ "void*", "unsigned char*", "unsigned long long" });
            _ = state.add_symbol("lua_ffi_pushmem", @ptrCast(@alignCast(&ffi_c_interface.pushmem)));
        },
        inline else => |_, T| {
            const declname = "push" ++ @tagName(T);
            const pushfn = @field(ffi_c_interface, declname);
            try generateExported(source, "lua_ffi_" ++ declname, "void", &.{ "void*", T.typeName() });
            _ = state.add_symbol("lua_ffi_" ++ declname, @ptrCast(@alignCast(&pushfn)));
        },
    }

    return pointers;
}

fn lua_dlopen(L: *VM.lua.State) !i32 {
    const path = try L.Zcheckvalue([]const u8, 1, null);

    const allocator = luau.getallocator(L);

    try L.Zchecktype(2, .Table);

    var func_map = std.StringArrayHashMap(FunctionSymbol).init(allocator);
    defer func_map.deinit();
    defer {
        var iter = func_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.args);
        }
    }

    var iter: LuaHelper.TableIterator = .{ .L = L, .idx = 2 };
    while (iter.next()) |key| switch (key) {
        .String => {
            if (L.typeOf(-1) != .Table)
                return L.Zerrorf("function type must be a table (got {s})", .{VM.lapi.typename(L.typeOf(-1))});

            const name = L.tostring(-2).?;

            const symbol = try getfunctionSymbol(allocator, L, -1);

            const name_copy = try allocator.dupe(u8, name); // Zig owned string to prevent GC from Lua owned strings
            errdefer allocator.free(name_copy);
            try func_map.put(name_copy, symbol);
        },
        else => return L.Zerrorf("external function name must be a string (got {s})", .{VM.lapi.typename(key)}),
    };

    const ptr = try L.newuserdatadtor(LuaHandle, LuaHandle.__dtor);

    ptr.* = .{
        .lib = undefined,
        .open = false,
    };

    var lib = try std.DynLib.open(path);

    ptr.lib = lib;
    ptr.open = true;

    try L.createtable(0, 2);

    try L.createtable(0, @intCast(func_map.count()));
    while (func_map.pop()) |entry| {
        const key = entry.key;
        const value = entry.value;
        defer allocator.free(key);
        defer allocator.free(value.args);
        const namez = try allocator.dupeZ(u8, key);
        defer allocator.free(namez);
        const func = lib.lookup(*anyopaque, namez) orelse {
            return L.Zerrorf("symbol '{s}' not found", .{key});
        };

        const code = try fetchCallableFunction(value.returns, value.args);
        errdefer code.unref();

        try L.pushlstring(key);
        (try L.newuserdatadtor(FFIFunction, FFIFunction.__dtor)).* = .{
            .lib = ptr,
            .callable = @ptrCast(@alignCast(code.getSymbol())),
            .code = code,
            .ptr = func,
        };
        L.pushvalue(-5);
        try L.pushcclosure(VM.zapi.toCFn(FFIFunction.fn_inner), "ffi_func", 2);
        try L.rawset(-3);
    }
    try L.rawsetfield(-2, luau.Metamethods.index);

    try L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaHandle.__namecall);
    try L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");

    _ = try L.setmetatable(-2);

    return 1;
}

fn FFIReturnTypeConversion(
    comptime T: type,
    ret_ptr: *anyopaque,
    L: *VM.lua.State,
) void {
    const size = @sizeOf(T);
    const mem = @as([*]u8, @ptrCast(@alignCast(ret_ptr)))[0..size];
    switch (L.typeOf(-1)) {
        .Number => switch (@typeInfo(T)) {
            .int => |i| {
                if (i.bits > 32) {
                    const value = L.tonumber(-1).?;
                    if (i.signedness == .unsigned) {
                        var bytes: [size]u8 = @bitCast(@as(
                            T,
                            @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(value))))),
                        ));
                        @memcpy(mem, &bytes);
                    } else {
                        var bytes: [size]u8 = @bitCast(@as(T, @truncate(@as(i64, @intFromFloat(value)))));
                        @memcpy(mem, &bytes);
                    }
                } else {
                    const value = if (i.signedness == .signed) L.tointeger(-1).? else L.tounsigned(-1).?;
                    var bytes: [size]u8 = @bitCast(@as(T, @truncate(value)));
                    @memcpy(mem, &bytes);
                }
            },
            .float => {
                const value = L.tonumber(-1).?;
                var bytes: [size]u8 = @bitCast(@as(T, @floatCast(value)));
                @memcpy(mem, &bytes);
            },
            else => @compileError("Unsupported type"),
        },
        .Boolean => {
            var bytes: [size]u8 = @bitCast(@as(T, if (L.toboolean(-1) == true) 1 else 0));
            @memcpy(mem, &bytes);
        },
        .Buffer => {
            const lua_buf = L.tobuffer(-1) orelse unreachable;
            if (lua_buf.len < size)
                return std.debug.panic("Small buffer ('{s}')", .{@typeName(T)});
            @memcpy(mem, lua_buf[0..size]);
        },
        else => std.debug.panic("invalid return type (expected number for '{s}')", .{@typeName(T)}),
    }
}

fn FFIPushPtrType(
    comptime T: type,
    L: *VM.lua.State,
    ptr: *anyopaque,
) void {
    switch (@typeInfo(T)) {
        .int => |int| {
            if (int.bits > 32) {
                const bytes: [@divExact(int.bits, 8)]u8 = @bitCast(@as(*T, @ptrCast(@alignCast(ptr))).*);
                L.Zpushbuffer(&bytes) catch |e| std.debug.panic("{}", .{e});
                return;
            }
            if (int.signedness == .signed)
                L.pushinteger(@intCast(@as(*T, @ptrCast(@alignCast(ptr))).*))
            else
                L.pushunsigned(@intCast(@as(*T, @ptrCast(@alignCast(ptr))).*));
        },
        .float => {
            if (T == f32)
                L.pushnumber(@floatCast(@as(T, @bitCast(@as(*u32, @ptrCast(@alignCast(ptr))).*))))
            else
                L.pushnumber(@as(T, @bitCast(@as(*u64, @ptrCast(@alignCast(ptr))).*)));
        },
        else => @compileError("Unsupported type"),
    }
}

fn ffi_closure_inner(call_info: *const LuaClosure.CallInfo, extern_args: [*]?*anyopaque, ret: ?*anyopaque) callconv(.c) void {
    const scheduler = Scheduler.getScheduler(call_info.thread);

    const main_thread = std.Thread.getCurrentId() == scheduler.threadId;

    if (!main_thread)
        std.debug.panic("Cannot call FFI closure from non-main thread", .{});

    const args = extern_args[0..call_info.args];

    if (!(call_info.thread.checkstack(1) catch |e| std.debug.panic("{}", .{e})))
        return std.debug.panic("Failed to grow stack for ffi closure", .{});

    const L = call_info.thread.newthread() catch |e| std.debug.panic("{}", .{e});
    defer call_info.thread.pop(1);
    var ref: LuaHelper.Ref(void) = .{
        .ref = .{
            .registry = call_info.ref orelse return std.debug.panic("invalid call info: no reference to call", .{}),
        },
        .value = undefined,
    };

    _ = ref.push(L);

    for (call_info.type.args, 0..) |arg_type, i| {
        switch (arg_type.kind) {
            .void => unreachable,
            .pointer => {
                const ptr = LuaPointer.newStaticPtr(L, @as(*[*]u8, @ptrCast(@alignCast(args[i]))).*) catch |err| std.debug.panic("Failed: {}", .{err});
                ptr.data = arg_type.kind.pointer;
            },
            .@"struct" => {
                const bytes: [*]u8 = @ptrCast(@alignCast(args[i]));
                L.Zpushbuffer(bytes[0..arg_type.size]) catch |e| std.debug.panic("{}", .{e});
            },
            inline else => |_, tag| FFIPushPtrType(tag.asType(), L, args[i].?),
        }
    }

    const has_return = call_info.type.returns.size > 0;

    _ = L.pcall(@intCast(args.len), if (has_return) 1 else 0, 0).check() catch {
        std.debug.panic("C Closure Runtime Error: {s}", .{L.tostring(-1) orelse "UnknownError"});
    };

    if (has_return) {
        defer L.pop(1);
        switch (call_info.type.returns.kind) {
            .void => unreachable,
            .pointer => switch (L.typeOf(-1)) {
                .Userdata => {
                    const ptr = LuaPointer.value(L, -1) orelse std.debug.panic("invalid pointer", .{});
                    if (ptr.owner == .none or ptr.ptr == null)
                        std.debug.panic("No address available", .{});
                    if (ptr.data.tag != call_info.type.returns.kind.pointer.tag)
                        std.debug.panic("Pointer tag mismatch", .{});
                    @as(*[*]u8, @ptrCast(@alignCast(ret))).* = @ptrCast(ptr.ptr);
                },
                .String => std.debug.panic("Unsupported return type (use a pointer to a buffer instead)", .{}),
                .Nil => {
                    @as(*?*anyopaque, @ptrCast(@alignCast(ret))).* = null;
                },
                else => return std.debug.panic("invalid return type (expected buffer/nil for '*anyopaque')", .{}),
            },
            .@"struct" => {
                if (L.typeOf(-1) != .Buffer)
                    return std.debug.panic("invalid return type (expected buffer for struct)", .{});
                const buf = L.tobuffer(-1) orelse unreachable;
                if (buf.len != call_info.type.returns.size)
                    return std.debug.panic("invalid return type (expected buffer of size {d} for struct)", .{call_info.type.returns.size});
                @memcpy(@as([*]u8, @ptrCast(@alignCast(ret))), buf);
            },
            inline else => |_, T| FFIReturnTypeConversion(T.asType(), ret.?, L),
        }
    }
}

fn lua_closure(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);
    try L.Zchecktype(2, .Function);

    const allocator = luau.getallocator(L);

    const symbol = try getfunctionSymbol(allocator, L, 1);
    var handled = false;
    errdefer if (!handled) allocator.free(symbol.args);

    const state = try tinycc.new();
    errdefer state.deinit();

    state.set_output_type(tinycc.TCC_OUTPUT_MEMORY);
    state.set_options("-std=c11 -nostdlib -Wl,--export-all-symbols");

    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();
    const writer = source.writer();

    try generateExported(&source, "external_call", "void", &.{ "void*", "void**", "void*" });
    try generateExported(&source, "external_ptr", "void**", &.{});

    try writer.print("\n", .{});

    try generateTypesFromSymbol(&source, symbol.returns, symbol.args);

    try generateTypeFromSymbol(&source, symbol.returns, 0, false);
    try source.appendSlice(" call_closure_ffi(");
    for (symbol.args, 0..) |arg, i| {
        if (i != 0)
            try source.appendSlice(", ");
        try generateTypeFromSymbol(&source, arg, i + 1, false);
        try writer.print(" arg_{d}", .{i});
    }
    try source.appendSlice(") {\n  ");
    if (symbol.args.len > 0) {
        try writer.print("void* args[{d}];\n  ", .{symbol.args.len});
    }
    if (symbol.returns.size > 0) {
        try generateTypeFromSymbol(&source, symbol.returns, 0, false);
        try source.appendSlice(" ret;\n  ");
    }

    for (symbol.args, 0..) |_, i| {
        try writer.print("args[{d}] = (void*)&arg_{d};\n  ", .{ i, i });
    }

    if (symbol.returns.size > 0) {
        try writer.print("external_call(&external_ptr, args, (void*)&ret);\n  ", .{});
        try writer.print("return ret;\n}}\n", .{});
    } else {
        try writer.print("external_call(&external_ptr, args, 0);\n}}", .{});
    }

    const call_ptr = try allocator.create(LuaClosure.CallInfo);
    errdefer allocator.destroy(call_ptr);

    call_ptr.* = .{
        .args = @intCast(symbol.args.len),
        .thread = L.mainthread(),
        .ref = null,
        .type = .{
            .returns = symbol.returns,
            .args = symbol.args,
        },
    };

    _ = state.add_symbol("external_ptr", @ptrCast(@alignCast(call_ptr)));
    _ = state.add_symbol("external_call", @ptrCast(@alignCast(&ffi_closure_inner)));

    state.compileStringOnce(allocator, source.items) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };
    const callable = state.get_symbol("call_closure_ffi") orelse return error.BadCompilation;

    call_ptr.ref = try L.ref(2);

    const data = try L.newuserdatadtor(LuaClosure, LuaClosure.__dtor);
    handled = true;
    data.* = .{
        .allocator = allocator,
        .callable = callable,
        .callinfo = call_ptr,
        .sym = .{
            .state = state,
            .type = .{
                .returns = symbol.returns,
                .args = symbol.args,
            },
        },
    };

    try L.createtable(0, 2);

    try L.createtable(0, 1);
    {
        L.pushvalue(2);
        try L.rawsetfield(-2, "callback");
    }
    try L.rawsetfield(-2, luau.Metamethods.index);

    L.pushvalue(-3);
    try L.rawsetfield(-2, "thread");

    L.setreadonly(-1, true);

    _ = try L.setmetatable(-2);

    _ = try L.ref(-1); // permenently reference the closure

    const ptr = try LuaPointer.newStaticPtr(L, data.callable);
    try ptr.retain(L);
    ptr.size = 0;

    return 1;
}

const FFIFunction = struct {
    code: *CallableFunction,
    ptr: *const anyopaque,
    lib: ?*LuaHandle = null,

    callable: FFICallable,

    pub const FFICallable = *align(8) const fn (lua_State: *anyopaque, fnPtr: *const anyopaque) callconv(.c) void;

    pub fn fn_inner(L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);
        const self = L.touserdata(FFIFunction, VM.lua.upvalueindex(1)) orelse unreachable;

        if (self.lib) |lib|
            if (!lib.open)
                return L.Zerrorf("library is closed", .{});

        const callable = self.callable;

        const arg_count = L.gettop();
        if (arg_count < self.code.sym.type.args.len)
            return L.Zerrorf("invalid number of arguments (expected {d} args, got {d} args)", .{ self.code.sym.type.args.len, arg_count });

        var arena: ?std.heap.ArenaAllocator = null;
        defer if (arena) |a| a.deinit();

        const pointers = self.code.pointers;
        if (pointers) |ptrs| {
            arena = std.heap.ArenaAllocator.init(allocator);
            const arena_allocator = arena.?.allocator();
            var order: usize = 0;
            for (self.code.sym.type.args, 1..) |arg, i| {
                switch (arg.kind) {
                    .pointer => {
                        defer order += 1;
                        const idx: i32 = @intCast(i);
                        switch (L.typeOf(idx)) {
                            .Userdata => {
                                const ptr = LuaPointer.value(L, idx) orelse return L.Zerrorf("userdata is not a Pointer", .{});
                                if (ptr.owner == .none)
                                    return L.Zerrorf("Pointer no address available", .{});
                                if (ptr.data.tag != arg.kind.pointer.tag)
                                    return L.Zerrorf("Pointer tag mismatch", .{});
                                ptrs[order] = @ptrCast(@alignCast(ptr.ptr));
                            },
                            .String => {
                                const str: [:0]const u8 = L.tostring(idx).?;
                                const dup = arena_allocator.dupeZ(u8, str) catch return L.Zerrorf("OutOfMemory", .{});
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Buffer => {
                                const buf = L.tobuffer(idx).?;
                                const dup = arena_allocator.dupe(u8, buf) catch return L.Zerrorf("OutOfMemory", .{});
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Nil => ptrs[order] = @ptrFromInt(0),
                            .Proto, .UpVal, .Deadkey => unreachable,
                            inline else => |e| return L.Zerrorf("invalid argument type (got {s})", .{comptime VM.lapi.typename(e)}),
                        }
                    },
                    .@"struct" => {
                        defer order += 1;
                        const idx: i32 = @intCast(i);
                        switch (L.typeOf(idx)) {
                            .Buffer => {},
                            .Proto, .UpVal, .Deadkey => unreachable,
                            inline else => |e| return L.Zerrorf("invalid argument type (expected buffer, got {s})", .{comptime VM.lapi.typename(e)}),
                        }
                        const buf = L.tobuffer(idx).?;
                        if (buf.len != arg.size)
                            return L.Zerrorf("invalid buffer size mismatch (expected {d} bytes, got {d} bytes)", .{ arg.size, buf.len });
                        const mem: []u8 = @alignCast((arena_allocator.rawAlloc(arg.size, .fromByteUnits(arg.alignment), @returnAddress()) orelse return L.Zerrorf("OutOfMemory", .{}))[0..arg.size]);
                        @memcpy(mem, buf);
                        ptrs[order] = @ptrCast(@alignCast(mem.ptr));
                    },
                    else => {},
                }
            }
        }

        @call(.never_tail, callable, .{
            @as(*anyopaque, @ptrCast(@alignCast(L))),
            self.ptr,
        });

        const returns = self.code.sym.type.returns;
        if (returns.size > 0) {
            if (returns.kind == .pointer and returns.kind.pointer.tag != 0) {
                const ptr = LuaPointer.value(L, -1) orelse unreachable;
                ptr.data = returns.kind.pointer;
            }
            return 1;
        }
        return 0;
    }

    pub fn __dtor(self: *FFIFunction) void {
        self.code.unref();
    }
};

fn lua_fn(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);
    const src = LuaPointer.value(L, 2) orelse return L.Zerror("invalid pointer");
    switch (src.type) {
        .allocated => return error.PointerNotCallable,
        else => {},
    }
    const ptr: *anyopaque = src.ptr orelse return error.NoAddressAvailable;

    const allocator = luau.getallocator(L);

    const symbol = try getfunctionSymbol(allocator, L, 1);
    defer allocator.free(symbol.args);

    const code = try fetchCallableFunction(symbol.returns, symbol.args);
    errdefer code.unref();

    const data = try L.newuserdatadtor(FFIFunction, FFIFunction.__dtor);

    data.* = .{
        .callable = @ptrCast(@alignCast(code.getSymbol())),
        .code = code,
        .ptr = ptr,
    };

    try L.pushcclosure(VM.zapi.toCFn(FFIFunction.fn_inner), "ffi_fn", 1);

    return 1;
}

fn lua_tagName(L: *VM.lua.State) !i32 {
    const id = L.Lcheckunsigned(1);
    if (id == 0) {
        L.pushnil();
        return 1;
    }
    const names = TAGGED_FFI_POINTERS.keys();
    if (id > names.len) {
        L.pushnil();
        return 1;
    }
    const name = names[id - 1];
    try L.pushlstring(name);
    return 1;
}

fn lua_alloc(L: *VM.lua.State) !i32 {
    const len = L.Lchecknumber(1);
    const alignment = L.Loptnumber(2, 1);
    if (alignment <= 0)
        return L.Zerror("invalid alignment");
    _ = try LuaPointer.allocBlockPtr(L, @intFromFloat(len), .fromByteUnits(@intFromFloat(alignment)));
    return 1;
}

fn lua_getLuaState(L: *VM.lua.State) !i32 {
    if (try L.Zcheckvalue(?bool, 1, null) orelse false) {
        _ = try LuaPointer.newStaticPtr(L, @ptrCast(L.mainthread()));
        return 1;
    }
    _ = try LuaPointer.newStaticPtr(L, @ptrCast(L));
    return 1;
}

fn lua_free(L: *VM.lua.State) !i32 {
    const ptr = LuaPointer.value(L, 1) orelse return L.Zerror("invalid pointer");
    if (ptr.owner == .none)
        return L.Zerror("Double free");
    const allocator = luau.getallocator(L);
    if (ptr.local_ref) |ref| {
        L.unref(ref);
        ptr.local_ref = null;
    }
    switch (ptr.type) {
        .allocated => {
            ptr.owner = .none;
            if ((ptr.size orelse 1) == 0)
                return 0;
            allocator.rawFree(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0 .. ptr.size orelse 8],
                ptr.alignment orelse .@"1",
                @returnAddress(),
            );
        },
        .static => {
            ptr.owner = .none;
            if (ptr.size) |size| {
                if (size > 0)
                    allocator.rawFree(
                        @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size],
                        ptr.alignment orelse .@"1",
                        @returnAddress(),
                    );
            }
        },
    }
    return 0;
}

fn lua_dupe(L: *VM.lua.State) !i32 {
    switch (L.typeOf(1)) {
        .Buffer => {
            const buf = L.tobuffer(1) orelse unreachable;
            const ptr = try LuaPointer.allocBlockPtr(L, buf.len, .@"1");
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..buf.len],
                buf,
            );
        },
        .Userdata => {
            const ptr = LuaPointer.value(L, 1) orelse return error.Fail;
            if (ptr.owner == .none or ptr.ptr == null)
                return error.NoAddressAvailable;
            const len = ptr.size orelse return L.Zerror("unknown sized pointer");
            const dup_ptr = try LuaPointer.allocBlockPtr(L, len, ptr.alignment orelse .@"1");
            dup_ptr.data = ptr.data;
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(dup_ptr.ptr)))[0..len],
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..len],
            );
        },
        else => return L.Zerror("invalid type (expected buffer or userdata)"),
    }
    return 1;
}

const LuaCompiled = struct {
    state: *tinycc.TCCState,

    pub fn deinit(self: *LuaCompiled) void {
        self.state.deinit();
    }

    pub fn lua_getSymbol(self: *LuaCompiled, L: *VM.lua.State) !i32 {
        if (self.state.get_symbol(L.Lcheckstring(2))) |ptr| {
            _ = try LuaPointer.newStaticPtr(L, ptr);
            return 1;
        }
        return 0;
    }

    pub const __namecall = MethodMap.CreateNamecallMap(LuaCompiled, null, .{
        .{ "getSymbol", lua_getSymbol },
    });
};

fn lua_compile(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const source_code = L.Lcheckstring(1);

    const state = try tinycc.new();
    errdefer state.deinit();

    state.set_output_type(tinycc.TCC_OUTPUT_MEMORY);
    state.set_options("-std=c11 -nostdlib -Wl,--export-all-symbols");

    var error_output: std.ArrayList(u8) = .init(allocator);
    defer error_output.deinit();

    state.set_error_func(@ptrCast(@alignCast(&error_output)), struct {
        fn inner(ud: ?*anyopaque, msg: [*:0]const u8) callconv(.c) void {
            const o = @as(*std.ArrayList(u8), @ptrCast(@alignCast(ud.?)));
            o.appendSlice(std.mem.span(msg)) catch |err| @panic(@errorName(err));
        }
    }.inner);

    if (try L.Zcheckvalue(?struct {
        options: ?[:0]const u8 = null,
    }, 2, null)) |opts| {
        if (opts.options) |o|
            state.set_options(o);

        if (LuaHelper.maybeKnownType(L.rawgetfield(2, "files"))) |@"type"| {
            if (@"type" != .Table)
                return L.Zerrorf("files must be a table (got {s})", .{VM.lapi.typename(@"type")});
            var iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = -1 };
            while (try iter.next()) |t| switch (t) {
                .String => try state.add_file(L.tostring(-1).?),
                else => return L.Zerrorf("file must be a string (got {s})", .{VM.lapi.typename(t)}),
            };
        }
        L.pop(1);

        if (LuaHelper.maybeKnownType(L.rawgetfield(2, "libraries"))) |@"type"| {
            if (@"type" != .Table)
                return L.Zerrorf("libraries must be a table (got {s})", .{VM.lapi.typename(@"type")});
            var iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = -1 };
            while (try iter.next()) |t| switch (t) {
                .String => try state.add_library(L.tostring(-1).?),
                else => return L.Zerrorf("library must be a string (got {s})", .{VM.lapi.typename(t)}),
            };
        }
        L.pop(1);

        if (LuaHelper.maybeKnownType(L.rawgetfield(2, "includes"))) |@"type"| {
            if (@"type" != .Table)
                return L.Zerrorf("includes must be a table (got {s})", .{VM.lapi.typename(@"type")});
            var iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = -1 };
            while (try iter.next()) |t| switch (t) {
                .String => _ = state.add_include_path(L.tostring(-1).?),
                else => return L.Zerrorf("include path must be a string (got {s})", .{VM.lapi.typename(t)}),
            };
        }
        L.pop(1);

        if (LuaHelper.maybeKnownType(L.rawgetfield(2, "sysincludes"))) |@"type"| {
            if (@"type" != .Table)
                return L.Zerrorf("sysincludes must be a table (got {s})", .{VM.lapi.typename(@"type")});
            var iter: LuaHelper.ArrayIterator = .{ .L = L, .idx = -1 };
            while (try iter.next()) |t| switch (t) {
                .String => _ = state.add_sysinclude_path(L.tostring(-1).?),
                else => return L.Zerrorf("sysinclude path must be a string (got {s})", .{VM.lapi.typename(t)}),
            };
        }
        L.pop(1);

        if (LuaHelper.maybeKnownType(L.rawgetfield(2, "symbols"))) |@"type"| {
            if (@"type" != .Table)
                return L.Zerrorf("symbols must be a table (got {s})", .{VM.lapi.typename(@"type")});
            var iter: LuaHelper.TableIterator = .{ .L = L, .idx = -1 };
            while (iter.next()) |t| switch (t) {
                .String => {
                    const ptr = LuaPointer.value(L, -1) orelse return L.Zerror("include path must be a pointer");
                    _ = state.add_symbol(L.tostring(-2).?, @ptrCast(@alignCast(ptr.ptr)));
                },
                else => return L.Zerrorf("symbol name must be a string (got {s})", .{VM.lapi.typename(t)}),
            };
        }
        L.pop(1);
    }

    state.compile_string(source_code) catch {
        return L.Zerror(if (error_output.items.len > 0) error_output.items else "CompilationError");
    };
    if (error_output.items.len > 0)
        return L.Zerror(error_output.items);

    state.set_error_func(null, struct {
        fn inner(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
    }.inner);

    try state.relocate();

    const obj = try L.newuserdatadtor(LuaCompiled, LuaCompiled.deinit);
    obj.* = .{
        .state = state,
    };
    std.debug.assert(!(try L.Lgetmetatable(@typeName(LuaCompiled))).isnoneornil());
    _ = try L.setmetatable(-2);
    return 1;
}

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaDataType), .{
            .__metatable = "Metatable is locked",
            .__type = "FFIDataType",
        });
        try LuaDataType.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatadtor(LuaDataType, TAG_FFI_DATATYPE, LuaDataType.__dtor);
        L.setuserdatametatable(TAG_FFI_DATATYPE);
    }
    {
        _ = try L.Znewmetatable(@typeName(LuaPointer), .{
            .__tostring = LuaPointer.__tostring,
            .__metatable = "Metatable is locked",
            .__type = "FFIPointer",
        });
        try LuaPointer.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatadtor(LuaPointer, TAG_FFI_POINTER, LuaPointer.__dtor);
        L.setuserdatametatable(TAG_FFI_POINTER);
    }
    {
        _ = try L.Znewmetatable(@typeName(LuaCompiled), .{
            .__namecall = LuaCompiled.__namecall,
            .__metatable = "Metatable is locked",
            .__type = "FFICompiled",
        });
        L.setreadonly(-1, true);
        L.pop(1);
    }

    CACHED_POINTER.table = try .init(L, true);

    try L.createtable(0, 16);

    _ = try LuaPointer.newStaticPtr(L, null);
    try L.rawsetfield(-2, "null");

    try L.Zsetfieldfn(-1, "dlopen", lua_dlopen);
    try L.Zsetfieldfn(-1, "struct", lua_struct);
    try L.Zsetfieldfn(-1, "closure", lua_closure);
    try L.Zsetfieldfn(-1, "fn", lua_fn);

    try L.Zsetfieldfn(-1, "alloc", lua_alloc);
    try L.Zsetfieldfn(-1, "free", lua_free);
    try L.Zsetfieldfn(-1, "dupe", lua_dupe);

    try L.Zsetfieldfn(-1, "tagName", lua_tagName);

    try L.Zsetfieldfn(-1, "ptr", LuaPointer.allocPtr);
    try L.Zsetfieldfn(-1, "ptrFromAddress", LuaPointer.ptrFromAddress);

    try L.Zsetfieldfn(-1, "getLuaState", lua_getLuaState);

    try L.Zsetfield(-1, "c", .{
        .compile = lua_compile,
    });

    try L.createtable(0, @intCast(@typeInfo(DataTypes.Types).@"struct".decls.len));
    inline for (@typeInfo(DataTypes.Types).@"struct".decls, 0..) |decl, i| {
        try L.pushstring(decl.name[5..]);
        const ptr = try L.newuserdatataggedwithmetatable(LuaDataType, TAG_FFI_DATATYPE);
        ptr.* = .{
            .type = DataTypes.order[i].*,
        };
        try L.rawset(-3);
    }
    L.setreadonly(-1, true);
    try L.rawsetfield(-2, "types");

    switch (comptime builtin.os.tag) {
        .linux => try L.pushstring("so"),
        .macos => try L.pushstring("dylib"),
        .windows => try L.pushstring("dll"),
        else => try L.pushstring(""),
    }
    try L.rawsetfield(-2, "suffix");

    switch (comptime builtin.os.tag) {
        .windows => try L.pushstring(""),
        else => try L.pushstring("lib"),
    }
    try L.rawsetfield(-2, "prefix");

    L.setreadonly(-1, true);
    try LuaHelper.registerModule(L, LIB_NAME);
}

test "ffi" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/ffi/init.luau"),
        &.{},
        .{ .ref_leak_check = false },
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total >= 0);
}
