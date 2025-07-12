const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const Zune = @import("zune");

const LuaHelper = Zune.Utils.LuaHelper;

const SerdeJson = @import("./serde/json.zig");

const VM = luau.VM;

pub const LIB_NAME = "luau";

fn lua_compile(L: *VM.lua.State) !i32 {
    const source = try L.Zcheckvalue([]const u8, 1, null);

    var compileOpts = luau.CompileOptions{
        .debugLevel = Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL,
        .optimizationLevel = Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL,
    };

    if (try L.Zcheckvalue(?struct {
        debug_level: ?i32,
        optimization_level: ?i32,
        coverage_level: ?i32,
        // vector_ctor: ?[:0]const u8,
        // vector_lib: ?[:0]const u8,
        // vector_type: ?[:0]const u8,
    }, 2, null)) |opts| {
        compileOpts.debugLevel = opts.debug_level orelse compileOpts.debugLevel;
        if (compileOpts.debugLevel < 0 or compileOpts.debugLevel > 2)
            return L.Zerror("Invalid debug level");

        compileOpts.optimizationLevel = opts.optimization_level orelse compileOpts.optimizationLevel;
        if (compileOpts.optimizationLevel < 0 or compileOpts.optimizationLevel > 3)
            return L.Zerror("Invalid optimization level");

        compileOpts.coverageLevel = opts.coverage_level orelse compileOpts.coverageLevel;
        if (compileOpts.coverageLevel < 0 or compileOpts.coverageLevel > 2)
            return L.Zerror("Invalid coverage level");

        // TODO: Enable after tests are added
        // compileOpts.vector_ctor = opts.vector_ctor orelse compileOpts.vector_ctor;
        // compileOpts.vector_lib = opts.vector_lib orelse compileOpts.vector_lib;
        // compileOpts.vector_type = opts.vector_type orelse compileOpts.vector_type;
    }

    const allocator = luau.getallocator(L);
    const bytecode = try luau.compile(allocator, source, compileOpts);
    defer allocator.free(bytecode);

    if (bytecode.len < 2)
        return error.LuauCompileError;

    const version = bytecode[0];
    const success = version != 0;
    if (!success) {
        L.pushlstring(bytecode[1..]);
        return error.RaiseLuauError;
    }

    L.pushlstring(bytecode);

    return 1;
}

fn lua_load(L: *VM.lua.State) !i32 {
    const bytecode = try L.Zcheckvalue([]const u8, 1, null);

    const Options = struct {
        nativeCodeGen: bool = false,
        chunkName: [:0]const u8 = "(load)",
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};

    var useCodeGen = opts.nativeCodeGen;
    const chunkName = opts.chunkName;

    try L.load(chunkName, bytecode, 0);

    if (L.typeOf(-1) != .Function)
        return L.Zerror("Luau Error (Bad Load)");

    if (L.typeOf(2) == .Table) {
        if (L.rawgetfield(2, "env") == .Table) {
            // TODO: should allow env to have a metatable?
            if (L.getmetatable(-1)) {
                useCodeGen = false; // dynamic env, disable codegen
                L.pop(1); // drop metatable
            }
            if (useCodeGen)
                L.setsafeenv(-1, true);
            if (!L.setfenv(-2))
                return L.Zerror("Luau Error (Bad Env)");
        } else L.pop(1);
    }

    if (useCodeGen and luau.CodeGen.Supported() and Zune.STATE.LUAU_OPTIONS.JIT_ENABLED)
        luau.CodeGen.Compile(L, -1);

    return 1;
}

fn lua_coverage(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Function);

    L.newtable();
    L.getcoverage(VM.lua.State, L, 1, struct {
        fn inner(l: *VM.lua.State, fnname: ?[:0]const u8, line: i32, depth: i32, hits: []const i32) void {
            l.createtable(0, 3);
            if (fnname) |name|
                l.Zsetfield(-1, "name", name);
            l.Zsetfield(-1, "line", line);
            l.Zsetfield(-1, "depth", depth);
            for (hits, 0..) |hit, i| {
                if (hit != -1) {
                    l.pushinteger(hit);
                    l.rawseti(-2, @intCast(i));
                }
            }
            l.rawseti(-2, @intCast(l.objlen(-2) + 1));
        }
    }.inner);

    return 1;
}

fn lua_parse(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const source = try L.Zcheckvalue([]const u8, 1, null);

    const lallocator = luau.Ast.Allocator.init();
    defer lallocator.deinit();

    const astNameTable = luau.Ast.Lexer.AstNameTable.init(lallocator);
    defer astNameTable.deinit();

    const parseResult = luau.Ast.Parser.parse(source, astNameTable, lallocator, .{
        .captureComments = true,
        .allowDeclarationSyntax = false,
        .storeCstData = true, // doesn't do anything with AstJsonEncoder
    });
    defer parseResult.deinit();

    var static_loc_buf: [256]u8 = undefined;
    if (!parseResult.errors.empty()) {
        L.createtable(0, 1);
        {
            L.createtable(@truncate(@as(isize, @intCast(parseResult.errors.size()))), 0);
            var iter = parseResult.errors.iterator();
            var count: i32 = 1;
            while (iter.next()) |err| : (count += 1) {
                const loc_str = try std.fmt.bufPrint(static_loc_buf[0..], "{d},{d} - {d},{d}", .{
                    err.value.location.begin.line,
                    err.value.location.begin.column,
                    err.value.location.end.line,
                    err.value.location.end.column,
                });
                L.Zpushvalue(.{
                    .message = err.value.message.slice(),
                    .location = loc_str,
                });
                L.rawseti(-2, count);
            }
        }
        L.setfield(-2, "errors");
    } else {
        const json_str = try luau.Analysis.AstJsonEncoder.toJson(allocator, @ptrCast(@alignCast(parseResult.root)));
        defer allocator.free(json_str);

        var root = try json.parse(allocator, json_str);
        defer root.deinit();

        L.createtable(0, 3);
        try SerdeJson.decodeValue(L, root.value, false);
        L.setfield(-2, "root");

        L.Zsetfield(-1, "lines", @as(f64, @floatFromInt(parseResult.lines)));

        {
            L.createtable(@truncate(@as(isize, @intCast(parseResult.commentLocations.size()))), 0);
            var iter = parseResult.commentLocations.iterator();
            var count: i32 = 1;
            while (iter.next()) |loc| : (count += 1) {
                const loc_str = try std.fmt.bufPrint(static_loc_buf[0..], "{d},{d} - {d},{d}", .{
                    loc.location.begin.line,
                    loc.location.begin.column,
                    loc.location.end.line,
                    loc.location.end.column,
                });
                L.Zpushvalue(.{
                    .type = @tagName(loc.type),
                    .location = loc_str,
                });
                L.rawseti(-2, count);
            }
        }
        L.setfield(-2, "commentLocations");

        {
            L.createtable(@truncate(@as(isize, @intCast(parseResult.hotcomments.size()))), 0);
            var iter = parseResult.hotcomments.iterator();
            var count: i32 = 1;
            while (iter.next()) |hc| : (count += 1) {
                const loc_str = try std.fmt.bufPrint(static_loc_buf[0..], "{d},{d} - {d},{d}", .{
                    hc.location.begin.line,
                    hc.location.begin.column,
                    hc.location.end.line,
                    hc.location.end.column,
                });
                L.Zpushvalue(.{
                    .header = hc.header,
                    .content = hc.content.slice(),
                    .location = loc_str,
                });
                L.rawseti(-2, count);
            }
        }
        L.setfield(-2, "hotcomments");
    }

    return 1;
}

fn lua_parseExpr(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const source = try L.Zcheckvalue([]const u8, 1, null);

    const lallocator = luau.Ast.Allocator.init();
    defer lallocator.deinit();

    const astNameTable = luau.Ast.Lexer.AstNameTable.init(lallocator);
    defer astNameTable.deinit();

    const parseResult = luau.Ast.Parser.parseExpr(source, astNameTable, lallocator, .{
        .captureComments = true,
        .allowDeclarationSyntax = false,
        .storeCstData = true, // doesn't do anything with AstJsonEncoder
    });
    defer parseResult.deinit();

    var static_loc_buf: [256]u8 = undefined;
    if (!parseResult.errors.empty()) {
        L.createtable(0, 1);
        {
            L.createtable(@truncate(@as(isize, @intCast(parseResult.errors.size()))), 0);
            var iter = parseResult.errors.iterator();
            var count: i32 = 1;
            while (iter.next()) |err| : (count += 1) {
                const loc_str = try std.fmt.bufPrint(static_loc_buf[0..], "{d},{d} - {d},{d}", .{
                    err.value.location.begin.line,
                    err.value.location.begin.column,
                    err.value.location.end.line,
                    err.value.location.end.column,
                });
                L.Zpushvalue(.{
                    .message = err.value.message.slice(),
                    .location = loc_str,
                });
                L.rawseti(-2, count);
            }
        }
        L.setfield(-2, "errors");
    } else {
        const json_str = try luau.Analysis.AstJsonEncoder.toJson(allocator, @ptrCast(@alignCast(parseResult.expr)));
        defer allocator.free(json_str);

        var root = try json.parse(allocator, json_str);
        defer root.deinit();

        L.createtable(0, 3);
        try SerdeJson.decodeValue(L, root.value, false);
        L.setfield(-2, "root");

        L.Zsetfield(-1, "lines", @as(f64, @floatFromInt(parseResult.lines)));

        {
            L.createtable(@truncate(@as(isize, @intCast(parseResult.commentLocations.size()))), 0);
            var iter = parseResult.commentLocations.iterator();
            var count: i32 = 1;
            while (iter.next()) |loc| : (count += 1) {
                const loc_str = try std.fmt.bufPrint(static_loc_buf[0..], "{d},{d} - {d},{d}", .{
                    loc.location.begin.line,
                    loc.location.begin.column,
                    loc.location.end.line,
                    loc.location.end.column,
                });
                L.Zpushvalue(.{
                    .type = @tagName(loc.type),
                    .location = loc_str,
                });
                L.rawseti(-2, count);
            }
        }
        L.setfield(-2, "commentLocations");

        {
            L.createtable(@truncate(@as(isize, @intCast(parseResult.hotcomments.size()))), 0);
            var iter = parseResult.hotcomments.iterator();
            var count: i32 = 1;
            while (iter.next()) |hc| : (count += 1) {
                const loc_str = try std.fmt.bufPrint(static_loc_buf[0..], "{d},{d} - {d},{d}", .{
                    hc.location.begin.line,
                    hc.location.begin.column,
                    hc.location.end.line,
                    hc.location.end.column,
                });
                L.Zpushvalue(.{
                    .header = hc.header,
                    .content = hc.content.slice(),
                    .location = loc_str,
                });
                L.rawseti(-2, count);
            }
        }
        L.setfield(-2, "hotcomments");
    }

    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    L.Zpushvalue(.{
        .compile = lua_compile,
        .load = lua_load,
        .coverage = lua_coverage,
        .parse = lua_parse,
        .parseExpr = lua_parseExpr,
    });
    L.setreadonly(-1, true);
    LuaHelper.registerModule(L, LIB_NAME);
}

test "luau" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/luau.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
