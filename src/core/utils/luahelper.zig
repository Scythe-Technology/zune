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

    pub fn init(L: *VM.lua.State, comptime weak: bool) RefTable {
        L.newtable();
        defer L.pop(1);

        if (weak) {
            L.Zpushvalue(.{ .__mode = "v" });
            L.setreadonly(-1, true);
            _ = L.setmetatable(-2);
        }

        return .{ .table_ref = .init(L, -1, undefined) };
    }

    pub fn deinit(self: *RefTable, L: *VM.lua.State) void {
        self.table_ref.deref(L);
    }

    pub fn ref(self: *RefTable, L: *VM.lua.State, idx: i32) ?i32 {
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
        L.rawseti(-2, id);
        L.pop(1);
        return id;
    }

    pub fn unref(self: *RefTable, L: *VM.lua.State, id: i32) void {
        if (self.table_ref.push(L)) {
            defer L.pop(1);
            L.pushinteger(self.free);
            L.rawseti(-2, id);
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
            const ref = L.ref(idx) orelse std.debug.panic("Failed to create ref\n", .{});
            return .{
                .value = value,
                .ref = .{ .registry = ref },
            };
        }

        pub fn initWithTable(L: *VM.lua.State, idx: i32, value: T, reftable: *RefTable) This {
            std.debug.assert(reftable.table_ref.ref != null);
            const ref = reftable.ref(L, idx) orelse unreachable;
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

/// Register a table in the registry.
/// Pops the module from the stack.
pub fn registerModule(L: *VM.lua.State, comptime libName: [:0]const u8) void {
    _ = L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    if (L.rawgetfield(-1, libName) != .Table) {
        L.pop(1);
        L.pushvalue(-2);
        L.setfield(-2, libName);
    } else L.pop(1);
    L.pop(2);
}
