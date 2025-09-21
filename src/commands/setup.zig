const std = @import("std");
const json = @import("json");
const builtin = @import("builtin");
const lcompress = @import("lcompress");

const Zune = @import("zune");

const command = @import("lib.zig");

const file = @import("../core/resolvers/file.zig");

const OldWriter = @import("../core/utils/old_writer.zig");

const typedef = struct {
    name: []const u8,
    content: []const u8,
    docs: ?[]const u8,
};

pub const luaudefs = &[_]typedef{
    typedef{
        .name = "global/zune",
        .content = @embedFile("../types/global/zune.d.luau.gz"),
        .docs = @embedFile("../types/global/zune.d.json.gz"),
    },
};

const SetupInfo = struct {
    cwd: std.fs.Dir,
    home: []const u8,
};

const EditorKind = enum {
    vscode,
    zed,
    neovim,
    emacs,
};

const SetupMap = std.StaticStringMap(EditorKind).initComptime(.{
    .{ "vscode", .vscode },
    .{ "zed", .zed },
    .{ "emacs", .emacs },
    .{ "nvim", .neovim },
    .{ "neovim", .neovim },
});

fn setup(editor: EditorKind, allocator: std.mem.Allocator, setupInfo: SetupInfo) !void {
    const settings_file_path = switch (editor) {
        .vscode => ".vscode/settings.json",
        .neovim => ".nvim.lua",
        .emacs => ".dir-locals.el",
        .zed => ".zed/settings.json",
    };

    const cwd = setupInfo.cwd;

    if (std.fs.path.dirname(settings_file_path)) |parent_dir|
        cwd.makeDir(parent_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

    const settings_file = try cwd.createFile(settings_file_path, .{ .read = true, .truncate = false });
    defer settings_file.close();

    const settings_content = try settings_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(settings_content);

    const data = switch (editor) {
        .vscode => output: {
            const LUAU_LSP_DEFINITION_FILES = "luau-lsp.types.definitionFiles";
            const LUAU_LSP_DOCUMENTATION_FILES = "luau-lsp.types.documentationFiles";

            // Parse settings.json
            // settings_content
            var settings_root = json.parseJson5(allocator, "{}") catch |err| switch (err) {
                error.ParseValueError => {
                    std.debug.print("Failed to parse {s}\n", .{settings_file_path});
                    return;
                },
                else => return err,
            };
            defer settings_root.deinit();

            var settings_object = settings_root.value.asObject();

            // Get Values of luau-lsp.require.mode and luau-lsp.require.directoryAliases
            const definition_files = settings_object.get(LUAU_LSP_DEFINITION_FILES) orelse try settings_root.value.setWith(LUAU_LSP_DEFINITION_FILES, try settings_root.newArray());
            const documentation_files = settings_object.get(LUAU_LSP_DOCUMENTATION_FILES) orelse try settings_root.value.setWith(LUAU_LSP_DOCUMENTATION_FILES, try settings_root.newArray());
            var definition_files_array = definition_files.arrayOrNull() orelse Zune.quitMsg("{s} is not a valid Array", .{LUAU_LSP_DEFINITION_FILES});
            var documentation_files_array = documentation_files.arrayOrNull() orelse Zune.quitMsg("{s} is not a valid Array", .{LUAU_LSP_DOCUMENTATION_FILES});

            for (luaudefs) |type_file| {
                {
                    const file_name = try std.mem.join(allocator, "", &.{ type_file.name, ".d.luau" });
                    defer allocator.free(file_name);
                    const def_path = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", file_name });
                    defer allocator.free(def_path);
                    var exists = false;
                    for (definition_files_array.items) |value| {
                        if (value != .string)
                            continue;
                        const str = value.asString();
                        if (std.mem.eql(u8, str, def_path)) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists)
                        continue;
                    const defPath_copy = try settings_root.allocator.dupe(u8, def_path);
                    errdefer allocator.free(defPath_copy);
                    try definition_files_array.append(allocator, .{ .string = defPath_copy });
                }
                if (type_file.docs) |_| {
                    const file_name = try std.mem.join(allocator, "", &.{ type_file.name, ".d.json" });
                    defer allocator.free(file_name);
                    const file_path = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", file_name });
                    defer allocator.free(file_path);
                    var exists = false;
                    for (documentation_files_array.items) |value| {
                        if (value != .string)
                            continue;
                        const str = value.asString();
                        if (std.mem.eql(u8, str, file_path)) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists)
                        continue;
                    const file_path_copy = try settings_root.allocator.dupe(u8, file_path);
                    errdefer allocator.free(file_path_copy);
                    try documentation_files_array.append(allocator, .{ .string = file_path_copy });
                }
            }

            // Serialize settings.json
            var serialized_array: std.Io.Writer.Allocating = .init(allocator);
            defer serialized_array.deinit();

            try settings_root.value.serialize(&serialized_array.writer, .SPACES_2, 0);

            if (settings_content.len > 2) {
                std.debug.print(
                    \\Could not automatically update '{s}' because it already exists and has values.
                    \\Add these setting values below to '{s}'
                    \\
                    \\{s}
                    \\
                , .{ settings_file_path, settings_file_path, serialized_array.written() });
                return;
            }

            std.debug.print("{s}\n", .{serialized_array.written()});

            break :output try serialized_array.toOwnedSlice();
        },
        .zed => output: {
            // Parse settings.json
            var settings_root = json.parseJson5(allocator, "{}") catch |err| switch (err) {
                error.ParseValueError => {
                    std.debug.print("Failed to parse {s}\n", .{settings_file_path});
                    return;
                },
                else => return err,
            };
            defer settings_root.deinit();

            // Get Values of luau-lsp.require.mode and luau-lsp.require.directoryAliases
            var lsp = settings_root.value.asObject().get("lsp") orelse try settings_root.value.setWith("lsp", try settings_root.newObject());

            var luau_lsp_ext = lsp.asObject().get("luau-lsp") orelse try lsp.setWith("luau-lsp", try settings_root.newObject());

            var lsp_settings = luau_lsp_ext.asObject().get("settings") orelse try luau_lsp_ext.setWith("settings", try settings_root.newObject());

            var luau_ext = lsp_settings.asObject().get("ext") orelse try lsp_settings.setWith("ext", try settings_root.newObject());

            var definition_files = luau_ext.asObject().get("definitions") orelse try luau_ext.setWith("definitions", try settings_root.newArray());
            const definition_files_array = definition_files.asArray();

            var documentation_files = luau_ext.asObject().get("documentation") orelse try luau_ext.setWith("documentation", try settings_root.newArray());
            const documentation_files_array = documentation_files.asArray();

            for (luaudefs) |type_file| {
                {
                    const file_name = try std.mem.join(allocator, "", &.{ type_file.name, ".d.luau" });
                    defer allocator.free(file_name);
                    const file_path = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", file_name });
                    defer allocator.free(file_path);
                    var exists = false;
                    for (definition_files_array.items) |value| {
                        if (value != .string)
                            continue;
                        const str = value.asString();
                        if (std.mem.eql(u8, str, file_path)) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists)
                        continue;

                    const file_path_copy = try settings_root.allocator.dupe(u8, file_path);
                    errdefer allocator.free(file_path_copy);
                    try definition_files_array.append(allocator, .{ .string = file_path_copy });
                }
                if (type_file.docs) |_| {
                    const file_name = try std.mem.join(allocator, "", &.{ type_file.name, ".d.json" });
                    defer allocator.free(file_name);
                    const file_path = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", file_name });
                    defer allocator.free(file_path);
                    var exists = false;
                    for (documentation_files_array.items) |value| {
                        if (value != .string)
                            continue;
                        const str = value.asString();
                        if (std.mem.eql(u8, str, file_path)) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists)
                        continue;

                    const file_path_copy = try settings_root.allocator.dupe(u8, file_path);
                    errdefer allocator.free(file_path_copy);
                    try documentation_files_array.append(allocator, .{ .string = file_path_copy });
                }
            }

            // Serialize settings.json
            var serialized_array: std.Io.Writer.Allocating = .init(allocator);
            defer serialized_array.deinit();

            try settings_root.value.serialize(&serialized_array.writer, .SPACES_2, 0);

            if (settings_content.len > 2) {
                std.debug.print(
                    \\Could not automatically update '{s}' because it already exists and has values.
                    \\Add these setting values below to '{s}'
                    \\
                    \\{s}
                    \\
                , .{ settings_file_path, settings_file_path, serialized_array.written() });
                return;
            }

            std.debug.print("{s}\n", .{serialized_array.written()});

            break :output try serialized_array.toOwnedSlice();
        },
        .neovim => output: {
            const SEP = std.fs.path.sep_str;
            var typedef_path = try std.fmt.allocPrint(allocator, "{s}" ++ SEP ++ ".zune" ++ SEP ++ "typedefs" ++ SEP ++ "global" ++ SEP ++ "zune.d.luau", .{setupInfo.home});
            defer allocator.free(typedef_path);
            if (comptime builtin.os.tag == .windows) {
                const allocated = typedef_path;
                typedef_path = try std.mem.replaceOwned(u8, allocator, typedef_path, SEP, SEP ++ SEP);
                allocator.free(allocated);
            }

            var typedocs_path = try std.fmt.allocPrint(allocator, "{s}" ++ SEP ++ ".zune" ++ SEP ++ "typedefs" ++ SEP ++ "global" ++ SEP ++ "zune.d.json", .{setupInfo.home});
            defer allocator.free(typedocs_path);
            if (comptime builtin.os.tag == .windows) {
                const allocated = typedocs_path;
                typedocs_path = try std.mem.replaceOwned(u8, allocator, typedocs_path, SEP, SEP ++ SEP);
                allocator.free(allocated);
            }

            const config = try std.fmt.allocPrint(allocator,
                \\require("luau-lsp").config {{
                \\  types = {{
                \\    definition_files = {{
                \\      "{s}"
                \\    }},
                \\    documentation_files = {{
                \\      "{s}"
                \\    }},
                \\  }},
                \\}}
                \\
            , .{ typedef_path, typedocs_path });

            if (settings_content.len > 0) {
                defer allocator.free(config);
                std.debug.print(
                    \\Copy and paste the configuration below to '{s}'
                    \\ - configuration based on https://github.com/lopi-py/luau-lsp.nvim
                    \\
                    \\{s}
                    \\
                , .{ settings_file_path, config });
                return;
            }
            break :output config;
        },
        .emacs => output: {
            const SEP = std.fs.path.sep_str;
            var typedef_path = try std.fmt.allocPrint(allocator, "{s}" ++ SEP ++ ".zune" ++ SEP ++ "typedefs" ++ SEP ++ "global" ++ SEP ++ "zune.d.luau", .{setupInfo.home});
            defer allocator.free(typedef_path);
            if (comptime builtin.os.tag == .windows) {
                const allocated = typedef_path;
                typedef_path = try std.mem.replaceOwned(u8, allocator, typedef_path, SEP, SEP ++ SEP);
                allocator.free(allocated);
            }

            const config = try std.fmt.allocPrint(allocator,
                \\((nil . ((eglot-luau-custom-type-files . ("{s}")))))
                \\
            , .{typedef_path});

            if (settings_content.len > 0) {
                std.debug.print(
                    \\Copy and paste the configuration below to '{s}'
                    \\ - configuration based on https://github.com/kennethloeffler/eglot-luau
                    \\
                    \\{s}
                    \\
                , .{ settings_file_path, config });
                return;
            }
            break :output config;
        },
    };
    defer allocator.free(data);

    try settings_file.seekTo(0);
    try settings_file.writeAll(data);
    try settings_file.setEndPos(data.len);

    std.debug.print("Saved configuration to '{s}'\n", .{settings_file_path});
}

const USAGE = "usage: setup <nvim | zed | vscode | emacs>\n";
fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var envMap = try std.process.getEnvMap(allocator);
    defer envMap.deinit();

    const cwd = std.fs.cwd();

    const HOME = file.getHomeDir(envMap) orelse Zune.quitMsg("Failed to setup, $HOME/$USERPROFILE variable not found", .{});

    const path = try std.fs.path.resolve(allocator, &.{ HOME, ".zune/typedefs" });
    defer allocator.free(path);

    std.debug.print("Setting up zune in {s}\n", .{path});
    {
        const core_dir = try std.fs.path.resolve(allocator, &.{ path, "core" });
        defer allocator.free(core_dir);
        cwd.makePath(core_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    {
        const global_dir = try std.fs.path.resolve(allocator, &.{ path, "global" });
        defer allocator.free(global_dir);
        cwd.makePath(global_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    for (luaudefs) |type_def| {
        const file_name = try std.mem.concat(allocator, u8, &.{ type_def.name, ".d.luau" });
        defer allocator.free(file_name);
        const type_path = try std.fs.path.resolve(allocator, &.{ path, file_name });
        defer allocator.free(type_path);

        {
            var reader: std.Io.Reader = .fixed(type_def.content);
            var decompressed: std.Io.Writer.Allocating = .init(allocator);
            defer decompressed.deinit();

            try lcompress.gzip.decompress(reader.adaptToOldInterface(), OldWriter.adaptToOldInterface(&decompressed.writer));

            try cwd.writeFile(.{
                .sub_path = type_path,
                .data = decompressed.written(),
            });
        }

        if (type_def.docs) |docs| {
            const docs_name = try std.mem.concat(allocator, u8, &.{ type_def.name, ".d.json" });
            defer allocator.free(docs_name);
            const docs_path = try std.fs.path.resolve(allocator, &.{ path, docs_name });
            defer allocator.free(docs_path);

            var reader: std.Io.Reader = .fixed(docs);
            var decompressed: std.Io.Writer.Allocating = .init(allocator);
            defer decompressed.deinit();

            try lcompress.gzip.decompress(reader.adaptToOldInterface(), OldWriter.adaptToOldInterface(&decompressed.writer));

            try cwd.writeFile(.{
                .sub_path = docs_path,
                .data = decompressed.written(),
            });
        }
    }

    if (args.len > 0) {
        var out: [6]u8 = undefined;
        if (args[0].len > out.len) {
            std.debug.print("unknown editor configuration (input too large)\n", .{});
            return;
        }
        if (SetupMap.get(std.ascii.lowerString(&out, args[0]))) |editor| {
            try setup(editor, allocator, .{
                .cwd = cwd,
                .home = HOME,
            });
        } else std.debug.print(USAGE, .{});
    } else {
        std.debug.print("Setup complete, configuration: <none>\n", .{});
        std.debug.print("  For editor configuration -> {s}", .{USAGE});
    }
}

pub const Command = command.Command{ .name = "setup", .execute = Execute };
