--!strict
--- @description Setup environment for luau-lsp with editor of your choice.

local process = zune.process
local serde = zune.serde

local fs = require("@zune/fs")
local io = require("@zune/io")
local ansi = require("@zune/ansi").auto()

type Editor = {
    path: string,
    empty_limit: number,
    show_body: boolean,
    render: (definition_path: string, documentation_path: string) -> string,
    blocked: (settings_path: string, body: string) -> string,
}

local function fail(label: string, msg: string): never
    print(`{ansi.paint(ansi.red, label)}: {msg}`)
    return process.exit(1)
end

local function vscode(definition_path: string, documentation_path: string): string
    return serde.json.encode({
        ["luau-lsp.types.definitionFiles"] = { zune = definition_path },
        ["luau-lsp.types.documentationFiles"] = { documentation_path },
    }, { pretty_indent = 1 })
end

local function zed(definition_path: string, documentation_path: string): string
    return serde.json.encode({
        lsp = {
            ["luau-lsp"] = {
                settings = {
                    ext = {
                        definitions = { definition_path },
                        documentation = { documentation_path },
                    },
                },
            },
        },
    }, { pretty_indent = 1 })
end

local function escape(path: string): string
    local escaped = (string.gsub(path, "\\", "\\\\"))
    return (string.gsub(escaped, '"', '\\"'))
end

local function neovim(definition_path: string, documentation_path: string): string
    local definition = escape(definition_path)
    local documentation = escape(documentation_path)
    return table.concat({
        'require("luau-lsp").config {',
        "  platform = {",
        '    type = "standard",',
        "  },",
        "  types = {",
        "    definition_files = {",
        `      zune = "{definition}",`,
        "    },",
        "    documentation_files = {",
        `      "{documentation}",`,
        "    },",
        "  },",
        "}",
        "",
    }, "\n")
end

local function emacs(definition_path: string, documentation_path: string): string
    local definition = escape(definition_path)
    local documentation = escape(documentation_path)
    return table.concat({
        `((nil . ((eglot-luau-custom-type-files . ("{definition}"))`,
        `         (eglot-luau-custom-doc-files . ("{documentation}")))))`,
        "",
    }, "\n")
end

local function jsonBlocked(settings_path: string, body: string): string
    return `Could not automatically update '{settings_path}' because it already exists and has values.\nAdd these setting values below to '{settings_path}'\n\n{body}\n`
end

local function pasteBlocked(page: string): (string, string) -> string
    return function(settings_path: string, body: string): string
        return `Copy and paste the configuration below to '{settings_path}'\n - configuration based on {page}\n\n{body}`
    end
end

local neovim_editor: Editor = {
    path = ".nvim.lua",
    empty_limit = 0,
    show_body = false,
    render = neovim,
    blocked = pasteBlocked("https://github.com/lopi-py/luau-lsp.nvim"),
}

local EDITORS: { [string]: Editor } = {
    vscode = {
        path = ".vscode/settings.json",
        empty_limit = 2,
        show_body = true,
        render = vscode,
        blocked = jsonBlocked,
    },
    zed = {
        path = ".zed/settings.json",
        empty_limit = 2,
        show_body = true,
        render = zed,
        blocked = jsonBlocked,
    },
    nvim = neovim_editor,
    neovim = neovim_editor,
    emacs = {
        path = ".dir-locals.el",
        empty_limit = 0,
        show_body = false,
        render = emacs,
        blocked = pasteBlocked("https://github.com/kennethloeffler/eglot-luau"),
    },
}

local function install(cwd: Dir, editor: Editor, definition_path: string, documentation_path: string)
    local body = editor.render(definition_path, documentation_path)
    local parent = fs.path.dirname(editor.path)
    if parent then
        local ok, err = pcall(function()
            cwd:createDir(parent)
        end)
        if not ok and (err :: any) ~= "PathAlreadyExists" then
            error(tostring(err), 0)
        end
    end

    local file = cwd:createFile(editor.path, {
        read = true,
        truncate = false,
        nonblocking = true,
    })

    local reader = io.createReader(file, { positional = true })
    local existing = buffer.tostring(reader:readRemainingAlloc())
    if #existing > editor.empty_limit then
        file:close()
        print(editor.blocked(editor.path, body))
        return
    end

    if editor.show_body then
        print(body)
    end

    local writer = io.createWriter(file, { positional = true })
    writer:writeAll(body)
    file:setSize(#body)
    file:close()
    print(`Saved configuration to '{editor.path}'`)
end

local exe_path = process.getExePath()
local exe_dir = fs.path.dirname(exe_path)
if not exe_dir then
    fail("error", "failed to get the directory of the executable")
    return
end

local types_dir = fs.path.resolve(exe_dir, "types")
local definition_path = fs.path.join(types_dir, "zune.d.luau")
local documentation_path = fs.path.join(types_dir, "zune.d.json")

local ok, dir = pcall(function()
    return io.cwd():openDir(exe_dir)
end)
if not ok then
    fail("error", `failed to open directory: {tostring(dir)}`)
    return
end
if fs.statFile(dir, "types").kind ~= "directory" then
    dir:close()
    fail("error", `'{types_dir}' directory not found`)
    return
end
if fs.statFile(dir, fs.path.join("types", "zune.d.luau")).kind ~= "file" then
    dir:close()
    fail("error", `'{definition_path}' file not found`)
    return
end
if fs.statFile(dir, fs.path.join("types", "zune.d.json")).kind ~= "file" then
    dir:close()
    fail("error", `'{documentation_path}' file not found`)
    return
end
dir:close()

print(`setting up zune in {types_dir}`)

local OPTIONS = "<nvim | zed | vscode | emacs>"

local editor_name = process.args[2]
if not editor_name then
    print("setup complete, configuration: <none>")
    print(`  For editor configuration -> setup {OPTIONS}`)
    return
end

local editor = EDITORS[string.lower(editor_name)]
if not editor then
    fail("usage", `setup {OPTIONS}`)
    return
end

install(io.cwd(), editor, definition_path, documentation_path)
