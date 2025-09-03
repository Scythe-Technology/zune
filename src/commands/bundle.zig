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
    kind: Kind = .script,

    pub const Kind = enum { script, file };
};

fn scanDir(
    allocator: std.mem.Allocator,
    map: *std.StringArrayHashMapUnmanaged(void),
    dir: std.fs.Dir,
    opts: ScanOptions,
    path: []const u8,
    recursive: bool,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        errdefer allocator.free(entry_path);
        blk: switch (entry.kind) {
            .file => {
                if (!Glob.match(opts.glob, entry_path).matches())
                    break :blk;
                if (opts.kind == .script and File.getLuaFileType(entry.name) == null)
                    break :blk;
                if (try map.fetchPut(allocator, entry_path, undefined)) |_|
                    allocator.free(entry_path);
                continue;
            },
            .directory => {
                if (!recursive)
                    break :blk;
                var entry_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer entry_dir.close();
                try scanDir(allocator, map, entry_dir, opts, entry_path, recursive);
            },
            else => {},
        }
        allocator.free(entry_path);
    }
}

const COMPRESSION_MAP = std.StaticStringMap(Bundle.Section.Compression).initComptime(.{
    .{ "none", .none },
    .{ "zlib", .zlib },
    .{ "lz4", .lz4 },
    .{ "zstd", .zstd },
});

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const bundle_args, const flags = splitArgs(args);

    if (bundle_args.len < 1) {
        Zune.debug.print("<red>usage<clear>: bundle [flags] <<luau file>> [...luau files]\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    var home_dir = File.getHomeDir(Zune.STATE.ENV_MAP) orelse "";

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    const module = bundle_args[0];

    const cwd_path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const entry_file, const contents = getFile(allocator, dir, module) catch |err| switch (err) {
        error.FileNotFound => {
            Zune.debug.print("<red>error<clear>: file not found '{s}'\n", .{module});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(entry_file);
    defer allocator.free(contents);

    const file_path = entry_file[1..];

    var SCRIPTS: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer SCRIPTS.deinit(allocator);
    defer for (SCRIPTS.keys()) |script| allocator.free(script);
    var FILES: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer FILES.deinit(allocator);
    defer for (FILES.keys()) |file| allocator.free(file);

    {
        const abs_entry_file = try std.fs.path.resolve(allocator, &.{ cwd_path, file_path });
        errdefer allocator.free(abs_entry_file);
        try SCRIPTS.put(allocator, abs_entry_file, undefined);

        var basket: *std.StringArrayHashMapUnmanaged(void) = &SCRIPTS;
        var backet_kind: ScanOptions.Kind = .script;
        for (bundle_args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--files") or std.mem.eql(u8, arg, "-f")) {
                    basket = &FILES;
                    backet_kind = .file;
                } else if (std.mem.eql(u8, arg, "--scripts") or std.mem.eql(u8, arg, "-s")) {
                    basket = &SCRIPTS;
                    backet_kind = .script;
                }
                continue;
            }
            const glob = try std.fs.path.resolve(allocator, &.{ cwd_path, arg });
            if (std.mem.indexOfScalar(u8, glob, '*')) |i| {
                defer allocator.free(glob);
                if (comptime builtin.os.tag == .windows)
                    std.mem.replaceScalar(u8, glob, '\\', '/');
                var d = if (i > 0) try dir.openDir(glob[0..i], .{ .iterate = true }) else dir;
                defer if (i > 0) d.close();
                try scanDir(allocator, basket, d, .{
                    .glob = glob,
                    .kind = backet_kind,
                }, glob[0..i], std.mem.indexOf(u8, glob[i..], "**") != null);
            } else {
                errdefer allocator.free(glob);
                if (try basket.fetchPut(allocator, glob, undefined)) |_|
                    allocator.free(glob);
            }
        }
    }

    var EXEC: ?[]const u8 = null;
    var COMPRESSION: Bundle.Section.Compression = .none;
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
                    Zune.debug.print("<red>error<clear>: invalid optimization level, usage: -O<<N>>\n", .{});
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
                        Zune.debug.print("<red>error<clear>: invalid debug level, usage: -g<<N>>\n", .{});
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
                } else if (std.mem.eql(u8, flag, "--no_home")) {
                    home_dir = cwd_path;
                } else if (std.mem.startsWith(u8, flag, "--exe=") and flag.len > 6) {
                    EXEC = flag[6..];
                } else if (std.mem.startsWith(u8, flag, "--out=") and flag.len > 6) {
                    OUTPUT = .{ .path = flag[6..] };
                } else if (std.mem.startsWith(u8, flag, "--home=") and flag.len > 7) {
                    home_dir = flag[7..];
                } else if (std.mem.startsWith(u8, flag, "--compression=") and flag.len > 14) {
                    COMPRESSION = COMPRESSION_MAP.get(flag[14..]) orelse {
                        Zune.debug.print("<red>error<clear>: unknown compression type '{s}'\n", .{flag[14..]});
                        std.process.exit(1);
                    };
                },
                else => {
                    Zune.debug.print("<red>error<clear>: unknown flag '{s}'\n", .{flag});
                    std.process.exit(1);
                },
            },
            else => unreachable,
        }
    };

    const exe = if (EXEC) |path|
        std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => {
                Zune.debug.print("<red>error<clear>: executable '{s}' was not found\n", .{path});
                std.process.exit(1);
            },
            error.IsDir => {
                Zune.debug.print("<red>error<clear>: '{s}' is a directory, expected an executable file\n", .{path});
                std.process.exit(1);
            },
            else => |e| return e,
        }
    else
        try std.fs.openSelfExe(.{ .mode = .read_only });
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
            .enabled = Zune.STATE.FORMAT.ENABLED,
            .use_color = Zune.STATE.FORMAT.USE_COLOR,
            .max_depth = Zune.STATE.FORMAT.MAX_DEPTH,
            .table_address = Zune.STATE.FORMAT.TABLE_ADDRESS,
            .recursive_table = Zune.STATE.FORMAT.RECURSIVE_TABLE,
            .buffer_max_display = Zune.STATE.FORMAT.BUFFER_MAX_DISPLAY,
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
        defer if (home_dir.len > 0) allocator.free(home_relative);
        if (std.mem.indexOfAny(u8, home_relative, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") != null) {
            Zune.debug.print("<yellow>warning<clear>: resolved home directory relative path '{s}' contains normal characters\n", .{home_relative});
            Zune.debug.print("The bundled application may contain unwanted path names\n", .{});
        }
        try writer.writeInt(u16, @intCast(home_relative.len), .big);
        try writer.writeAll(home_relative);
    }

    for (SCRIPTS.keys()) |script| {
        const name = try std.fs.path.relative(allocator, cwd_path, script);
        defer allocator.free(name);
        const script_contents = std.fs.cwd().readFileAlloc(allocator, script, std.math.maxInt(usize)) catch |err| switch (err) {
            error.FileNotFound => {
                Zune.debug.print("<red>error<clear>: '{s}' was not found\n", .{name});
                std.process.exit(1);
            },
            error.IsDir => continue, // skip directories
            else => |e| return e,
        };
        defer allocator.free(script_contents);
        const bytecode = try luau.Compiler.luacode.compile(allocator, script_contents, .{
            .optimizationLevel = Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
            .debugLevel = Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL,
        });
        defer allocator.free(bytecode);
        if (bytecode[0] == 0) {
            Zune.debug.print("<red>compile error<clear>: {s}{s}\n", .{ name, bytecode[1..] });
            std.process.exit(1);
        }
        (switch (BUILD_MODE) {
            .debug => Bundle.Section.writeScript(writer, name, script_contents),
            .release => Bundle.Section.writeScript(writer, name, bytecode),
        }) catch |err| switch (err) {
            error.NameTooLong => {
                Zune.debug.print("<red>error<clear>: script name '{s}' is too long to bundle\n", .{name});
                std.process.exit(1);
            },
            error.DataTooLarge => {
                Zune.debug.print("<red>error<clear>: script '{s}' is too large to bundle\n", .{name});
                std.process.exit(1);
            },
            else => return err,
        };
    }

    for (FILES.keys()) |file| {
        if (SCRIPTS.get(file)) |_| {
            Zune.debug.print("<yellow>warning<clear>: attempted to bundle an existing script '{s}' as file, skipping...\n", .{file});
            continue;
        }
        const name = try std.fs.path.relative(allocator, cwd_path, file);
        defer allocator.free(name);
        const file_contents = try std.fs.cwd().readFileAlloc(allocator, file, std.math.maxInt(usize));
        defer allocator.free(file_contents);
        Bundle.Section.writeFile(allocator, writer, name, file_contents, COMPRESSION) catch |err| switch (err) {
            error.NameTooLong => {
                Zune.debug.print("<red>error<clear>: file name '{s}' is too long to bundle\n", .{name});
                std.process.exit(1);
            },
            error.DataTooLarge => {
                Zune.debug.print("<red>error<clear>: file '{s}' is too large to bundle\n", .{name});
                std.process.exit(1);
            },
            else => return err,
        };
    }

    const sections = SCRIPTS.keys().len + FILES.keys().len;
    std.debug.assert(sections > 0);

    if (sections > Bundle.ExeHeader.maxValue(.sections)) {
        Zune.debug.print("<red>error<clear>: too many sections ({d}), maximum is {d}\n", .{ sections, Bundle.ExeHeader.maxValue(.sections) });
        Zune.debug.print("sections are files and scripts combined, try reducing the amount of files or scripts.\n", .{});
        std.process.exit(1);
    }
    const bundled = bundled_bytes.items[zune_build_len..];
    if (bundled.len > Bundle.ExeHeader.maxValue(.size)) {
        Zune.debug.print("<red>error<clear>: large bundled size ({d} MB), exceeds maximum ({d} MB)\n", .{ @divTrunc(bundled.len, 1_000_000), @divTrunc(Bundle.ExeHeader.maxValue(.size), 1_000_000) });
        Zune.debug.print("try bundling more compact data, either by bundling with bytecode instead of script source code with --release flag,\n", .{});
        Zune.debug.print("or compressing files with --compress=<<zstd|lz4|zlib>>.\n", .{});
        std.process.exit(1);
    }
    const hash = std.hash.XxHash3.hash(Bundle.SEED, bundled);
    try Bundle.ExeHeader.write(writer, .{
        .sections = @intCast(sections),
        .size = @intCast(bundled.len),
    });
    try writer.writeInt(u64, hash, .big);
    try writer.writeAll(Bundle.TAG);

    switch (OUTPUT) {
        .stdout => |_| {
            const stdout = std.fs.File.stdout();
            var buffer: [4096]u8 = undefined;
            var stdout_writer = stdout.writer(&buffer);
            const wr = &stdout_writer.interface;
            try wr.writeAll(bundled_bytes.items);
            try wr.flush();
        },
        inline .path, .default => |path| {
            const dir_path = std.fs.path.dirname(path);
            if (dir_path != null and dir_path.?.len > 0)
                std.fs.cwd().makePath(dir_path.?) catch |err| switch (err) {
                    error.NotDir => {
                        Zune.debug.print("<red>error<clear>: failed to create path tree '{s}' (expected directory, got file)\n", .{dir_path.?});
                        std.process.exit(1);
                    },
                    else => return err,
                };
            const file_name = if (comptime builtin.os.tag == .windows)
                if (OUTPUT == .default) try std.mem.concat(allocator, u8, &.{ path, ".exe" }) else path
            else
                path;
            defer if (comptime builtin.os.tag == .windows) if (OUTPUT == .default) allocator.free(file_name);
            const handle = std.fs.cwd().createFile(file_name, .{
                .truncate = true,
                .exclusive = OUTPUT == .default,
                .mode = switch (comptime builtin.os.tag) {
                    .wasi, .windows => 0,
                    else => 0o755,
                },
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    Zune.debug.print("<red>error<clear>: '{s}' already exists, use '--out=<<file>>' to specify a path you allow to be written to\n", .{file_name});
                    std.process.exit(1);
                },
                else => |e| return e,
            };
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
    var temporaryDir = std.testing.tmpDir(.{
        .access_sub_paths = true,
    });
    defer temporaryDir.cleanup();

    {
        const exe_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &temporaryDir.sub_path, "test" });
        defer allocator.free(exe_path);
        const sub_path = try std.mem.concat(allocator, u8, &.{ "--out=", exe_path });
        defer allocator.free(sub_path);
        const args: []const []const u8 = &.{ sub_path, "test/cli/bundle.luau", "--files", "test/runner.zig" };

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
        const args: []const []const u8 = &.{ sub_path, "test/cli/bundle.luau", "-f", "test/*.zig" };

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
