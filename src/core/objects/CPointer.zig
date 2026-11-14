const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

const CPointer = @This();

pub const OBJECT_TAG = Zune.Tags.get("C_POINTER").?;
pub const PlatformSupported = Zune.standard.libraries.c.PlatformSupported;

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

pub fn initCacheTable(L: *VM.lua.State) !void {
    try Scripting.initTable(L, true);
    try L.rawsetfield(VM.lua.REGISTRYINDEX, "_CACHED_FFI_TABLE");
}

pub fn getCacheTable(L: *VM.lua.State) void {
    const @"type" = L.rawgetfield(VM.lua.REGISTRYINDEX, "_CACHED_FFI_TABLE");
    std.debug.assert(@"type" == .Table);
}

pub fn allocBlockPtr(L: *VM.lua.State, size: usize, alignment: std.mem.Alignment) !*CPointer {
    const allocator = Scheduler.fromState(L).allocator();

    const mem: [*]u8 = blk: {
        const bytes = allocator.rawAlloc(@max(size, 1), alignment, @returnAddress()) orelse return std.mem.Allocator.Error.OutOfMemory;
        @memset(bytes[0..@max(size, 1)], 0);
        break :blk bytes;
    };

    getCacheTable(L);
    const ptr = try L.newuserdatataggedwithmetatable(CPointer, OBJECT_TAG);

    ptr.* = .{
        .ptr = @ptrCast(@alignCast(mem)),
        .size = size,
        .alignment = alignment,
        .owner = .runtime,
        .type = .allocated,
        .data = .{},
    };

    L.pushlightuserdata(@ptrCast(@alignCast(mem)));
    L.pushvalue(-2);
    try L.rawset(-4);

    try ptr.retain(L);

    return ptr;
}

pub fn newStaticPtr(L: *VM.lua.State, static_ptr: ?*anyopaque) !*CPointer {
    getCacheTable(L);
    L.pushlightuserdata(static_ptr);
    if (L.rawget(-2) != .Nil) {
        L.remove(-2);
        return L.touserdatatagged(CPointer, -1, OBJECT_TAG) orelse @panic("expected LuaPointer");
    }
    L.pop(1);

    const ptr = try L.newuserdatataggedwithmetatable(CPointer, OBJECT_TAG);

    ptr.* = .{
        .ptr = static_ptr,
        .owner = .user,
        .type = .static,
        .data = .{},
    };

    L.pushlightuserdata(static_ptr);
    L.pushvalue(-2);
    try L.rawset(-4);

    L.remove(-2);

    return ptr;
}

pub fn retain(ptr: *CPointer, L: *VM.lua.State) !void {
    if (ptr.local_ref != null) {
        ptr.retained = true;
        return;
    }
    const local = try L.ref(-1) orelse return error.Fail;
    ptr.retained = true;
    ptr.local_ref = local;
}

pub inline fn is(L: *VM.lua.State, idx: i32) bool {
    return L.getUserdataTag(idx) == OBJECT_TAG;
}

pub inline fn value(L: *VM.lua.State, idx: i32) ?*CPointer {
    return L.touserdatatagged(CPointer, idx, OBJECT_TAG);
}

pub fn lua_retain(ptr: *CPointer, L: *VM.lua.State) !i32 {
    L.pushvalue(1);
    if (ptr.owner == .runtime)
        try ptr.retain(L);
    return 1;
}

pub fn lua_release(ptr: *CPointer, L: *VM.lua.State) !i32 {
    ptr.retained = false;
    if (ptr.owner == .runtime) {
        if (ptr.local_ref) |ref|
            L.unref(ref);
        ptr.local_ref = null;
    }
    L.pushvalue(1);
    return 1;
}

pub fn lua_tag(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (ptr.owner == .none or ptr.ptr == null) {
        L.pushnil();
        return 1;
    }
    const tag = L.tounsigned(2) orelse {
        L.pushunsigned(ptr.data.tag);
        return 1;
    };
    ptr.data.tag = tag;
    L.pushvalue(1);
    return 1;
}

pub fn lua_drop(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (ptr.owner == .none or ptr.ptr == null) {
        L.pushnil();
        return 1;
    }
    if (ptr.type == .static)
        return L.Zerror("cannot drop a static pointer");
    ptr.owner = .user;
    L.pushvalue(1);
    if (ptr.local_ref == null)
        try ptr.retain(L);
    return 1;
}

pub fn lua_offset(ptr: *CPointer, L: *VM.lua.State) !i32 {
    const pos: i32 = try L.Zcheckvalue(i32, 2, null);
    if (ptr.ptr == null) {
        if (pos < 0)
            return L.Zerror("negative offset on null pointer is not allowed");
        _ = try CPointer.newStaticPtr(L, @ptrFromInt(@as(usize, @intCast(pos))));
        return 1;
    }
    if (ptr.size) |size|
        if (size < pos)
            return L.Zerror("offset out of bounds");

    const static = try CPointer.newStaticPtr(
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

pub fn lua_read(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (ptr.owner == .none or ptr.ptr == null)
        return L.Zerror("unavailable address");

    const src_offset: usize = @truncate(try L.Zcheckvalue(u53, 2, null));
    const dest_offset: usize = @truncate(try L.Zcheckvalue(u53, 4, null));
    var dest_bounds: ?usize = null;
    const dest: [*]u8 = blk: {
        switch (L.typeOf(3)) {
            .Buffer => {
                const buf = L.tobuffer(3) orelse unreachable;
                dest_bounds = buf.len;
                break :blk @ptrCast(@alignCast(buf.ptr));
            },
            .Userdata => {
                const other = CPointer.value(L, 3) orelse return error.Fail;
                if (other.owner == .none or other.ptr == null)
                    return L.Zerror("unavailable address");
                dest_bounds = other.size;
                break :blk @ptrCast(@alignCast(other.ptr));
            },
            else => return L.Zerror("invalid type (expected buffer or userdata)"),
        }
    };
    const len: usize = @truncate(try L.Zcheckvalue(u53, 5, null));

    if (dest_bounds) |size| if (size < dest_offset + len)
        return L.Zerror("access out of bounds");

    if (ptr.size) |size| if (size < src_offset + len)
        return L.Zerror("access out of bounds");

    const src: [*]u8 = @ptrCast(@alignCast(ptr.ptr));

    @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

    L.pushvalue(3);
    return 1;
}

pub fn lua_write(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (ptr.owner == .none or ptr.ptr == null)
        return L.Zerror("unavailable address");

    const dest_offset: usize = @truncate(try L.Zcheckvalue(u53, 2, null));
    const src_offset: usize = @truncate(try L.Zcheckvalue(u53, 4, null));
    var src_bounds: ?usize = null;
    const src: [*]u8 = blk: {
        switch (L.typeOf(3)) {
            .Buffer => {
                const buf = L.tobuffer(3) orelse unreachable;
                src_bounds = buf.len;
                break :blk @ptrCast(@alignCast(buf.ptr));
            },
            .Userdata => {
                const other = CPointer.value(L, 3) orelse return error.Fail;
                if (other.owner == .none or other.ptr == null)
                    return L.Zerror("unavailable address");
                src_bounds = other.size;
                break :blk @ptrCast(@alignCast(other.ptr));
            },
            else => return L.Zerror("invalid type (expected buffer or userdata)"),
        }
    };
    const len: usize = @intCast(try L.Zcheckvalue(i32, 5, null));

    if (ptr.size) |size| if (size < dest_offset + len) {
        L.pushnumber(0);
        try L.pushlstring("access out of bounds");
        return 2;
    };

    if (src_bounds) |size| if (size < src_offset + len) {
        L.pushnumber(0);
        try L.pushlstring("access out of bounds");
        return 2;
    };

    const dest: [*]u8 = @ptrCast(@alignCast(ptr.ptr));
    const input = src[src_offset .. src_offset + len];
    @memcpy(dest[dest_offset .. dest_offset + len], input);

    L.pushnumber(@floatFromInt(input.len));
    return 1;
}

pub fn GenerateReadLuaMethod(comptime T: type) fn (ptr: *CPointer, L: *VM.lua.State) anyerror!i32 {
    if (comptime @sizeOf(T) == 0)
        @compileError("Cannot read void type");
    const len = @sizeOf(T);
    return struct {
        fn inner(ptr: *CPointer, L: *VM.lua.State) !i32 {
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
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
                .pointer => _ = try CPointer.newStaticPtr(L, @ptrFromInt(std.mem.bytesToValue(usize, mem[0..@sizeOf(usize)]))),
                else => @compileError("Unsupported type"),
            }

            return 1;
        }
    }.inner;
}

pub fn GenerateWriteLuaMethod(comptime T: type) fn (ptr: *CPointer, L: *VM.lua.State) anyerror!i32 {
    if (comptime @sizeOf(T) == 0)
        @compileError("Cannot write void type");
    const ti = @typeInfo(T);
    const len = @sizeOf(T);
    return struct {
        fn inner(ptr: *CPointer, L: *VM.lua.State) !i32 {
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
            const pos: usize = @intCast(L.Loptinteger(2, 0));

            if (ptr.size) |size| if (size < len + pos)
                return L.Zerror("access out of bounds");

            const mem: []u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[pos .. pos + len];

            switch (ti) {
                .int, .float => try Zune.standard.libraries.c.TypeConversion(T, mem, L, 3, 0),
                .pointer => switch (L.typeOf(3)) {
                    .Userdata => {
                        const lptr = CPointer.value(L, 3) orelse return error.Fail;
                        if (lptr.owner == .none)
                            return L.Zerror("unavailable address");
                        var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lptr.ptr)));
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

pub fn lua_size(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (L.typeOf(2) != .Number) {
        if (ptr.owner == .none or ptr.ptr == null) {
            L.pushnil();
            return 1;
        }
        if (ptr.size) |size|
            L.pushnumber(@floatFromInt(size))
        else
            L.pushnil();
        return 1;
    }
    const size = try L.Zcheckvalue(u53, 2, null);
    if (ptr.owner == .none or ptr.ptr == null)
        return L.Zerror("unavailable address");

    const len: usize = @truncate(size);

    switch (ptr.type) {
        .allocated => return L.Zerror("cannot set size of a known size pointer"),
        .static => {},
    }

    ptr.size = len;

    return 0;
}

pub fn lua_alignment(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (L.typeOf(2) != .Number) {
        if (ptr.owner == .none or ptr.ptr == null) {
            L.pushnil();
            return 1;
        }
        if (ptr.alignment) |alignment|
            L.pushnumber(@floatFromInt(alignment.toByteUnits()))
        else
            L.pushnil();
        return 1;
    }
    const alignment = try L.Zcheckvalue(u53, 2, null);
    if (ptr.owner == .none or ptr.ptr == null)
        return L.Zerror("unavailable address");

    const len: usize = alignment;

    switch (ptr.type) {
        .allocated => return L.Zerror("alignment already known"),
        .static => {
            if (ptr.alignment) |_|
                return L.Zerror("alignment already set");
        },
    }

    ptr.alignment = .fromByteUnits(len);

    return 0;
}

pub fn lua_span(ptr: *CPointer, L: *VM.lua.State) !i32 {
    if (ptr.owner == .none or ptr.ptr == null)
        return 0;
    const src_offset: usize = try L.Zcheckvalue(?u32, 2, null) orelse 0;

    const target: [*c]u8 = @ptrCast(@alignCast(ptr.ptr));

    const bytes = blk: {
        if (ptr.size) |size| {
            if (src_offset > size)
                return L.Zerror("offset out of bounds");
            const index = std.mem.indexOfScalar(u8, target[src_offset..size], 0);
            if (index) |i| {
                const bytes: []const u8 = target[src_offset .. src_offset + i];
                break :blk bytes;
            } else break :blk &[0]u8{};
        } else {
            const bytes: [:0]const u8 = std.mem.span(target[src_offset..]);
            ptr.size = bytes.len;
            break :blk bytes;
        }
    };

    const buf = try L.newbuffer(bytes.len + 1);
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;

    return 1;
}

pub const lua_readi8 = GenerateReadLuaMethod(i8);
pub const lua_readu8 = GenerateReadLuaMethod(u8);
pub const lua_readi16 = GenerateReadLuaMethod(i16);
pub const lua_readu16 = GenerateReadLuaMethod(u16);
pub const lua_readi32 = GenerateReadLuaMethod(i32);
pub const lua_readu32 = GenerateReadLuaMethod(u32);
pub const lua_readi64 = GenerateReadLuaMethod(i64);
pub const lua_readu64 = GenerateReadLuaMethod(u64);
pub const lua_readf32 = GenerateReadLuaMethod(f32);
pub const lua_readf64 = GenerateReadLuaMethod(f64);
pub const lua_readptr = GenerateReadLuaMethod(*anyopaque);

pub const lua_writei8 = GenerateWriteLuaMethod(i8);
pub const lua_writeu8 = GenerateWriteLuaMethod(u8);
pub const lua_writei16 = GenerateWriteLuaMethod(i16);
pub const lua_writeu16 = GenerateWriteLuaMethod(u16);
pub const lua_writei32 = GenerateWriteLuaMethod(i32);
pub const lua_writeu32 = GenerateWriteLuaMethod(u32);
pub const lua_writei64 = GenerateWriteLuaMethod(i64);
pub const lua_writeu64 = GenerateWriteLuaMethod(u64);
pub const lua_writef32 = GenerateWriteLuaMethod(f32);
pub const lua_writef64 = GenerateWriteLuaMethod(f64);
pub const lua_writeptr = GenerateWriteLuaMethod(*anyopaque);

pub fn __tostring(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Userdata);
    const ptr = value(L, 1) orelse return error.Failed;

    var buf: [48]u8 = undefined;

    const str = try std.fmt.bufPrint(&buf, "<pointer: 0x{x}>", .{@as(usize, @intFromPtr(ptr.ptr))});

    try L.pushlstring(str);

    return 1;
}

pub fn __dtor(L: *VM.lua.State, ptr: *CPointer) void {
    if (ptr.owner != .runtime)
        return;
    switch (ptr.type) {
        .allocated => {
            const size = @max(ptr.size orelse 8, 1);
            const allocator = Scheduler.fromState(L).allocator();
            ptr.owner = .none;
            allocator.rawFree(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size],
                ptr.alignment orelse .@"1",
                @returnAddress(),
            );
        },
        .static => {},
    }
}

pub fn __setup(L: *VM.lua.State) !void {
    try initCacheTable(L);
}
