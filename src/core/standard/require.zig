const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Config = Zune.Resolvers.Config;
const Navigator = Zune.Resolvers.Navigator;

const VM = luau.VM;

pub const LIB_NAME = "require";

const LuaContext = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    config: union(enum) {
        none,
        auto,
        forced: Config,
    },

    pub fn getConfig(self: *LuaContext, buf: []u8, path: []const u8, out_err: ?*?[]const u8) !Config {
        switch (self.config) {
            .forced => return self.config.forced,
            .none => return error.NotPresent,
            .auto => {},
        }

        const allocator = self.allocator;

        const Result = union(enum) {
            file: []const u8,
            script: []const u8,
        };

        const contents: Result = blk: {
            const luaurc_path = Navigator.getLuaurcPath(buf, path);
            const luaurc_file: ?std.Io.File = self.dir.openFile(Zune.io(), luaurc_path, .{
                .allow_directory = false,
            }) catch |err| switch (err) {
                error.AccessDenied, error.FileNotFound => null,
                error.IsDir => null,
                else => return err,
            };
            defer if (luaurc_file) |f| f.close(Zune.io());
            const config_luau_path = Navigator.getConfigLuauPath(buf, path);
            const config_luau_file: ?std.Io.File = self.dir.openFile(Zune.io(), config_luau_path, .{
                .allow_directory = false,
            }) catch |err| switch (err) {
                error.AccessDenied, error.FileNotFound => null,
                error.IsDir => null,
                else => return err,
            };
            defer if (config_luau_file) |f| f.close(Zune.io());

            if (luaurc_file != null and config_luau_file != null)
                return error.Ambiguous;

            const file = luaurc_file orelse config_luau_file orelse return error.NotPresent;
            const is_file = luaurc_file != null;

            var file_reader = file.reader(Zune.io(), &.{});
            const data = file_reader.interface.allocRemainingAlignedSentinel(allocator, .unlimited, .of(u8), null) catch |err| switch (err) {
                error.ReadFailed => return file_reader.err.?,
                error.OutOfMemory, error.StreamTooLong => |e| return e,
            };
            if (is_file)
                break :blk .{ .file = data }
            else
                break :blk .{ .script = data };
        };

        defer allocator.free(switch (contents) {
            .file => |b| b,
            .script => |b| b,
        });

        return switch (contents) {
            .file => |b| try Config.parse(allocator, b, out_err),
            .script => |b| blk: {
                var L = try luau.VM.lstate.Lnewstate();
                defer L.deinit();

                try L.Lopenlibs();
                try L.Lsandbox();

                luau.Compiler.Compiler.compileLoad(L, "=config", b, .{}, 0) catch {
                    if (out_err) |ptr_out| {
                        const err = L.tostring(-1) orelse "syntax error";
                        ptr_out.* = try allocator.dupe(u8, err);
                    }
                    return error.SyntaxError;
                };

                const time = std.Io.Clock.now(.awake, Zune.io()).addDuration(.fromMilliseconds(2000));
                L.userdata = @ptrCast(@alignCast(@constCast(&time)));
                L.callbacks().interrupt = struct {
                    fn interrupt(l: *VM.lua.State, _: c_int) callconv(.c) void {
                        const time_ptr: *const std.Io.Timestamp = @ptrCast(@alignCast(l.userdata));
                        const now = std.Io.Clock.now(.awake, Zune.io());
                        if (time_ptr.compare(.lte, now)) {
                            l.pushlstring("configuration execution timed out") catch @panic("OOM");
                            l.raiseerror();
                        }
                    }
                }.interrupt;

                switch (L.resumethread(null, 0)) {
                    .Ok => {},
                    .Break, .Yield => {
                        if (out_err) |ptr_out|
                            ptr_out.* = try allocator.dupe(u8, "configuration execution cannot yield");
                        return error.Runtime;
                    },
                    .ErrErr, .ErrRun => {
                        if (out_err) |ptr_out| {
                            const err = L.tostring(-1) orelse "bad config error type";
                            ptr_out.* = try allocator.dupe(u8, err);
                        }
                        return error.Runtime;
                    },
                    .ErrMem => {
                        if (out_err) |ptr_out|
                            ptr_out.* = try allocator.dupe(u8, "configuration out of memory error");
                        return error.Runtime;
                    },
                    .ErrSyntax => {
                        if (out_err) |ptr_out|
                            ptr_out.* = try allocator.dupe(u8, "configuration syntax error");
                        return error.SyntaxError;
                    },
                }

                if (L.gettop() != 1) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try allocator.dupe(u8, "configuration must return exactly one value");
                    return error.Runtime;
                }

                if (L.typeOf(-1) != .Table) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try allocator.dupe(u8, "configuration did not return a table");
                    return error.Runtime;
                }

                var config: Config = .{};
                errdefer config.deinit(Zune.DEFAULT_ALLOCATOR);

                const luau_type = L.rawgetfield(-1, "luau");
                if (luau_type.isnoneornil())
                    break :blk config;
                if (luau_type != .Table) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try allocator.dupe(u8, "configuration 'luau' must be a table");
                    return error.Runtime;
                }

                const aliases_type = L.rawgetfield(-1, "aliases");
                if (aliases_type.isnoneornil())
                    break :blk config;
                if (aliases_type != .Table) {
                    if (out_err) |ptr_out|
                        ptr_out.* = try allocator.dupe(u8, "configuration 'aliases' must be a table");
                    return error.Runtime;
                }

                var iter: Scripting.TableIterator = .{ .L = L, .idx = -1 };
                while (iter.next()) |key_type| {
                    switch (key_type) {
                        .String => {
                            const alias = L.tostring(-2).?;
                            if (L.typeOf(-1) != .String) {
                                if (out_err) |ptr_out|
                                    ptr_out.* = try std.fmt.allocPrint(allocator, "configuration 'aliases.{s}' value must be a string", .{alias});
                                return error.Runtime;
                            }
                            if (!Config.isValidAlias(alias)) {
                                if (out_err) |ptr_out|
                                    ptr_out.* = try std.fmt.allocPrint(allocator, "invalid alias '{s}'", .{alias});
                                return error.Runtime;
                            }
                            const value_str = L.tostring(-1).?;
                            const key = try std.ascii.allocLowerString(allocator, alias);
                            errdefer allocator.free(key);
                            const copy = try allocator.dupe(u8, value_str);
                            errdefer allocator.free(copy);
                            const result = try config.aliases.getOrPut(allocator, key);
                            if (result.found_existing) {
                                defer allocator.free(key);
                                allocator.free(result.value_ptr.*);
                            }
                            result.value_ptr.* = copy;
                        },
                        else => {},
                    }
                }

                break :blk config;
            },
        };
    }
    pub fn freeConfig(self: *LuaContext, config: *Config) void {
        if (self.config == .auto)
            config.deinit(self.allocator);
    }
    pub fn resolvePathAlloc(_: *LuaContext, a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
        return std.fs.path.resolve(a, &.{ from, to });
    }
};

pub fn lua_navigate(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();

    const path = try L.Zcheckvalue([]const u8, 1, null);
    const from = try L.Zcheckvalue(?[]const u8, 2, null);

    var context: LuaContext = .{
        .config = .auto,
        .dir = .cwd(),
        .allocator = allocator,
    };

    defer switch (context.config) {
        .forced => |*forced| forced.deinit(allocator),
        .none, .auto => {},
    };

    switch (L.typeOf(3)) {
        .None, .Nil => {},
        .Number => {
            const value = L.tounsigned(3) orelse return L.Zerror("configuration mode must be an unsigned number");
            if (value == 0)
                context.config = .none
            else
                context.config = .auto;
        },
        .Table => {
            context.config = .{
                .forced = blk: {
                    var config: Config = .{};
                    errdefer config.deinit(allocator);

                    const luau_type = L.rawgetfield(3, "luau");
                    if (luau_type.isnoneornil())
                        break :blk config;
                    if (luau_type != .Table) {
                        return L.Zerror("configuration 'luau' must be a table");
                    }

                    const aliases_type = L.rawgetfield(-1, "aliases");
                    if (aliases_type.isnoneornil())
                        break :blk config;
                    if (aliases_type != .Table) {
                        return L.Zerror("configuration 'aliases' must be a table");
                    }

                    var iter: Scripting.TableIterator = .{ .L = L, .idx = -1 };
                    while (iter.next()) |key_type| {
                        switch (key_type) {
                            .String => {
                                const alias = L.tostring(-2).?;
                                if (L.typeOf(-1) != .String) {
                                    return L.Zerrorf("configuration 'aliases.{s}' value must be a string", .{alias});
                                }
                                if (!Zune.Resolvers.Config.isValidAlias(alias)) {
                                    return L.Zerrorf("invalid alias '{s}'", .{alias});
                                }
                                const value_str = L.tostring(-1).?;
                                const key = try std.ascii.allocLowerString(allocator, alias);
                                errdefer allocator.free(key);
                                const copy = try allocator.dupe(u8, value_str);
                                errdefer allocator.free(copy);
                                const result = try config.aliases.getOrPut(allocator, key);
                                if (result.found_existing) {
                                    defer allocator.free(key);
                                    allocator.free(result.value_ptr.*);
                                }
                                result.value_ptr.* = copy;
                            },
                            else => {},
                        }
                    }

                    break :blk config;
                },
            };
        },
        else => return L.Zerror("configuration must be a number or table"),
    }

    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    {
        var level: i32 = 1;
        while (true) : (level += 1) {
            if (!L.getinfo(level, "s", &ar))
                return L.Zerror("could not get source");
            if (ar.what == .lua)
                break;
        }
    }

    const src = from orelse blk: {
        const ctx = ar.source orelse return error.BadContext;
        if (std.mem.startsWith(u8, ctx, "@")) {
            break :blk ctx[1..];
        } else break :blk ctx;
    };

    var err_msg: ?[]const u8 = null;
    defer if (err_msg) |msg| allocator.free(msg);
    const script_path = Zune.Resolvers.Navigator.navigate(allocator, &context, src, path, &err_msg) catch |err| switch (err) {
        error.SyntaxError, error.AliasNotFound, error.AliasPathNotSupported, error.AliasJumpFail => return L.Zerrorf("{s}", .{err_msg.?}),
        error.PathUnsupported => return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix"),
        else => return err,
    };
    defer allocator.free(script_path);

    try L.pushlstring(script_path);

    return 1;
}

pub fn lua_getCached(L: *VM.lua.State) !i32 {
    const resolved_path = try L.Zcheckvalue([:0]const u8, 1, null);
    _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);

    _ = L.rawgetfield(-1, resolved_path);
    return 1;
}
