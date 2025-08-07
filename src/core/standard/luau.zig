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
        type_info_Level: ?i32,
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

        compileOpts.typeInfoLevel = opts.type_info_Level orelse compileOpts.typeInfoLevel;
        if (compileOpts.typeInfoLevel < 0 or compileOpts.typeInfoLevel > 1)
            return L.Zerror("Invalid type info level");

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
        try L.pushlstring(bytecode[1..]);
        return error.RaiseLuauError;
    }

    try L.pushlstring(bytecode);

    return 1;
}

fn lua_load(L: *VM.lua.State) !i32 {
    const bytecode = try L.Zcheckvalue([]const u8, 1, null);

    const Options = struct {
        native_code_gen: bool = false,
        chunk_name: [:0]const u8 = "(load)",
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};

    var use_code_gen = opts.native_code_gen;

    try L.load(opts.chunk_name, bytecode, 0);

    if (L.typeOf(-1) != .Function)
        return L.Zerror("Luau Error (Bad Load)");

    if (L.typeOf(2) == .Table) {
        if (L.rawgetfield(2, "env") == .Table) {
            // TODO: should allow env to have a metatable?
            if (L.getmetatable(-1)) {
                use_code_gen = false; // dynamic env, disable codegen
                L.pop(1); // drop metatable
            }
            if (use_code_gen)
                L.setsafeenv(-1, true);
            if (!L.setfenv(-2))
                return L.Zerror("Luau Error (Bad Env)");
        } else L.pop(1);
    }

    if (use_code_gen and luau.CodeGen.Supported() and Zune.STATE.LUAU_OPTIONS.JIT_ENABLED)
        luau.CodeGen.Compile(L, -1);

    return 1;
}

fn getcoverage(L: *VM.lua.State, fnname: ?[:0]const u8, line: i32, depth: i32, hits: []const i32) !void {
    try L.createtable(0, 3);
    if (fnname) |name|
        try L.Zsetfield(-1, "name", name);
    try L.Zsetfield(-1, "line", line);
    try L.Zsetfield(-1, "depth", depth);
    for (hits, 0..) |hit, i| {
        if (hit != -1) {
            L.pushinteger(hit);
            try L.rawseti(-2, @intCast(i));
        }
    }
    try L.rawseti(-2, @intCast(L.objlen(-2) + 1));
}

fn lua_coverage(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Function);

    try L.newtable();
    L.getcoverage(VM.lua.State, L, 1, struct {
        fn inner(l: *VM.lua.State, fnname: ?[:0]const u8, line: i32, depth: i32, hits: []const i32) void {
            getcoverage(l, fnname, line, depth, hits) catch luau.VM.ldo.throw(l, .ErrMem); // only memory errors would occur
        }
    }.inner);

    return 1;
}

pub fn computeLineOffsets(allocator: std.mem.Allocator, source: []const u8) ![]const u32 {
    var offests: std.ArrayListUnmanaged(u32) = .empty;
    defer offests.deinit(allocator);

    try offests.append(allocator, 0);

    if (source.len > std.math.maxInt(u32))
        return error.LargeSource;

    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        switch (c) {
            '\r' => if (i + 1 < source.len and source[i + 1] == '\n') {
                i += 1;
            },
            '\n' => {},
            else => continue,
        }
        try offests.append(allocator, @intCast(i + 1));
    }

    return offests.toOwnedSlice(allocator);
}

const AstSerializer = struct {
    // Based on https://github.com/luau-lang/lute/blob/76fa819ee3cf202d979b59c477241c3968fe8b1a/lute/luau/src/luau.cpp#L135
    const Ast = luau.Ast.Ast;
    const Cst = luau.Ast.Cst;
    const Parser = luau.Ast.Parser;
    const Location = luau.Ast.Location.Location;

    allocator: std.mem.Allocator,

    L: *VM.lua.State,
    cst_node_map: *Parser.CstNodeMap,
    source: []const u8,
    current_position: Location.Position = .zeros,
    comment_locations: []const Parser.Comment,
    local_table_index: i32,
    last_token_ref: ?i32 = null,
    line_offsets: []const u32,

    fn advancePosition(self: *@This(), contents: []const u8) void {
        if (contents.len == 0)
            return;

        var index: usize = 0;
        var numLines: usize = 0;
        while (true) {
            const newlinePos = std.mem.indexOfScalar(u8, contents[index..], '\n') orelse break;
            numLines += 1;
            index += newlinePos + 1;
        }

        self.current_position.line += @intCast(numLines);
        if (numLines > 0)
            self.current_position.column = @intCast(contents.len - index)
        else
            self.current_position.column += @intCast(contents.len);
    }

    fn serializeLocal(self: *@This(), local: *Ast.Local, createToken: bool, colonPosition: ?Location.Position) !void {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 3);

        self.L.pushlightuserdata(@ptrCast(@alignCast(local)));

        if (self.L.rawget(self.local_table_index).isnoneornil()) {
            self.L.pop(1);
            try self.L.createtable(0, 4);

            self.L.pushlightuserdata(@ptrCast(@alignCast(local)));
            self.L.pushvalue(-2);
            try self.L.rawset(self.local_table_index);

            if (createToken) {
                try self.serializeToken(local.location.begin, std.mem.span(local.name.value), null);
                try self.L.rawsetfield(-2, "name");

                if (local.annotation != null) {
                    std.debug.assert(colonPosition != null);
                    try self.serializeToken(colonPosition.?, ":", null);
                    try self.L.rawsetfield(-2, "colon");
                }

                if (local.annotation) |annotation| {
                    try annotation.visit(self);
                    try self.L.rawsetfield(-2, "annotation");
                }
            }

            if (local.shadow) |shadow| {
                try self.serializeLocal(shadow, true, null);
                try self.L.rawsetfield(-2, "shadows");
            }
        }
    }

    fn serializeExprTableItem(self: *@This(), item: Ast.ExprTable.Item, cstNode: *Cst.ExprTable.Item) !void {
        try self.L.rawcheckstack(2);
        switch (item.kind) {
            .List => {
                try self.L.createtable(0, 3);
                try self.L.Zsetfield(-1, "kind", "list");

                _ = try self.visitExpr(item.value);
                try self.L.rawsetfield(-2, "value");
            },
            .Record => {
                try self.L.createtable(0, 5);
                try self.L.Zsetfield(-1, "kind", "record");

                const value = item.key.?.as(.expr_constant_string).?.value;
                try self.serializeToken(item.key.?.location.begin, value.slice(), null);
                try self.L.rawsetfield(-2, "key");

                std.debug.assert(cstNode.equalsPosition.has);
                try self.serializeToken(cstNode.equalsPosition.to().?, "=", null);
                try self.L.rawsetfield(-2, "equals");

                _ = try self.visitExpr(item.value);
                try self.L.rawsetfield(-2, "value");
            },
            .General => {
                try self.L.createtable(0, 7);
                try self.L.Zsetfield(-1, "kind", "general");

                std.debug.assert(cstNode.indexerOpenPosition.has);
                try self.serializeToken(cstNode.indexerOpenPosition.to().?, "[", null);
                try self.L.rawsetfield(-2, "indexerOpen");

                _ = try self.visitExpr(item.key.?);
                try self.L.rawsetfield(-2, "key");

                std.debug.assert(cstNode.indexerClosePosition.has);
                try self.serializeToken(cstNode.indexerClosePosition.to().?, "]", null);
                try self.L.rawsetfield(-2, "indexerClose");

                std.debug.assert(cstNode.equalsPosition.has);
                try self.serializeToken(cstNode.equalsPosition.to().?, "=", null);
                try self.L.rawsetfield(-2, "equals");

                _ = try self.visitExpr(item.value);
                try self.L.rawsetfield(-2, "value");
            },
        }
        if (cstNode.separator.has) {
            try self.serializeToken(cstNode.separatorPosition.value, if (cstNode.separator.value == .comma) "," else ";", null);
            try self.L.rawsetfield(-2, "separator");
        }
    }

    pub const Trivia = struct {
        kind: enum {
            Whitespace,
            SingleLineComment,
            MultiLineComment,
        },
        location: Location,
        text: []const u8,
    };

    fn extractWhitespace(self: *@This(), results: *std.ArrayListUnmanaged(Trivia), newPos: Location.Position) !void {
        const start_offset = self.line_offsets[self.current_position.line] + self.current_position.column;
        const end_offset = self.line_offsets[newPos.line] + newPos.column;

        var begin_position = self.current_position;

        var trivia = self.source[start_offset..end_offset];
        while (trivia.len > 0) {
            const index = std.mem.indexOfScalar(u8, trivia, '\n');
            var part: []const u8 = trivia;
            if (index) |idx| {
                part = trivia[0 .. idx + 1];
                trivia = trivia[idx + 1 ..];
            }
            self.advancePosition(part);
            try results.append(self.allocator, Trivia{
                .kind = .Whitespace,
                .location = .{ .begin = begin_position, .end = self.current_position },
                .text = part,
            });
            begin_position = self.current_position;
            if (index == null)
                break;
        }
    }

    fn extractTrivia(self: *@This(), newPos: Location.Position) ![]Trivia {
        std.debug.assert(self.current_position.lessThanOrEq(newPos));
        if (self.current_position.eq(newPos))
            return &.{};

        var results: std.ArrayListUnmanaged(Trivia) = .empty;
        errdefer results.deinit(self.allocator);
        const span: Location = .{ .begin = self.current_position, .end = newPos };
        for (self.comment_locations) |comment| {
            if (!span.encloses(comment.location))
                continue;

            if (self.current_position.lessThan(comment.location.begin))
                try self.extractWhitespace(&results, comment.location.begin);

            const start_offset = self.line_offsets[comment.location.begin.line] + comment.location.begin.column;
            const end_offset = self.line_offsets[comment.location.end.line] + comment.location.end.column;

            const comment_text = self.source[start_offset..end_offset];

            self.advancePosition(comment_text);

            try results.append(self.allocator, .{
                .kind = if (comment.type == .Comment) .SingleLineComment else .MultiLineComment,
                .location = comment.location,
                .text = comment_text,
            });
        }

        if (self.current_position.lessThan(newPos))
            try self.extractWhitespace(&results, newPos);

        return try results.toOwnedSlice(self.allocator);
    }

    fn splitTrivia(self: *@This(), trivia: []Trivia) !struct { []Trivia, []Trivia } {
        var split: usize = 0;
        for (trivia, 0..) |t, i| {
            split = i;
            if (t.kind == .Whitespace and std.mem.indexOfScalar(u8, t.text, '\n') != null)
                break;
        }

        if (split == trivia.len)
            return .{ trivia, &.{} };

        const trailing = try self.allocator.alloc(Trivia, trivia.len - split);
        errdefer self.allocator.free(trailing);
        const leading = try self.allocator.alloc(Trivia, split);
        errdefer self.allocator.free(leading);

        defer self.allocator.free(trivia);

        @memcpy(leading, trivia[0..split]);
        @memcpy(trailing, trivia[split..]);

        return .{ leading, trailing };
    }

    pub fn serializeTrivia(self: *@This(), trivia: []Trivia) !void {
        try self.L.rawcheckstack(3);
        try self.L.createtable(@truncate(trivia.len), 0);

        for (trivia, 0..) |t, i| {
            try self.L.Zpushvalue(.{
                .tag = switch (t.kind) {
                    .Whitespace => "whitespace",
                    .SingleLineComment => "comment",
                    .MultiLineComment => "blockcomment",
                },
                .location = t.location,
                .text = t.text,
            });
            try self.L.rawseti(-2, @intCast(i + 1));
        }
    }

    pub fn serializeToken(self: *@This(), position: Location.Position, text: []const u8, nrec: ?u32) !void {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, (nrec orelse 0) + 4);

        const trivia = try self.extractTrivia(position);
        if (self.last_token_ref) |ref| {
            const trailing_trivia, const leading_trivia = try self.splitTrivia(trivia);
            defer self.allocator.free(trailing_trivia);
            defer self.allocator.free(leading_trivia);

            std.debug.assert(self.L.getref(ref) == .Table);
            {
                defer self.L.unref(ref);
                try self.serializeTrivia(trailing_trivia);
                try self.L.rawsetfield(-2, "trailingTrivia");
                self.L.pop(1);
            }
            self.last_token_ref = null;

            try self.serializeTrivia(leading_trivia);
        } else {
            defer self.allocator.free(trivia);
            try self.serializeTrivia(trivia);
        }
        try self.L.rawsetfield(-2, "leadingTrivia");

        try self.L.Zsetfield(-1, "position", position);
        try self.L.Zsetfield(-1, "text", text);
        self.advancePosition(text);

        try self.L.createtable(0, 0);
        try self.L.rawsetfield(-2, "trailingTrivia");

        self.last_token_ref = try self.L.ref(-1);
    }

    fn serializeExprs(self: *@This(), exprs: Ast.Array(*Ast.Expr), nrec: u32) !void {
        try self.L.rawcheckstack(2);
        try self.L.createtable(@truncate(exprs.size), nrec);

        for (exprs.slice(), 1..) |expr, i| {
            try expr.visit(self);
            try self.L.rawseti(-2, @intCast(i));
        }
    }

    fn serializeStats(self: *@This(), stats: Ast.Array(*Ast.Stat), nrec: u32) !void {
        try self.L.rawcheckstack(2);
        try self.L.createtable(@truncate(stats.size), nrec);

        for (stats.slice(), 1..) |stat, i| {
            try stat.visit(self);
            try self.L.rawseti(-2, @intCast(i));
        }
    }

    fn serializeAttributes(self: *@This(), attrs: Ast.Array(*Ast.Attr), nrec: u32) !void {
        try self.L.rawcheckstack(3);
        try self.L.createtable(@truncate(attrs.size), nrec);

        for (attrs.slice(), 1..) |attr, i| {
            try self.L.createtable(0, nrec);

            switch (attr.type) {
                .Checked => try self.serializeToken(attr.location.begin, "@checked", null),
                .Native => try self.serializeToken(attr.location.begin, "@native", null),
                .Deprecated => try self.serializeToken(attr.location.begin, "@deprecated", null),
            }

            try self.L.Zsetfield(-1, "tag", "attribute");
            try self.L.Zsetfield(-1, "location", attr.location);

            try self.L.rawseti(-2, @intCast(i));
        }
    }

    fn serializePunctuated(self: *@This(), nodes: anytype, separators: []const Location.Position, separatorText: []const u8) !void {
        try self.L.rawcheckstack(3);
        try self.L.createtable(@truncate(nodes.size), 0);

        for (nodes.slice(), 0..) |arg, i| {
            try self.L.createtable(0, 2);

            try arg.visit(self);
            try self.L.rawsetfield(-2, "node");

            if (i < separators.len) {
                try self.serializeToken(separators[i], separatorText, null);
                try self.L.rawsetfield(-2, "separator");
            }

            try self.L.rawseti(-2, @intCast(i + 1));
        }
    }

    fn serializePunctuatedTypeOrPack(
        self: *@This(),
        nodes: Ast.Array(Ast.TypeOrPack),
        separators: []const Location.Position,
        separatorText: []const u8,
    ) !void {
        try self.L.rawcheckstack(3);
        try self.L.createtable(@truncate(nodes.size), 0);

        for (nodes.slice(), 0..) |arg, i| {
            try self.L.createtable(0, 2);

            if (arg.type) |@"type"|
                try @"type".visit(self)
            else
                try arg.typePack.?.visit(self);
            try self.L.rawsetfield(-2, "node");

            if (i < separators.len) {
                try self.serializeToken(separators[i], separatorText, null);
                try self.L.rawsetfield(-2, "separator");
            }

            try self.L.rawseti(-2, @intCast(i + 1));
        }
    }

    fn serializePunctuatedLocal(
        self: *@This(),
        nodes: Ast.Array(*Ast.Local),
        separators: []const Location.Position,
        separatorText: []const u8,
        colonPositions: Ast.Array(Location.Position),
    ) !void {
        try self.L.rawcheckstack(3);
        try self.L.createtable(@truncate(nodes.size), 0);

        for (nodes.slice(), 0..) |arg, i| {
            try self.L.createtable(0, 2);

            try self.serializeLocal(arg, true, if (colonPositions.size > i) colonPositions.data.?[i] else null);
            try self.L.rawsetfield(-2, "node");

            if (i < separators.len) {
                try self.serializeToken(separators[i - 1], separatorText, null);
                try self.L.rawsetfield(-2, "separator");
            }

            try self.L.rawseti(-2, @intCast(i + 1));
        }
    }

    pub fn visitExpr(self: *@This(), node: *Ast.Expr) !bool {
        try node.visit(self);
        return false;
    }
    pub fn visitExprGroup(self: *@This(), node: *Ast.ExprGroup) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "group");
        try self.L.Zsetfield(-1, "location", node.location);
        return false;
    }
    pub fn visitExprConstantNil(self: *@This(), node: *Ast.ExprConstantNil) !bool {
        try self.serializeToken(node.location.begin, "nil", 2);
        try self.L.Zsetfield(-1, "tag", "nil");
        try self.L.Zsetfield(-1, "location", node.location);
        return false;
    }
    pub fn visitExprConstantBool(self: *@This(), node: *Ast.ExprConstantBool) !bool {
        try self.serializeToken(node.location.begin, if (node.value) "true" else "false", 3);
        try self.L.Zsetfield(-1, "tag", "boolean");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.L.Zsetfield(-1, "value", node.value);
        return false;
    }
    pub fn visitExprConstantNumber(self: *@This(), node: *Ast.ExprConstantNumber) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_constant_number).?;

        try self.serializeToken(node.location.begin, cstNode.value.slice(), 3);
        try self.L.Zsetfield(-1, "tag", "number");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.L.Zsetfield(-1, "value", node.value);
        return false;
    }
    pub fn visitExprConstantString(self: *@This(), node: *Ast.ExprConstantString) !bool {
        // TODO: fix class index issues
        const cstNode: *Cst.ExprConstantString = @ptrCast(self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_constant_number).?);

        try self.serializeToken(node.location.begin, cstNode.sourceString.slice(), 4);
        try self.L.Zsetfield(-1, "tag", "string");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.L.Zsetfield(-1, "quoteStyle", switch (cstNode.quoteStyle) {
            .quoted_single => "single",
            .quoted_double => "double",
            .quoted_raw => "block",
            .quoted_interp => "interp",
        });
        try self.L.Zsetfield(-1, "blockDepth", cstNode.blockDepth);

        self.current_position = node.location.end;
        return false;
    }
    pub fn visitExprLocal(self: *@This(), node: *Ast.ExprLocal) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "local");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, std.mem.span(node.local.?.name.value), null);
        try self.L.rawsetfield(-2, "token");

        try self.serializeLocal(node.local.?, true, null);
        try self.L.rawsetfield(-2, "local");

        try self.L.Zsetfield(-1, "upvalue", node.upvalue);
        return false;
    }
    pub fn visitExprGlobal(self: *@This(), node: *Ast.ExprGlobal) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 3);

        try self.L.Zsetfield(-1, "tag", "global");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, std.mem.span(node.name.value), null);
        try self.L.rawsetfield(-2, "name");
        return false;
    }
    pub fn visitExprVarargs(self: *@This(), node: *Ast.ExprVarargs) !bool {
        try self.serializeToken(node.location.begin, "...", 2);
        try self.L.Zsetfield(-1, "tag", "vararg");
        try self.L.Zsetfield(-1, "location", node.location);
        return false;
    }
    pub fn visitExprCall(self: *@This(), node: *Ast.ExprCall) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_call).?;
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 8);

        try self.L.Zsetfield(-1, "tag", "call");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.func.visit(self);
        try self.L.rawsetfield(-2, "func");

        if (cstNode.openParens.to()) |parens| {
            try self.serializeToken(parens, "(", null);
            try self.L.rawsetfield(-2, "openParens");
        }

        try self.serializePunctuated(node.args, cstNode.commaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "arguments");

        try self.L.Zsetfield(-1, "self", node.self);
        try self.L.Zsetfield(-1, "argLocation", node.argLocation);

        if (cstNode.closeParens.to()) |parens| {
            try self.serializeToken(parens, ")", null);
            try self.L.rawsetfield(-2, "closeParens");
        }
        return false;
    }
    pub fn visitExprIndexName(self: *@This(), node: *Ast.ExprIndexName) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "indexname");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.expr.visit(self);
        try self.L.rawsetfield(-2, "expression");

        try self.serializeToken(node.opPosition, &[1]u8{node.op}, null);
        try self.L.rawsetfield(-2, "accessor");

        try self.serializeToken(node.indexLocation.begin, std.mem.span(node.index.value), null);
        try self.L.rawsetfield(-2, "index");
        try self.L.Zsetfield(-1, "indexLocation", node.indexLocation);
        return false;
    }
    pub fn visitExprIndexExpr(self: *@This(), node: *Ast.ExprIndexExpr) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_index_expr).?;
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "index");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.expr.visit(self);
        try self.L.rawsetfield(-2, "expression");

        try self.serializeToken(cstNode.openBracketPosition, "[", null);
        try self.L.rawsetfield(-2, "openBrackets");

        try node.index.visit(self);
        try self.L.rawsetfield(-2, "index");

        try self.serializeToken(cstNode.closeBracketPosition, "]", null);
        try self.L.rawsetfield(-2, "closeBrackets");
        return false;
    }
    pub fn serializeFunctionBody(self: *@This(), node: *Ast.ExprFunction) !void {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_function).?;
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 15);

        if (node.generics.size > 0 or node.genericPacks.size > 0) {
            try self.serializeToken(cstNode.openGenericsPosition, "<", null);
            try self.L.rawsetfield(-2, "openGenerics");

            const commas = cstNode.genericsCommaPositions;
            try self.serializePunctuated(node.generics, commas.slice(), ",");
            try self.L.rawsetfield(-2, "generics");

            try self.serializePunctuated(node.genericPacks, commas.slice()[node.generics.size..], ",");
            try self.L.rawsetfield(-2, "genericPacks");

            try self.serializeToken(cstNode.closeGenericsPosition, ">", null);
            try self.L.rawsetfield(-2, "closeGenerics");
        }

        if (node.self) |s| {
            try self.serializeLocal(s, false, null);
            try self.L.rawsetfield(-2, "self");
        }

        if (node.argLocation.to()) |argLocation| {
            try self.serializeToken(argLocation.begin, "(", null);
            try self.L.rawsetfield(-2, "openParens");
        }

        try self.serializePunctuatedLocal(node.args, cstNode.argsCommaPositions.slice(), ",", cstNode.argsAnnotationColonPositions);
        try self.L.rawsetfield(-2, "parameters");

        if (node.vararg) {
            try self.serializeToken(node.varargLocation.begin, "...", null);
            try self.L.rawsetfield(-2, "vararg");
        }

        if (node.varargAnnotation) |varargAnnotation| {
            try self.serializeToken(cstNode.varargAnnotationColonPosition, ":", null);
            try self.L.rawsetfield(-2, "varargColon");

            if (varargAnnotation.as(.type_pack_variadic)) |variadic|
                try self.serializeTypePackVariadic(variadic, true)
            else
                try varargAnnotation.visit(self);
            try self.L.rawsetfield(-2, "varargAnnotation");
        }

        if (node.argLocation.to()) |argLocation| {
            try self.serializeToken(.{
                .line = argLocation.end.line,
                .column = argLocation.end.column - 1,
            }, ")", null);
            try self.L.rawsetfield(-2, "closeParens");
        }

        if (node.returnAnnotation) |returnAnnotation| {
            try self.serializeToken(cstNode.returnSpecifierPosition, ":", null);
            try self.L.rawsetfield(-2, "returnSpecifier");

            try returnAnnotation.visit(self);
            try self.L.rawsetfield(-2, "returnAnnotation");
        }

        try node.body.visit(self);
        try self.L.rawsetfield(-2, "body");

        try self.serializeToken(node.body.location.end, "end", null);
        try self.L.rawsetfield(-2, "endKeyword");
    }
    pub fn visitExprFunction(self: *@This(), node: *Ast.ExprFunction) !bool {
        try self.L.rawcheckstack(3);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "function");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeAttributes(node.attributes, 0);
        try self.L.rawsetfield(-2, "attributes");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_function).?;

        try self.serializeToken(cstNode.functionKeywordPosition, "function", null);
        try self.L.rawsetfield(-2, "functionKeyword");

        try self.serializeFunctionBody(node);
        try self.L.rawsetfield(-2, "body");
        return false;
    }
    pub fn visitExprTable(self: *@This(), node: *Ast.ExprTable) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_table).?;
        try self.L.rawcheckstack(3);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "table");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "{", null);
        try self.L.rawsetfield(-2, "openBrace");

        try self.L.createtable(@truncate(node.items.size), 0);
        for (node.items.slice(), 0..) |item, i| {
            try self.serializeExprTableItem(item, &cstNode.items.data.?[i]);
            try self.L.rawseti(-2, @intCast(i + 1));
        }
        try self.L.rawsetfield(-2, "entries");

        try self.serializeToken(.{
            .line = node.location.end.line,
            .column = node.location.end.column - 1,
        }, "}", null);
        try self.L.rawsetfield(-2, "closeBrace");
        return false;
    }
    pub fn visitExprUnary(self: *@This(), node: *Ast.ExprUnary) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "unary");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_op).?;
        try self.serializeToken(cstNode.opPosition, node.op.toString(), null);
        try self.L.rawsetfield(-2, "operator");

        try node.expr.visit(self);
        try self.L.rawsetfield(-2, "operand");
        return false;
    }
    pub fn visitExprBinary(self: *@This(), node: *Ast.ExprBinary) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "binary");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.left.visit(self);
        try self.L.rawsetfield(-2, "lhsoperand");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_op).?;
        try self.serializeToken(cstNode.opPosition, node.op.toString(), null);
        try self.L.rawsetfield(-2, "operator");

        try node.right.visit(self);
        try self.L.rawsetfield(-2, "rhsoperand");
        return false;
    }
    pub fn visitExprTypeAssertion(self: *@This(), node: *Ast.ExprTypeAssertion) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "cast");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.expr.visit(self);
        try self.L.rawsetfield(-2, "operand");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_type_assertion).?;
        try self.serializeToken(cstNode.opPosition, "::", null);
        try self.L.rawsetfield(-2, "operator");

        try node.annotation.visit(self);
        try self.L.rawsetfield(-2, "annotation");
        return false;
    }
    pub fn visitExprIfElse(self: *@This(), node: *Ast.ExprIfElse) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_if_else).?;
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 9);

        try self.L.Zsetfield(-1, "tag", "conditional");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "if", null);
        try self.L.rawsetfield(-2, "ifKeyword");

        try node.condition.visit(self);
        try self.L.rawsetfield(-2, "condition");

        if (node.hasThen) {
            try self.serializeToken(cstNode.thenPosition, "then", null);
            try self.L.rawsetfield(-2, "thenKeyword");

            try node.trueExpr.visit(self);
            try self.L.rawsetfield(-2, "consequent");
        }

        try self.L.createtable(0, 6);

        var currentNode = node;
        var currentCstNode = cstNode;
        var i: usize = 1;
        while (currentNode.hasElse and currentNode.falseExpr.is(.expr_if_else) and currentCstNode.isElseIf) : (i += 1) {
            try self.L.createtable(0, 4);

            currentNode = node.falseExpr.as(.expr_if_else).?;
            currentCstNode = self.cst_node_map.find(@ptrCast(currentNode)).?.second.*.as(.expr_if_else).?;

            try self.serializeToken(node.location.begin, "elseif", null);
            try self.L.rawsetfield(-2, "elseifKeyword");

            try node.condition.visit(self);
            try self.L.rawsetfield(-2, "condition");

            if (node.hasThen) {
                try self.serializeToken(currentCstNode.thenPosition, "then", null);
                try self.L.rawsetfield(-2, "thenKeyword");
                try node.trueExpr.visit(self);
                try self.L.rawsetfield(-2, "consequent");
            }

            try self.L.rawseti(-2, @intCast(i));
        }
        try self.L.rawsetfield(-2, "elseifs");

        if (currentNode.hasElse) {
            try self.serializeToken(currentCstNode.elsePosition, "else", null);
            try self.L.rawsetfield(-2, "elseKeyword");
            try currentNode.falseExpr.visit(self);
            try self.L.rawsetfield(-2, "antecedent");
        }
        return false;
    }
    pub fn visitExprInterpString(self: *@This(), node: *Ast.ExprInterpString) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.expr_interp_string).?;
        try self.L.rawcheckstack(3);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "interpolatedstring");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.L.createtable(@truncate(node.strings.size), 0);
        try self.L.createtable(@truncate(node.expressions.size), 0);

        for (0..node.strings.size) |i| {
            const position = if (i > 0) cstNode.stringPositions.data.?[i] else node.location.begin;
            try self.serializeToken(position, cstNode.sourceStrings.data.?[i].slice(), null);
            try self.L.rawseti(-3, @intCast(i + 1));

            self.current_position.column += if (position.line == self.current_position.line) 2 else 1;

            if (i < node.expressions.size) {
                try node.expressions.data.?[i].visit(self);
                try self.L.rawseti(-2, @intCast(i + 1));
            }
        }

        try self.L.rawsetfield(-3, "expressions");
        try self.L.rawsetfield(-2, "strings");

        return false;
    }
    pub fn visitExprError(self: *@This(), node: *Ast.ExprError) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "error");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeExprs(node.expressions, 0);
        try self.L.rawsetfield(-2, "expressions");
        return false;
    }
    pub fn visitStat(self: *@This(), node: *Ast.Stat) !bool {
        try node.visit(self);
        return false;
    }
    pub fn visitStatBlock(self: *@This(), node: *Ast.StatBlock) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 3);

        try self.L.Zsetfield(-1, "tag", "block");
        try self.L.Zsetfield(-1, "location", node.location);

        {
            try self.L.rawcheckstack(2);
            try self.L.createtable(@truncate(node.body.size), 0);
            for (node.body.slice(), 1..) |stat, i| {
                try stat.visit(self);
                try self.L.rawseti(-2, @intCast(i));
            }
        }
        try self.L.rawsetfield(-2, "statements");

        return false;
    }
    pub fn visitStatIf(self: *@This(), node: *Ast.StatIf) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 10);

        try self.L.Zsetfield(-1, "tag", "conditional");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "if", null);
        try self.L.rawsetfield(-2, "ifKeyword");

        try node.condition.visit(self);
        try self.L.rawsetfield(-2, "condition");

        try self.serializeToken(node.thenLocation.value.begin, "then", null);
        try self.L.rawsetfield(-2, "thenKeyword");

        try node.thenbody.visit(self);
        try self.L.rawsetfield(-2, "consequent");

        try self.L.createtable(0, 6);

        var currentNode = node;
        var i: usize = 1;
        while (currentNode.elsebody) |elsebody| : (i += 1) {
            if (!elsebody.is(.stat_if))
                break;
            try self.L.createtable(0, 4);

            const elseif = elsebody.as(.stat_if).?;
            try self.serializeToken(elseif.location.begin, "elseif", null);
            try self.L.rawsetfield(-2, "elseifKeyword");

            try elseif.condition.visit(self);
            try self.L.rawsetfield(-2, "condition");

            try self.serializeToken(elseif.thenLocation.value.begin, "then", null);
            try self.L.rawsetfield(-2, "thenKeyword");

            try elseif.thenbody.visit(self);
            try self.L.rawsetfield(-2, "consequent");

            try self.L.rawseti(-2, @intCast(i));
            currentNode = elseif;
        }
        try self.L.rawsetfield(-2, "elseifs");

        if (currentNode.elsebody) |elsebody| {
            std.debug.assert(currentNode.elseLocation.has);
            try self.serializeToken(currentNode.elseLocation.value.begin, "else", null);
            try self.L.rawsetfield(-2, "elseKeyword");
            try currentNode.elsebody.?.visit(self);
            try self.L.rawsetfield(-2, "antecedent");

            try self.serializeToken(elsebody.location.end, "end", null);
            try self.L.rawsetfield(-2, "endKeyword");
        } else {
            try self.serializeToken(currentNode.thenbody.location.end, "end", null);
            try self.L.rawsetfield(-2, "endKeyword");
        }
        return false;
    }
    pub fn visitStatWhile(self: *@This(), node: *Ast.StatWhile) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 7);

        try self.L.Zsetfield(-1, "tag", "while");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "while", null);
        try self.L.rawsetfield(-2, "whileKeyword");

        try node.condition.visit(self);
        try self.L.rawsetfield(-2, "condition");

        if (node.hasDo) {
            try self.serializeToken(node.doLocation.begin, "do", null);
            try self.L.rawsetfield(-2, "doKeyword");
        }

        try node.body.visit(self);
        try self.L.rawsetfield(-2, "body");

        try self.serializeToken(node.body.location.end, "end", null);
        try self.L.rawsetfield(-2, "endKeyword");
        return false;
    }
    pub fn visitStatRepeat(self: *@This(), node: *Ast.StatRepeat) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "repeat");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "repeat", null);
        try self.L.rawsetfield(-2, "repeatKeyword");

        try node.body.visit(self);
        try self.L.rawsetfield(-2, "body");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_repeat).?;
        try self.serializeToken(cstNode.untilPosition, "until", null);
        try self.L.rawsetfield(-2, "untilKeyword");

        try node.condition.visit(self);
        try self.L.rawsetfield(-2, "condition");
        return false;
    }
    pub fn visitStatBreak(self: *@This(), node: *Ast.StatBreak) !bool {
        try self.L.rawcheckstack(2);
        try self.serializeToken(node.location.begin, "break", 2);

        try self.L.Zsetfield(-1, "tag", "break");
        try self.L.Zsetfield(-1, "location", node.location);
        return false;
    }
    pub fn visitStatContinue(self: *@This(), node: *Ast.StatContinue) !bool {
        try self.L.rawcheckstack(2);
        try self.serializeToken(node.location.begin, "continue", 2);
        try self.L.Zsetfield(-1, "tag", "continue");
        try self.L.Zsetfield(-1, "location", node.location);
        return false;
    }
    pub fn visitStatReturn(self: *@This(), node: *Ast.StatReturn) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "return");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "return", null);
        try self.L.rawsetfield(-2, "returnKeyword");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_return).?;
        try self.serializePunctuated(node.list, cstNode.commaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "expressions");
        return false;
    }
    pub fn visitStatExpr(self: *@This(), node: *Ast.StatExpr) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 3);

        try self.L.Zsetfield(-1, "tag", "expression");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.expr.visit(self);
        try self.L.rawsetfield(-2, "expression");
        return false;
    }
    pub fn visitStatLocal(self: *@This(), node: *Ast.StatLocal) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "local");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "local", null);
        try self.L.rawsetfield(-2, "localKeyword");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_local).?;
        try self.serializePunctuatedLocal(node.vars, cstNode.varsCommaPositions.slice(), ",", cstNode.varsAnnotationColonPositions);
        try self.L.rawsetfield(-2, "variables");

        if (node.equalsSignLocation.to()) |equalsSignLocation| {
            try self.serializeToken(equalsSignLocation.begin, "=", null);
            try self.L.rawsetfield(-2, "equals");
        }

        try self.serializePunctuated(node.values, cstNode.valuesCommaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "values");
        return false;
    }
    pub fn visitStatFor(self: *@This(), node: *Ast.StatFor) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 13);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_for).?;

        try self.L.Zsetfield(-1, "tag", "for");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "for", null);
        try self.L.rawsetfield(-2, "forKeyword");

        try self.serializeLocal(node.variable, true, cstNode.annotationColonPosition);
        try self.L.rawsetfield(-2, "variable");

        try self.serializeToken(cstNode.equalsPosition, "=", null);
        try self.L.rawsetfield(-2, "equals");

        try node.from.visit(self);
        try self.L.rawsetfield(-2, "from");

        try self.serializeToken(cstNode.endCommaPosition, ",", null);
        try self.L.rawsetfield(-2, "toComma");

        try node.to.visit(self);
        try self.L.rawsetfield(-2, "to");

        if (cstNode.stepCommaPosition.to()) |stepCommaPosition| {
            try self.serializeToken(stepCommaPosition, ",", null);
            try self.L.rawsetfield(-2, "stepComma");
        }

        if (node.step) |step| {
            try step.visit(self);
            try self.L.rawsetfield(-2, "step");
        }

        if (node.hasDo) {
            try self.serializeToken(node.doLocation.begin, "do", null);
            try self.L.rawsetfield(-2, "doKeyword");
        }

        try node.body.visit(self);
        try self.L.rawsetfield(-2, "body");

        try self.serializeToken(node.body.location.end, "end", null);
        try self.L.rawsetfield(-2, "endKeyword");
        return false;
    }
    pub fn visitStatForIn(self: *@This(), node: *Ast.StatForIn) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 9);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_for_in).?;

        try self.L.Zsetfield(-1, "tag", "forin");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "for", null);
        try self.L.rawsetfield(-2, "forKeyword");

        try self.serializePunctuatedLocal(node.vars, cstNode.varsCommaPositions.slice(), ",", cstNode.varsAnnotationColonPositions);
        try self.L.rawsetfield(-2, "variables");

        if (node.hasIn) {
            try self.serializeToken(node.inLocation.begin, "in", null);
            try self.L.rawsetfield(-2, "inKeyword");
        }

        try self.serializePunctuated(node.values, cstNode.valuesCommaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "values");

        if (node.hasDo) {
            try self.serializeToken(node.doLocation.begin, "do", null);
            try self.L.rawsetfield(-2, "doKeyword");
        }

        try node.body.visit(self);
        try self.L.rawsetfield(-2, "body");

        try self.serializeToken(node.body.location.end, "end", null);
        try self.L.rawsetfield(-2, "endKeyword");
        return false;
    }
    pub fn visitStatAssign(self: *@This(), node: *Ast.StatAssign) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_assign).?;

        try self.L.Zsetfield(-1, "tag", "assign");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializePunctuated(node.vars, cstNode.varsCommaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "variables");

        try self.serializeToken(cstNode.equalsPosition, "=", null);
        try self.L.rawsetfield(-2, "equals");

        try self.serializePunctuated(node.values, cstNode.valuesCommaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "values");
        return false;
    }
    pub fn visitStatCompoundAssign(self: *@This(), node: *Ast.StatCompoundAssign) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "compoundassign");
        try self.L.Zsetfield(-1, "location", node.location);

        try node.variable.visit(self);
        try self.L.rawsetfield(-2, "variable");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_compound_assign).?;
        try self.serializeToken(cstNode.opPosition, &[_]u8{ node.op.toString()[1], '=' }, null);
        try self.L.rawsetfield(-2, "operand");

        try node.value.visit(self);
        try self.L.rawsetfield(-2, "value");
        return false;
    }
    pub fn visitStatFunction(self: *@This(), node: *Ast.StatFunction) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "function");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_function).?;

        try self.serializeAttributes(node.func.attributes, 0);
        try self.L.rawsetfield(-2, "attributes");

        try self.serializeToken(cstNode.functionKeywordPosition, "function", null);
        try self.L.rawsetfield(-2, "functionKeyword");

        try node.name.visit(self);
        try self.L.rawsetfield(-2, "name");

        try self.serializeFunctionBody(node.func);
        try self.L.rawsetfield(-2, "body");
        return false;
    }
    pub fn visitStatLocalFunction(self: *@This(), node: *Ast.StatLocalFunction) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 7);

        try self.L.Zsetfield(-1, "tag", "localfunction");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeAttributes(node.func.attributes, 0);
        try self.L.rawsetfield(-2, "attributes");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_local_function).?;

        try self.serializeToken(cstNode.localKeywordPosition, "local", null);
        try self.L.rawsetfield(-2, "localKeyword");

        try self.serializeToken(cstNode.functionKeywordPosition, "function", null);
        try self.L.rawsetfield(-2, "functionKeyword");

        try self.serializeLocal(node.name, true, null);
        try self.L.rawsetfield(-2, "name");

        try self.serializeFunctionBody(node.func);
        try self.L.rawsetfield(-2, "body");
        return false;
    }
    pub fn visitStatTypeAlias(self: *@This(), node: *Ast.StatTypeAlias) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 11);

        try self.L.Zsetfield(-1, "tag", "typealias");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_type_alias).?;

        if (node.exported) {
            try self.serializeToken(node.location.begin, "export", null);
            try self.L.rawsetfield(-2, "export");
        }

        try self.serializeToken(cstNode.typeKeywordPosition, "type", null);
        try self.L.rawsetfield(-2, "typeToken");

        try self.serializeToken(node.nameLocation.begin, "name", null);
        try self.L.rawsetfield(-2, "name");

        if (node.generics.size > 0 or node.genericPacks.size > 0) {
            try self.serializeToken(cstNode.genericsOpenPosition, "<", null);
            try self.L.rawsetfield(-2, "openGenerics");

            const commas = cstNode.genericsCommaPositions;
            try self.serializePunctuated(node.generics, commas.slice(), ",");
            try self.L.rawsetfield(-2, "generics");

            try self.serializePunctuated(node.genericPacks, commas.slice()[node.generics.size..], ",");
            try self.L.rawsetfield(-2, "genericPacks");

            try self.serializeToken(cstNode.genericsClosePosition, ">", null);
            try self.L.rawsetfield(-2, "closeGenerics");
        }

        try self.serializeToken(cstNode.equalsPosition, "=", null);
        try self.L.rawsetfield(-2, "equals");

        try node.type.visit(self);
        try self.L.rawsetfield(-2, "type");
        return false;
    }
    pub fn visitStatTypeFunction(self: *@This(), node: *Ast.StatTypeFunction) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 7);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.stat_type_function).?;

        try self.L.Zsetfield(-1, "tag", "typefunction");
        try self.L.Zsetfield(-1, "location", node.location);

        if (node.exported) {
            try self.serializeToken(node.location.begin, "export", null);
            try self.L.rawsetfield(-2, "export");
        }

        try self.serializeToken(cstNode.typeKeywordPosition, "type", null);
        try self.L.rawsetfield(-2, "type");

        try self.serializeToken(cstNode.functionKeywordPosition, "function", null);
        try self.L.rawsetfield(-2, "functionKeyword");

        try self.serializeToken(node.nameLocation.begin, "name", null);
        try self.L.rawsetfield(-2, "name");

        try self.serializeFunctionBody(node.body);
        try self.L.rawsetfield(-2, "body");
        return false;
    }
    pub fn visitStatDeclareFunction(self: *@This(), node: *Ast.StatDeclareFunction) !bool {
        _ = self;
        _ = node;
        return false;
    }
    pub fn visitStatDeclareGlobal(self: *@This(), node: *Ast.StatDeclareGlobal) !bool {
        _ = self;
        _ = node;
        return false;
    }
    pub fn visitStatDeclareExternType(self: *@This(), node: *Ast.StatDeclareExternType) !bool {
        _ = self;
        _ = node;
        return false;
    }
    pub fn visitStatError(self: *@This(), node: *Ast.StatError) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "error");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeExprs(node.expressions, 0);
        try self.L.rawsetfield(-2, "expressions");

        try self.serializeStats(node.statements, 0);
        try self.L.rawsetfield(-2, "statements");
        return false;
    }
    pub fn visitType(_: *@This(), _: *Ast.Type) !bool {
        return true;
    }
    pub fn visitTypeReference(self: *@This(), node: *Ast.TypeReference) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 8);

        try self.L.Zsetfield(-1, "tag", "reference");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = if (node.prefix.has or node.hasParameterList)
            self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_reference).?
        else
            null;

        if (node.prefix.to()) |prefix| {
            std.debug.assert(node.prefixLocation.has);
            try self.serializeToken(node.prefixLocation.value.begin, std.mem.span(prefix.value), null);
            try self.L.rawsetfield(-2, "prefix");

            std.debug.assert(cstNode != null);
            std.debug.assert(cstNode.?.prefixPointPosition.has);
            try self.serializeToken(cstNode.?.prefixPointPosition.value, ".", null);
            try self.L.rawsetfield(-2, "prefixPoint");
        }

        try self.serializeToken(node.nameLocation.begin, std.mem.span(node.name.value), null);
        try self.L.rawsetfield(-2, "name");

        if (node.hasParameterList) {
            std.debug.assert(cstNode != null);
            try self.serializeToken(cstNode.?.openParametersPosition, "<", null);
            try self.L.rawsetfield(-2, "openParens");

            try self.serializePunctuatedTypeOrPack(node.parameters, cstNode.?.parametersCommaPositions.slice(), ",");
            try self.L.rawsetfield(-2, "parameters");

            try self.serializeToken(cstNode.?.closeParametersPosition, ">", null);
            try self.L.rawsetfield(-2, "closeParameters");
        }
        return false;
    }
    pub fn visitTypeTable(self: *@This(), node: *Ast.TypeTable) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_table).?;
        try self.L.rawcheckstack(2);
        if (cstNode.isArray) {
            try self.L.createtable(0, 6);

            try self.L.Zsetfield(-1, "tag", "array");
            try self.L.Zsetfield(-1, "location", node.location);

            try self.serializeToken(node.location.begin, "{", null);
            try self.L.rawsetfield(-2, "openBrace");

            if (node.indexer.?.accessLocation.to()) |accessLocation| {
                std.debug.assert(node.indexer.?.access != .ReadWrite);
                try self.serializeToken(accessLocation.begin, if (node.indexer.?.access == .Read) "read" else "write", null);
                try self.L.rawsetfield(-2, "access");
            }

            try node.indexer.?.resultType.visit(self);
            try self.L.rawsetfield(-2, "type");

            try self.serializeToken(.{
                .line = node.location.end.line,
                .column = node.location.end.column - 1,
            }, "}", null);
            try self.L.rawsetfield(-2, "closeBrace");
            return false;
        }
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "table");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "{", null);
        try self.L.rawsetfield(-2, "openBrace");

        try self.L.createtable(@truncate(cstNode.items.size), 0);
        var prop = node.props.data.?;
        for (cstNode.items.slice(), 0..) |item, i| {
            try self.L.rawcheckstack(2);
            try self.L.createtable(0, 8);

            if (item.kind == .indexer) {
                std.debug.assert(node.indexer != null);

                try self.L.Zsetfield(-1, "kind", "indexer");

                if (node.indexer.?.accessLocation.to()) |accessLocation| {
                    std.debug.assert(node.indexer.?.access != .ReadWrite);
                    try self.serializeToken(accessLocation.begin, if (node.indexer.?.access == .Read) "read" else "write", null);
                    try self.L.rawsetfield(-2, "access");
                }

                try self.serializeToken(item.indexerOpenPosition.to().?, "[", null);
                try self.L.rawsetfield(-2, "indexerOpen");

                try node.indexer.?.indexType.visit(self);
                try self.L.rawsetfield(-2, "key");

                try self.serializeToken(item.indexerClosePosition.to().?, "]", null);
                try self.L.rawsetfield(-2, "indexerClose");

                try self.serializeToken(item.colonPosition, ":", null);
                try self.L.rawsetfield(-2, "colon");

                try node.indexer.?.resultType.visit(self);
                try self.L.rawsetfield(-2, "type");

                if (item.separator.to()) |separator| {
                    try self.serializeToken(item.separatorPosition.to().?, if (separator == .comma) "," else ";", null);
                    try self.L.rawsetfield(-2, "separator");
                }
            } else {
                try self.L.Zsetfield(-1, "kind", if (item.kind == .string_property) "stringproperty" else "property");

                if (prop[0].accessLocation.to()) |accessLocation| {
                    std.debug.assert(prop[0].access != .ReadWrite);
                    try self.serializeToken(accessLocation.begin, if (prop[0].access == .Read) "read" else "write", null);
                    try self.L.rawsetfield(-2, "access");
                }

                if (item.kind == .string_property) {
                    try self.serializeToken(item.indexerOpenPosition.to().?, "[", null);
                    try self.L.rawsetfield(-2, "indexerOpen");
                    {
                        try self.serializeToken(item.stringPosition, item.stringInfo.?.sourceString.slice(), null);

                        switch (item.stringInfo.?.quoteStyle) {
                            .quoted_single => try self.L.Zsetfield(-2, "quoteStyle", "single"),
                            .quoted_double => try self.L.Zsetfield(-2, "quoteStyle", "double"),
                            else => unreachable,
                        }

                        if (item.stringPosition.line == self.current_position.line)
                            self.current_position.column += 2
                        else
                            self.current_position.column += 1;
                    }
                    try self.L.rawsetfield(-2, "key");

                    try self.serializeToken(item.indexerClosePosition.to().?, "]", null);
                    try self.L.rawsetfield(-2, "indexerClose");
                } else {
                    try self.serializeToken(prop[0].location.begin, std.mem.span(prop[0].name.value), null);
                    try self.L.rawsetfield(-2, "key");
                }

                try self.serializeToken(item.colonPosition, ":", null);
                try self.L.rawsetfield(-2, "colon");

                try prop[0].type.visit(self);
                try self.L.rawsetfield(-2, "value");

                if (item.separator.to()) |separator| {
                    try self.serializeToken(item.separatorPosition.to().?, if (separator == .comma) "," else ";", null);
                    try self.L.rawsetfield(-2, "separator");
                }

                prop += 1;
            }
            try self.L.rawseti(-2, @intCast(i + 1));
        }
        try self.L.rawsetfield(-2, "entries");

        try self.serializeToken(.{
            .line = node.location.end.line,
            .column = node.location.end.column - 1,
        }, "}", null);
        try self.L.rawsetfield(-2, "closeBrace");
        return false;
    }
    pub fn visitTypeFunction(self: *@This(), node: *Ast.TypeFunction) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 12);

        try self.L.Zsetfield(-1, "tag", "function");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_function).?;

        if (node.generics.size > 0 or node.genericPacks.size > 0) {
            try self.serializeToken(cstNode.openGenericsPosition, "<", null);
            try self.L.rawsetfield(-2, "openGenerics");

            const commas = cstNode.genericsCommaPositions;
            try self.serializePunctuated(node.generics, commas.slice(), ",");
            try self.L.rawsetfield(-2, "generics");

            try self.serializePunctuated(node.genericPacks, commas.slice()[node.generics.size..], ",");
            try self.L.rawsetfield(-2, "genericPacks");

            try self.serializeToken(cstNode.closeGenericsPosition, ">", null);
            try self.L.rawsetfield(-2, "closeGenerics");
        }

        try self.serializeToken(cstNode.openArgsPosition, "(", null);
        try self.L.rawsetfield(-2, "openParens");

        try self.L.createtable(@truncate(node.argTypes.types.size), 0);
        for (node.argTypes.types.slice(), 0..) |argType, i| {
            try self.L.rawcheckstack(4);
            try self.L.createtable(0, 2);

            {
                try self.L.createtable(0, 3);
                if (i < node.argNames.size and node.argNames.data.?[i].has) {
                    try self.serializeToken(node.argNames.data.?[i].value.location.begin, std.mem.span(node.argNames.data.?[i].value.name.value), null);
                    try self.L.rawsetfield(-2, "name");
                }

                if (i < cstNode.argumentNameColonPositions.size and cstNode.argumentNameColonPositions.data.?[i].has) {
                    try self.serializeToken(cstNode.argumentNameColonPositions.data.?[i].value, ":", null);
                    try self.L.rawsetfield(-2, "colon");
                }

                try argType.visit(self);
                try self.L.rawsetfield(-2, "type");
            }
            try self.L.rawsetfield(-2, "node");

            if (i < cstNode.argumentsCommaPositions.size) {
                try self.serializeToken(cstNode.argumentsCommaPositions.data.?[i], ",", null);
                try self.L.rawsetfield(-2, "separator");
            }

            try self.L.rawseti(-2, @intCast(i + 1));
        }
        try self.L.rawsetfield(-2, "parameters");

        if (node.argTypes.tailType) |tailType| {
            try tailType.visit(self);
            try self.L.rawsetfield(-2, "vararg");
        }

        try self.serializeToken(cstNode.closeArgsPosition, ")", null);
        try self.L.rawsetfield(-2, "closeParens");

        try self.serializeToken(cstNode.returnArrowPosition, "->", null);
        try self.L.rawsetfield(-2, "returnArrow");

        try node.returnTypes.visit(self);
        try self.L.rawsetfield(-2, "returnTypes");
        return false;
    }
    pub fn visitTypeTypeof(self: *@This(), node: *Ast.TypeTypeof) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "typeof");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "typeof", null);
        try self.L.rawsetfield(-2, "typeof");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_typeof).?;
        try self.serializeToken(cstNode.openPosition, "(", null);
        try self.L.rawsetfield(-2, "openParens");

        try node.expr.visit(self);
        try self.L.rawsetfield(-2, "expression");

        try self.serializeToken(cstNode.closePosition, ")", null);
        try self.L.rawsetfield(-2, "closeParens");
        return false;
    }
    pub fn visitTypeUnion(self: *@This(), node: *Ast.TypeUnion) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_union).?;

        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "union");
        try self.L.Zsetfield(-1, "location", node.location);

        if (cstNode.leadingPosition.to()) |leadingPosition| {
            try self.serializeToken(leadingPosition, "|", null);
            try self.L.rawsetfield(-2, "leading");
        }

        try self.L.createtable(@truncate(node.types.size), 0);
        var separatorPositions: usize = 0;
        for (node.types.slice(), 0..) |typeNode, i| {
            try self.L.rawcheckstack(2);
            try self.L.createtable(0, 2);

            if (typeNode.is(.type_optional)) {
                try self.serializeToken(typeNode.location.begin, "?", 1);
                try self.L.Zsetfield(-2, "tag", "optional");
                try self.L.rawsetfield(-2, "node");
            } else {
                try typeNode.visit(self);
                try self.L.rawsetfield(-2, "node");

                if (i < node.types.size - 1 and !node.types.data.?[i + 1].is(.type_optional) and
                    separatorPositions < cstNode.separatorPositions.size)
                {
                    try self.serializeToken(cstNode.separatorPositions.data.?[separatorPositions], "|", null);
                    try self.L.rawsetfield(-2, "separator");
                }
                separatorPositions += 1;
            }

            try self.L.rawseti(-2, @intCast(i + 1));
        }
        try self.L.rawsetfield(-2, "types");
        return false;
    }
    pub fn visitTypeIntersection(self: *@This(), node: *Ast.TypeIntersection) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_intersection).?;

        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "intersection");
        try self.L.Zsetfield(-1, "location", node.location);

        if (cstNode.leadingPosition.to()) |leadingPosition| {
            try self.serializeToken(leadingPosition, "&", null);
            try self.L.rawsetfield(-2, "leading");
        }

        try self.serializePunctuated(node.types, cstNode.separatorPositions.slice(), "&");
        try self.L.rawsetfield(-2, "types");
        return false;
    }
    pub fn visitTypeSingletonBool(self: *@This(), node: *Ast.TypeSingletonBool) !bool {
        try self.serializeToken(node.location.begin, if (node.value) "true" else "false", 3);
        try self.L.Zsetfield(-1, "tag", "boolean");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.L.Zsetfield(-1, "value", node.value);
        return false;
    }
    pub fn visitTypeSingletonString(self: *@This(), node: *Ast.TypeSingletonString) !bool {
        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_singleton_string).?;
        try self.serializeToken(node.location.begin, cstNode.sourceString.slice(), 3);
        try self.L.Zsetfield(-1, "tag", "string");
        try self.L.Zsetfield(-1, "location", node.location);

        switch (cstNode.quoteStyle) {
            .quoted_single => try self.L.Zsetfield(-1, "quoteStyle", "single"),
            .quoted_double => try self.L.Zsetfield(-1, "quoteStyle", "double"),
            else => unreachable,
        }

        std.debug.assert(self.current_position.lessThanOrEq(node.location.end));
        self.current_position = node.location.end;
        return false;
    }
    pub fn visitTypeError(_: *@This(), _: *Ast.TypeError) !bool {
        return true;
    }
    pub fn visitTypePack(_: *@This(), _: *Ast.TypePack) !bool {
        return true;
    }
    pub fn visitTypePackExplicit(self: *@This(), node: *Ast.TypePackExplicit) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 6);

        try self.L.Zsetfield(-1, "tag", "explicit");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_pack_explicit).?;

        if (cstNode.hasParentheses) {
            try self.serializeToken(cstNode.openParenthesesPosition, "(", null);
            try self.L.rawsetfield(-2, "openParens");
        }

        try self.serializePunctuated(node.typeList.types, cstNode.commaPositions.slice(), ",");
        try self.L.rawsetfield(-2, "types");

        if (node.typeList.tailType) |tailType| {
            try tailType.visit(self);
            try self.L.rawsetfield(-2, "tailType");
        }

        if (cstNode.hasParentheses) {
            try self.serializeToken(cstNode.closeParenthesesPosition, ")", null);
            try self.L.rawsetfield(-2, "closeParens");
        }

        return false;
    }
    fn serializeTypePackVariadic(self: *@This(), node: *Ast.TypePackVariadic, forVarArg: bool) !void {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "variadic");
        try self.L.Zsetfield(-1, "location", node.location);

        if (forVarArg) {
            try self.serializeToken(node.location.begin, "...", null);
            try self.L.rawsetfield(-2, "ellipsis");
        }

        try node.variadicType.visit(self);
        try self.L.rawsetfield(-2, "type");
    }
    pub fn visitTypePackVariadic(self: *@This(), node: *Ast.TypePackVariadic) !bool {
        try self.serializeTypePackVariadic(node, false);
        return false;
    }
    pub fn visitTypePackGeneric(self: *@This(), node: *Ast.TypePackGeneric) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "generic");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, std.mem.span(node.genericName.value), null);
        try self.L.rawsetfield(-2, "name");

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.type_pack_generic).?;
        try self.serializeToken(cstNode.ellipsisPosition, "...", null);
        try self.L.rawsetfield(-2, "ellipsis");
        return false;
    }
    pub fn visitTypeGroup(self: *@This(), node: *Ast.TypeGroup) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "group");
        try self.L.Zsetfield(-1, "location", node.location);

        try self.serializeToken(node.location.begin, "(", null);
        try self.L.rawsetfield(-2, "openParens");

        try node.type.visit(self);
        try self.L.rawsetfield(-2, "type");

        try self.serializeToken(.{
            .line = node.location.end.line,
            .column = node.location.end.column - 1,
        }, ")", null);
        try self.L.rawsetfield(-2, "closeParens");
        return false;
    }
    pub fn visitGenericType(self: *@This(), node: *Ast.GenericType) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 5);

        try self.L.Zsetfield(-1, "tag", "generic");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.generic_type).?;

        try self.serializeToken(node.location.begin, std.mem.span(node.name.value), null);
        try self.L.rawsetfield(-2, "name");

        if (node.defaultValue) |defaultValue| {
            try self.serializeToken(cstNode.defaultEqualsPosition.value, "=", null);
            try self.L.rawsetfield(-2, "equals");

            try defaultValue.visit(self);
            try self.L.rawsetfield(-2, "default");
        }
        return false;
    }
    pub fn visitGenericTypePack(self: *@This(), node: *Ast.GenericTypePack) !bool {
        try self.L.rawcheckstack(2);
        try self.L.createtable(0, 4);

        try self.L.Zsetfield(-1, "tag", "generic");
        try self.L.Zsetfield(-1, "location", node.location);

        const cstNode = self.cst_node_map.find(@ptrCast(node)).?.second.*.as(.generic_type_pack).?;
        try self.serializeToken(node.location.begin, std.mem.span(node.name.value), null);
        try self.L.rawsetfield(-2, "name");

        try self.serializeToken(cstNode.ellipsisPosition, "...", null);
        try self.L.rawsetfield(-2, "ellipsis");

        if (node.defaultValue) |defaultValue| {
            try self.serializeToken(cstNode.defaultEqualsPosition.value, "=", null);
            try self.L.rawsetfield(-2, "equals");

            try defaultValue.visit(self);
            try self.L.rawsetfield(-2, "default");
        }
        return false;
    }
};

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

    if (!parseResult.errors.empty()) {
        try L.createtable(0, 1);
        {
            try L.createtable(@truncate(parseResult.errors.size()), 0);
            var iter = parseResult.errors.iterator();
            var count: i32 = 1;
            while (iter.next()) |err| : (count += 1) {
                try L.Zpushvalue(.{
                    .message = err.value.message.slice(),
                    .location = err.value.location,
                });
                try L.rawseti(-2, count);
            }
        }
        try L.rawsetfield(-2, "errors");
        return 1;
    }

    const line_offsets = try computeLineOffsets(allocator, source);
    defer allocator.free(line_offsets);

    try L.createtable(0, 0);
    try L.createtable(0, 4);
    var serializer: AstSerializer = .{
        .L = L,
        .allocator = allocator,
        .cst_node_map = &parseResult.cstNodeMap,
        .source = source,
        .local_table_index = L.absindex(-2),
        .comment_locations = parseResult.commentLocations.begin[0..parseResult.commentLocations.size()],
        .line_offsets = line_offsets,
    };
    try parseResult.root.visit(&serializer);

    try L.rawsetfield(-2, "root");

    try serializer.serializeToken(parseResult.root.location.end, "", null);
    if (serializer.last_token_ref) |ref|
        L.unref(ref);
    try L.Zsetfield(-1, "tag", "eof");
    try L.rawsetfield(-2, "eof");

    try L.Zsetfield(-1, "lines", @as(f64, @floatFromInt(parseResult.lines)));
    try L.createtable(@intCast(line_offsets.len), 0);
    for (line_offsets, 0..) |offset, i| {
        L.pushunsigned(offset);
        try L.rawseti(-2, @intCast(i + 1));
    }
    try L.rawsetfield(-2, "lineOffsets");
    {
        try L.createtable(@truncate(parseResult.hotcomments.size()), 0);
        var iter = parseResult.hotcomments.iterator();
        var count: i32 = 1;
        while (iter.next()) |hc| : (count += 1) {
            try L.Zpushvalue(.{
                .header = hc.header,
                .content = hc.content.slice(),
                .location = hc.location,
            });
            try L.rawseti(-2, count);
        }
    }
    try L.rawsetfield(-2, "hotcomments");

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
        .storeCstData = true,
    });
    defer parseResult.deinit();

    if (!parseResult.errors.empty()) {
        try L.createtable(0, 1);
        {
            try L.createtable(@truncate(parseResult.errors.size()), 0);
            var iter = parseResult.errors.iterator();
            var count: i32 = 1;
            while (iter.next()) |err| : (count += 1) {
                try L.Zpushvalue(.{
                    .message = err.value.message.slice(),
                    .location = err.value.location,
                });
                try L.rawseti(-2, count);
            }
        }
        try L.rawsetfield(-2, "errors");
        return 1;
    }

    const line_offsets = try computeLineOffsets(allocator, source);
    defer allocator.free(line_offsets);

    try L.createtable(0, 0);
    var serializer: AstSerializer = .{
        .L = L,
        .allocator = allocator,
        .cst_node_map = &parseResult.cstNodeMap,
        .source = source,
        .local_table_index = L.absindex(-1),
        .comment_locations = parseResult.commentLocations.begin[0..parseResult.commentLocations.size()],
        .line_offsets = line_offsets,
    };
    try parseResult.expr.visit(&serializer);
    if (serializer.last_token_ref) |ref|
        L.unref(ref);
    return 1;
}

fn lua_garbagecollect(L: *VM.lua.State) !i32 {
    _ = L.gc(.Collect, 0);
    return 0;
}

pub fn loadLib(L: *VM.lua.State) !void {
    try L.Zpushvalue(.{
        .compile = lua_compile,
        .load = lua_load,
        .coverage = lua_coverage,
        .parse = lua_parse,
        .parseExpr = lua_parseExpr,
        .garbagecollect = lua_garbagecollect,
    });
    L.setreadonly(-1, true);
    try LuaHelper.registerModule(L, LIB_NAME);
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
