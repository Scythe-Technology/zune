const std = @import("std");
const builtin = @import("builtin");

fn getPackageVersion(b: *std.Build) !std.SemanticVersion {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .{ .mode = .zon });
    defer tree.deinit(b.allocator);
    const version = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    if (version.len < 3)
        @panic("Version length too short");
    return std.SemanticVersion.parse(version[1 .. version.len - 1]);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_bin = b.option(bool, "no-bin", "skip emitting binary") orelse false;
    const release_ver = b.option(bool, "release-ver", "Set release version") orelse false;
    const use_llvm = b.option(bool, "llvm", "Use llvm");

    const perf_profiling = b.option(bool, "pprof", "Build with performance profiling focused settings.");
    const test_filter = b.option([]const u8, "test-filter", "test to filter");
    const rt_test_filter = b.option([]const u8, "rt-test-filter", "test to filter");

    const api_dump = b.option(bool, "api-dump", "Enable API dump") orelse false;

    const packed_optimize = switch (optimize) {
        .fast => .small,
        else => optimize,
    };
    const fast_optimize = switch (optimize) {
        .small => .fast,
        else => optimize,
    };

    const dep_luau = b.dependency("luau", .{
        .target = target,
        .optimize = fast_optimize,
        .Analysis = false,
    });
    const dep_zio = b.dependency("zio", .{ .target = target, .optimize = fast_optimize });
    const dep_tls = b.dependency("tls", .{ .target = target, .optimize = fast_optimize });
    const dep_json = b.dependency("json", .{ .target = target, .optimize = fast_optimize });
    const dep_yaml = b.dependency("yaml", .{ .target = target, .optimize = fast_optimize });
    const dep_toml = b.dependency("toml", .{ .target = target, .optimize = fast_optimize });
    const dep_wire = b.dependency("wire", .{ .target = target, .optimize = fast_optimize });
    const dep_datetime = b.dependency("datetime", .{ .target = target, .optimize = packed_optimize });
    const dep_lz4 = b.dependency("lz4", .{ .target = target, .optimize = packed_optimize });
    const dep_zstd = b.dependency("zstd", .{ .target = target, .optimize = packed_optimize });
    const dep_pcre2 = b.dependency("pcre2", .{ .target = target, .optimize = packed_optimize });

    const version = try getPackageVersion(b);
    const commit_hash: ?[]const u8 = if (!release_ver) blk: {
        const hash = b.run(&.{ "git", "rev-parse", "HEAD" });
        const trimmed = std.mem.trim(u8, hash, "\r\n ");
        break :blk if (trimmed.len == 0) null else trimmed;
    } else null;

    const zune_info = b.addOptions();
    zune_info.addOption(bool, "api_dump", api_dump);
    zune_info.addOption(std.SemanticVersion, "version", version);
    zune_info.addOption(?[]const u8, "commit_hash", commit_hash);

    const mod_zune = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = switch (optimize) {
            .debug, .safe => null,
            .fast, .small => true and !(perf_profiling orelse false),
        },
        .omit_frame_pointer = if (perf_profiling) |p| !p else null,
    });

    mod_zune.addImport("zune", mod_zune);

    mod_zune.addOptions("zune-info", zune_info);

    mod_zune.addImport("luau", dep_luau.module("root"));
    mod_zune.addImport("zio", dep_zio.module("zio"));
    mod_zune.addImport("tls", dep_tls.module("tls"));
    mod_zune.addImport("yaml", dep_yaml.module("yaml"));
    mod_zune.addImport("lz4", dep_lz4.module("root"));
    mod_zune.addImport("zstd", dep_zstd.module("root"));
    mod_zune.addImport("json", dep_json.module("json"));
    mod_zune.addImport("regex", dep_pcre2.module("root"));
    mod_zune.addImport("datetime", dep_datetime.module("zdt"));
    mod_zune.addImport("toml", dep_toml.module("root"));
    mod_zune.addImport("wire", dep_wire.module("root"));

    // LLD cannot link macho with zig 0.17+.
    const use_lld: ?bool = if (target.result.ofmt == .macho) false else use_llvm;

    const exe = b.addExecutable(.{
        .name = "zune",
        .root_module = mod_zune,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });

    exe.lto = switch (optimize) {
        .debug => null,
        .small => .thin,
        else => .full,
    };

    exe.link_function_sections = true;
    exe.link_data_sections = true;
    exe.link_gc_sections = true;

    exe.stack_size = if (optimize == .debug) 64 * 1024 * 1024 else 16 * 1024 * 1024;

    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
        b.installDirectory(.{
            .source_dir = b.path("lib"),
            .install_dir = .bin,
            .install_subdir = "lib",
        });
        b.installDirectory(.{
            .source_dir = b.path("types"),
            .install_dir = .bin,
            .install_subdir = "types",
        });
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

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

    // sample_dylib.step.dependOn(prebuild_step);

    const install_sample_dylib = b.addInstallArtifact(sample_dylib, .{
        .dest_dir = .{ .override = .lib },
    });

    const exe_unit_tests = b.addTest(.{
        .filters = if (rt_test_filter) |filter| &.{filter} else &.{},
        .root_module = mod_zune,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
    });

    exe_unit_tests.step.dependOn(&install_sample_dylib.step);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const run_tests_cmd = b.addRunArtifact(exe);
    run_tests_cmd.addArgs(&.{ "run", "test", if (test_filter) |filter| filter else "" });

    run_tests_cmd.step.dependOn(&run_exe_unit_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests_cmd.step);

    const version_step = b.step("version", "Get build version");

    const version_str = b.fmt("{d}.{d}.{d}{s}", .{
        version.major,
        version.minor,
        version.patch,
        if (commit_hash) |hash| b.fmt("-dev.{s}", .{hash[0..7]}) else "",
    });

    version_step.dependOn(&b.addSystemCommand(&.{ "echo", version_str }).step);
}
