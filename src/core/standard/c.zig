const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");
const wire = @import("wire");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const CType = Zune.objects.CType;
const CPointer = Zune.objects.CPointer;
const DynamicLibrary = Zune.objects.DynamicLibrary;

const VM = luau.VM;

pub const LIB_NAME = "c";
pub fn PlatformSupported() ?Zune.PlatformSupportKind {
    return switch (comptime builtin.cpu.arch) {
        inline .x86_64, .aarch64, .riscv64 => |arch| switch (comptime builtin.os.tag) {
            .macos => return .Full,
            .linux => if (!arch.isAARCH64()) switch (comptime builtin.abi) {
                .gnu => return .Full,
                .musl => return .Limited,
                else => return null,
            } else return null,
            .windows => if (!arch.isAARCH64()) return .Full else return null,
            .freebsd => return .Full,
            else => return null,
        },
        else => return null,
    };
}

const Hash = std.crypto.hash.sha3.Sha3_256;

pub threadlocal var TAGGED_POINTERS: std.array_hash_map.String(bool) = undefined;
pub threadlocal var CACHED_WIRE_COMPILATON: std.hash_map.StringHashMapUnmanaged(*CallableFunction) = undefined;

pub threadlocal var CALLING_STATE: ?*VM.lua.State = null;

pub threadlocal var JIT_POOL: wire.mem.Pool = undefined;

pub const Types = struct {
    pub const @"void": CType.TypedData = .{ .type = .void, .kind = .void };

    pub const int8: CType.TypedData = .{ .type = .int8, .kind = .i8 };
    pub const int16: CType.TypedData = .{ .type = .int16, .kind = .i16 };
    pub const int32: CType.TypedData = .{ .type = .int32, .kind = .i32 };
    pub const int64: CType.TypedData = .{ .type = .int64, .kind = .i64 };

    pub const uint8: CType.TypedData = .{ .type = .uint8, .kind = .u8 };
    pub const uint16: CType.TypedData = .{ .type = .uint16, .kind = .u16 };
    pub const uint32: CType.TypedData = .{ .type = .uint32, .kind = .u32 };
    pub const uint64: CType.TypedData = .{ .type = .uint64, .kind = .u64 };

    pub const float: CType.TypedData = .{ .type = .float32, .kind = .f32 };
    pub const double: CType.TypedData = .{ .type = .float64, .kind = .f64 };
    pub const pointer: CType.TypedData = .{ .type = .pointer, .kind = .{ .pointer = .{} } };

    pub const vector2_32: CType.TypedData = .{ .type = .{ .size = 8, .alignment = .@"4", .class = .sse }, .kind = .vector2_32 };
    pub const vector3_32: CType.TypedData = .{ .type = .{ .size = 12, .alignment = .@"4", .class = .sse }, .kind = .vector3_32 };
};

const FunctionSymbol = struct {
    returns: CType.TypedData,
    args: []CType.TypedData,
};

const CompiledSymbol = struct {
    type: FunctionSymbol,
    buffer: wire.mem.Buffer,

    pub fn free(self: CompiledSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.type.args);
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
            _ = CACHED_WIRE_COMPILATON.fetchRemove(hash);
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
        return @ptrCast(@alignCast(self.sym.buffer.ptr));
    }
};

fn hashFunctionSignature(out: *[Hash.digest_length]u8, returns: CType.TypedData, args: []const CType.TypedData) void {
    const size_len = @sizeOf(usize) + 6;
    var buffer: [size_len]u8 = undefined;

    var hash = Hash.init(.{});

    std.mem.writeInt(u8, buffer[0..1], @backingInt(returns.kind), .little);
    std.mem.writeInt(u8, buffer[1..2], @backingInt(returns.type.class), .little);
    std.mem.writeInt(u32, buffer[2..6], @backingInt(returns.type.alignment), .little);
    std.mem.writeInt(usize, buffer[6..size_len], returns.type.size, .little);
    hash.update(buffer[0..size_len]);
    if (returns.kind == .pointer and returns.kind.pointer.tag != 0) {
        std.mem.writeInt(u32, buffer[0..4], returns.kind.pointer.tag, .little);
        hash.update(buffer[0..4]);
    }

    for (args) |arg| {
        std.mem.writeInt(u8, buffer[0..1], @backingInt(arg.kind), .little);
        std.mem.writeInt(u8, buffer[1..2], @backingInt(arg.type.class), .little);
        std.mem.writeInt(u32, buffer[2..6], @backingInt(arg.type.alignment), .little);
        std.mem.writeInt(usize, buffer[6..size_len], arg.type.size, .little);
        hash.update(buffer[0..size_len]);
        if (arg.kind == .pointer and arg.kind.pointer.tag != 0) {
            std.mem.writeInt(u32, buffer[0..4], arg.kind.pointer.tag, .little);
            hash.update(buffer[0..4]);
        }
    }
    hash.final(out);
}

fn compileCallableFunction(returns: CType.TypedData, args: []const CType.TypedData) !CallableFunction {
    const allocator = Zune.DEFAULT_ALLOCATOR;

    var code = try wire.Code.init(allocator, &.{ .pointer, .pointer }, .void);
    defer code.deinit();

    const l = code.param(0);
    const fn_ptr = code.param(1);

    var call_args: []wire.Code.Value = try allocator.alloc(wire.Code.Value, args.len);
    defer allocator.free(call_args);

    var pointer_count: usize = 0;
    for (args) |arg| switch (arg.kind) {
        .void => return error.VoidParameter,
        .pointer, .@"struct" => pointer_count += 1,
        else => {},
    };

    const pointers: ?[]*allowzero anyopaque = if (pointer_count != 0)
        try allocator.alloc(*allowzero anyopaque, pointer_count)
    else
        null;
    errdefer if (pointers) |p| allocator.free(p);

    const pointers_arr: ?wire.Code.Value = if (pointers) |p| .symbol(@ptrCast(p.ptr)) else null;

    pointer_count = 0;
    for (args, 0..) |arg, idx| {
        switch (arg.kind) {
            .void => return error.VoidParameter,
            .pointer => {
                defer pointer_count += 1;
                call_args[idx] = try code.index(pointers_arr.?, pointer_count, .pointer);
            },
            .@"struct" => {
                defer pointer_count += 1;
                const p = try code.index(pointers_arr.?, pointer_count, .pointer);
                call_args[idx] = try code.load(p, 0, arg.type);
            },
            inline else => |_, T| {
                const impl_name = "check" ++ @tagName(T);
                const checkfn = @field(c_interface, impl_name);
                const a = (try code.call(.imm(@ptrCast(&checkfn)), &.{ l, .imm(.int32, @bitCast(idx + 1)) }, arg.type)).?;
                call_args[idx] = a;
            },
        }
    }

    const ret = try code.call(.value(fn_ptr), call_args, returns.type);

    switch (returns.kind) {
        .void => {},
        .@"struct" => {
            const ret_ptr = try code.addrOf(ret.?);
            _ = try code.call(.imm(@ptrCast(&c_interface.pushmem)), &.{ l, ret_ptr, .imm(.int64, returns.type.size) }, .void);
        },
        .vector2_32 => {
            const ret_ptr = try code.addrOf(ret.?);
            _ = try code.call(.imm(@ptrCast(&c_interface.pushvector2)), &.{ l, ret_ptr }, .void);
        },
        .vector3_32 => {
            const ret_ptr = try code.addrOf(ret.?);
            _ = try code.call(.imm(@ptrCast(&c_interface.pushvector3)), &.{ l, ret_ptr }, .void);
        },
        inline else => |_, T| {
            const pushfn = @field(c_interface, "push" ++ @tagName(T));
            _ = try code.call(.imm(@ptrCast(&pushfn)), &.{ l, ret.? }, .void);
        },
    }
    const args_copy = try allocator.dupe(CType.TypedData, args);
    errdefer allocator.free(args_copy);

    const machine_bytes = try code.compileAlloc(allocator, null);
    defer allocator.free(machine_bytes);

    const buf = try JIT_POOL.executable(machine_bytes, false);

    return .{
        .sym = .{
            .buffer = buf,
            .type = .{
                .returns = returns,
                .args = args_copy,
            },
        },
        .pointers = pointers,
        .references = 0,
        .hash = null,
    };
}

fn fetchCallableFunction(returns: CType.TypedData, args: []const CType.TypedData) !*CallableFunction {
    const allocator = Zune.DEFAULT_ALLOCATOR;
    var hash: [Hash.digest_length]u8 = undefined;
    hashFunctionSignature(&hash, returns, args);

    if (CACHED_WIRE_COMPILATON.getEntry(&hash)) |entry| {
        entry.value_ptr.*.ref();
        return entry.value_ptr.*;
    }

    var code = try compileCallableFunction(returns, args);
    errdefer code.deinit();

    const code_ptr = try allocator.create(CallableFunction);
    errdefer allocator.destroy(code_ptr);

    const hash_key = try allocator.dupe(u8, &hash);
    errdefer allocator.free(hash_key);

    code.hash = hash_key;
    code_ptr.* = code;

    try CACHED_WIRE_COMPILATON.put(allocator, hash_key, code_ptr);

    code_ptr.ref();

    return code_ptr;
}

const LuaClosure = struct {
    callinfo: *CallInfo,
    sym: CompiledSymbol,

    pub const CallInfo = struct {
        ref: Scripting.Reference,
        args: c_uint,
        type: FunctionSymbol,
        thread: *VM.lua.State,
    };

    pub fn __dtor(L: *VM.lua.State, self: *LuaClosure) void {
        const allocator = Scheduler.fromState(L).allocator();

        allocator.destroy(self.callinfo);
        self.sym.free(allocator);
    }
};

fn toCType(L: *VM.lua.State, idx: i32) ?CType.TypedData {
    switch (L.typeOf(idx)) {
        .Userdata => return (L.touserdatatagged(CType, idx, CType.OBJECT_TAG) orelse return null).*.type,
        else => return null,
    }
}

pub fn TypeConversion(
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

const c_interface = struct {
    fn ArgumentLoad(comptime T: type) fn (L: *VM.lua.State, index: i32) callconv(.c) T {
        const ti = @typeInfo(T);
        if (ti != .int and ti != .float)
            @compileError("Unsupported type");
        const size = @sizeOf(T);
        return struct {
            fn inner(L: *VM.lua.State, index: i32) callconv(.c) T {
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
                    .Proto, .UpVal, .Deadkey, .All => unreachable,
                    inline else => |e| L.LerrorL("invalid argument type (got {s})", .{comptime VM.lapi.typename(e)}) catch |err| std.debug.panic("{}", .{err}),
                }
            }
        }.inner;
    }

    fn ArgumentPush(comptime T: type) fn (L: *VM.lua.State, value: T) callconv(.c) void {
        const ti = @typeInfo(T);
        if (ti != .int and ti != .float)
            @compileError("Unsupported type");
        const isFloat = ti == .float;
        const size = @sizeOf(T);
        return struct {
            fn inner(L: *VM.lua.State, value: T) callconv(.c) void {
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

    pub const checki8 = ArgumentLoad(i8);
    pub const checku8 = ArgumentLoad(u8);
    pub const checki16 = ArgumentLoad(i16);
    pub const checku16 = ArgumentLoad(u16);
    pub const checki32 = ArgumentLoad(i32);
    pub const checku32 = ArgumentLoad(u32);
    pub const checki64 = ArgumentLoad(i64);
    pub const checku64 = ArgumentLoad(u64);
    pub const checkf32 = ArgumentLoad(f32);
    pub const checkf64 = ArgumentLoad(f64);

    const Vec2_32 = extern struct { x: f32, y: f32 };
    pub fn checkvector2_32(L: *VM.lua.State, index: i32) callconv(.c) Vec2_32 {
        const size = @sizeOf(f32) * 2;
        switch (L.typeOf(index)) {
            .Buffer => {
                const lua_buf = L.tobuffer(index).?;
                if (lua_buf.len < size)
                    return L.LerrorL("buffer too small", .{}) catch |e| std.debug.panic("{}", .{e});
                return std.mem.bytesToValue(Vec2_32, lua_buf[0..size]);
            },
            .Vector => {
                const vec = L.tovector(index).?;
                return .{ .x = vec[0], .y = vec[1] };
            },
            .Proto, .UpVal, .Deadkey, .All => unreachable,
            inline else => |e| L.LerrorL("invalid argument type (got {s})", .{comptime VM.lapi.typename(e)}) catch |err| std.debug.panic("{}", .{err}),
        }
    }

    const Vec3_32 = extern struct { x: f32, y: f32, z: f32 };
    pub fn checkvector3_32(L: *VM.lua.State, index: i32) callconv(.c) Vec3_32 {
        const size = @sizeOf(f32) * 3;
        switch (L.typeOf(index)) {
            .Buffer => {
                const lua_buf = L.tobuffer(index).?;
                if (lua_buf.len < size)
                    return L.LerrorL("buffer too small", .{}) catch |e| std.debug.panic("{}", .{e});
                return std.mem.bytesToValue(Vec3_32, lua_buf[0..size]);
            },
            .Vector => {
                const vec = L.tovector(index).?;
                return .{ .x = vec[0], .y = vec[1], .z = vec[2] };
            },
            .Proto, .UpVal, .Deadkey, .All => unreachable,
            inline else => |e| L.LerrorL("invalid argument type (got {s})", .{comptime VM.lapi.typename(e)}) catch |err| std.debug.panic("{}", .{err}),
        }
    }

    pub const pushi8 = ArgumentPush(i8);
    pub const pushu8 = ArgumentPush(u8);
    pub const pushi16 = ArgumentPush(i16);
    pub const pushu16 = ArgumentPush(u16);
    pub const pushi32 = ArgumentPush(i32);
    pub const pushu32 = ArgumentPush(u32);
    pub const pushi64 = ArgumentPush(i64);
    pub const pushu64 = ArgumentPush(u64);
    pub const pushf32 = ArgumentPush(f32);
    pub const pushf64 = ArgumentPush(f64);

    pub fn pushpointer(L: *VM.lua.State, ptr: ?*anyopaque) callconv(.c) void {
        _ = CPointer.newStaticPtr(L, ptr) catch (L.LerrorL("failed to create pointer", .{}) catch |e| std.debug.panic("{}", .{e}));
    }

    pub fn pushmem(L: *VM.lua.State, ptr: [*c]u8, size: usize) callconv(.c) void {
        L.Zpushbuffer(ptr[0..size]) catch |e| std.debug.panic("{}", .{e});
    }

    pub fn pushvector2(L: *VM.lua.State, ptr: [*c]f32) callconv(.c) void {
        L.pushvector(ptr[0], ptr[1], 0);
    }
    pub fn pushvector3(L: *VM.lua.State, ptr: [*c]f32) callconv(.c) void {
        L.pushvector(ptr[0], ptr[1], ptr[2]);
    }
};

fn getFunctionSymbol(allocator: std.mem.Allocator, L: *VM.lua.State, idx: i32) !FunctionSymbol {
    const return_type = toCType(L, idx) orelse
        return L.Zerror("function return type must be a valid c type");
    const returns = return_type;

    try L.Zchecktype(idx + 1, .Table);

    const args_len = L.objlen(idx + 1);

    const args = try allocator.alloc(CType.TypedData, @intCast(args_len));
    errdefer allocator.free(args);

    var order: usize = 0;
    var arr_iter: Scripting.ArrayIterator = .{ .L = L, .idx = idx + 1 };
    while (try arr_iter.next()) |t| switch (t) {
        .Userdata => {
            const ctype = toCType(L, -1) orelse
                return L.Zerrorf("function arg type must be a valid c type (got {s})", .{VM.lapi.typename(L.typeOf(-1))});

            args[order] = ctype;
            order += 1;
        },
        else => return L.Zerrorf("function arg must be a userdata (got {s})", .{VM.lapi.typename(t)}),
    };
    return .{
        .returns = returns,
        .args = args,
    };
}

pub fn lua_struct(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);

    const alignment: ?std.mem.Alignment = if (try L.Zcheckvalue(?u32, 2, null)) |a| .fromByteUnits(a) else null;

    const allocator = Scheduler.fromState(L).allocator();

    var struct_map: std.array_hash_map.String(CType.TypedData) = .empty;
    errdefer struct_map.deinit(allocator);
    errdefer {
        var iter = struct_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
    }

    var order: i32 = 1;
    var iter: Scripting.ArrayIterator = .{ .L = L, .idx = 1 };
    while (try iter.next()) |t| switch (t) {
        .Table => {
            if (L.rawiter(-1, 0) < 0)
                return L.Zerror("struct field contains no field type");

            if (L.typeOf(-2) != .String)
                return L.Zerrorf("struct field name must be a string (got {s})", .{VM.lapi.typename(L.typeOf(-2))});
            const name = L.tostring(-2) orelse unreachable;

            const @"type" = toCType(L, -1) orelse
                return L.Zerror("struct field type must be a valid c type");

            if (struct_map.contains(name))
                return L.Zerrorf("struct field '{s}' already exists", .{name});

            {
                const name_copy = try allocator.dupe(u8, name); // Zig owned string to prevent GC from Lua owned strings
                errdefer allocator.free(name_copy);
                try struct_map.put(allocator, name_copy, @"type");
            }

            L.pop(2);

            if (L.rawiter(-1, 1) >= 0)
                return L.Zerror("struct field contains more than one field type");

            order += 1;
        },
        else => return L.Zerrorf("struct field must be a table (got {s})", .{VM.lapi.typename(t)}),
    };

    const data = try L.newuserdatataggedwithmetatable(CType, CType.OBJECT_TAG);

    const types = try allocator.alloc(wire.Type, struct_map.values().len);
    defer allocator.free(types);
    for (struct_map.values(), 0..) |entry, i|
        types[i] = entry.type;

    const wr: wire.Type = try .@"struct"(allocator, types, alignment);

    data.* = .{
        .type = .{
            .type = wr,
            .kind = .@"struct",
        },
        .info = .{
            .@"struct" = struct_map,
        },
    };

    return 1;
}

pub fn lua_dlopen(L: *VM.lua.State) !i32 {
    const path = try L.Zcheckvalue([:0]const u8, 1, null);

    _ = try DynamicLibrary.openLibrary(L, path);

    return 1;
}

fn ReturnTypeConversion(
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

fn PushPtrType(
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

fn closureInner(call_info: *const LuaClosure.CallInfo, extern_args: ?[]const *anyopaque, ret: ?*anyopaque) !void {
    const scheduler = Scheduler.fromState(call_info.thread);

    const main_thread = std.Thread.getCurrentId() == scheduler.thread_id;

    if (!main_thread)
        std.debug.panic("cannot call c closure from non-main thread", .{});

    const args: []const *anyopaque = if (call_info.args > 0) extern_args.?[0..call_info.args] else &.{};

    if (!try call_info.thread.checkstack(1))
        return std.debug.panic("failed to grow stack for c closure", .{});

    const L = try call_info.thread.newthread();
    defer call_info.thread.pop(1);

    const has_return = call_info.type.returns.type.size > 0;

    try L.rawcheckstack(call_info.type.args.len + 1 + @as(usize, if (has_return) 1 else 0));

    call_info.ref.push(L);

    for (call_info.type.args, 0..) |arg_type, i| {
        switch (arg_type.kind) {
            .void => unreachable,
            .pointer => {
                const ptr = try CPointer.newStaticPtr(L, @as(*[*]u8, @ptrCast(@alignCast(args[i]))).*);
                ptr.data = arg_type.kind.pointer;
            },
            .@"struct" => {
                const bytes: [*]u8 = @ptrCast(@alignCast(args[i]));
                try L.Zpushbuffer(bytes[0..arg_type.type.size]);
            },
            .vector2_32 => {
                const vec = @as([*]f32, @ptrCast(@alignCast(args[i])));
                L.pushvector(vec[0], vec[1], 0);
            },
            .vector3_32 => {
                const vec = @as([*]f32, @ptrCast(@alignCast(args[i])));
                L.pushvector(vec[0], vec[1], vec[2]);
            },
            inline else => |_, tag| PushPtrType(@as(CType.TypedData.Kind, tag).asType(), L, args[i]),
        }
    }

    {
        const last_running_state = Scheduler.RUNNING_STATE;
        Scheduler.RUNNING_STATE = L;
        defer Scheduler.RUNNING_STATE = last_running_state;
        _ = L.pcall(@intCast(args.len), if (has_return) 1 else 0, 0).check() catch |err|
            return Engine.handleError(L, err);
    }

    if (has_return) {
        defer L.pop(1);
        switch (call_info.type.returns.kind) {
            .void => unreachable,
            .pointer => switch (L.typeOf(-1)) {
                .Userdata => {
                    const ptr = CPointer.value(L, -1) orelse try L.LerrorL("invalid pointer", .{});
                    if (ptr.owner == .none or ptr.ptr == null)
                        try L.LerrorL("unavailable address", .{});
                    if (ptr.data.tag != call_info.type.returns.kind.pointer.tag)
                        try L.LerrorL("tag mismatch", .{});
                    @as(*[*]u8, @ptrCast(@alignCast(ret))).* = @ptrCast(ptr.ptr);
                },
                .String, .Buffer => try L.LerrorL("unsupported return type (allocate instead)", .{}),
                .Nil => {
                    @as(*?*anyopaque, @ptrCast(@alignCast(ret))).* = null;
                },
                else => try L.LerrorL("invalid return type (expected pointer)", .{}),
            },
            .@"struct" => {
                if (L.typeOf(-1) != .Buffer)
                    try L.LerrorL("invalid return type (expected buffer for struct)", .{});
                const buf = L.tobuffer(-1) orelse unreachable;
                if (buf.len != call_info.type.returns.type.size)
                    try L.LerrorL("invalid return type (expected buffer of size {d} for struct)", .{call_info.type.returns.type.size});
                @memcpy(@as([*]u8, @ptrCast(@alignCast(ret))), buf);
            },
            .vector2_32 => switch (L.typeOf(-1)) {
                .Vector => {
                    const vec = L.tovector(-1) orelse unreachable;
                    @memcpy(@as([*]f32, @ptrCast(@alignCast(ret))), vec[0..2]);
                },
                .Buffer => {
                    const buf = L.tobuffer(-1) orelse unreachable;
                    if (buf.len < @sizeOf(f32) * 2)
                        try L.LerrorL("invalid return type (expected buffer of size {d} for vector2_32)", .{@sizeOf(f32) * 2});
                    @memcpy(@as([*]u8, @ptrCast(@alignCast(ret))), buf[0 .. @sizeOf(f32) * 2]);
                },
                else => try L.LerrorL("invalid return type (expected vector/buffer for vector2_32)", .{}),
            },
            .vector3_32 => switch (L.typeOf(-1)) {
                .Vector => {
                    const vec = L.tovector(-1) orelse unreachable;
                    @memcpy(@as([*]f32, @ptrCast(@alignCast(ret))), vec[0..3]);
                },
                .Buffer => {
                    const buf = L.tobuffer(-1) orelse unreachable;
                    if (buf.len < @sizeOf(f32) * 3)
                        try L.LerrorL("invalid return type (expected buffer of size {d} for vector3_32)", .{@sizeOf(f32) * 3});
                    @memcpy(@as([*]u8, @ptrCast(@alignCast(ret))), buf[0 .. @sizeOf(f32) * 3]);
                },
                else => try L.LerrorL("invalid return type (expected vector/buffer for vector3_32)", .{}),
            },
            inline else => |_, tag| ReturnTypeConversion(@as(CType.TypedData.Kind, tag).asType(), ret.?, L),
        }
    }
}

fn c_closure_inner(ud: ?*anyopaque, extern_args: ?[*]const *anyopaque, ret: ?*anyopaque) callconv(.c) void {
    const call_info: *const LuaClosure.CallInfo = @ptrCast(@alignCast(ud.?));
    return closureInner(
        call_info,
        if (call_info.args > 0)
            extern_args.?[0..call_info.args]
        else
            &.{},
        ret,
    ) catch |err| std.debug.panic("{}", .{err});
}

pub fn lua_closure(L: *VM.lua.State) !i32 {
    try L.Zchecktype(3, .Function);

    const allocator = Scheduler.fromState(L).allocator();

    const symbol = try getFunctionSymbol(allocator, L, 1);
    var handled = false;
    errdefer if (!handled) allocator.free(symbol.args);

    const arg_types = try allocator.alloc(wire.Type, symbol.args.len);
    defer allocator.free(arg_types);
    for (symbol.args, 0..) |arg, i|
        arg_types[i] = arg.type;

    const call_ptr = try allocator.create(LuaClosure.CallInfo);
    errdefer allocator.destroy(call_ptr);

    call_ptr.* = .{
        .args = @intCast(symbol.args.len),
        .thread = L.mainthread(),
        .ref = .empty,
        .type = .{
            .returns = symbol.returns,
            .args = symbol.args,
        },
    };

    const closure_info = try wire.ffi.prepareClosureInfo(
        allocator,
        &JIT_POOL,
        arg_types,
        symbol.returns.type,
        c_closure_inner,
        @ptrCast(@alignCast(call_ptr)),
    );

    call_ptr.ref = .init(L, 3);

    const data = try L.newuserdatadtor(LuaClosure, LuaClosure.__dtor);
    handled = true;
    data.* = .{
        .callinfo = call_ptr,
        .sym = .{
            .buffer = closure_info.buffer,
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

    try L.setreadonly(-1, true);

    _ = try L.setmetatable(-2);

    _ = try L.ref(-1); // permenently reference the closure

    const ptr = try CPointer.newStaticPtr(L, @constCast(closure_info.pointer()));
    try ptr.retain(L);
    ptr.size = 0;

    return 1;
}

const CFunction = struct {
    code: *CallableFunction,
    ptr: *const anyopaque,

    callable: FFICallable,

    pub const FFICallable = *align(8) const fn (lua_State: *anyopaque, fnPtr: *const anyopaque) callconv(.c) void;

    pub fn fn_inner(L: *VM.lua.State) !i32 {
        CALLING_STATE = L;
        defer CALLING_STATE = null;
        const allocator = Scheduler.fromState(L).allocator();
        const self = L.touserdata(CFunction, VM.lua.upvalueindex(1)) orelse unreachable;

        const callable = self.callable;

        const arg_count = L.gettop();
        if (arg_count < self.code.sym.type.args.len)
            return L.Zerrorf("invalid number of arguments (expected {d} args, got {d} args)", .{ self.code.sym.type.args.len, arg_count });

        var arena: ?std.heap.ArenaAllocator = null;
        defer if (arena) |a| a.deinit();

        const returns = self.code.sym.type.returns;
        if (returns.type.size > 0)
            try L.rawcheckstack(1);

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
                                const ptr = CPointer.value(L, idx) orelse return L.Zerrorf("userdata is not a Pointer", .{});
                                if (ptr.owner == .none)
                                    return L.Zerrorf("unavailable address", .{});
                                if (ptr.data.tag != arg.kind.pointer.tag)
                                    return L.Zerrorf("tag mismatch", .{});
                                ptrs[order] = @ptrCast(@alignCast(ptr.ptr));
                            },
                            .String => {
                                const str: [:0]const u8 = L.tostring(idx).?;
                                const dup = arena_allocator.dupeSentinel(u8, str, 0) catch return L.Zerrorf("OutOfMemory", .{});
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Buffer => {
                                const buf = L.tobuffer(idx).?;
                                const dup = arena_allocator.dupe(u8, buf) catch return L.Zerrorf("OutOfMemory", .{});
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Vector => {
                                const vec = L.tovector(idx).?;
                                const dup = arena_allocator.dupe(f32, vec[0..3]) catch return L.Zerrorf("OutOfMemory", .{});
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Nil => ptrs[order] = @ptrFromInt(0),
                            .Proto, .UpVal, .Deadkey, .All => unreachable,
                            inline else => |e| return L.Zerrorf("invalid argument type (got {s})", .{comptime VM.lapi.typename(e)}),
                        }
                    },
                    .@"struct" => {
                        defer order += 1;
                        const idx: i32 = @intCast(i);
                        switch (L.typeOf(idx)) {
                            .Buffer => {},
                            .Proto, .UpVal, .Deadkey, .All => unreachable,
                            inline else => |e| return L.Zerrorf("invalid argument type (expected buffer, got {s})", .{comptime VM.lapi.typename(e)}),
                        }
                        const buf = L.tobuffer(idx).?;
                        if (buf.len != arg.type.size)
                            return L.Zerrorf("invalid buffer size mismatch (expected {d} bytes, got {d} bytes)", .{ arg.type.size, buf.len });
                        const mem: []u8 = @alignCast((arena_allocator.rawAlloc(arg.type.size, arg.type.alignment, @returnAddress()) orelse return L.Zerrorf("OutOfMemory", .{}))[0..arg.type.size]);
                        @memcpy(mem, buf);
                        ptrs[order] = @ptrCast(@alignCast(mem.ptr));
                    },
                    else => {},
                }
            }
            std.debug.assert(ptrs.len == order);
        }

        @call(.never_tail, callable, .{
            @as(*anyopaque, @ptrCast(@alignCast(L))),
            self.ptr,
        });

        if (returns.type.size > 0) {
            if (returns.kind == .pointer and returns.kind.pointer.tag != 0) {
                const ptr = CPointer.value(L, -1) orelse unreachable;
                ptr.data = returns.kind.pointer;
            }
            return 1;
        }
        return 0;
    }

    pub fn __dtor(L: *VM.lua.State, self: *CFunction) void {
        _ = L;
        self.code.unref();
    }
};

pub fn lua_fn(L: *VM.lua.State) !i32 {
    const src = CPointer.value(L, 3) orelse return L.Zerror("invalid pointer");
    switch (src.type) {
        .allocated => return error.PointerNotCallable,
        else => {},
    }
    const ptr: *anyopaque = src.ptr orelse return L.Zerror("unavailable address");

    const allocator = Scheduler.fromState(L).allocator();

    const symbol = try getFunctionSymbol(allocator, L, 1);
    defer allocator.free(symbol.args);

    const code = try fetchCallableFunction(symbol.returns, symbol.args);
    errdefer code.unref();

    const data = try L.newuserdatadtor(CFunction, CFunction.__dtor);
    L.pushvalue(3);

    data.* = .{
        .callable = @ptrCast(@alignCast(code.getSymbol())),
        .code = code,
        .ptr = ptr,
    };

    try L.pushcclosure(Scripting.toCFn(CFunction.fn_inner), "c_fn", 2);

    return 1;
}

pub fn lua_tagName(L: *VM.lua.State) !i32 {
    const id = L.Lcheckunsigned(1);
    if (id == 0) {
        L.pushnil();
        return 1;
    }
    const names = TAGGED_POINTERS.keys();
    if (id > names.len) {
        L.pushnil();
        return 1;
    }
    const name = names[id - 1];
    try L.pushlstring(name);
    return 1;
}

pub fn lua_ptr(L: *VM.lua.State) !i32 {
    const ref_ptr = CPointer.value(L, 1) orelse return L.Zerror("invalid pointer");

    const ptr = try CPointer.allocBlockPtr(L, @sizeOf(*anyopaque), .fromByteUnits(@alignOf(*anyopaque)));

    @as(**anyopaque, @ptrCast(@alignCast(ptr.ptr))).* = @ptrCast(@alignCast(ref_ptr.ptr));

    return 1;
}

pub fn lua_ptrFromAddress(L: *VM.lua.State) !i32 {
    const buf = L.Lcheckbuffer(1);
    if (buf.len < @sizeOf(usize))
        return error.SmallBuffer;

    const static_ptr: ?*anyopaque = @ptrFromInt(std.mem.bytesToValue(usize, buf[0..@sizeOf(usize)]));

    _ = try CPointer.newStaticPtr(L, static_ptr);

    return 1;
}

pub fn lua_alloc(L: *VM.lua.State) !i32 {
    const len = try L.Zcheckvalue(u53, 1, null);
    const alignment = L.Loptunsigned(2, 1);
    if (alignment == 0)
        return L.Zerror("invalid alignment");
    _ = try CPointer.allocBlockPtr(L, @truncate(len), .fromByteUnits(alignment));
    return 1;
}

pub fn lua_create(L: *VM.lua.State) !i32 {
    const datatype = toCType(L, 1) orelse return L.Zerror("invalid c type");
    const ptr = try CPointer.allocBlockPtr(L, datatype.type.size, datatype.type.alignment);
    switch (datatype.kind) {
        .pointer => |p| ptr.data.tag = p.tag,
        else => {},
    }
    return 1;
}

pub fn lua_getLuaState(L: *VM.lua.State) !i32 {
    if (try L.Zcheckvalue(?bool, 1, null) orelse false) {
        _ = try CPointer.newStaticPtr(L, @ptrCast(L.mainthread()));
        return 1;
    }
    _ = try CPointer.newStaticPtr(L, @ptrCast(L));
    return 1;
}

pub fn lua_free(L: *VM.lua.State) !i32 {
    const ptr = CPointer.value(L, 1) orelse return L.Zerror("invalid pointer");
    if (ptr.owner == .none)
        return L.Zerror("Double free");
    const allocator = Scheduler.fromState(L).allocator();
    if (ptr.local_ref) |ref| {
        L.unref(ref);
        ptr.local_ref = null;
    }
    switch (ptr.type) {
        .allocated => {
            ptr.owner = .none;
            const size = @max(ptr.size orelse 8, 1);
            allocator.rawFree(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size],
                ptr.alignment orelse .@"1",
                @returnAddress(),
            );
        },
        .static => {
            ptr.owner = .none;
            // allowed assuming the caller knows what they're doing
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

pub fn lua_dupe(L: *VM.lua.State) !i32 {
    switch (L.typeOf(1)) {
        .Buffer => {
            const buf = L.tobuffer(1) orelse unreachable;
            const ptr = try CPointer.allocBlockPtr(L, buf.len, .@"1");
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..buf.len],
                buf,
            );
        },
        .Vector => {
            const vec = L.tovector(1) orelse unreachable;
            const ptr = try CPointer.allocBlockPtr(L, @sizeOf(f32) * 3, .fromByteUnits(@alignOf(f32)));
            @memcpy(
                @as([*]f32, @ptrCast(@alignCast(ptr.ptr)))[0..3],
                vec[0..3],
            );
        },
        .Userdata => {
            const ptr = CPointer.value(L, 1) orelse return error.Fail;
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
            const len = ptr.size orelse return L.Zerror("unknown sized pointer");
            const dup_ptr = try CPointer.allocBlockPtr(L, len, ptr.alignment orelse .@"1");
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

pub fn init(L: *VM.lua.State) !void {
    _ = L;
    TAGGED_POINTERS = .empty;
    CACHED_WIRE_COMPILATON = .empty;
    JIT_POOL = .init(Zune.DEFAULT_ALLOCATOR);
}

pub fn deinit(L: *VM.lua.State) void {
    _ = L;
    for (TAGGED_POINTERS.keys()) |key|
        Zune.DEFAULT_ALLOCATOR.free(key);
    TAGGED_POINTERS.deinit(Zune.DEFAULT_ALLOCATOR);
    CACHED_WIRE_COMPILATON.deinit(Zune.DEFAULT_ALLOCATOR);
    JIT_POOL.deinit();
}

pub fn lua_custom_types(L: *VM.lua.State) !void {
    try L.createtable(0, @intCast(@typeInfo(Types).@"struct".decl_names.len));
    inline for (@typeInfo(Types).@"struct".decl_names) |decl_name| {
        try L.pushstring(decl_name);
        const ptr = try L.newuserdatataggedwithmetatable(CType, CType.OBJECT_TAG);
        ptr.* = .{
            .type = @field(Types, decl_name),
        };
        try L.rawset(-3);
    }
    try L.setreadonly(-1, true);
}

pub const lua_prefix = switch (builtin.os.tag) {
    .windows => "",
    else => "lib",
};

pub const lua_suffix = switch (builtin.os.tag) {
    .linux, .freebsd => "so",
    .macos => "dylib",
    .windows => "dll",
    else => "",
};

pub fn lua_null(L: *VM.lua.State) !i32 {
    _ = try CPointer.newStaticPtr(L, null);
    return 1;
}
