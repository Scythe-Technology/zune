const std = @import("std");
const luau = @import("luau");
const sqlite = @import("sqlite");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const VM = luau.VM;

const TAG_SQLITE_DATABASE = Zune.Tags.get("SQLITE_DATABASE").?;
const TAG_SQLITE_STATEMENT = Zune.Tags.get("SQLITE_STATEMENT").?;

pub const LIB_NAME = "sqlite";

const LuaStatement = struct {
    db: *LuaDatabase,
    ref: ?i32,
    statement: sqlite.Statement,
    closed: bool = false,

    // Placeholder
    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        return 0;
    }

    pub fn loadParams(allocator: std.mem.Allocator, L: *VM.lua.State, statement: sqlite.Statement, idx: i32) ![]?sqlite.Value {
        if (L.typeOf(idx) != .Table)
            return L.Zerrorf("expected table in argument #{d}", .{idx - 1});
        const values = try allocator.alloc(?sqlite.Value, statement.param_list.items.len);
        errdefer allocator.free(values);
        for (statement.param_list.items, 0..) |info, i| {
            try L.pushlstring(info.name);
            switch (L.rawget(idx)) {
                .Number => values[i] = .{ .f64 = L.tonumber(-1) orelse unreachable },
                .String => values[i] = .{ .text = L.tostring(-1) orelse unreachable },
                .Buffer => values[i] = .{ .blob = L.tobuffer(-1) orelse unreachable },
                .Nil => values[i] = null,
                else => return L.Zerrorf("unsupported type for parameter {s}", .{info.name}),
            }
        }
        return values;
    }

    fn resultToTable(L: *VM.lua.State, statement: sqlite.Statement, res: []const ?sqlite.Value) !void {
        try L.createtable(0, @intCast(res.len));
        for (res, 0..) |value, idx| {
            const name = statement.column_list.items[idx].name;
            if (value) |v| {
                try L.pushlstring(name);
                switch (v) {
                    .f64 => |n| L.pushnumber(n),
                    .i32 => |n| L.pushinteger(n),
                    .i64 => |n| L.pushnumber(@floatFromInt(n)),
                    .text => |s| try L.pushlstring(s),
                    .blob => |b| try L.Zpushbuffer(b),
                }
                try L.rawset(-3);
            }
        }
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdatatagged(LuaStatement, 1, TAG_SQLITE_STATEMENT) orelse return L.Zerror("invalid userdata");
        const namecall = L.namecallstr() orelse return 0;
        const allocator = luau.getallocator(L);
        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "all")) {
            if (ptr.closed)
                return L.Zerror("statement closed");

            ptr.statement.reset();
            defer ptr.statement.reset();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            var order: i32 = 1;
            try L.newtable();
            while (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res| {
                defer allocator.free(res);
                try resultToTable(L, ptr.statement, res);
                try L.rawseti(-2, order);
                order += 1;
            }

            return 1;
        } else if (std.mem.eql(u8, namecall, "get")) {
            if (ptr.closed)
                return L.Zerror("statement closed");
            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            if (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res| {
                defer allocator.free(res);
                try resultToTable(L, ptr.statement, res);
            } else {
                ptr.statement.reset();
                L.pushnil();
            }
            return 1;
        } else if (std.mem.eql(u8, namecall, "run")) {
            if (ptr.closed)
                return L.Zerror("statement closed");

            ptr.statement.reset();
            defer ptr.statement.reset();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            if (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res|
                allocator.free(res);

            try L.Zpushvalue(.{
                .last_insert_row_id = @as(i32, @truncate(ptr.db.db.getLastInsertRowId())),
                .changes = @as(i32, @truncate(ptr.db.db.countChanges())),
            });

            return 1;
        } else if (std.mem.eql(u8, namecall, "finalize")) {
            ptr.close(L);
        }
        return L.Zerrorf("unknown method: {s}", .{namecall});
    }

    pub fn close(ptr: *LuaStatement, L: *VM.lua.State) void {
        if (ptr.closed)
            return;
        const allocator = luau.getallocator(L);
        defer ptr.statement.deinit(allocator);
        ptr.closed = true;
        if (ptr.ref) |ref| {
            defer L.unref(ref);
            if (ptr.db.closed)
                return;
            for (ptr.db.statements.items, 0..) |saved_ref, idx| {
                if (saved_ref != ref)
                    continue;
                _ = ptr.db.statements.orderedRemove(idx);
                break;
            }
        }
        ptr.ref = null;
    }

    pub fn __dtor(L: *VM.lua.State, ptr: *LuaStatement) void {
        ptr.close(L);
    }
};

const LuaDatabase = struct {
    db: sqlite.Database,
    statements: std.ArrayList(i32),
    closed: bool = false,

    const TransactionKind = enum {
        None,
        Deferred,
        Immediate,
        Exclusive,
    };
    const TransactionMap = std.StaticStringMap(TransactionKind).initComptime(.{
        .{ "deferred", .Deferred },
        .{ "immediate", .Immediate },
        .{ "exclusive", .Exclusive },
    });

    const Transaction = struct {
        ptr: *LuaDatabase,
        state: Scheduler.ThreadRef,
    };

    pub fn transactionResumed(ctx: *Transaction, L: *VM.lua.State, _: *Scheduler) void {
        const ptr = ctx.ptr;
        const command = switch (L.status()) {
            .Ok => "COMMIT",
            else => "ROLLBACK",
        };
        const state = ctx.state.value;
        ptr.db.exec(command, &.{}) catch |err| {
            switch (err) {
                error.OutOfMemory => state.pushstring(@errorName(err)) catch |e| std.debug.panic("{}", .{e}),
                else => state.pushfstring("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }) catch |e| std.debug.panic("{}", .{e}),
            }
            _ = Scheduler.resumeStateError(state, null) catch {};
            return;
        };
        if (L.status() != .Ok) {
            L.xpush(state, 1);
            _ = Scheduler.resumeStateError(state, null) catch {};
        } else {
            const results = L.gettop();
            L.xmove(state, @truncate(results));
            _ = Scheduler.resumeState(state, null, @intCast(results)) catch {};
        }
    }

    pub fn transactionResumedDtor(ctx: *Transaction, L: *VM.lua.State, _: *Scheduler) void {
        const allocator = luau.getallocator(L);
        defer allocator.destroy(ctx);
        defer ctx.state.deref();
    }

    pub fn lua_utransaction(L: *VM.lua.State) !i32 {
        if (!L.isyieldable())
            return L.Zyielderror();
        const scheduler = Scheduler.getScheduler(L);

        const ptr = L.touserdatatagged(LuaDatabase, VM.lua.upvalueindex(1), TAG_SQLITE_DATABASE) orelse unreachable;
        const kind: TransactionKind = @enumFromInt(L.tointeger(VM.lua.upvalueindex(3)) orelse unreachable);
        const activator = switch (kind) {
            .None => "BEGIN",
            .Deferred => "BEGIN DEFERRED",
            .Immediate => "BEGIN IMMEDIATE",
            .Exclusive => "BEGIN EXCLUSIVE",
        };
        ptr.db.exec(activator, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
        };
        const args = L.gettop();
        const ML = try L.newthread();
        L.xpush(ML, VM.lua.upvalueindex(2));
        if (args > 0)
            for (1..@intCast(args + 1)) |i| {
                L.xpush(ML, @intCast(i));
            };

        const status = Scheduler.resumeState(ML, L, @intCast(args)) catch |err| {
            ptr.db.exec("ROLLBACK", &.{}) catch |sql_err| switch (sql_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ sql_err, ptr.db.getErrorMessage() }),
            };
            switch (err) {
                error.Runtime => {
                    ML.xpush(L, -1);
                    return error.RaiseLuauError;
                },
                else => return err,
            }
        };

        if (status == .Yield) {
            const allocator = luau.getallocator(L);
            const data = try allocator.create(Transaction);
            data.* = .{
                .ptr = ptr,
                .state = .init(L),
            };
            scheduler.awaitResult(Transaction, data, ML, transactionResumed, transactionResumedDtor, .User);
            return L.yield(0);
        } else {
            ptr.db.exec("COMMIT", &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
        }
        const results = ML.gettop();
        ML.xmove(L, @truncate(results));
        return @intCast(results);
    }

    pub fn lua_query(self: *LuaDatabase, L: *VM.lua.State) !i32 {
        if (self.closed)
            return L.Zerror("database closed");
        const allocator = luau.getallocator(L);
        const query = try L.Zcheckvalue([]const u8, 2, null);
        try self.statements.ensureTotalCapacity(allocator, self.statements.items.len + 1);
        const statement = self.db.prepare(query) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidParameter => return L.Zerrorf("SQLite Query Error ({}): must have '$', ':', '?', or '@'", .{err}),
            else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, self.db.getErrorMessage() }),
        };
        const ptr = try L.newuserdatataggedwithmetatable(LuaStatement, TAG_SQLITE_STATEMENT);
        const ref = try L.ref(-1) orelse unreachable;
        self.statements.appendAssumeCapacity(ref);
        ptr.* = .{
            .db = self,
            .ref = ref,
            .statement = statement,
            .closed = false,
        };
        return 1;
    }

    pub fn lua_exec(self: *LuaDatabase, L: *VM.lua.State) !i32 {
        if (self.closed)
            return L.Zerror("database closed");
        const allocator = luau.getallocator(L);

        const query = try L.Zcheckvalue([]const u8, 2, null);

        var stmt = self.db.prepare(query) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidParameter => return L.Zerrorf("SQLite Query Error ({}): must have '$', ':', '?', or '@'", .{err}),
            else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, self.db.getErrorMessage() }),
        };
        defer stmt.deinit(allocator);

        var params: ?[]?sqlite.Value = null;
        defer if (params) |p| allocator.free(p);
        if (stmt.paramSize() > 0)
            params = try LuaStatement.loadParams(allocator, L, stmt, 3);

        stmt.exec(allocator, params orelse &.{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, self.db.getErrorMessage() }),
        };

        try L.Zpushvalue(.{
            .last_insert_row_id = @as(i32, @truncate(self.db.getLastInsertRowId())),
            .changes = @as(i32, @truncate(self.db.countChanges())),
        });

        return 1;
    }

    pub fn lua_transaction(_: *LuaDatabase, L: *VM.lua.State) !i32 {
        try L.Zchecktype(2, .Function);
        const kind_str = L.tostring(3);
        const kind: TransactionKind = if (kind_str) |str|
            TransactionMap.get(str) orelse return L.Zerrorf("unknown transaction kind: {s}.", .{str})
        else
            .None;
        L.pushvalue(1);
        L.pushvalue(2);
        L.pushinteger(@intFromEnum(kind));
        try L.pushcclosure(VM.zapi.toCFn(lua_utransaction), "Transaction", 3);
        return 1;
    }

    pub fn lua_close(self: *LuaDatabase, L: *VM.lua.State) !i32 {
        if (!L.Loptboolean(2, false)) {
            self.close(L) catch {};
        } else {
            self.close(L) catch {
                return L.Zerrorf("SQLite Error: {s}", .{self.db.getErrorMessage()});
            };
        }
        return 0;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaDatabase, TAG_SQLITE_DATABASE, .{
        .{ "query", lua_query },
        .{ "exec", lua_exec },
        .{ "transaction", lua_transaction },
        .{ "close", lua_close },
    });

    pub fn close(ptr: *LuaDatabase, L: *VM.lua.State) !void {
        if (ptr.closed)
            return;
        ptr.closed = true;
        const allocator = luau.getallocator(L);
        defer ptr.statements.deinit(allocator);
        try L.rawcheckstack(2);
        if (ptr.statements.items.len > 0) {
            var i = ptr.statements.items.len;
            while (i > 0) {
                i -= 1;
                const ref = ptr.statements.swapRemove(i);
                defer L.pop(1);
                if (L.rawgeti(VM.lua.REGISTRYINDEX, ref) != .Userdata)
                    continue;
                const stmt_ptr = L.touserdatatagged(LuaStatement, -1, TAG_SQLITE_STATEMENT) orelse continue;
                stmt_ptr.close(L);
            }
        }
        try ptr.db.close();
    }

    pub fn __dtor(L: *VM.lua.State, ptr: *LuaDatabase) void {
        ptr.close(L) catch {};
    }
};

fn sqlite_open(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    var db: sqlite.Database = undefined;
    if (L.tolstring(1)) |path| {
        db = if (std.mem.eql(u8, path, ":MEMORY:") or std.mem.eql(u8, path, ":memory:"))
            try sqlite.Database.open(allocator, .{})
        else
            try sqlite.Database.open(allocator, .{ .path = path });
    } else {
        db = try sqlite.Database.open(allocator, .{});
    }
    const ptr = try L.newuserdatataggedwithmetatable(LuaDatabase, TAG_SQLITE_DATABASE);
    ptr.* = .{
        .db = db,
        .statements = .empty,
    };
    return 1;
}

pub fn loadLib(L: *VM.lua.State) !void {
    {
        _ = try L.Znewmetatable(@typeName(LuaDatabase), .{
            .__metatable = "Metatable is locked",
            .__type = "SQLiteDatabase",
        });
        try LuaDatabase.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatadtor(LuaDatabase, TAG_SQLITE_DATABASE, LuaDatabase.__dtor);
        L.setuserdatametatable(TAG_SQLITE_DATABASE);
    }
    {
        _ = try L.Znewmetatable(@typeName(LuaStatement), .{
            .__index = LuaStatement.__index,
            .__namecall = LuaStatement.__namecall,
            .__metatable = "Metatable is locked",
            .__type = "SQLiteStatement",
        });
        L.setreadonly(-1, true);
        L.setuserdatadtor(LuaStatement, TAG_SQLITE_STATEMENT, LuaStatement.__dtor);
        L.setuserdatametatable(TAG_SQLITE_STATEMENT);
    }

    try L.Zpushvalue(.{
        .open = sqlite_open,
    });
    L.setreadonly(-1, true);

    try LuaHelper.registerModule(L, LIB_NAME);
}

test "sqlite" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/sqlite/init.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
