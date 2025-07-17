const std = @import("std");
const xev = @import("xev");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const VM = luau.VM;

const zune_test_files = @import("zune-test-files");

const TestFile = struct {
    path: []const u8,
};

pub fn newTestFile(comptime path: []const u8) TestFile {
    return TestFile{
        .path = "test/" ++ path,
    };
}

const TestOptions = struct {
    std_out: bool = true,
    ref_leak_check: bool = true,
};

pub fn runTest(comptime testFile: TestFile, args: []const []const u8, comptime options: TestOptions) !Zune.corelib.testing.TestResult {
    const allocator = std.testing.allocator;

    try Zune.init();

    var L = try luau.init(&allocator);
    defer L.deinit();

    if (!options.std_out)
        try L.Zsetfield(VM.lua.GLOBALSINDEX, "_testing_stdOut", false);

    var scheduler = try Scheduler.init(allocator, L);
    defer scheduler.deinit();

    var temporaryDir = std.testing.tmpDir(std.fs.Dir.OpenDirOptions{
        .access_sub_paths = true,
    });
    // FIXME: freezes windows
    // defer temporaryDir.cleanup();

    const tempPath = try std.mem.joinZ(allocator, "/", &.{
        ".zig-cache/tmp",
        &temporaryDir.sub_path,
    });
    defer allocator.free(tempPath);
    try L.Zsetglobal("__test_tempdir", tempPath);

    const cwd = std.fs.cwd();

    const content = try cwd.readFileAlloc(allocator, testFile.path, std.math.maxInt(usize));
    defer allocator.free(content);

    const dir_path = std.fs.path.dirname(testFile.path) orelse unreachable;
    var dir = try cwd.openDir(dir_path, .{});
    defer dir.close();

    Zune.STATE.RUN_MODE = .Test;

    Zune.loadConfiguration(dir);

    try Engine.prepAsync(L, &scheduler);
    const current_top = L.gettop();
    try Zune.openZune(L, args, .{});
    std.debug.assert(L.gettop() == current_top); // zune should not leave anything on the stack

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = try L.newthread();

    try ML.Lsandboxthread();

    try Engine.setLuaFileContext(ML, .{
        .source = content,
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    Engine.loadModule(ML, "@" ++ testFile.path, content, .{
        .debugLevel = 2,
    }) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("Syntax: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return err;
        },
        else => return err,
    };

    Zune.corelib.testing.REF_LEAK_CHECK = options.ref_leak_check;
    return Zune.corelib.testing.runTestAsync(ML, &scheduler) catch |err| return err;
}
