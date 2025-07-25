const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const command = @import("lib.zig");

const Glob = Zune.glob;

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Debugger = Zune.Runtime.Debugger;
const Profiler = Zune.Runtime.Profiler;

const File = Zune.Resolvers.File;
const Bundle = Zune.Resolvers.Bundle;

fn getFile(allocator: std.mem.Allocator, dir: std.fs.Dir, input: []const u8) !struct { []u8, []const u8 } {
    var maybe_src: ?[]u8 = null;
    errdefer if (maybe_src) |s| allocator.free(s);
    var maybe_content: ?[]const u8 = null;
    errdefer if (maybe_content) |c| allocator.free(c);

    const path = try File.resolve(allocator, Zune.STATE.ENV_MAP, &.{input});
    defer allocator.free(path);
    if (dir.readFileAlloc(allocator, path, std.math.maxInt(usize)) catch null) |content| {
        maybe_content = content;
        maybe_src = try std.mem.concat(allocator, u8, &.{ "@", path });
    } else {
        const result = File.findLuauFile(dir, path) catch |err| switch (err) {
            error.RedundantFileExtension => return error.FileNotFound,
            else => return err,
        } orelse return error.FileNotFound;
        maybe_content = try result.val.handle.readToEndAlloc(allocator, std.math.maxInt(usize));
        maybe_src = try std.mem.concat(allocator, u8, &.{ "@", path, result.ext });
    }

    return .{ maybe_src.?, maybe_content.? };
}

fn splitArgs(args: []const []const u8) struct { []const []const u8, ?[]const []const u8 } {
    var run_args: []const []const u8 = args;
    var flags: ?[]const []const u8 = null;
    blk: {
        for (args, 0..) |arg, ap| {
            if (arg.len <= 1 or arg[0] != '-') {
                if (ap > 0)
                    flags = args[0..ap];
                run_args = args[ap..];
                break :blk;
            }
        }
        flags = args;
        run_args = &[0][]const u8{};
        break :blk;
    }
    return .{ run_args, flags };
}

const ScanOptions = struct {
    glob: []const u8,
    kind: enum { script, file } = .script,
};

fn scanDir(
    allocator: std.mem.Allocator,
    map: *std.StringArrayHashMapUnmanaged(void),
    dir: std.fs.Dir,
    opts: ScanOptions,
    path: []const u8,
) !void {
    var iter = dir.iterate();
    const recursive = std.mem.indexOf(u8, opts.glob, "**") != null;
    while (try iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        errdefer allocator.free(entry_path);
        blk: switch (entry.kind) {
            .file => {
                if (!Glob.match(opts.glob, entry_path).matches())
                    break :blk;
                if (opts.kind == .script and File.getLuaFileType(entry.name) == null)
                    break :blk;
                if (try map.fetchPut(allocator, entry_path, undefined)) |key_entry|
                    allocator.free(key_entry.key);
                continue;
            },
            .directory => {
                if (!recursive)
                    break :blk;
                var entry_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer entry_dir.close();
                try scanDir(allocator, map, entry_dir, opts, entry_path);
            },
            else => {},
        }
        allocator.free(entry_path);
    }
}

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const bundle_args, const flags = splitArgs(args);

    if (bundle_args.len < 1) {
        std.debug.print("Usage: bundle [flags] <luau file> [...luau files]\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    const home_dir = File.getHomeDir(Zune.STATE.ENV_MAP) orelse "";

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    const module = bundle_args[0];

    const cwd_path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const entry_file, const contents = try getFile(allocator, dir, module);
    defer allocator.free(entry_file);
    defer allocator.free(contents);

    const file_path = entry_file[1..];

    var SCRIPTS: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer SCRIPTS.deinit(allocator);
    defer for (SCRIPTS.keys()) |script| allocator.free(script);
    var FILES: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer FILES.deinit(allocator);
    defer for (FILES.keys()) |file| allocator.free(file);

    const abs_entry_file = try std.fs.path.resolve(allocator, &.{ cwd_path, file_path });
    {
        errdefer allocator.free(abs_entry_file);
        try SCRIPTS.put(allocator, abs_entry_file, undefined);
    }

    for (bundle_args[1..]) |arg| {
        const glob = try std.fs.path.resolve(allocator, &.{ cwd_path, arg });
        if (std.mem.indexOfScalar(u8, glob, '*')) |i| {
            if (comptime builtin.os.tag == .windows)
                std.mem.replaceScalar(u8, glob, '\\', '/');
            defer allocator.free(glob);
            var d = if (i > 0) try dir.openDir(glob[0..i], .{ .iterate = true }) else dir;
            defer if (i > 0) d.close();
            try scanDir(allocator, &SCRIPTS, d, .{
                .glob = glob,
                .kind = .script,
            }, glob[0..i]);
        } else {
            errdefer allocator.free(glob);
            if (try SCRIPTS.fetchPut(allocator, glob, undefined)) |key_entry|
                allocator.free(key_entry.key);
        }
    }

    var BUILD_MODE: enum(u1) { debug, release } = .debug;
    var OUTPUT: union(enum) {
        stdout: void,
        path: []const u8,
        default: []const u8,
    } = .{ .default = std.fs.path.stem(file_path) };
    var LOAD_FLAGS: Zune.Flags = .{};
    if (flags) |f| for (f) |flag| {
        if (flag.len < 2)
            continue;
        switch (flag[0]) {
            '-' => switch (flag[1]) {
                'O' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                    const level: u2 = switch (flag[2]) {
                        '0' => 0,
                        '1' => 1,
                        '2' => 2,
                        else => unreachable,
                    };
                    Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = level;
                } else {
                    std.debug.print("Flag: -O, Invalid Optimization level, usage: -O<N>\n", .{});
                    std.process.exit(1);
                },
                'g' => {
                    if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                        const level: u2 = switch (flag[2]) {
                            '0' => 0,
                            '1' => 1,
                            '2' => 2,
                            else => unreachable,
                        };
                        Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL = level;
                    } else {
                        std.debug.print("Flag: -g, Invalid Debug level, usage: -g<N>\n", .{});
                        std.process.exit(1);
                    }
                },
                '-' => if (std.mem.eql(u8, flag, "--native")) {
                    Zune.STATE.LUAU_OPTIONS.CODEGEN = true;
                } else if (std.mem.eql(u8, flag, "--no-native")) {
                    Zune.STATE.LUAU_OPTIONS.CODEGEN = false;
                } else if (std.mem.eql(u8, flag, "--no-jit")) {
                    Zune.STATE.LUAU_OPTIONS.JIT_ENABLED = false;
                } else if (std.mem.eql(u8, flag, "--limbo")) {
                    LOAD_FLAGS.limbo = true;
                } else if (std.mem.eql(u8, flag, "--release")) {
                    BUILD_MODE = .release;
                } else if (std.mem.eql(u8, flag, "--debug")) {
                    BUILD_MODE = .debug;
                } else if (std.mem.startsWith(u8, flag, "--out=") and flag.len > 6) {
                    OUTPUT = .{ .path = flag[6..] };
                } else if (std.mem.startsWith(u8, flag, "--files=") and flag.len > 8) {
                    const glob = try std.fs.path.resolve(allocator, &.{ cwd_path, flag[8..] });
                    if (std.mem.indexOfScalar(u8, glob, '*')) |i| {
                        if (comptime builtin.os.tag == .windows)
                            std.mem.replaceScalar(u8, glob, '\\', '/');
                        defer allocator.free(glob);
                        var d = if (i > 0) try dir.openDir(glob[0..i], .{ .iterate = true }) else dir;
                        defer if (i > 0) d.close();
                        try scanDir(allocator, &FILES, d, .{
                            .glob = glob,
                            .kind = .file,
                        }, glob[0..i]);
                    } else {
                        errdefer allocator.free(glob);
                        if (try FILES.fetchPut(allocator, glob, undefined)) |key_entry|
                            allocator.free(key_entry.key);
                    }
                },
                else => {
                    std.debug.print("Unknown flag: {s}\n", .{flag});
                    std.process.exit(1);
                },
            },
            else => unreachable,
        }
    };

    const exe = try std.fs.openSelfExe(.{ .mode = .read_only });
    defer exe.close();

    const zune_build = try exe.readToEndAlloc(allocator, std.math.maxInt(usize));
    const zune_build_len = zune_build.len;

    var bundled_bytes: std.ArrayListUnmanaged(u8) = .{ .capacity = zune_build_len, .items = zune_build };
    defer bundled_bytes.deinit(allocator);

    const writer = bundled_bytes.writer(allocator);

    try Bundle.PackedState.write(writer, .{
        .mode = .{
            .compiled = @enumFromInt(@intFromEnum(BUILD_MODE)),
            .limbo = LOAD_FLAGS.limbo,
        },
        .format = .{
            .use_color = Zune.STATE.FORMAT.USE_COLOR,
            .max_depth = Zune.STATE.FORMAT.MAX_DEPTH,
            .show_table_address = Zune.STATE.FORMAT.SHOW_TABLE_ADDRESS,
            .show_recursive_table = Zune.STATE.FORMAT.SHOW_RECURSIVE_TABLE,
            .display_buffer_contents_max = Zune.STATE.FORMAT.DISPLAY_BUFFER_CONTENTS_MAX,
        },
        .luau = .{
            .codegen = Zune.STATE.LUAU_OPTIONS.CODEGEN,
            .jit_enabled = Zune.STATE.LUAU_OPTIONS.JIT_ENABLED,
            .optimization_level = Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
            .debug_level = Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL,
        },
    });

    var features: Bundle.Features = .{};
    inline for (@typeInfo(@TypeOf(Zune.FEATURES)).@"struct".fields) |field|
        @field(features, field.name) = @field(Zune.FEATURES, field.name);

    try Bundle.Features.write(writer, features);

    {
        const home_relative = if (home_dir.len > 0) try std.fs.path.relative(allocator, cwd_path, home_dir) else "";
        defer allocator.free(home_relative);
        if (std.mem.indexOfAny(u8, home_relative, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") != null) {
            Zune.debug.print("<yellow>Warning<clear>: resolved home directory relative path '{s}' contains normal characters\n", .{home_relative});
            Zune.debug.print("The bundled application may contain unwanted path names\n", .{});
        }
        try writer.writeInt(u16, @intCast(home_relative.len), .big);
        try writer.writeAll(home_relative);
    }

    for (SCRIPTS.keys()) |script| {
        const name = try std.fs.path.relative(allocator, cwd_path, script);
        defer allocator.free(name);
        const script_contents = try std.fs.cwd().readFileAlloc(allocator, script, std.math.maxInt(usize));
        defer allocator.free(script_contents);
        const bytecode = try luau.Compiler.luacode.compile(allocator, script_contents, .{
            .optimizationLevel = Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
            .debugLevel = Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL,
        });
        defer allocator.free(bytecode);
        if (bytecode[0] == 0) {
            Zune.debug.print("<red>CompileError<clear>: {s}{s}\n", .{ script, bytecode[1..] });
            std.process.exit(1);
        }
        switch (BUILD_MODE) {
            .debug => try Bundle.Section.writeScript(writer, name, script_contents),
            .release => try Bundle.Section.writeScript(writer, name, bytecode),
        }
    }

    for (FILES.keys()) |file| {
        if (SCRIPTS.get(file)) |_| {
            Zune.debug.print("<yellow>Warning<clear>: attempted to bundle an existing script '{s}' as file, skipping...\n", .{file});
            continue;
        }
        const name = try std.fs.path.relative(allocator, cwd_path, file);
        defer allocator.free(name);
        const file_contents = try std.fs.cwd().readFileAlloc(allocator, file, std.math.maxInt(usize));
        defer allocator.free(file_contents);
        try Bundle.Section.writeFile(allocator, writer, name, file_contents, .none);
    }

    const sections = SCRIPTS.keys().len + FILES.keys().len;
    std.debug.assert(sections > 0);

    if (sections > Bundle.ExeHeader.maxValue(.sections))
        return error.TooManyEmbeddedContent;

    const bundled = bundled_bytes.items[zune_build_len..];
    if (bundled.len > Bundle.ExeHeader.maxValue(.size))
        return error.BundleTooLarge;
    const hash = std.hash.XxHash3.hash(Bundle.SEED, bundled);
    try Bundle.ExeHeader.write(writer, .{
        .sections = @intCast(sections),
        .size = @intCast(bundled.len),
    });
    try writer.writeInt(u64, hash, .big);
    try writer.writeAll(Bundle.TAG);

    switch (OUTPUT) {
        .stdout => |_| {
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll(bundled_bytes.items);
        },
        inline .path, .default => |path| {
            const dir_path = std.fs.path.dirname(path);
            if (dir_path != null and dir_path.?.len > 0)
                try std.fs.cwd().makePath(dir_path.?);
            const file_name = if (comptime builtin.os.tag == .windows)
                if (OUTPUT == .default) try std.mem.concat(allocator, u8, &.{ path, ".exe" }) else path
            else
                path;
            defer if (comptime builtin.os.tag == .windows) if (OUTPUT == .default) allocator.free(file_name);
            const handle = try std.fs.cwd().createFile(file_name, .{
                .truncate = true,
                .exclusive = OUTPUT == .default,
                .mode = switch (comptime builtin.os.tag) {
                    .wasi, .windows => 0,
                    else => 0o755,
                },
            });
            defer handle.close();
            try handle.writeAll(bundled_bytes.items);
            try handle.sync();
        },
    }
}

pub const Command = command.Command{
    .name = "bundle",
    .execute = Execute,
};

fn OSPath(comptime path: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, path, '/');
    var static: []const u8 = iter.first();
    while (iter.next()) |component| {
        static = static ++ std.fs.path.sep_str ++ component;
    }
    return static;
}

test "cmdBundle" {
    const allocator = std.testing.allocator;
    var temporaryDir = std.testing.tmpDir(std.fs.Dir.OpenDirOptions{
        .access_sub_paths = true,
    });
    defer temporaryDir.cleanup();

    {
        const exe_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &temporaryDir.sub_path, "test" });
        defer allocator.free(exe_path);
        const sub_path = try std.mem.concat(allocator, u8, &.{ "--out=", exe_path });
        defer allocator.free(sub_path);
        const args: []const []const u8 = &.{ sub_path, "--files=test/runner.zig", "test/cli/bundle.luau" };

        try Execute(allocator, args);

        const file = try std.fs.cwd().openFile(exe_path, .{ .mode = .read_only });
        defer file.close();

        var map = (try Bundle.getFromFile(allocator, file)) orelse unreachable;
        defer map.deinit();

        _ = map.loadScript(comptime OSPath("test/cli/bundle.luau")) catch unreachable;
        _ = map.loadFile(comptime OSPath("test/runner.zig")) catch unreachable;
        try std.testing.expect(map.map.count() == 2);
    }

    {
        const exe_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &temporaryDir.sub_path, "test" });
        defer allocator.free(exe_path);
        const sub_path = try std.mem.concat(allocator, u8, &.{ "--out=", exe_path });
        defer allocator.free(sub_path);
        const args: []const []const u8 = &.{ sub_path, "--files=test/*.zig", "test/cli/bundle.luau" };

        try Execute(allocator, args);

        const file = try std.fs.cwd().openFile(exe_path, .{ .mode = .read_only });
        defer file.close();

        var map = (try Bundle.getFromFile(allocator, file)) orelse unreachable;
        defer map.deinit();

        _ = map.loadScript(comptime OSPath("test/cli/bundle.luau")) catch unreachable;
        _ = map.loadFile(comptime OSPath("test/runner.zig")) catch unreachable;
        try std.testing.expect(map.map.count() == 2);
    }
}
