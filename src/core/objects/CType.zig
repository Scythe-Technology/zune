const std = @import("std");
const zio = @import("zio");
const luau = @import("luau");
const wire = @import("wire");
const builtin = @import("builtin");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const CPointer = Zune.objects.CPointer;

const VM = luau.VM;

const CType = @This();

pub const OBJECT_TAG = Zune.Tags.get("C_TYPE").?;
pub const PlatformSupported = Zune.standard.libraries.c.PlatformSupported;

pub const TypedData = struct {
    type: wire.Type,
    kind: Kind,

    pub const Kind = union(enum) {
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
        pointer: CPointer.Info,
        @"struct": void,
        vector2_32: void,
        vector3_32: void,

        pub fn asType(self: Kind) type {
            return switch (self) {
                .void => void,
                .i8 => i8,
                .i16 => i16,
                .i32 => i32,
                .i64 => i64,
                .u8 => u8,
                .u16 => u16,
                .u32 => u32,
                .u64 => u64,
                .f32 => f32,
                .f64 => f64,
                .pointer => *anyopaque,
                .@"struct" => [*]u8,
                .vector2_32, .vector3_32 => [*]f32,
            };
        }
    };
};

type: TypedData,
info: Info = .none,

const Info = union(enum) {
    none: void,
    array: struct { TypedData, u32 },
    @"struct": std.array_hash_map.String(TypedData),
};

pub fn lua_newTag(self: *CType, L: *VM.lua.State) !i32 {
    if (self.type.kind != .pointer)
        return L.Zerror("'tag' is only available for pointers");
    if (self.type.kind.pointer.tag != 0)
        return L.Zerror("cannot create tagged pointer from tagged pointer");

    const allocator = Zune.DEFAULT_ALLOCATOR;

    const unique = try L.Zcheckvalue([]const u8, 2, null);
    const dupe = try allocator.dupe(u8, unique);

    const result = try Zune.standard.libraries.c.TAGGED_POINTERS.getOrPut(Zune.DEFAULT_ALLOCATOR, dupe);
    if (result.found_existing) {
        allocator.free(dupe);
    }
    result.value_ptr.* = true;

    if (result.index + 1 > std.math.maxInt(u32))
        return error.MaximumTagExceeded;

    const datatype = try L.newuserdatataggedwithmetatable(CType, OBJECT_TAG);

    datatype.* = .{
        .type = .{
            .type = .pointer,
            .kind = .{ .pointer = .{ .tag = @intCast(result.index + 1) } },
        },
    };

    return 1;
}

pub fn lua_offset(self: *CType, L: *VM.lua.State) !i32 {
    switch (self.type.kind) {
        .@"struct" => {
            switch (self.info) {
                .array => |a| {
                    const order = try L.Zcheckvalue(u32, 2, null);
                    if (order >= a.@"1")
                        return L.Zerror("index out of bounds");
                    L.pushnumber(@floatFromInt(order * a.@"0".type.size));
                },
                .@"struct" => |map| {
                    const field = try L.Zcheckvalue([]const u8, 2, null);
                    const order = map.getIndex(field) orelse return L.Zerrorf("unknown field: {s}", .{field});
                    L.pushunsigned(@truncate(self.type.type.offsets.?[order]));
                },
                else => return error.InvalidState,
            }
        },
        .vector2_32 => {
            const index = try L.Zcheckvalue(u32, 2, null);
            if (index >= 2)
                return L.Zerror("index out of bounds");
            L.pushunsigned(@truncate(index * @sizeOf(f32)));
        },
        .vector3_32 => {
            const index = try L.Zcheckvalue(u32, 2, null);
            if (index >= 3)
                return L.Zerror("index out of bounds");
            L.pushunsigned(@truncate(index * @sizeOf(f32)));
        },
        else => return L.Zerror("'offset' is only available for structs or vectors"),
    }

    return 1;
}

pub fn lua_new(self: *CType, L: *VM.lua.State) !i32 {
    if (self.type.kind != .@"struct")
        return L.Zerror("'new' is only available for structs");
    try L.Zchecktype(2, .Table);

    switch (self.info) {
        .none => return error.InvalidState,
        .array => |array| {
            const datatype, const count = array;

            try L.rawcheckstack(2);

            const mem = try L.newbuffer(self.type.type.size);

            for (0..count) |i| {
                if (i > 0)
                    L.pop(1);
                if (L.rawgeti(2, @as(i32, @intCast(i + 1))).isnoneornil())
                    continue;
                const pos = i * datatype.type.size;
                switch (datatype.kind) {
                    .void => return error.InvalidArgType,
                    .pointer => switch (L.typeOf(-1)) {
                        .Userdata => {
                            const lptr = CPointer.value(L, -1) orelse return error.Failed;
                            if (lptr.owner == .none)
                                return L.Zerror("unavailable address");
                            if (lptr.data.tag != datatype.kind.pointer.tag)
                                return L.Zerrorf("tag mismatch at index {d}", .{i + 1});
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lptr.ptr)));
                            @memcpy(mem[pos .. pos + @sizeOf(usize)], &bytes);
                        },
                        else => return error.InvalidArgType,
                    },
                    .@"struct" => {
                        if (L.typeOf(-1) != .Buffer)
                            return L.Zerrorf("invalid type at index {d} (expected buffer, got {s})", .{ i + 1, VM.lapi.typename(L.typeOf(-1)) });
                        const value = L.tobuffer(-1) orelse unreachable;
                        if (value.len != datatype.type.size)
                            return L.Zerrorf("size mismatch at index {d} (expected {d} bytes, got {d} bytes)", .{ i + 1, datatype.type.size, value.len });
                        @memcpy(mem[pos .. pos + datatype.type.size], value);
                    },
                    .vector2_32 => switch (L.typeOf(-1)) {
                        .Vector => {
                            const vec = L.tovector(-1) orelse unreachable;
                            @memcpy(@as([]f32, @ptrCast(@alignCast(mem[pos .. pos + (2 * @sizeOf(f32))]))), vec[0..2]);
                        },
                        .Buffer => {
                            const value = L.tobuffer(-1) orelse unreachable;
                            if (value.len != (2 * @sizeOf(f32)))
                                return L.Zerrorf("size mismatch at index {d} (expected {d} bytes, got {d} bytes)", .{ i + 1, datatype.type.size, value.len });
                            @memcpy(mem[pos .. pos + (2 * @sizeOf(f32))], value);
                        },
                        else => return L.Zerrorf("invalid type at index {d} (expected vector/buffer, got {s})", .{ i + 1, VM.lapi.typename(L.typeOf(-1)) }),
                    },
                    .vector3_32 => switch (L.typeOf(-1)) {
                        .Vector => {
                            const vec = L.tovector(-1) orelse unreachable;
                            @memcpy(@as([]f32, @ptrCast(@alignCast(mem[pos .. pos + (3 * @sizeOf(f32))]))), vec[0..3]);
                        },
                        .Buffer => {
                            const value = L.tobuffer(-1) orelse unreachable;
                            if (value.len != (3 * @sizeOf(f32)))
                                return L.Zerrorf("size mismatch at index {d} (expected {d} bytes, got {d} bytes)", .{ i + 1, datatype.type.size, value.len });
                            @memcpy(mem[pos .. pos + (3 * @sizeOf(f32))], value);
                        },
                        else => return L.Zerrorf("invalid type at index {d} (expected vector/buffer, got {s})", .{ i + 1, VM.lapi.typename(L.typeOf(-1)) }),
                    },
                    inline else => |_, tag| try Zune.standard.libraries.c.TypeConversion(@as(TypedData.Kind, tag).asType(), mem, L, -1, pos),
                }
            }
            L.pop(1);
        },
        .@"struct" => |map| {
            const offsets = self.type.type.offsets.?;

            try L.rawcheckstack(2);

            const mem = try L.newbuffer(self.type.type.size);

            for (map.keys(), map.values(), 0..) |field_name, field_value, order| {
                if (order > 0)
                    L.pop(1);
                try L.pushlstring(field_name);
                if (L.rawget(2).isnoneornil())
                    continue;
                const pos = offsets[order];
                switch (field_value.kind) {
                    .void => return error.InvalidArgType,
                    .pointer => switch (L.typeOf(-1)) {
                        .Userdata => {
                            const lptr = CPointer.value(L, -1) orelse return error.Failed;
                            if (lptr.owner == .none)
                                return L.Zerror("unavailable address");
                            if (lptr.data.tag != field_value.kind.pointer.tag)
                                return L.Zerrorf("tag mismatch for field: {s}", .{field_name});
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lptr.ptr)));
                            @memcpy(mem[pos .. pos + @sizeOf(usize)], &bytes);
                        },
                        else => return error.InvalidArgType,
                    },
                    .@"struct" => {
                        if (L.typeOf(-1) != .Buffer)
                            return L.Zerrorf("invalid type for field '{s}' (expected buffer, got {s})", .{ field_name, VM.lapi.typename(L.typeOf(-1)) });
                        const value = L.tobuffer(-1) orelse unreachable;
                        if (value.len != field_value.type.size)
                            return L.Zerrorf("size mismatch for field '{s}' (expected {d} bytes, got {d} bytes)", .{ field_name, field_value.type.size, value.len });
                        @memcpy(mem[pos .. pos + field_value.type.size], value);
                    },
                    .vector2_32 => switch (L.typeOf(-1)) {
                        .Vector => {
                            const vec = L.tovector(-1) orelse unreachable;
                            @memcpy(@as([]f32, @ptrCast(@alignCast(mem[pos .. pos + (2 * @sizeOf(f32))]))), vec[0..2]);
                        },
                        .Buffer => {
                            const value = L.tobuffer(-1) orelse unreachable;
                            if (value.len != (2 * @sizeOf(f32)))
                                return L.Zerrorf("size mismatch for field '{s}' (expected {d} bytes, got {d} bytes)", .{ field_name, field_value.type.size, value.len });
                            @memcpy(mem[pos .. pos + (2 * @sizeOf(f32))], value);
                        },
                        else => return L.Zerrorf("invalid type for field '{s}' (expected vector/buffer, got {s})", .{ field_name, VM.lapi.typename(L.typeOf(-1)) }),
                    },
                    .vector3_32 => switch (L.typeOf(-1)) {
                        .Vector => {
                            const vec = L.tovector(-1) orelse unreachable;
                            @memcpy(@as([]f32, @ptrCast(@alignCast(mem[pos .. pos + (3 * @sizeOf(f32))]))), vec[0..3]);
                        },
                        .Buffer => {
                            const value = L.tobuffer(-1) orelse unreachable;
                            if (value.len != (3 * @sizeOf(f32)))
                                return L.Zerrorf("size mismatch for field '{s}' (expected {d} bytes, got {d} bytes)", .{ field_name, field_value.type.size, value.len });
                            @memcpy(mem[pos .. pos + (3 * @sizeOf(f32))], value);
                        },
                        else => return L.Zerrorf("invalid type for field '{s}' (expected vector/buffer, got {s})", .{ field_name, VM.lapi.typename(L.typeOf(-1)) }),
                    },
                    inline else => |_, tag| try Zune.standard.libraries.c.TypeConversion(@as(TypedData.Kind, tag).asType(), mem, L, -1, pos),
                }
            }
            L.pop(1);
        },
    }
    return 1;
}

pub fn lua_size(self: *CType, L: *VM.lua.State) !i32 {
    L.pushunsigned(@truncate(self.type.type.size));
    return 1;
}

pub fn lua_alignment(self: *CType, L: *VM.lua.State) !i32 {
    L.pushnumber(@floatFromInt(self.type.type.alignment.toByteUnits()));
    return 1;
}

pub fn lua_tag(self: *CType, L: *VM.lua.State) !i32 {
    if (self.type.kind != .pointer)
        return 0;
    L.pushunsigned(self.type.kind.pointer.tag);
    return 1;
}

pub fn lua_array(self: *CType, L: *VM.lua.State) !i32 {
    const count = try L.Zcheckvalue(u32, 2, null);
    if (count <= 0)
        return L.Zerror("array count must be greater than zero");
    if (count > std.math.maxInt(i32))
        return L.Zerror("array count too large");
    const datatype = try L.newuserdatataggedwithmetatable(CType, OBJECT_TAG);
    datatype.* = .{
        .info = .{ .array = .{ self.type, count } },
        .type = .{
            .type = self.type.type.array(count),
            .kind = .@"struct",
        },
    };
    return 1;
}

pub fn __dtor(L: *VM.lua.State, self: *CType) void {
    switch (self.info) {
        .@"struct" => |*map| {
            const allocator = Scheduler.fromState(L).allocator();
            var iter = map.iterator();
            while (iter.next()) |entry|
                allocator.free(entry.key_ptr.*);
            map.deinit(allocator);
            self.type.type.free(allocator);
        },
        else => {},
    }
}
