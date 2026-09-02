const std = @import("std");
const json = @import("json");
const builtin = @import("builtin");
const Zune = @import("zune");

const command = @import("lib.zig");

const file = @import("../core/resolvers/file.zig");
const Flate = @import("../core/utils/flate.zig");

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
    cwd: std.Io.Dir,
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
        cwd.createDir(Zune.io(), parent_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

    const settings_file = try cwd.createFile(Zune.io(), settings_file_path, .{ .read = true, .truncate = false });
    defer settings_file.close(Zune.io());

    var settings_file_reader = settings_file.reader(Zune.io(), &.{});

    const settings_content = try settings_file_reader.interface.allocRemaining(allocator, .unlimited);
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
            defer settings_root.deinit(allocator);

            var settings_object = settings_root.value.asObject();

            // Get Values of luau-lsp.require.mode and luau-lsp.require.directoryAliases
            const definition_files = settings_object.get(LUAU_LSP_DEFINITION_FILES) orelse try settings_root.value.setWith(allocator, LUAU_LSP_DEFINITION_FILES, try json.Value.newObject(allocator));
            const documentation_files = settings_object.get(LUAU_LSP_DOCUMENTATION_FILES) orelse try settings_root.value.setWith(allocator, LUAU_LSP_DOCUMENTATION_FILES, try json.Value.newArray(allocator));
            var definition_files_object = definition_files.objectOrNull() orelse Zune.quitMsg("{s} is not a valid Object", .{LUAU_LSP_DEFINITION_FILES});
            var documentation_files_array = documentation_files.arrayOrNull() orelse Zune.quitMsg("{s} is not a valid Array", .{LUAU_LSP_DOCUMENTATION_FILES});

            for (luaudefs) |type_file| {
                {
                    const file_name = try std.mem.join(allocator, "", &.{ type_file.name, ".d.luau" });
                    defer allocator.free(file_name);
                    const def_path = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", file_name });
                    defer allocator.free(def_path);
                    if (definition_files_object.contains("zune"))
                        continue;
                    const def_path_copy = try allocator.dupe(u8, def_path);
                    errdefer allocator.free(def_path_copy);
                    const key = try allocator.dupe(u8, "zune");
                    errdefer allocator.free(key);
                    try definition_files_object.put(allocator, key, .{ .string = def_path_copy });
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
                    const file_path_copy = try allocator.dupe(u8, file_path);
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
            defer settings_root.deinit(allocator);

            // Get Values of luau-lsp.require.mode and luau-lsp.require.directoryAliases
            var lsp = settings_root.value.asObject().get("lsp") orelse try settings_root.value.setWith(allocator, "lsp", try json.Value.newObject(allocator));

            var luau_lsp_ext = lsp.asObject().get("luau-lsp") orelse try lsp.setWith(allocator, "luau-lsp", try json.Value.newObject(allocator));

            var lsp_settings = luau_lsp_ext.asObject().get("settings") orelse try luau_lsp_ext.setWith(allocator, "settings", try json.Value.newObject(allocator));

            var luau_ext = lsp_settings.asObject().get("ext") orelse try lsp_settings.setWith(allocator, "ext", try json.Value.newObject(allocator));

            var definition_files = luau_ext.asObject().get("definitions") orelse try luau_ext.setWith(allocator, "definitions", try json.Value.newArray(allocator));
            const definition_files_array = definition_files.asArray();

            var documentation_files = luau_ext.asObject().get("documentation") orelse try luau_ext.setWith(allocator, "documentation", try json.Value.newArray(allocator));
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

                    const file_path_copy = try allocator.dupe(u8, file_path);
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

                    const file_path_copy = try allocator.dupe(u8, file_path);
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

    try settings_file.writePositionalAll(Zune.io(), data, 0);
    try settings_file.setLength(Zune.io(), data.len);

    std.debug.print("Saved configuration to '{s}'\n", .{settings_file_path});
}

const OPTIONS = "<nvim | zed | vscode | emacs>";
fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const envMap = Zune.State.env_map;

    const cwd = std.Io.Dir.cwd();

    const HOME = file.getHomeDir(envMap) orelse Zune.quitMsg("<red>error<clear>: failed to setup, $HOME/$USERPROFILE variable not found", .{});

    const path = try std.fs.path.resolve(allocator, &.{ HOME, ".zune/typedefs" });
    defer allocator.free(path);

    std.debug.print("setting up zune in {s}\n", .{path});

    {
        const global_dir = try std.fs.path.resolve(allocator, &.{ path, "global" });
        defer allocator.free(global_dir);
        cwd.createDirPath(Zune.io(), global_dir) catch |err| switch (err) {
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
            const decompressed = try Flate.decompress(allocator, type_def.content, .gzip);
            defer allocator.free(decompressed);

            try cwd.writeFile(Zune.io(), .{
                .sub_path = type_path,
                .data = decompressed,
            });
        }

        if (type_def.docs) |docs| {
            const docs_name = try std.mem.concat(allocator, u8, &.{ type_def.name, ".d.json" });
            defer allocator.free(docs_name);
            const docs_path = try std.fs.path.resolve(allocator, &.{ path, docs_name });
            defer allocator.free(docs_path);

            const decompressed = try Flate.decompress(allocator, docs, .gzip);
            defer allocator.free(decompressed);

            try cwd.writeFile(Zune.io(), .{
                .sub_path = docs_path,
                .data = decompressed,
            });
        }
    }

    if (args.len > 0) {
        var out: [6]u8 = undefined;
        if (args[0].len > out.len) {
            Zune.quitMsg("<red>error<clear>: unknown editor configuration (input too large)\n", .{});
        }
        if (SetupMap.get(std.ascii.lowerString(&out, args[0]))) |editor| {
            try setup(editor, allocator, .{
                .cwd = cwd,
                .home = HOME,
            });
        } else Zune.quitMsg("<red>usage<clear>: setup {s}\n", .{OPTIONS});
    } else {
        std.debug.print("setup complete, configuration: <none>\n", .{});
        std.debug.print("  For editor configuration -> setup {s}", .{OPTIONS});
    }
}

pub const Command = command.Command{
    .name = "setup",
    .execute = Execute,
    .description = "Setup environment for luau-lsp with editor of your choice.",
    .template = "[editor]",
};
