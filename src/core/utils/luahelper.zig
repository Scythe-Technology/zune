const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub const MAX_LUAU_SIZE = 1073741824; // 1 GB

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

pub const RefTable = struct {
    table_ref: Ref(void),
    free: i32 = 0,

    pub fn init(L: *VM.lua.State, comptime weak: bool) !RefTable {
        try L.newtable();
        defer L.pop(1);

        if (weak) {
            try L.Zpushvalue(.{ .__mode = "v" });
            L.setreadonly(-1, true);
            _ = try L.setmetatable(-2);
        }

        return .{ .table_ref = .init(L, -1, undefined) };
    }

    pub fn deinit(self: *RefTable, L: *VM.lua.State) void {
        self.table_ref.deref(L);
    }

    pub fn ref(self: *RefTable, L: *VM.lua.State, idx: i32) !?i32 {
        L.pushvalue(idx);
        defer L.pop(1);
        if (!self.table_ref.push(L))
            return null;

        const id: i32 = if (self.free != 0)
            self.free
        else
            @intCast(L.objlen(-1) + 1);

        if (self.free != 0) {
            defer L.pop(1);
            if (L.rawgeti(-1, id) == .Number)
                self.free = L.tointeger(-1).?
            else
                self.free = 0;
        }

        L.pushvalue(-2);
        try L.rawseti(-2, id);
        L.pop(1);
        return id;
    }

    pub fn unref(self: *RefTable, L: *VM.lua.State, id: i32) void {
        if (self.table_ref.push(L)) {
            defer L.pop(1);
            L.pushinteger(self.free);
            L.rawseti(-2, id) catch unreachable; // the node at this id should exist and not readonly
            self.free = id;
        }
    }

    pub fn get(self: *RefTable, L: *VM.lua.State, id: i32) ?VM.lua.Type {
        if (!self.table_ref.push(L))
            return null;

        const value = L.rawgeti(-1, id);
        if (value == .Nil) {
            defer L.pop(2);
            self.unref(L, id);
            return null;
        }
        L.remove(-2);
        return value;
    }
};

pub fn Ref(comptime T: type) type {
    return struct {
        ref: ?union(enum) {
            registry: i32,
            table: struct {
                ref: i32,
                table: *RefTable,
            },
        } = null,
        value: T,

        pub const empty: This = .{ .ref = null, .value = undefined };

        const This = @This();

        pub fn init(L: *VM.lua.State, idx: i32, value: T) This {
            const ref = (L.ref(idx) catch |e| std.debug.panic("{}", .{e})) orelse std.debug.panic("Failed to create ref\n", .{});
            return .{
                .value = value,
                .ref = .{ .registry = ref },
            };
        }

        pub fn initWithTable(L: *VM.lua.State, idx: i32, value: T, reftable: *RefTable) This {
            std.debug.assert(reftable.table_ref.ref != null);
            const ref = reftable.ref(L, idx) catch |e| std.debug.panic("{}", .{e}) orelse unreachable;
            return .{
                .value = value,
                .ref = .{
                    .table = .{
                        .ref = ref,
                        .table = reftable,
                    },
                },
            };
        }

        pub inline fn hasRef(self: *This) bool {
            return self.ref != null;
        }

        pub fn copy(self: *This, L: *VM.lua.State) This {
            if (self.push(L)) {
                defer L.pop(1);
                return .init(L, -1, self.value);
            } else return .empty;
        }

        pub fn push(self: *This, L: *VM.lua.State) bool {
            if (self.ref) |r| {
                switch (r) {
                    .registry => |id| _ = L.rawgeti(VM.lua.REGISTRYINDEX, id),
                    .table => |t| if (t.table.get(L, t.ref) == null) {
                        self.ref = null;
                        return false;
                    },
                }
                return true;
            }
            return false;
        }

        pub fn deref(self: *This, L: *VM.lua.State) void {
            if (self.ref) |r| {
                switch (r) {
                    .registry => |id| {
                        if (id <= 0)
                            return;
                        L.unref(id);
                    },
                    .table => |t| t.table.unref(L, t.ref),
                }

                self.ref = null;
            }
        }
    };
}

pub fn maybeKnownType(T: VM.lua.Type) ?VM.lua.Type {
    if (T.isnoneornil())
        return null;
    return T;
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
pub fn registerModule(L: *VM.lua.State, comptime libName: [:0]const u8) !void {
    _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    if (L.rawgetfield(-1, libName) != .Table) {
        L.pop(1);
        L.pushvalue(-2);
        try L.rawsetfield(-2, libName);
    } else L.pop(1);
    L.pop(2);
}
