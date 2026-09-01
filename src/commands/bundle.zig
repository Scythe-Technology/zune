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

fn getFile(allocator: std.mem.Allocator, dir: std.Io.Dir, input: []const u8) !struct { []u8, []const u8 } {
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

const ScanOptions = struct {
    glob: []const u8,
    kind: Kind = .script,

    pub const Kind = enum { script, file };
};

fn scanDir(
    allocator: std.mem.Allocator,
    map: *std.array_hash_map.String(void),
    dir: std.Io.Dir,
    opts: ScanOptions,
    path: []const u8,
    recursive: bool,
) !void {
    var iter = dir.iterate();
    while (try iter.next(Zune.io())) |entry| {
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
                var entry_dir = try dir.openDir(Zune.io(), entry.name, .{ .iterate = true });
                defer entry_dir.close(Zune.io());
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
    .{ "flate", .flate },
    .{ "gzip", .gzip },
    .{ "lz4", .lz4 },
    .{ "zstd", .zstd },
});

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (comptime !Bundle.PlatformSupported())
        Zune.quitMsg("<red>error<clear>: platform not supported\n", .{});
    if (args.len < 1) {
        Zune.debug.print("<red>usage<clear>: bundle [...flags or files]\n", .{});
        return;
    }

    Zune.loadConfiguration(std.Io.Dir.cwd());

    if (std.mem.eql(u8, args[0], "--read")) {
        if (args.len != 2) {
            Zune.debug.print("<red>usage<clear>: bundle --read <<file>>\n", .{});
            return;
        }
        const path = args[1];
        const file = try std.Io.Dir.cwd().openFile(Zune.io(), path, .{ .mode = .read_only });
        defer file.close(Zune.io());

        const last_color = Zune.STATE.FORMAT.USE_COLOR;

        const map = Bundle.getFromFile(allocator, file) catch |err| switch (err) {
            error.CorruptBundle => Zune.quitMsg("<red>error<clear>: '{s}' is not a valid zune bundle (corrupt)\n", .{path}),
            else => return err,
        } orelse Zune.quitMsg("<red>error<clear>: '{s}' is not a valid zune bundle\n", .{path});

        Zune.STATE.FORMAT.USE_COLOR = last_color;

        Zune.debug.print("<bold>bundled size<clear>: {d}\n", .{map.allocated.len});
        Zune.debug.print("<bold>build mode<clear>:   <green>{t}<clear>\n", .{map.mode.compiled});
        Zune.debug.print("<bold>sections<clear>:     {d}\n", .{map.map.size});
        Zune.debug.print("<bold>entry<clear>:\n", .{});
        Zune.debug.print("- <bold>name<clear>: {s}\n", .{map.entry.name[1..]});
        Zune.debug.print("  <bold>size<clear>: {d}\n", .{map.entry.data.len});
        return;
    }

    var home_dir = File.getHomeDir(Zune.STATE.ENV_MAP) orelse "";

    var dir = try std.Io.Dir.cwd().openDir(Zune.io(), ".", .{ .iterate = true });
    defer dir.close(Zune.io());

    const cwd_path = try std.process.currentPathAlloc(Zune.io(), allocator);
    defer allocator.free(cwd_path);

    var EXEC: ?[]const u8 = null;
    var COMPRESSION: Bundle.Section.Compression = .none;
    var BUILD_MODE: enum(u1) { debug, release } = .debug;
    var OUTPUT: union(enum) {
        stdout: void,
        path: []const u8,
        default: []const u8,
    } = .{ .default = undefined };
    var LOAD_FLAGS: Zune.Flags = .{};

    var SCRIPTS: std.array_hash_map.String(void) = .empty;
    defer SCRIPTS.deinit(allocator);
    defer for (SCRIPTS.keys()) |script| allocator.free(script);
    var FILES: std.array_hash_map.String(void) = .empty;
    defer FILES.deinit(allocator);
    defer for (FILES.keys()) |file| allocator.free(file);

    {
        var basket: *std.array_hash_map.String(void) = &SCRIPTS;
        var backet_kind: ScanOptions.Kind = .script;
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) {
                if (arg.len < 2)
                    continue;
                const flag = arg;
                sw: switch (flag[1]) {
                    'O' => if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                        const level: u2 = switch (flag[2]) {
                            '0' => 0,
                            '1' => 1,
                            '2' => 2,
                            else => unreachable,
                        };
                        Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = level;
                    } else Zune.quitMsg("<red>error<clear>: invalid optimization level, usage: -O<<N>>\n", .{}),
                    'g' => {
                        if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                            const level: u2 = switch (flag[2]) {
                                '0' => 0,
                                '1' => 1,
                                '2' => 2,
                                else => unreachable,
                            };
                            Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL = level;
                        } else Zune.quitMsg("<red>error<clear>: invalid debug level, usage: -g<<N>>\n", .{});
                    },
                    'f' => if (std.mem.eql(u8, arg, "-f")) {
                        basket = &FILES;
                        backet_kind = .file;
                    } else continue :sw 0,
                    's' => if (std.mem.eql(u8, arg, "-s")) {
                        basket = &SCRIPTS;
                        backet_kind = .script;
                    } else continue :sw 0,
                    '-' => if (std.mem.eql(u8, flag, "--native")) {
                        Zune.STATE.LUAU_OPTIONS.CODEGEN = true;
                    } else if (std.mem.eql(u8, flag, "--no-native")) {
                        Zune.STATE.LUAU_OPTIONS.CODEGEN = false;
                    } else if (std.mem.eql(u8, flag, "--no-jit")) {
                        Zune.STATE.LUAU_OPTIONS.JIT_ENABLED = false;
                    } else if (std.mem.eql(u8, flag, "--limbo")) {
                        LOAD_FLAGS.limbo = true;
                    } else if (std.mem.eql(u8, flag, "--no-fmt")) {
                        Zune.STATE.FORMAT.ENABLED = false;
                    } else if (std.mem.eql(u8, flag, "--release")) {
                        BUILD_MODE = .release;
                    } else if (std.mem.eql(u8, flag, "--debug")) {
                        BUILD_MODE = .debug;
                    } else if (std.mem.eql(u8, flag, "--no_home")) {
                        home_dir = cwd_path;
                    } else if (std.mem.eql(u8, arg, "--files")) {
                        basket = &FILES;
                        backet_kind = .file;
                    } else if (std.mem.eql(u8, arg, "--scripts")) {
                        basket = &SCRIPTS;
                        backet_kind = .script;
                    } else if (std.mem.startsWith(u8, flag, "--exe=") and flag.len > 6) {
                        EXEC = flag[6..];
                    } else if (std.mem.startsWith(u8, flag, "--out=") and flag.len > 6) {
                        const path = flag[6..];
                        if (path.len == 1 and path[0] == '-')
                            OUTPUT = .stdout
                        else
                            OUTPUT = .{ .path = path };
                    } else if (std.mem.startsWith(u8, flag, "--home=") and flag.len > 7) {
                        home_dir = flag[7..];
                    } else if (std.mem.startsWith(u8, flag, "--compression=") and flag.len > 14) {
                        COMPRESSION = COMPRESSION_MAP.get(flag[14..]) orelse Zune.quitMsg("<red>error<clear>: unknown compression type '{s}'\n", .{flag[14..]});
                    } else continue :sw 0,
                    else => Zune.quitMsg("<red>error<clear>: unknown flag '{s}'\n", .{flag}),
                }
                continue;
            }
            const glob = try std.fs.path.resolve(allocator, &.{ cwd_path, arg });
            if (std.mem.indexOfScalar(u8, glob, '*')) |i| {
                defer allocator.free(glob);
                if (comptime builtin.os.tag == .windows)
                    std.mem.replaceScalar(u8, glob, '\\', '/');
                var d = if (i > 0) try dir.openDir(Zune.io(), glob[0..i], .{ .iterate = true }) else dir;
                defer if (i > 0) d.close(Zune.io());
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

    if (SCRIPTS.count() < 1) {
        Zune.debug.print("<red>usage<clear>: bundle would have no entry file\n", .{});
        return;
    }

    const entry_file = SCRIPTS.keys()[0];

    if (OUTPUT == .default)
        OUTPUT = .{ .default = std.fs.path.stem(entry_file) };

    const exe = if (EXEC) |path|
        std.Io.Dir.cwd().openFile(Zune.io(), path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => Zune.quitMsg("<red>error<clear>: executable '{s}' was not found\n", .{path}),
            error.IsDir => Zune.quitMsg("<red>error<clear>: '{s}' is a directory, expected an executable file\n", .{path}),
            else => |e| return e,
        }
    else
        try std.process.openExecutable(Zune.io(), .{ .mode = .read_only });
    defer exe.close(Zune.io());

    var reader = exe.reader(Zune.io(), &.{});

    const zune_build = try reader.interface.allocRemaining(allocator, .unlimited);
    const zune_build_len = zune_build.len;

    var bundled_bytes = std.Io.Writer.Allocating.initOwnedSlice(allocator, zune_build);
    defer bundled_bytes.deinit();

    bundled_bytes.shrinkRetainingCapacity(zune_build_len);

    const writer = &bundled_bytes.writer;

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
        const home_relative = if (home_dir.len > 0) try std.fs.path.relative(allocator, cwd_path, null, cwd_path, home_dir) else "";
        defer if (home_dir.len > 0) allocator.free(home_relative);
        if (std.mem.indexOfAny(u8, home_relative, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") != null) {
            Zune.debug.print("<yellow>warning<clear>: resolved home directory relative path '{s}' contains normal characters\n", .{home_relative});
            Zune.debug.print("The bundled application may contain unwanted path names\n", .{});
        }
        try writer.writeInt(u16, @intCast(home_relative.len), .big);
        try writer.writeAll(home_relative);
    }

    for (SCRIPTS.keys()) |script| {
        const name = try std.fs.path.relative(allocator, cwd_path, null, cwd_path, script);
        defer allocator.free(name);
        const script_contents = std.Io.Dir.cwd().readFileAlloc(Zune.io(), script, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => Zune.quitMsg("<red>error<clear>: '{s}' was not found\n", .{name}),
            error.IsDir => continue, // skip directories
            else => |e| return e,
        };
        defer allocator.free(script_contents);
        const bytecode = try luau.Compiler.luacode.compile(allocator, script_contents, .{
            .optimizationLevel = Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
            .debugLevel = Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL,
        });
        defer allocator.free(bytecode);
        if (bytecode[0] == 0)
            Zune.quitMsg("<red>compile error<clear>: {s}{s}\n", .{ name, bytecode[1..] });
        (switch (BUILD_MODE) {
            .debug => Bundle.Section.writeScript(writer, name, script_contents),
            .release => Bundle.Section.writeScript(writer, name, bytecode),
        }) catch |err| switch (err) {
            error.NameTooLong => Zune.quitMsg("<red>error<clear>: script name '{s}' is too long to bundle\n", .{name}),
            error.DataTooLarge => Zune.quitMsg("<red>error<clear>: script '{s}' is too large to bundle\n", .{name}),
            else => return err,
        };
    }

    for (FILES.keys()) |file| {
        if (SCRIPTS.get(file)) |_| {
            Zune.debug.print("<yellow>warning<clear>: attempted to bundle an existing script '{s}' as file, skipping...\n", .{file});
            continue;
        }
        const name = try std.fs.path.relative(allocator, cwd_path, null, cwd_path, file);
        defer allocator.free(name);
        const file_contents = try std.Io.Dir.cwd().readFileAlloc(Zune.io(), file, allocator, .unlimited);
        defer allocator.free(file_contents);
        Bundle.Section.writeFile(allocator, writer, name, file_contents, COMPRESSION) catch |err| switch (err) {
            error.NameTooLong => Zune.quitMsg("<red>error<clear>: file name '{s}' is too long to bundle\n", .{name}),
            error.DataTooLarge => Zune.quitMsg("<red>error<clear>: file '{s}' is too large to bundle\n", .{name}),
            else => return err,
        };
    }

    const sections = SCRIPTS.keys().len + FILES.keys().len;
    std.debug.assert(sections > 0);

    if (sections > Bundle.ExeHeader.maxValue(.sections)) {
        Zune.debug.print("<red>error<clear>: too many sections ({d}), maximum is {d}\n", .{ sections, Bundle.ExeHeader.maxValue(.sections) });
        Zune.quitMsg("sections are files and scripts combined, try reducing the amount of files or scripts.\n", .{});
    }
    const bundled = bundled_bytes.written()[zune_build_len..];
    if (bundled.len > Bundle.ExeHeader.maxValue(.size)) {
        Zune.debug.print("<red>error<clear>: large bundled size ({d} MB), exceeds maximum ({d} MB)\n", .{ @divTrunc(bundled.len, 1_000_000), @divTrunc(Bundle.ExeHeader.maxValue(.size), 1_000_000) });
        Zune.debug.print("try bundling more compact data, either by bundling with bytecode instead of script source code with --release flag,\n", .{});
        Zune.quitMsg("or compressing files with --compression=<<zstd|lz4|zlib|gzip|flate>>.\n", .{});
    }
    const hash = std.hash.XxHash3.hash(Bundle.SEED, bundled);
    try Bundle.ExeHeader.write(writer, .{
        .sections = @intCast(sections),
        .size = @intCast(bundled.len),
    });
    try writer.writeInt(u64, hash, .big);
    try writer.writeAll(Bundle.TAG);

    switch (OUTPUT) {
        .stdout => {
            const stdout = std.Io.File.stdout();
            var buffer: [4096]u8 = undefined;
            var stdout_writer = stdout.writer(Zune.io(), &buffer);
            const wr = &stdout_writer.interface;
            try wr.writeAll(bundled_bytes.written());
            try wr.flush();
        },
        inline .path, .default => |path| {
            const dir_path = std.fs.path.dirname(path);
            if (dir_path != null and dir_path.?.len > 0)
                std.Io.Dir.cwd().createDirPath(Zune.io(), dir_path.?) catch |err| switch (err) {
                    error.NotDir => Zune.quitMsg("<red>error<clear>: failed to create path tree '{s}' (expected directory, got file)\n", .{dir_path.?}),
                    else => return err,
                };
            const file_name = if (comptime builtin.os.tag == .windows)
                if (OUTPUT == .default) try std.mem.concat(allocator, u8, &.{ path, ".exe" }) else path
            else
                path;
            defer if (comptime builtin.os.tag == .windows) if (OUTPUT == .default) allocator.free(file_name);
            const handle = std.Io.Dir.cwd().createFile(Zune.io(), file_name, .{
                .truncate = true,
                .exclusive = OUTPUT == .default,
                .permissions = switch (comptime builtin.os.tag) {
                    .wasi, .windows => @enumFromInt(0),
                    else => @enumFromInt(0o755),
                },
            }) catch |err| switch (err) {
                error.PathAlreadyExists => Zune.quitMsg("<red>error<clear>: '{s}' already exists, use '--out=<<file>>' to specify a path you allow to be written to\n", .{file_name}),
                else => |e| return e,
            };
            defer handle.close(Zune.io());
            try handle.writePositionalAll(Zune.io(), bundled_bytes.written(), 0);
            try handle.sync(Zune.io());
        },
    }
}

pub const Command = command.Command{
    .name = "bundle",
    .execute = Execute,
    .description = "Bundle lua/luau scripts, files with zune as standalone executable.",
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
    if (comptime !Bundle.PlatformSupported()) return error.SkipZigTest;

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

        const file = try std.Io.Dir.cwd().openFile(Zune.io(), exe_path, .{ .mode = .read_only });
        defer file.close(Zune.io());

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

        const file = try std.Io.Dir.cwd().openFile(Zune.io(), exe_path, .{ .mode = .read_only });
        defer file.close(Zune.io());

        var map = (try Bundle.getFromFile(allocator, file)) orelse unreachable;
        defer map.deinit();

        _ = map.loadScript(comptime OSPath("test/cli/bundle.luau")) catch unreachable;
        _ = map.loadFile(comptime OSPath("test/runner.zig")) catch unreachable;
        try std.testing.expect(map.map.count() == 2);
    }
}
