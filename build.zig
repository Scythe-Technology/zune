const std = @import("std");
const builtin = @import("builtin");

fn compressFile(b: *std.Build, exe: *std.Build.Step.Compile, file: []const u8, out_file: []const u8) *std.Build.Step.Run {
    const embedded_compressor_run = b.addRunArtifact(exe);

    embedded_compressor_run.addArg(b.path(file).getPath(b));
    embedded_compressor_run.addArg(b.path(out_file).getPath(b));

    return embedded_compressor_run;
}

fn compileFile(b: *std.Build, exe: *std.Build.Step.Compile, file: []const u8, out_file: []const u8) *std.Build.Step.Run {
    const embedded_compiler_run = b.addRunArtifact(exe);

    embedded_compiler_run.addArg(b.path(file).getPath(b));
    embedded_compiler_run.addArg(b.path(out_file).getPath(b));

    return embedded_compiler_run;
}

fn compressRecursive(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step, dependentStep: *std.Build.Step, path: []const u8) !void {
    const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and entry.name.len > 2 and !std.mem.eql(u8, entry.name[entry.name.len - 3 ..], ".gz")) {
            const file_name = try std.fs.path.resolve(b.allocator, &[_][]const u8{ path, entry.name });
            defer b.allocator.free(file_name);
            const file_name_with_ext = try std.mem.concat(b.allocator, u8, &[_][]const u8{ entry.name, ".gz" });
            defer b.allocator.free(file_name_with_ext);
            const out_file_name = try std.fs.path.resolve(b.allocator, &[_][]const u8{ path, file_name_with_ext });
            defer b.allocator.free(out_file_name);
            const run = compressFile(b, exe, file_name, out_file_name);
            run.step.dependOn(dependentStep);
            step.dependOn(&run.step);
        } else if (entry.kind == .directory) {
            const dir_path = try std.fs.path.resolve(b.allocator, &[_][]const u8{ path, entry.name });
            defer b.allocator.free(dir_path);
            try compressRecursive(b, exe, step, dependentStep, dir_path);
        }
    }
}

fn getPackageVersion(b: *std.Build) !std.SemanticVersion {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon);
    defer tree.deinit(b.allocator);
    const version = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    if (version.len < 3)
        @panic("Version length too short");
    return std.SemanticVersion.parse(version[1 .. version.len - 1]);
}

fn buildLegacyCompress(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !void {
    _ = b.addModule("legacy-compress", .{
        .root_source_file = b.path("legacy/compress.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn prebuild(b: *std.Build, step: *std.Build.Step) !void {
    const compile = b.step("prebuild_compile", "Compile static luau");
    const compress = b.step("prebuild_compress", "Compress static files");

    const build_native_target: std.Build.ResolvedTarget = .{
        .query = try std.Target.Query.parse(.{}),
        .result = builtin.target,
    };

    { // Pre-compile Luau
        const dep_luau = b.dependency("luau", .{ .target = build_native_target, .optimize = .Debug, .Analysis = false });
        const bytecode_builder = b.addExecutable(.{
            .name = "bytecode_builder",
            .root_module = b.createModule(.{
                .target = build_native_target,
                .optimize = .Debug,
                .root_source_file = b.path("prebuild/bytecode.zig"),
            }),
            .use_llvm = true,
        });

        bytecode_builder.root_module.addImport("luau", dep_luau.module("root"));

        const testing_framework_run = compileFile(
            b,
            bytecode_builder,
            "src/core/lua/testing_lib.luau",
            "src/core/lua/testing_lib.luauc",
        );

        compile.dependOn(&testing_framework_run.step);
    }

    { // Compress files
        const embedded_compressor = b.addExecutable(.{
            .name = "embedded_compressor",
            .root_module = b.createModule(.{
                .root_source_file = b.path("prebuild/compressor.zig"),
                .target = build_native_target,
                .optimize = .Debug,
            }),
            .use_llvm = true,
        });
        embedded_compressor.root_module.addImport("lcompress", b.createModule(.{
            .root_source_file = b.path("legacy/compress.zig"),
            .target = build_native_target,
            .optimize = .Debug,
        }));

        try compressRecursive(b, embedded_compressor, compress, compile, "src/types/");
    }

    step.dependOn(compile);
    step.dependOn(compress);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    const release_ver = b.option(bool, "release-ver", "Set release version") orelse false;
    const use_llvm = b.option(bool, "llvm", "Use llvm");

    const packed_optimize = switch (optimize) {
        .ReleaseFast => .ReleaseSmall,
        else => optimize,
    };

    const dep_luau = b.dependency("luau", .{
        .target = target,
        .optimize = optimize,
        .Analysis = false,
    });
    const dep_xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const dep_tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
    const dep_json = b.dependency("json", .{ .target = target, .optimize = optimize });
    const dep_yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const dep_toml = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const dep_datetime = b.dependency("datetime", .{ .target = target, .optimize = optimize });
    const dep_lz4 = b.dependency("lz4", .{ .target = target, .optimize = packed_optimize });
    const dep_brotli = b.dependency("brotli", .{ .target = target, .optimize = packed_optimize });
    const dep_zstd = b.dependency("zstd", .{ .target = target, .optimize = packed_optimize });
    const dep_pcre2 = b.dependency("pcre2", .{ .target = target, .optimize = packed_optimize });
    const dep_tinycc = b.dependency("tinycc", .{ .target = target, .optimize = packed_optimize, .CONFIG_TCC_BACKTRACE = false, .no_fail = true });
    const dep_sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = packed_optimize,
        .SQLITE_ENABLE_RTREE = true,
        .SQLITE_ENABLE_FTS3 = true,
        .SQLITE_ENABLE_FTS5 = true,
        .SQLITE_ENABLE_COLUMN_METADATA = true,
        .SQLITE_MAX_VARIABLE_NUMBER = 200000,
        .SQLITE_ENABLE_MATH_FUNCTIONS = true,
        .SQLITE_ENABLE_FTS3_PARENTHESIS = true,
    });

    const prebuild_step = b.step("prebuild", "Setup project for build");

    prebuild_step.dependOn(&dep_tinycc.builder.top_level_steps.get("config-tcc").?.step);

    try buildLegacyCompress(b, target, optimize);

    try prebuild(b, prebuild_step);

    const version = try getPackageVersion(b);
    const commit_hash: ?[]const u8 = if (!release_ver) blk: {
        const hash = b.run(&.{ "git", "rev-parse", "HEAD" });
        const trimmed = std.mem.trim(u8, hash, "\r\n ");
        break :blk if (trimmed.len == 0) null else trimmed;
    } else null;

    const zune_info = b.addOptions();
    zune_info.addOption(std.SemanticVersion, "version", version);
    zune_info.addOption(?[]const u8, "commit_hash", commit_hash);

    const mod_zune = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = switch (optimize) {
            .Debug, .ReleaseSafe => null,
            .ReleaseFast, .ReleaseSmall => true,
        },
    });

    mod_zune.addImport("zune", mod_zune);

    mod_zune.addOptions("zune-info", zune_info);

    mod_zune.addImport("luau", dep_luau.module("root"));
    mod_zune.addImport("xev", dep_xev.module("xev"));
    mod_zune.addImport("tls", dep_tls.module("tls"));
    mod_zune.addImport("yaml", dep_yaml.module("yaml"));
    mod_zune.addImport("lz4", dep_lz4.module("lz4"));
    mod_zune.addImport("brotli", dep_brotli.module("brotli"));
    mod_zune.addImport("zstd", dep_zstd.module("zig-zstd"));
    mod_zune.addImport("json", dep_json.module("json"));
    mod_zune.addImport("regex", dep_pcre2.module("zpcre2"));
    mod_zune.addImport("datetime", dep_datetime.module("zdt"));
    mod_zune.addImport("toml", dep_toml.module("tomlz"));
    mod_zune.addImport("sqlite", dep_sqlite.module("z-sqlite"));
    switch (target.result.os.tag) {
        .windows => switch (target.result.cpu.arch) {
            .aarch64 => {},
            else => mod_zune.addImport("tinycc", dep_tinycc.module("root")),
        },
        else => switch (target.result.cpu.arch) {
            .x86_64, .aarch64, .riscv64 => mod_zune.addImport("tinycc", dep_tinycc.module("root")),
            else => {},
        },
    }
    mod_zune.addImport("lcompress", b.modules.get("legacy-compress").?);

    const exe = b.addExecutable(.{
        .name = "zune",
        .root_module = mod_zune,
        .use_llvm = use_llvm,
        .use_lld = true,
    });

    exe.lto = switch (optimize) {
        .Debug => null,
        .ReleaseSmall => .thin,
        else => .full,
    };

    exe.step.dependOn(prebuild_step);

    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const sample_dylib = b.addLibrary(.{
        .name = "sample",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/standard/c/sample.zig"),
            .link_libc = false,
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });

    sample_dylib.step.dependOn(prebuild_step);

    const install_sample_dylib = b.addInstallArtifact(sample_dylib, .{
        .dest_dir = .{ .override = .lib },
    });

    const exe_unit_tests = b.addTest(.{
        .filters = b.args orelse &.{},
        .test_runner = .{
            .mode = .simple,
            .path = b.path("test/runner.zig"),
        },
        .root_module = mod_zune,
        .use_llvm = use_llvm,
    });

    exe_unit_tests.step.dependOn(prebuild_step);
    exe_unit_tests.step.dependOn(&install_sample_dylib.step);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const version_step = b.step("version", "Get build version");

    const version_str = b.fmt("{d}.{d}.{d}{s}", .{
        version.major,
        version.minor,
        version.patch,
        if (commit_hash) |hash| b.fmt("-dev.{s}", .{hash[0..7]}) else "",
    });

    version_step.dependOn(&b.addSystemCommand(&.{ "echo", version_str }).step);
}
