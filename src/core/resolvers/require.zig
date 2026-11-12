const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Debugger = Zune.Runtime.Debugger;
const Scripting = Zune.Runtime.Scripting;

const File = Zune.Resolvers.File;
const Config = Zune.Resolvers.Config;
const Navigator = Zune.Resolvers.Navigator;

const VM = luau.VM;

const RequireItem = union(enum) {
    loading: void,
    @"error": void,
    loaded: void,
    yielded: std.ArrayList(Scheduler.ThreadRef),
};

threadlocal var REQUIRE_MAP: std.hash_map.StringHashMapUnmanaged(RequireItem) = .empty;
threadlocal var CONFIG_CACHE: std.hash_map.StringHashMapUnmanaged(Config) = .empty;

const RequireContext = struct {
    path: []const u8,
};
fn require_finished(self: *RequireContext, ML: *VM.lua.State, scheduler: *Scheduler) void {
    var out_err: ?[]const u8 = null;
    const allocator = scheduler.allocator();
    defer allocator.destroy(self);

    const queue = REQUIRE_MAP.getEntry(self.path) orelse std.debug.panic("require_finished: queue not found", .{});
    std.debug.assert(queue.value_ptr.* == .yielded);

    var free_path = false;

    if (ML.status() == .Ok) jmp: {
        const t = ML.gettop();
        if (t > 1 or t < 0) {
            out_err = "module must return one value";
            break :jmp;
        } else if (t == 0)
            ML.pushnil();
    } else out_err = "requested module failed to load";

    const GL = ML.mainthread();

    GL.rawcheckstack(2) catch |e| std.debug.panic("{}", .{e});

    var list = queue.value_ptr.*.yielded;

    if (out_err != null)
        queue.value_ptr.* = .@"error"
    else {
        _ = GL.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1) catch |e| std.debug.panic("{}", .{e});
        ML.xpush(GL, -1);
        if (GL.typeOf(-1) != .Nil) {
            free_path = true;
            GL.rawsetfield(-2, self.path) catch |e| std.debug.panic("{}", .{e}); // SET: _MODULES[moduleName] = module
        } else {
            GL.pop(1); // drop: nil
            queue.value_ptr.* = .loaded;
        }
        GL.pop(1); // drop: _MODULES
    }

    if (free_path) {
        defer allocator.free(self.path);
        _ = REQUIRE_MAP.remove(self.path);
    }

    for (list.items, 0..) |item, i| {
        const L = item.value;
        if (L.status() != .Yield)
            continue;
        if (i == 0) {
            if (out_err) |msg| {
                L.pushlstring(msg) catch |e| std.debug.panic("{}", .{e});
                _ = Scheduler.resumeStateErrorFast(L, null) catch {};
                continue;
            }
        }
        if (out_err != null) {
            L.pushlstring("requested module failed to load") catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeStateErrorFast(L, null) catch {};
        } else {
            ML.xpush(L, -1);
            _ = Scheduler.resumeStateFast(L, null, 1) catch {};
        }
    }

    ML.pop(1);

    for (list.items) |*item|
        item.deref();
    list.deinit(Zune.DEFAULT_ALLOCATOR);
}

const RequireNavigatorContext = struct {
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,

    const This = @This();

    pub fn getConfig(self: *This, buf: []u8, path: []const u8, out_err: ?*?[]const u8) !Config {
        const allocator = self.allocator;

        if (CONFIG_CACHE.get(path)) |cached|
            return cached;

        const Result = union(enum) {
            file: []const u8,
            script: []const u8,
        };

        const contents: Result = blk: {
            const luaurc_path = Navigator.getLuaurcPath(buf, path);
            if (Zune.State.bundle) |*bundle| {
                const luaurc_key = Zune.Resolvers.Bundle.Map.shortResolve(luaurc_path);
                const key = if (bundle.map.contains(luaurc_key)) luaurc_key else alt: {
                    const config_luau_path = Navigator.getConfigLuauPath(buf, path);
                    const config_key = Zune.Resolvers.Bundle.Map.shortResolve(config_luau_path);
                    if (!bundle.map.contains(config_key))
                        return error.NotPresent;
                    break :alt config_key;
                };
                const bytes = try bundle.load(key);
                break :blk switch (bundle.map.get(key).?) {
                    .file => .{ .file = bytes },
                    .script => .{ .script = bytes },
                };
            }
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

        defer if (Zune.State.bundle == null)
            allocator.free(switch (contents) {
                .file => |b| b,
                .script => |b| b,
            });

        var config = switch (contents) {
            .file => |b| try Config.parse(Zune.DEFAULT_ALLOCATOR, b, out_err),
            .script => |b| blk: {
                const gpa = Zune.DEFAULT_ALLOCATOR;

                var L = try luau.VM.lstate.Lnewstate();
                defer L.deinit();

                try L.Lopenlibs();
                try L.Lsandbox();

                const compileOptions: luau.CompileOptions = .{};

                if (Zune.State.bundle == null or Zune.State.bundle.?.mode.compiled == .debug) {
                    luau.Compiler.Compiler.compileLoad(L, "=config", b, compileOptions, 0) catch {
                        if (out_err) |ptr_out| {
                            const err = L.tostring(-1) orelse "syntax error";
                            ptr_out.* = try allocator.dupe(u8, err);
                        }
                        return error.SyntaxError;
                    };
                } else {
                    L.load("=config", b, 0) catch unreachable; // should not error
                }

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
                            const key = try std.ascii.allocLowerString(gpa, alias);
                            errdefer gpa.free(key);
                            const copy = try gpa.dupe(u8, value_str);
                            errdefer gpa.free(copy);
                            const result = try config.aliases.getOrPut(gpa, key);
                            if (result.found_existing) {
                                defer gpa.free(key);
                                gpa.free(result.value_ptr.*);
                            }
                            result.value_ptr.* = copy;
                        },
                        else => {},
                    }
                }

                break :blk config;
            },
        };
        errdefer config.deinit(Zune.DEFAULT_ALLOCATOR);

        const copy = try Zune.DEFAULT_ALLOCATOR.dupe(u8, path);
        errdefer Zune.DEFAULT_ALLOCATOR.free(copy);

        try CONFIG_CACHE.put(Zune.DEFAULT_ALLOCATOR, copy, config);

        return config;
    }
    pub fn freeConfig(_: *This, _: *Config) void {
        // the config is stored in cache.
    }
    pub fn resolvePathAlloc(_: *This, allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
        return try Zune.Resolvers.File.resolveBundled(allocator, Zune.State.env_map, &.{ from, to }, Zune.State.bundle);
    }
};

pub fn getFilePath(source: ?[]const u8) []const u8 {
    if (source) |src|
        if (src.len > 0 and src[0] == '@') {
            const path = src[1..];
            return path;
        };
    return ".";
}

pub fn resolveScriptPath(
    allocator: std.mem.Allocator,
    L: *VM.lua.State,
    moduleName: []const u8,
    dir: std.Io.Dir,
) ![]const u8 {
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

    return blk: {
        var nav_context: RequireNavigatorContext = .{
            .dir = dir,
            .allocator = allocator,
        };

        var err_msg: ?[]const u8 = null;
        defer if (err_msg) |err| allocator.free(err);
        break :blk Navigator.navigate(allocator, &nav_context, getFilePath(ar.source), moduleName, &err_msg) catch |err| switch (err) {
            error.SyntaxError,
            error.AliasNotFound,
            error.AliasPathNotSupported,
            error.AliasJumpFail,
            error.Runtime,
            error.Ambiguous,
            => return L.Zerrorf("{s}", .{err_msg.?}),
            error.PathUnsupported => return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix"),
            error.HomeDirNotFound => return L.Zerror("alias could not resolve home directory"),
            error.NotAllowed => return L.Zerror("not allowed"),
            else => return err,
        };
    };
}

pub fn checkSearchResult(
    allocator: std.mem.Allocator,
    L: *VM.lua.State,
    path: []const u8,
    res: File.SearchResult,
) !void {
    if (res.count == 0)
        return L.Zerrorf("module not found: \"{s}\"", .{path});

    if (res.count > 1) {
        @branchHint(.unlikely);

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();

        const writer = &buf.writer;

        try writer.writeAll("module name conflicted.");

        const len = res.count;
        for (res.slice(), 1..) |entry, i| {
            if (len == i)
                try writer.writeAll("\n└─ ")
            else
                try writer.writeAll("\n├─ ");
            try writer.print("{s}{s}", .{ path, entry.ext.ext });
        }

        try L.pushlstring(buf.written());
        return error.RaiseLuauError;
    }
}

pub fn zune_require(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.fromState(L);
    const allocator = scheduler.allocator();

    const moduleName = L.Lcheckstring(1);

    const cwd = std.Io.Dir.cwd();

    const script_path = try resolveScriptPath(allocator, L, moduleName, cwd);
    jmp: {
        errdefer allocator.free(script_path);
        _ = try L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);
        const res = REQUIRE_MAP.getEntry(script_path) orelse {
            switch (L.rawgetfield(-1, script_path)) {
                .Nil => {},
                else => {
                    defer allocator.free(script_path);
                    return 1;
                },
            }
            L.pop(1); // drop: nil
            break :jmp;
        };
        switch (res.value_ptr.*) {
            .loading => return L.Zerror("cyclic dependency detected"),
            .@"error" => return L.Zerror("requested module failed to load"),
            .loaded => {
                defer allocator.free(script_path);
                L.pushnil(); // return nil
                return 1;
            },
            .yielded => |*arr| {
                defer allocator.free(script_path);
                if (!L.isyieldable())
                    return L.Zyielderror();

                try arr.append(Zune.DEFAULT_ALLOCATOR, .init(L));
                return L.yield(0);
            },
        }
    }

    const module_src_buf: [:0]u8 = try allocator.allocSentinel(u8, 1 + script_path.len + File.LARGEST_EXTENSION.len, 0);
    defer allocator.free(module_src_buf);

    const search_result = blk: {
        errdefer allocator.free(script_path);

        std.debug.assert(script_path.len <= std.Io.Dir.max_path_bytes);

        module_src_buf[0] = '@';
        @memcpy(module_src_buf[1..][0..script_path.len], script_path);

        const input_buf = module_src_buf[1..][0 .. script_path.len + File.LARGEST_EXTENSION.len];
        const result = (if (Zune.State.bundle) |*bundle|
            File.searchLuauFileBundle(input_buf, bundle, script_path)
        else
            File.searchLuauFile(input_buf, cwd, script_path)) catch |err| switch (err) {
            error.RedundantFileExtension => return L.Zerrorf("redundant file extension, remove '{s}'", .{std.fs.path.extension(script_path)}),
            else => return err,
        };
        errdefer result.deinit();

        try checkSearchResult(allocator, L, script_path, result);

        break :blk result;
    };
    defer search_result.deinit();

    const file = search_result.first();

    if (file.ext.type == .Luau and std.mem.eql(u8, std.fs.path.basename(script_path), ".config")) {
        return L.Zerror("cannot require configuration file");
    }

    const extended = module_src_buf[1 + script_path.len ..];
    @memcpy(extended[0..file.ext.ext.len], file.ext.ext);
    extended[file.ext.ext.len] = 0;

    const module_src: [:0]u8 = module_src_buf[0 .. 1 + script_path.len + file.ext.ext.len :0];

    var entry: @TypeOf(REQUIRE_MAP).Entry = blk: {
        errdefer allocator.free(script_path);
        const result = try REQUIRE_MAP.getOrPut(Zune.DEFAULT_ALLOCATOR, script_path);
        break :blk .{
            .key_ptr = result.key_ptr,
            .value_ptr = result.value_ptr,
        };
    };

    entry.value_ptr.* = .loading;

    const GL = L.mainthread();
    const ML = try GL.newthread();
    GL.xmove(L, 1);
    {
        const file_content: []const u8 = switch (file.val) {
            .contents => |c| c,
            .handle => |h| blk: {
                var reader = h.reader(Zune.io(), &.{});
                break :blk reader.interface.allocRemaining(allocator, .unlimited) catch |err| {
                    entry.value_ptr.* = .@"error";
                    return L.Zerrorf("could not read file: {}", .{err});
                };
            },
        };
        defer if (file.val == .handle) allocator.free(file_content);

        try ML.Lsandboxthread();

        try Engine.setLuaFileContext(ML, .{
            .main = false,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        if (Zune.State.bundle == null or Zune.State.bundle.?.mode.compiled == .debug) {
            @branchHint(.likely);
            Engine.loadModule(ML, module_src, file_content, null) catch |err| switch (err) {
                error.Syntax => {
                    L.pop(1); // drop: thread
                    entry.value_ptr.* = .@"error";
                    return L.Zerror(ML.tostring(-1) orelse "UnknownError");
                },
            };
        } else {
            ML.load(module_src, file_content, 0) catch unreachable; // should not error
            Engine.loadNative(ML);
        }
    }

    switch (Scheduler.resumeStateFast(ML, L, 0) catch {
        L.pop(1); // drop: thread
        entry = REQUIRE_MAP.getEntry(script_path) orelse unreachable;
        entry.value_ptr.* = .@"error";
        return L.Zerror("requested module failed to load");
    }) {
        .Ok => {
            const t = ML.gettop();
            if (t > 1) {
                L.pop(1); // drop: thread
                entry.value_ptr.* = .@"error";
                return L.Zerror("module must return one value");
            } else if (t == 0)
                return L.Zerror("module did not exactly return one value");
        },
        .Yield => {
            {
                const ptr = try allocator.create(RequireContext);

                ptr.* = .{
                    .path = script_path,
                };

                scheduler.awaitResult(RequireContext, ptr, ML, require_finished, .Internal);
            }

            var list: std.ArrayList(Scheduler.ThreadRef) = .empty;
            if (L.isyieldable())
                try list.append(Zune.DEFAULT_ALLOCATOR, .init(L));

            entry = REQUIRE_MAP.getEntry(script_path) orelse unreachable;

            entry = REQUIRE_MAP.getEntry(script_path) orelse unreachable;
            entry.value_ptr.* = .{ .yielded = list };

            if (!L.isyieldable())
                return L.Zyielderror();
            return L.yield(0);
        },
        else => unreachable,
    }

    ML.xmove(L, 1);
    if (L.typeOf(-1) != .Nil) {
        defer allocator.free(script_path);
        _ = REQUIRE_MAP.remove(script_path);
        L.pushvalue(-1);
        try L.rawsetfield(-4, script_path); // SET: _MODULES[moduleName] = module
    } else {
        entry = REQUIRE_MAP.getEntry(script_path) orelse unreachable;
        entry.value_ptr.* = .loaded;
    }

    return 1;
}

pub fn init(allocator: std.mem.Allocator) !void {
    REQUIRE_MAP = .empty;
    CONFIG_CACHE = .empty;
    Navigator.PATH_ALLOCATOR = .init(try allocator.alloc(u8, (std.Io.Dir.max_path_bytes * 4) + 32));
}

pub fn deinit(allocator: std.mem.Allocator) void {
    allocator.free(Navigator.PATH_ALLOCATOR.buffer);

    {
        var iter = CONFIG_CACHE.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        CONFIG_CACHE.deinit(Zune.DEFAULT_ALLOCATOR);
    }
    {
        var iter = REQUIRE_MAP.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
        REQUIRE_MAP.deinit(Zune.DEFAULT_ALLOCATOR);
    }
}

pub fn load(L: *VM.lua.State) !void {
    try L.Zsetglobalfn("require", Scripting.toCFn(zune_require));
}
