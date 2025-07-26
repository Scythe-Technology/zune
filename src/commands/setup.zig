const std = @import("std");
const json = @import("json");

const command = @import("lib.zig");

const file = @import("../core/resolvers/file.zig");

const typedef = struct {
    name: []const u8,
    content: []const u8,
};

pub const luaudefs = &[_]typedef{
    typedef{ .name = "global/zune", .content = @embedFile("../types/global/zune.d.luau.gz") },
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

            // Parse settings.json
            var settingsRoot = json.parseJson5(allocator, if (settings_content.len > 2) settings_content else "{}") catch |err| switch (err) {
                error.ParseValueError => {
                    std.debug.print("Failed to parse {s}\n", .{settings_file_path});
                    return;
                },
                else => return err,
            };
            defer settingsRoot.deinit();

            var settingsObject = settingsRoot.value.asObject();

            // Get Values of luau-lsp.require.mode and luau-lsp.require.directoryAliases
            const definitionFiles = settingsObject.get(LUAU_LSP_DEFINITION_FILES) orelse try settingsRoot.value.setWith(LUAU_LSP_DEFINITION_FILES, try settingsRoot.newArray());
            var definitionFilesArray = definitionFiles.arrayOrNull() orelse std.debug.panic("{s} is not a valid Array", .{LUAU_LSP_DEFINITION_FILES});

            for (luaudefs) |typeFile| {
                const fileName = try std.mem.join(allocator, "", &.{ typeFile.name, ".d.luau" });
                defer allocator.free(fileName);
                const defPath = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", fileName });
                defer allocator.free(defPath);
                var exists = false;
                for (definitionFilesArray.items) |value| {
                    if (value != .string)
                        continue;
                    const str = value.asString();
                    if (std.mem.eql(u8, str, defPath)) {
                        exists = true;
                        break;
                    }
                }
                if (exists)
                    continue;
                const defPath_copy = try settingsRoot.allocator.dupe(u8, defPath);
                errdefer allocator.free(defPath_copy);
                try definitionFilesArray.append(.{ .string = defPath_copy });
            }

            // Serialize settings.json
            var serializedArray = std.ArrayList(u8).init(allocator);
            defer serializedArray.deinit();

            try settingsRoot.value.serialize(serializedArray.writer(), .SPACES_2, 0);

            std.debug.print(
                \\{{
                \\  "luau-lsp.types.definitionFiles": [
                \\    "{s}/.zune/typedefs/global/zune.d.luau"
                \\  ]
                \\}}
                \\
            , .{setupInfo.home});

            break :output try serializedArray.toOwnedSlice();
        },
        .zed => output: {
            // Parse settings.json
            var settingsRoot = json.parseJson5(allocator, if (settings_content.len > 2) settings_content else "{}") catch |err| switch (err) {
                error.ParseValueError => {
                    std.debug.print("Failed to parse {s}\n", .{settings_file_path});
                    return;
                },
                else => return err,
            };
            defer settingsRoot.deinit();

            // Get Values of luau-lsp.require.mode and luau-lsp.require.directoryAliases
            var lsp = settingsRoot.value.asObject().get("lsp") orelse try settingsRoot.value.setWith("lsp", try settingsRoot.newObject());

            var luau_lsp_ext = lsp.asObject().get("luau-lsp") orelse try lsp.setWith("luau-lsp", try settingsRoot.newObject());

            var lsp_settings = luau_lsp_ext.asObject().get("settings") orelse try luau_lsp_ext.setWith("settings", try settingsRoot.newObject());

            var luau_ext = lsp_settings.asObject().get("ext") orelse try lsp_settings.setWith("ext", try settingsRoot.newObject());

            var definitionFiles = luau_ext.asObject().get("definitions") orelse try luau_ext.setWith("definitions", try settingsRoot.newArray());
            const definitionFilesArray = definitionFiles.asArray();
            for (luaudefs) |typeFile| {
                const fileName = try std.mem.join(allocator, "", &.{ typeFile.name, ".d.luau" });
                defer allocator.free(fileName);
                const defPath = try std.fs.path.resolve(allocator, &.{ setupInfo.home, ".zune/typedefs/", fileName });
                defer allocator.free(defPath);
                var exists = false;
                for (definitionFilesArray.items) |value| {
                    if (value != .string)
                        continue;
                    const str = value.asString();
                    if (std.mem.eql(u8, str, defPath)) {
                        exists = true;
                        break;
                    }
                }
                if (exists)
                    continue;

                const defPath_copy = try settingsRoot.allocator.dupe(u8, defPath);
                errdefer allocator.free(defPath_copy);
                try definitionFilesArray.append(.{ .string = defPath_copy });
            }

            // Serialize settings.json
            var serializedArray = std.ArrayList(u8).init(allocator);
            defer serializedArray.deinit();
            try settingsRoot.value.serialize(serializedArray.writer(), .SPACES_2, 0);

            std.debug.print(
                \\{{
                \\  "lsp": {{
                \\    "luau-lsp": {{
                \\      "settings": {{
                \\        "ext": {{
                \\          "definitions": [
                \\            "{s}/.zune/typedefs/global/zune.d.luau"
                \\          ]
                \\        }}
                \\      }}
                \\    }}
                \\  }}
                \\}}
                \\
            , .{setupInfo.home});

            break :output try serializedArray.toOwnedSlice();
        },
        .neovim => output: {
            const config = try std.fmt.allocPrint(allocator,
                \\require("luau-lsp").config {{
                \\  types = {{
                \\    definition_files = {{
                \\      "{s}/.zune/typedefs/global/zune.d.luau"
                \\    }},
                \\  }},
                \\}}
                \\
            , .{setupInfo.home});

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
            const config = try std.fmt.allocPrint(allocator,
                \\((nil . ((eglot-luau-custom-type-files . ("{s}/.zune/typedefs/global/zune.d.luau")))))
                \\
            , .{setupInfo.home});

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

    const HOME = file.getHomeDir(envMap) orelse std.debug.panic("Failed to setup, $HOME/$USERPROFILE variable not found", .{});

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

    for (luaudefs) |typeFile| {
        const fileName = try std.mem.join(allocator, "", &.{ typeFile.name, ".d.luau" });
        defer allocator.free(fileName);
        const typePath = try std.fs.path.resolve(allocator, &.{ path, fileName });
        defer allocator.free(typePath);

        var contentStream = std.io.fixedBufferStream(typeFile.content);
        var decompressed = std.ArrayList(u8).init(allocator);
        defer decompressed.deinit();

        try std.compress.gzip.decompress(contentStream.reader(), decompressed.writer());

        try cwd.writeFile(std.fs.Dir.WriteFileOptions{
            .sub_path = typePath,
            .data = decompressed.items,
        });
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
