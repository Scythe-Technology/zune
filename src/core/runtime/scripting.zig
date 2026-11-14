const std = @import("std");
const luau = @import("luau");
const Zune = @import("zune");

const Debug = @import("./debug.zig");

const VM = luau.VM;

const CPointer = Zune.objects.CPointer;

pub const MAX_LUAU_SIZE = 1073741824; // 1 GB

fn ZigErrorHandler(L: *VM.lua.State, err: anyerror) noreturn {
    switch (err) {
        error.RaiseLuauError => L.raiseerror(),
        error.OutOfMemory => VM.ldo.throw(L, .ErrMem),
        else => L.LerrorL("{s}", .{@errorName(err)}) catch VM.ldo.throw(L, .ErrMem),
    }
}

pub fn ZigToCFn(
    comptime fnType: std.builtin.Type.Fn,
    f: fn (L: (fnType.param_types[0] orelse *VM.lua.State)) (fnType.return_type orelse void),
) VM.lua.CFunction {
    if (fnType.param_types.len != 1)
        @compileError("Fn must have exactly 1 parameter");
    const param_type = fnType.param_types[0] orelse @compileError("Param must have a type");
    if (param_type != *VM.lua.State)
        @compileError("Fn parameter must be *lua.State");
    switch (@typeInfo(fnType.return_type orelse @compileError("Fn must return something"))) {
        .int => {
            if (fnType.return_type != i32)
                @compileError("Unsupported Fn Return type, must be i32");
            return struct {
                fn inner(s: *VM.lua.State) callconv(.c) c_int {
                    return @call(.always_inline, f, .{s});
                }
            }.inner;
        },
        .void => {
            return struct {
                fn inner(s: *VM.lua.State) callconv(.c) c_int {
                    @call(.always_inline, f, .{s});
                    return 0;
                }
            }.inner;
        },
        .error_union => |error_union| {
            switch (@typeInfo(error_union.payload)) {
                .int => {
                    if (error_union.payload != i32)
                        @compileError("Unsupported Fn Return type, must be i32");
                    return struct {
                        fn inner(s: *VM.lua.State) callconv(.c) c_int {
                            if (@call(.always_inline, f, .{s})) |res|
                                return res
                            else |err|
                                ZigErrorHandler(s, err);
                        }
                    }.inner;
                },
                .void => {
                    return struct {
                        fn inner(s: *VM.lua.State) callconv(.c) c_int {
                            if (@call(.always_inline, f, .{s}))
                                return 0
                            else |err|
                                ZigErrorHandler(s, err);
                        }
                    }.inner;
                },
                else => |t| @compileError("Unsupported Fn Return type " ++ @tagName(t)),
            }
        },
        else => |t| @compileError("Unsupported Fn Return type " ++ @tagName(t)),
    }
}

pub fn toCFn(f: anytype) VM.lua.CFunction {
    const t = @TypeOf(f);
    const ti = @typeInfo(t);
    switch (ti) {
        .@"fn" => |Fn| return ZigToCFn(Fn, f),
        .pointer => |ptr| {
            // *const fn ...
            if (!ptr.is_const)
                @compileError("Pointer must be constant");
            const pi = @typeInfo(ptr.child);
            switch (pi) {
                .@"fn" => |Fn| return ZigToCFn(Fn, f),
                else => @compileError("Pointer must be a pointer to a function"),
            }
        },
        else => @compileError("zig_fn must be a Fn or a Fn Pointer"),
    }
    @compileError("Could not determine zig_fn type");
}

pub fn withFn(
    comptime T: type,
    comptime f: anytype,
    comptime before: ?fn (ptr: *T, L: *VM.lua.State) anyerror!void,
) fn (ptr: *T, L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(ptr: *T, L: *VM.lua.State) !i32 {
            if (comptime before) |@"fn"|
                try @call(.always_inline, @"fn", .{ ptr, L });
            return switch (@typeInfo(@TypeOf(f))) {
                .@"fn" => @call(.always_inline, f, .{ ptr, L }),
                else => @compileError("Invalid type for method map"),
            };
        }
    }.inner;
}

pub fn createNamecallMap(
    comptime T: type,
    comptime tag: ?i32,
    comptime method_map: anytype,
) VM.lua.CFunction {
    const map = std.StaticStringMap(*const fn (ptr: *T, L: *VM.lua.State) anyerror!i32).initComptime(method_map);

    return toCFn(struct {
        fn inner(L: *VM.lua.State) !i32 {
            const ptr = if (comptime tag) |t|
                L.touserdatatagged(T, 1, t) orelse return L.Zerrorf("invalid userdata", .{})
            else
                L.touserdata(T, 1) orelse return L.Zerrorf("invalid userdata", .{});

            const namecall = L.namecallstr() orelse return 0;
            const method = map.get(namecall) orelse return L.Zerrorf("unknown method: {s}", .{namecall});
            return @call(.auto, method, .{ ptr, L });
        }
    }.inner);
}

pub fn createStaticIndexMap(
    comptime T: type,
    comptime tag: i32,
    comptime index_map: anytype,
) fn (L: *VM.lua.State, comptime idx: i32) anyerror!void {
    return struct {
        fn inner(state: *VM.lua.State, comptime index: i32) !void {
            const idx = comptime if (index != VM.lua.GLOBALSINDEX and index != VM.lua.REGISTRYINDEX and index < 0) index - 1 else index;
            try state.createtable(0, index_map.len);
            inline for (index_map) |kv| {
                try state.Zpushfunction(toCFn(struct {
                    fn inner(L: *VM.lua.State) !i32 {
                        const ptr = L.touserdatatagged(T, 1, tag) orelse return L.Zerror("expected ':' calling member function " ++ kv[0]);
                        return @call(.always_inline, kv[1], .{ ptr, L });
                    }
                }.inner), kv[0]);
                try state.rawsetfield(-2, kv[0]);
            }
            try state.rawsetfield(idx, "__index");
        }
    }.inner;
}

pub fn createEnumMap(comptime Enum: type) std.StaticStringMap(Enum) {
    const enum_data = @typeInfo(Enum).@"enum";
    var list: [enum_data.field_names.len]struct { []const u8, Enum } = undefined;

    for (enum_data.field_names, enum_data.field_values, 0..) |field_name, field_value, i| {
        list[i] = .{ field_name, @fromBackingInt(@intCast(field_value)) };
    }

    return std.StaticStringMap(Enum).initComptime(list);
}

pub fn deepclone(L: *VM.lua.State, idx: i32) void {
    L.clonetable(idx);
    var i: i32 = L.rawiter(-1, 0);
    while (i >= 0) : (i = L.rawiter(-1, i)) {
        defer L.pop(2);
        if (L.typeOf(-1) == .Table) {
            deepclone(L, -1);
            L.remove(-2); // remove table
            L.settable(-3);
        }
    }
}

pub const ReferenceTable = struct {
    parked: Reference,
    free: i32 = 0,

    pub fn init(L: *VM.lua.State, comptime weak: bool) !ReferenceTable {
        try initTable(L, weak);
        defer L.pop(1);

        return .{ .parked = .init(L, -1) };
    }

    /// stack never modified
    pub fn deinit(self: *ReferenceTable, L: *VM.lua.State) void {
        self.parked.deref(L);
    }

    pub fn slot(self: *ReferenceTable, L: *VM.lua.State, id: i32) *VM.lobject.TValue {
        const table_slot = self.parked.slot(L);
        std.debug.assert(table_slot.ttistable());

        const s = VM.ltable.Hgetnum(table_slot.hvalue(), id);
        std.debug.assert(s != VM.lobject.Onilobject);
        return @constCast(s);
    }

    /// stack never modified
    pub fn ref(self: *ReferenceTable, L: *VM.lua.State, idx: i32) !i32 {
        const obj = L.Atoobject(idx) orelse unreachable;

        const table_slot = self.parked.slot(L);
        std.debug.assert(table_slot.ttistable());

        const id: i32 = if (self.free != 0)
            self.free
        else
            @intCast(L.objlen(-1) + 1);

        if (self.free != 0) {
            const ref_slot = VM.ltable.Hgetnum(table_slot.hvalue(), id);
            if (ref_slot.ttisnumber())
                self.free = @intFromFloat(ref_slot.nvalue())
            else
                self.free = 0;
        }

        (try VM.ltable.Hsetnum(L, table_slot.hvalue(), id)).setobj(L, obj);
        VM.lgc.Cbarriert(L, table_slot.hvalue(), obj);

        return id;
    }

    /// stack never modified
    pub fn unref(self: *ReferenceTable, L: *VM.lua.State, id: i32) void {
        const ref_slot = self.slot(L, id);

        ref_slot.setnvalue(@floatFromInt(self.free));

        self.free = id;
    }

    /// uses exactly 1 stack and pushes value to the stack
    pub fn get(self: *ReferenceTable, L: *VM.lua.State, id: i32) void {
        VM.lgc.Cthreadbarrier(L);
        L.Apushvalue(self.slot(L, id));
    }
};

pub fn initTable(L: *VM.lua.State, comptime weak: bool) !void {
    try L.newtable();

    if (weak) {
        errdefer L.pop(1);
        try L.Zpushvalue(.{ .__mode = "v" });
        errdefer L.pop(1);
        try L.setreadonly(-1, true);
        _ = try L.setmetatable(-2);
    }
}

pub const CountedReference = struct {
    id: Reference = .empty,
    count: usize = 0,

    pub const empty: CountedReference = .{ .id = .empty, .count = 0 };

    pub fn deref(self: *CountedReference, L: *VM.lua.State) void {
        std.debug.assert(self.count > 0);
        self.count -= 1;
        if (self.count == 0)
            self.id.deref(L);
    }

    pub fn ref(self: *CountedReference, L: *VM.lua.State, idx: i32) void {
        if (self.count == 0) {
            self.id = .init(L, idx);
        }
        self.count += 1;
    }
};

pub const Reference = struct {
    id: i32,

    pub const empty: Reference = .{ .id = 0 };

    pub fn init(L: *VM.lua.State, idx: i32) Reference {
        const ref = (L.ref(idx) catch |e|
            std.debug.panic("{}", .{e})) orelse std.debug.panic("failed to create reference\n", .{});
        return .{
            .id = ref,
        };
    }

    pub fn valid(self: Reference) bool {
        return self.id > 0;
    }

    /// pushes the referenced value onto the stack
    pub fn push(self: Reference, L: *VM.lua.State) void {
        std.debug.assert(self.id > 0);
        _ = L.rawgeti(VM.lua.REGISTRYINDEX, self.id);
    }

    /// Get pointer to TValue of the referenced value.
    /// Useful for direct manipulation of the TValue without affecting the stack,
    /// faster than pushing and popping the value.
    /// stack never modified
    pub fn slot(self: Reference, L: *VM.lua.State) *VM.lobject.TValue {
        std.debug.assert(self.id > 0);
        const reg = L.registry().hvalue();

        const s = VM.ltable.Hgetnum(reg, self.id);
        std.debug.assert(s != VM.lobject.Onilobject);
        return @constCast(s);
    }

    /// stack never modified
    pub fn deref(self: *Reference, L: *VM.lua.State) void {
        if (self.id > 0) {
            L.unref(self.id);
            self.id = 0;
        }
    }

    /// stack never modified
    pub fn derefUnretained(self: Reference, L: *VM.lua.State) void {
        if (self.id > 0)
            L.unref(self.id);
    }
};

pub fn ValueReference(comptime T: type) type {
    return struct {
        ref: Reference,
        value: T,

        pub const Self = @This();

        pub const empty: Self = .{ .ref = .empty, .value = undefined };

        pub fn init(L: *VM.lua.State, idx: i32, value: T) Self {
            return .{
                .ref = .init(L, idx),
                .value = value,
            };
        }

        pub fn valid(self: Self) bool {
            return self.ref.valid();
        }

        pub fn deref(self: *Self, L: *VM.lua.State) void {
            self.ref.deref(L);
        }

        pub fn derefUnretained(self: Self, L: *VM.lua.State) void {
            self.ref.derefUnretained(L);
        }
    };
}

pub const TableReference = struct {
    id: i32,
    table: *ReferenceTable,

    pub const empty: TableReference = .{ .id = 0, .table = undefined };

    pub fn init(L: *VM.lua.State, idx: i32, reftable: *ReferenceTable) TableReference {
        const ref = reftable.ref(L, idx) catch |e| std.debug.panic("{}", .{e});
        return .{
            .id = ref,
            .table = reftable,
        };
    }

    pub fn valid(self: TableReference) bool {
        return self.id > 0;
    }

    /// pushes the referenced table onto the stack.
    pub fn push(self: TableReference, L: *VM.lua.State) void {
        std.debug.assert(self.id > 0);
        self.table.get(L, self.id);
    }

    /// stack never modified
    pub fn slot(self: TableReference, L: *VM.lua.State) *VM.lobject.TValue {
        std.debug.assert(self.id > 0);
        return self.table.slot(L, self.id);
    }

    /// stack never modified
    pub fn deref(self: *TableReference, L: *VM.lua.State) void {
        if (self.id > 0) {
            self.table.unref(L, self.id);
            self.id = 0;
        }
    }

    /// stack never modified
    pub fn derefUnretained(self: TableReference, L: *VM.lua.State) void {
        if (self.id > 0)
            self.table.unref(L, self.id);
    }
};

pub const LuaValue = union(enum) {
    nil: void,
    boolean: bool,
    number: f64,
    string: []const u8,
    buffer: []const u8,
    table: struct {
        keys: [*]LuaValue,
        values: [*]LuaValue,
        len: usize,
    },
    vector: [VM.lua.config.VECTOR_SIZE]f32,

    pub fn push(self: LuaValue, L: *VM.lua.State) !void {
        switch (self) {
            .nil => L.pushnil(),
            .boolean => |v| L.pushboolean(v),
            .number => |v| L.pushnumber(v),
            .string => |v| try L.pushlstring(v),
            .buffer => |v| try L.Zpushbuffer(v),
            .table => |v| {
                var narray: u32 = 0;
                var nrec: u32 = 0;
                for (v.keys[0..v.len]) |key| switch (key) {
                    .number => |n| {
                        if (@as(i32, @intFromFloat(n)) == narray + 1)
                            narray += 1;
                    },
                    else => nrec += 1,
                };
                try L.createtable(narray, nrec);
                try L.rawcheckstack(2);
                for (v.keys[0..v.len], v.values[0..v.len]) |key, value| {
                    try key.push(L);
                    try value.push(L);
                    try L.rawset(-3);
                }
            },
            .vector => |v| L.pushvector(v[0], v[1], v[2]),
        }
    }

    fn storeTracked(
        allocator: std.mem.Allocator,
        L: *VM.lua.State,
        idx: i32,
        out_type: ?*VM.lua.Type,
        map: *std.array_hash_map.Auto(usize, bool),
    ) !LuaValue {
        switch (L.typeOf(idx)) {
            .Nil => return .nil,
            .Boolean => return .{ .boolean = L.toboolean(idx) },
            .Number => return .{ .number = L.tonumber(idx).? },
            .String => {
                const copy = try allocator.dupe(u8, L.tostring(idx).?);
                return .{ .string = copy };
            },
            .Buffer => {
                const copy = try allocator.dupe(u8, L.tobuffer(idx).?);
                return .{ .buffer = copy };
            },
            .Table => {
                const ptr = @intFromPtr(L.topointer(idx).?);
                if (map.get(ptr)) |_|
                    return error.CyclicReference;
                try map.put(allocator, ptr, true);

                var keys: std.ArrayList(LuaValue) = .empty;
                errdefer keys.deinit(allocator);
                errdefer for (keys.items) |v| v.deinit(allocator);
                var values: std.ArrayList(LuaValue) = .empty;
                errdefer values.deinit(allocator);
                errdefer for (values.items) |v| v.deinit(allocator);

                var i = L.rawiter(idx, 0);
                while (i >= 0) : (i = L.rawiter(idx, i)) {
                    defer L.pop(2);
                    {
                        const key = try storeTracked(allocator, L, -2, out_type, map);
                        errdefer key.deinit(allocator);
                        try keys.append(allocator, key);
                    }
                    {
                        const value = try storeTracked(allocator, L, -1, out_type, map);
                        errdefer value.deinit(allocator);
                        try values.append(allocator, value);
                    }
                }

                const keys_slice = try keys.toOwnedSlice(allocator);
                errdefer allocator.free(keys_slice);
                const values_slice = try values.toOwnedSlice(allocator);
                return .{
                    .table = .{
                        .keys = keys_slice.ptr,
                        .values = values_slice.ptr,
                        .len = keys_slice.len,
                    },
                };
            },
            .Vector => {
                const vec = L.tovector(idx).?;
                var value: LuaValue = .{ .vector = undefined };
                for (vec, 0..) |n, i|
                    value.vector[i] = n;
                return value;
            },
            else => |@"type"| {
                if (out_type) |t|
                    t.* = @"type";
                return error.UnsupportedType;
            },
        }
    }

    pub fn store(
        allocator: std.mem.Allocator,
        L: *VM.lua.State,
        idx: i32,
        out_type: ?*VM.lua.Type,
    ) !LuaValue {
        var map: std.array_hash_map.Auto(usize, bool) = .empty;
        defer map.deinit(allocator);
        return try storeTracked(allocator, L, idx, out_type, &map);
    }

    pub fn deinit(self: LuaValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string, .buffer => |v| allocator.free(v),
            .table => |v| {
                for (v.keys[0..v.len]) |key|
                    key.deinit(allocator);
                for (v.values[0..v.len]) |value|
                    value.deinit(allocator);
                allocator.free(v.keys[0..v.len]);
                allocator.free(v.values[0..v.len]);
            },
            else => {},
        }
    }
};

pub inline fn controlledSlice(L: *VM.lua.State, comptime T: type, buf: T, offset: u32, count: ?u32) !T {
    if (offset > buf.len)
        return L.Zerror("buffer offset exceeds buffer length");

    var final = buf[offset..];

    if (count) |amt| {
        if (amt == 0)
            return error.NoSpace;

        if (amt > buf.len)
            return L.Zerror("requested size exceeds buffer length");

        final = final[0..amt];
    }

    if (final.len == 0)
        return error.NoSpace;

    return final;
}

pub fn getControlledBuffer(L: *VM.lua.State, comptime T: type, index: i32) !T {
    const buf = try L.Zcheckvalue(T, index, "invalid buffer");
    const buf_offset: u32 = L.tounsigned(index + 1) orelse 0;
    const count = L.tounsigned(index + 2);

    return try controlledSlice(L, T, buf, buf_offset, count);
}

pub fn getReadable(L: *VM.lua.State, index: i32) ![]const u8 {
    return switch (L.typeOf(index)) {
        .Buffer => L.tobuffer(index).?,
        .String => L.tolstring(index).?,
        .Userdata => blk: {
            const ptr = CPointer.value(L, index) orelse return L.Zerror("expected a buffer or userdata");
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
            break :blk @as([*]u8, @ptrCast(@alignCast(ptr.ptr.?)))[0 .. ptr.size orelse return L.Zerror("unknown pointer size")];
        },
        else => return L.Zerror("expected a buffer, string, or userdata"),
    };
}

pub fn getWritable(L: *VM.lua.State, index: i32) ![]u8 {
    return switch (L.typeOf(index)) {
        .Buffer => L.tobuffer(index).?,
        .Userdata => blk: {
            const ptr = CPointer.value(L, index) orelse return L.Zerror("expected a buffer or userdata");
            if (ptr.owner == .none or ptr.ptr == null)
                return L.Zerror("unavailable address");
            break :blk @as([*]u8, @ptrCast(@alignCast(ptr.ptr.?)))[0 .. ptr.size orelse return L.Zerror("unknown pointer size")];
        },
        else => return L.Zerror("expected a buffer or userdata"),
    };
}

pub fn getControlledReadable(L: *VM.lua.State, index: i32) ![]const u8 {
    const buf = try getReadable(L, index);
    const buf_offset: u32 = L.tounsigned(index + 1) orelse 0;
    const count = L.tounsigned(index + 2);

    return try controlledSlice(L, []const u8, buf, buf_offset, count);
}

pub fn getControlledWritable(L: *VM.lua.State, index: i32) ![]u8 {
    const buf = try getWritable(L, index);
    const buf_offset: u32 = L.tounsigned(index + 1) orelse 0;
    const count = L.tounsigned(index + 2);

    return try controlledSlice(L, []u8, buf, buf_offset, count);
}

pub fn collectVec(L: *VM.lua.State, idx: i32, slices: [][]const u8, refs: []Reference) !u8 {
    if (L.typeOf(idx) != .Table)
        return L.Zerror("invalid buffer list");

    std.debug.assert(slices.len == refs.len);
    std.debug.assert(slices.len <= std.math.maxInt(u8));

    var out: u8 = 0;
    errdefer for (refs[0..out]) |*pin| pin.deref(L);

    var seen: usize = 0;
    var iter: ArrayIterator = .{ .L = L, .idx = idx };
    while (try iter.next()) |ty| {
        if (seen == slices.len)
            return L.Zerrorf("vec list exceeds {d} buffers", .{slices.len});
        seen += 1;
        switch (ty) {
            .String, .Buffer => {
                const raw = try L.Zcheckvalue([]const u8, -1, "invalid buffer");
                slices[out] = raw;
                refs[out] = .init(L, -1);
                out += 1;
            },
            .Table => {
                _ = L.rawgeti(-1, 1);
                _ = L.rawgeti(-2, 2);
                _ = L.rawgeti(-3, 3);
                const buf = try getControlledBuffer(L, []const u8, -3);
                slices[out] = buf;
                refs[out] = .init(L, -3);
                out += 1;
                L.pop(3);
            },
            else => return L.Zerror("invalid buffer"),
        }
    }

    return out;
}

pub fn maybeKnownType(T: VM.lua.Type) ?VM.lua.Type {
    if (T.isnoneornil())
        return null;
    return T;
}

pub const SyncResult = union(enum) {
    none: void,
    boolean: bool,
    number: i32,
};

pub fn callSyncGlobalFunction(L: *VM.lua.State, ref: Reference, arg: anytype) !?SyncResult {
    if (!ref.valid())
        return null;
    if (L.rawgeti(luau.VM.lua.REGISTRYINDEX, ref.id) == .Function) {
        const ML = try L.newthread();
        L.xpush(ML, -2);
        if (comptime @TypeOf(arg) != void)
            try ML.Zpushvalue(arg);
        if (ML.pcall(if (comptime @TypeOf(arg) != void) 1 else 0, 0, 0).check()) |_| {
            var res: SyncResult = .none;
            if (ML.gettop() > 0) switch (ML.typeOf(-1)) {
                .Boolean => res = .{ .boolean = ML.toboolean(-1) },
                .Number => res = .{ .number = ML.tointeger(-1).? },
                else => {},
            };
            L.pop(2); // drop: thread, function
            return res;
        } else |err| Debug.dumpErrorTrace(ML, err, false);
        L.pop(1); // drop: thread
    }
    L.pop(1); // drop: ?function
    return null;
}

pub const ArrayIterator = struct {
    L: *VM.lua.State,
    idx: i32,
    iter: i32 = 0,

    /// Returns the next type in the array, or null if there are no more elements.
    /// The return type is the value type of the next element in the array.
    /// Both index and value are pushed to the stack and automatically popped after the next call to `next`.
    ///
    /// This function will return an error if the table is not an array.
    pub fn next(self: *ArrayIterator) !?VM.lua.Type {
        if (self.iter > 0)
            self.L.pop(2);
        self.iter = self.L.rawiter(self.idx, self.iter);
        if (self.iter < 0)
            return null;
        if ((self.L.tointeger(-2) orelse return self.L.Zerror("index must be an array")) != self.iter)
            return self.L.Zerror("table must be an array");
        return self.L.typeOf(-1);
    }
};

pub const TableIterator = struct {
    L: *VM.lua.State,
    idx: i32,
    iter: i32 = 0,

    /// Returns the next type in the table, or null if there are no more elements.
    /// The return type is the key type of the next element in the table.
    /// Both key and value are pushed to the stack and automatically popped after the next call to `next`.
    pub fn next(self: *TableIterator) ?VM.lua.Type {
        if (self.iter > 0)
            self.L.pop(2);
        self.iter = self.L.rawiter(self.idx, self.iter);
        if (self.iter < 0)
            return null;
        return self.L.typeOf(-2);
    }
};

/// Register a table in the registry.
/// Pops the module from the stack.
pub fn registerModule(L: *VM.lua.State, comptime libName: []const u8) !void {
    _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    if (L.rawgetfield(-1, libName) != .Table) {
        L.pop(1);
        L.pushvalue(-2);
        try L.rawsetfield(-2, libName);
    } else L.pop(1);
    L.pop(2);
}

pub fn getModule(L: *VM.lua.State, comptime libName: [:0]const u8) !VM.lua.Type {
    _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    const @"type" = L.rawgetfield(-1, libName);
    L.remove(-2); // remove _LIBS table
    return @"type";
}
