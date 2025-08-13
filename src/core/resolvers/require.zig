const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Debugger = Zune.Runtime.Debugger;

const File = Zune.Resolvers.File;
const Config = Zune.Resolvers.Config;
const Navigator = Zune.Resolvers.Navigator;

const VM = luau.VM;

const RequireError = error{
    ModuleNotFound,
    NoAlias,
};

const States = enum {
    Error,
    Waiting,
    Preloaded,
    Loaded,
};

const QueueItem = struct {
    state: Scheduler.ThreadRef,
};

const RequireItem = union(enum) {
    loading: void,
    @"error": void,
    loaded: void,
    yielded: std.ArrayListUnmanaged(QueueItem),
};

threadlocal var REQUIRE_MAP: std.StringHashMapUnmanaged(RequireItem) = .empty;

const RequireContext = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
};
fn require_finished(self: *RequireContext, ML: *VM.lua.State, _: *Scheduler) void {
    var outErr: ?[]const u8 = null;

    const queue = REQUIRE_MAP.getEntry(self.path) orelse std.debug.panic("require_finished: queue not found", .{});
    std.debug.assert(queue.value_ptr.* == .yielded);

    var free_path = false;

    if (ML.status() == .Ok) jmp: {
        const t = ML.gettop();
        if (t > 1 or t < 0) {
            outErr = "module must return one value";
            break :jmp;
        } else if (t == 0)
            ML.pushnil();
    } else outErr = "requested module failed to load";

    const GL = ML.mainthread();

    GL.rawcheckstack(2) catch |e| std.debug.panic("{}", .{e});

    var list = queue.value_ptr.*.yielded;

    if (outErr != null)
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
        defer self.allocator.free(self.path);
        _ = REQUIRE_MAP.remove(self.path);
    }

    for (list.items, 0..) |item, i| {
        const L = item.state.value;
        if (i == 0) {
            if (outErr) |msg| {
                L.pushlstring(msg) catch |e| std.debug.panic("{}", .{e});
                _ = Scheduler.resumeStateError(L, null) catch {};
                continue;
            }
        }
        if (outErr != null) {
            L.pushlstring("requested module failed to load") catch |e| std.debug.panic("{}", .{e});
            _ = Scheduler.resumeStateError(L, null) catch {};
        } else {
            ML.xpush(L, -1);
            _ = Scheduler.resumeState(L, null, 1) catch {};
        }
    }

    ML.pop(1);

    for (list.items) |*item|
        item.state.deref();
    list.deinit(Zune.DEFAULT_ALLOCATOR);
}

fn require_dtor(self: *RequireContext, _: *VM.lua.State, _: *Scheduler) void {
    const allocator = self.allocator;
    defer allocator.destroy(self);
}

const RequireNavigatorContext = struct {
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    const This = @This();

    pub fn getConfig(self: *This, path: []const u8, out_err: ?*?[]const u8) !Config {
        const allocator = self.allocator;

        if (Zune.STATE.CONFIG_CACHE.get(path)) |cached|
            return cached;

        const contents = if (Zune.STATE.BUNDLE) |*bundle|
            bundle.loadFileAlloc(allocator, path) catch |err| switch (err) {
                error.FileNotFound => return error.NotPresent,
                else => return err,
            }
        else
            self.dir.readFileAlloc(allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
                error.AccessDenied, error.FileNotFound => return error.NotPresent,
                else => return err,
            };
        defer allocator.free(contents);

        var config = try Config.parse(Zune.DEFAULT_ALLOCATOR, contents, out_err);
        errdefer config.deinit(Zune.DEFAULT_ALLOCATOR);

        const copy = try Zune.DEFAULT_ALLOCATOR.dupe(u8, path);
        errdefer Zune.DEFAULT_ALLOCATOR.free(copy);

        try Zune.STATE.CONFIG_CACHE.put(Zune.DEFAULT_ALLOCATOR, copy, config);

        return config;
    }
    pub fn freeConfig(_: *This, _: *Config) void {
        // the config is stored in cache.
    }
    pub fn resolvePathAlloc(_: *This, allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
        return try Zune.Resolvers.File.resolveBundled(allocator, Zune.STATE.ENV_MAP, &.{ from, to }, Zune.STATE.BUNDLE);
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
    dir: std.fs.Dir,
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
            error.SyntaxError, error.AliasNotFound, error.AliasPathNotSupported, error.AliasJumpFail => return L.Zerrorf("{s}", .{err_msg.?}),
            error.PathUnsupported => return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix"),
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

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        const writer = buf.writer(allocator);

        try writer.writeAll("module name conflicted.");

        const len = res.count;
        for (res.slice(), 1..) |entry, i| {
            if (len == i)
                try writer.writeAll("\n└─ ")
            else
                try writer.writeAll("\n├─ ");
            try writer.print("{s}{s}", .{ path, entry.ext });
        }

        try L.pushlstring(buf.items);
        return error.RaiseLuauError;
    }
}

pub fn zune_require(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const moduleName = L.Lcheckstring(1);

    const cwd = std.fs.cwd();

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
            .loading => return L.Zerror("Cyclic dependency detected"),
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

                try arr.append(Zune.DEFAULT_ALLOCATOR, .{
                    .state = Scheduler.ThreadRef.init(L),
                });
                return L.yield(0);
            },
        }
    }

    const module_src_buf: [:0]u8 = try allocator.allocSentinel(u8, 1 + script_path.len + File.LARGEST_EXTENSION.len, 0);
    defer allocator.free(module_src_buf);

    const search_result = blk: {
        errdefer allocator.free(script_path);

        std.debug.assert(script_path.len <= std.fs.max_path_bytes);

        module_src_buf[0] = '@';
        @memcpy(module_src_buf[1..][0..script_path.len], script_path);

        const input_buf = module_src_buf[1..][0 .. script_path.len + File.LARGEST_EXTENSION.len];
        const result = (if (Zune.STATE.BUNDLE) |*bundle|
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

    const extended = module_src_buf[1 + script_path.len ..];
    @memcpy(extended[0..file.ext.len], file.ext);
    extended[file.ext.len] = 0;

    const module_src: [:0]u8 = module_src_buf[0 .. 1 + script_path.len + file.ext.len :0];

    const entry = blk: {
        errdefer allocator.free(script_path);
        break :blk try REQUIRE_MAP.getOrPut(Zune.DEFAULT_ALLOCATOR, script_path);
    };

    entry.value_ptr.* = .loading;

    const GL = L.mainthread();
    const ML = try GL.newthread();
    GL.xmove(L, 1);
    {
        const file_content: []const u8 = switch (file.val) {
            .contents => |c| c,
            .handle => |h| h.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| {
                entry.value_ptr.* = .@"error";
                return L.Zerrorf("could not read file: {}", .{err});
            },
        };
        defer if (file.val == .handle) allocator.free(file_content);

        try ML.Lsandboxthread();

        try Engine.setLuaFileContext(ML, .{
            .source = if (Zune.STATE.BUNDLE == null or Zune.STATE.BUNDLE.?.mode.compiled == .debug) file_content else null,
            .main = false,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        if (Zune.STATE.BUNDLE == null or Zune.STATE.BUNDLE.?.mode.compiled == .debug) {
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

    switch (ML.resumethread(L, 0).check() catch |err| {
        Engine.logError(ML, err, false);
        if (Zune.Runtime.Debugger.ACTIVE) {
            @branchHint(.unpredictable);
            switch (err) {
                error.Runtime => Zune.Runtime.Debugger.luau_panic(ML, -2),
                else => {},
            }
        }
        L.pop(1); // drop: thread
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
                ML.pushnil();
        },
        .Yield => {
            {
                const ptr = try allocator.create(RequireContext);

                ptr.* = .{
                    .allocator = allocator,
                    .path = script_path,
                };

                scheduler.awaitResult(RequireContext, ptr, ML, require_finished, require_dtor, .Internal);
            }

            var list: std.ArrayListUnmanaged(QueueItem) = .empty;
            if (L.isyieldable())
                try list.append(Zune.DEFAULT_ALLOCATOR, .{
                    .state = Scheduler.ThreadRef.init(L),
                });

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
    } else entry.value_ptr.* = .loaded;

    return 1;
}

pub fn init(L: *VM.lua.State) !void {
    const allocator = luau.getallocator(L);

    REQUIRE_MAP = .empty;
    Navigator.PATH_ALLOCATOR = .init(try allocator.alloc(u8, (std.fs.max_path_bytes * 4) + 32));
}

pub fn deinit(L: *VM.lua.State) void {
    const allocator = luau.getallocator(L);

    allocator.free(Navigator.PATH_ALLOCATOR.buffer);

    var iter = REQUIRE_MAP.iterator();
    while (iter.next()) |entry|
        allocator.free(entry.key_ptr.*);
    REQUIRE_MAP.deinit(Zune.DEFAULT_ALLOCATOR);
}

pub fn load(L: *VM.lua.State) !void {
    try L.Zsetglobalfn("require", zune_require);
}

test "require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("engine/require.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
