--!strict
--!optimize 2

local mem = zune.mem
local ascii = zune.ascii
local task = zune.task
local luau = zune.luau
local crypto = zune.crypto
local process = zune.process

local fs = require("@zune/fs")
local io = require("@zune/io")
local text = require("@zune/text")
local runtime = require("@zune/runtime")
local archive = require("@zune/package/archive")
local fetch = require("@zune/package/fetch")
local git = require("@zune/package/git")
local trace = require("@zune/package/trace")
local slot = require("@zune/package/slot")
local spec = require("@zune/spec")

local ansi = require("@zune/ansi").auto()

local SemanticVersion = require("@zune/SemanticVersion")
local Node = require("@zune/package/Node")
local Dependency = require("@zune/package/Dependency")

trace.mask(getfenv())

export type RegistryValue = {
    value: any,
}

export type CopyFile = {
    node: Node.Node,
    key: string,
    override: boolean,
}

export type InstallFile = {
    node: Node.Node,
    key: string,
    name: string,
    dir_text: string?,
    dir_node: Node.Node?,
}

export type ModuleFile = {
    dest: Node.Node,
    value: any,
}

export type PackageState = {
    exported: { [string]: RegistryValue },
    installs: { InstallFile },
    copies: { CopyFile },
    modules: { ModuleFile },
    phase: "declare" | "build" | "done",
    dep_at: number,
    given: any?,
    rerun: (() -> ())?,
}

export type Package = {
    name: string,
    version: string?,
    dir: string,
    file: string?,
    deps: { Node.Node },
    entry: Node.Node?,
    scripts: { Node.Node },
    embeds: { Node.Node },
    paths: { string }?,
    config: any?,
    scheduled: { Node.Node },
    state: PackageState,
}

export type Claim = {
    pkg: Package,
    trace: string,
}

export type Reporter = {
    message: (self: Reporter, text: string, name: string?) -> (),
    confirm: (self: Reporter, prompt: string, msg: string?) -> boolean,
    progress: (self: Reporter, name: string, got: number, total: number?, done: number?, known: number?) -> (),
}

type DownloadPart = {
    got: number,
    total: number?,
}

export type Meter = {
    seen: { [string]: boolean },
    known: number,
    done: number,
    parts: { [string]: DownloadPart },
    active: boolean,
}

export type Context = {
    root_dir: string,
    workspace: string,
    target: string,
    zune_bin: string?,
    yes: boolean,

    reporter: Reporter?,

    edges: { [string]: { string } },
    known: { [string]: boolean },
    by_path: { [string]: Package },
    stack_path: { [string]: boolean },
    loaded: { Package },
    live: { [Node.Node]: boolean },
    waiting: { [Node.Node]: string },
    settled: { [Node.Node]: boolean },
    next_id: number,
    meter: Meter,
    no_fetch: boolean,
    no_unpack: boolean,
    missing: { Node.Node },
    copy_at: { [string]: Claim },
    install_at: { [string]: Claim },
    out: string?,
    failed: string,
    given: { [string]: any }?,

    createNode: (ctx: Context, pkg: Package, kind: Node.Kind, name: string) -> Node.Node,
}

export type LuauConfig = {
    languagemode: string?,
    lint: { [string]: boolean }?,
    linterrors: boolean?,
    typeerrors: boolean?,
    globals: { string }?,
    aliases: { [string]: string }?,
}

export type DependencySpec = {
    --- Local package directory, relative to the current package.
    --- (`url` must be unset)
    path: string?,
    --- Archive or repository URL to fetch (`http`, `https`, `file`, or `git+https://host/repo.git#commit`).
    --- (`path` must be unset)
    ---
    --- Cached under `.zune/pkg/<name>-<version>-<hash>` for managed packages, or `P_-<hash>` for unmanaged archives.
    url: string?,
    --- Integrity hash used to verify the downloaded archive.
    --- Leave unset on first install to generate the hash.
    hash: string?,
    --- Archive entries to extract.
    --- Defaults to the package's `paths` if managed, or the entire archive otherwise.
    paths: { string }?,
    --- Skip running this package's `build` script (treat it as a prebuilt artifact).
    --- A `package.luau` that fails to load is ignored, and the dependency stays unnamed.
    artifact: boolean?,
    --- Maximum unpacked size in bytes, checked before extraction. Defaults to 8 GiB.
    max_size: number?,
    --- Key-value options passed to the dependency's build script.
    options: { [string]: any }?,
}

export type PlaceOptions = {
    --- Destination directory as a node, or a path relative to the build directory.
    dir: (string | Node.Node)?,
    --- Target filename. Defaults to the source node's basename.
    name: string?,
}

export type CopyOptions = {
    --- Destination directory as a node, or a path relative to the build directory.
    --- Defaults to the current package directory.
    dir: (string | Node.Node)?,
    --- Target filename. Defaults to the source node's basename.
    name: string?,
    --- Overwrite the destination if it already exists. Defaults to `false`.
    override: boolean?,
}

export type CommandSpec = {
    --- Shell command to run.
    run: string,
    --- Input nodes copied into `ZUNE_INPUTS` before running the command.
    inputs: { Node.Node }?,
    --- Cache the step's output across runs. Defaults to `true`.
    cache: boolean?,
}

export type ExecuteSpec = {
    --- Input nodes copied into `ZUNE_INPUTS` before running the script.
    inputs: { Node.Node }?,
    --- Cache the step's output across runs. Defaults to `true`.
    cache: boolean?,
}

export type Build = {
    --- Declares a package or archive dependency, fetched on demand.
    ---
    --- For managed packages, the name and version are read from `package.luau`.
    ---
    --- ```lua
    --- local example = b.dependency({ path = "../example" })
    --- local lib = b.dependency({
    ---     url = "file:///vendor/libsample.tar.gz",
    ---     hash = "P_-5SSPtcx_KNcutrYLpDpDql1KO9I25FNzVN7TWjY9EOM=",
    ---     artifact = true,
    --- })
    --- local host = b.dependency(b.switch({
    ---     ["x86_64-linux"] = { path = "deps/linux" },
    ---     default = { path = "deps/host" },
    --- }))
    --- ```
    ---
    --- @param spec - Dependency specification.
    --- @return The dependency handle.
    dependency: (spec: DependencySpec) -> Dependency.Dependency,

    --- Exports a named value for dependent packages to read via `dep:get(name)`.
    ---
    --- Values are stored as-is. Throws an error if `name` is already exported.
    ---
    --- ```lua
    --- b.export("bin", lib:path("lib/libsample.so"))
    --- b.export("note") -- exports nil
    --- ```
    ---
    --- @param name - Export name.
    --- @param value - Value to export.
    export: (name: string, value: any?) -> (),

    --- Reads a build option passed by a dependent package.
    ---
    --- Returns `nil` if the option was not provided or holds an unsupported value
    --- (function, thread, userdata, or node).
    ---
    --- ```lua
    --- local version = b.option("version", "library release") or "6.0"
    --- ```
    ---
    --- @param name - Option name.
    --- @param description - Short description of the option.
    --- @return The option value, or `nil`.
    option: (name: string, description: string) -> any,

    --- Copies a file or directory into the final build output (`.zune/out` by default).
    ---
    --- Only takes effect in the root package; calls from dependencies are ignored.
    --- A string `options.dir` resolves relative to the build directory, while a node
    --- targets that directory directly. Leave `options.name` unset to keep the source basename.
    ---
    --- ```lua
    --- b.install(lib:get("bin"), { name = "libsample.so" })
    --- b.install(b.self():path("assets"), { dir = "assets" })
    --- ```
    ---
    --- @param item - File or directory node to install.
    --- @param options - Optional destination directory and filename.
    install: (item: Node.Node, options: PlaceOptions?) -> (),

    --- Copies a file or directory into the current package.
    ---
    --- Runs for every package during both install and build. Leave `options.dir` unset to copy
    --- into the package root. Existing files and directories are preserved unless
    --- `options.override` is `true`.
    ---
    --- ```lua
    --- local readme = b.copy(lib:path("README.md"))
    --- local bin = b.copy(lib:path("lib/libsample.so"), { name = "libsample.so", override = true })
    --- ```
    ---
    --- @param item - File or directory node to copy.
    --- @param options - Optional destination directory, filename, and overwrite behavior.
    --- @return A node for the destination path (`dir:path(name)`), or `nil` for an unnamed export.
    copy: (item: Node.Node, options: CopyOptions?) -> Node.Node?,

    --- Generates a Luau module (`return <value>`) inside the current package.
    ---
    --- Nodes are serialized as paths relative to the module file. Unserializable values
    --- fail when written, and unchanged files are not rewritten.
    ---
    --- ```lua
    --- b.module(b.self():path("settings.luau"), {
    ---     version = "6.0",
    ---     bin = lib:path("lib/libsample.so"),
    --- })
    --- ```
    ---
    --- @param dest - Target file node inside the current package.
    --- @param value - Literal value, node, or table of those to serialize.
    module: (dest: Node.Node, value: any) -> (),

    --- Sets the bundle's entry point script.
    ---
    --- ```lua
    --- b.entry(b.self():path("main.luau"))
    --- ```
    ---
    --- @param item - File node for the entry script.
    entry: (item: Node.Node) -> (),

    --- Includes Luau scripts in the bundle from a file, directory, or glob node.
    ---
    --- Directories expand to `<dir>/**/*.luau` (including `.config.luau`). `require` calls
    --- are not automatically crawled, so include needed scripts explicitly.
    ---
    --- ```lua
    --- b.embedScript(b.self():path("src/lib.luau"))
    --- b.embedScript(b.self():glob("**/*.luau"))
    --- b.embedScript(sample)
    --- ```
    ---
    --- @param item - File, directory, or glob node.
    embedScript: (item: Node.Node) -> (),

    --- Embeds static files into the bundle from a file or glob node.
    ---
    --- Pass a glob node to embed files from a directory.
    ---
    --- ```lua
    --- b.embedFile(b.self():path("assets/icon.png"))
    --- b.embedFile(b.self():glob("**/*.png"))
    --- ```
    ---
    --- @param item - File or glob node.
    embedFile: (item: Node.Node) -> (),

    --- Writes the package's `.config.luau` file, overwriting any existing file.
    ---
    --- `luau.aliases` accepts nodes or strings, and other fields under `luau` configure
    --- language settings. A node is a path relative to this file.
    --- Top-level keys outside `luau` are preserved as-is.
    --- Calling `bind` more than once throws an error.
    ---
    --- ```lua
    --- b.bind({
    ---     luau = {
    ---         aliases = {
    ---             sample = sample,
    ---             zune = b.std(),
    ---         },
    ---         languagemode = "strict",
    ---     },
    --- })
    --- ```
    ---
    --- @param spec - Configuration table matching the `.config.luau` schema.
    bind: (spec: any) -> (),

    --- Returns a node for the current package directory.
    ---
    --- ```lua
    --- b.entry(b.self():path("main.luau"))
    --- local src = b.self():path("src")
    --- ```
    ---
    --- @return The package directory node.
    self: () -> Node.Node,

    --- Runs a shell command during install (requires permission).
    ---
    --- Executes in the step's working directory with the following environment variables:
    --- - `ZUNE_OUT` - Path to the step's output/working directory.
    --- - `ZUNE_INPUTS` - Path to the directory containing copies of `spec.inputs`.
    ---
    --- ```lua
    --- b.command({
    ---     run = "echo ok",
    ---     inputs = { lib },
    --- })
    --- ```
    ---
    --- @param spec - Command specification.
    --- @return The output node for the command step.
    command: (spec: CommandSpec) -> Node.Node,

    --- Runs a Luau script with `zune run` during install (requires permission).
    ---
    --- Executes in the step's working directory with the following environment variables:
    --- - `ZUNE_OUT` - Path to the step's output/working directory.
    --- - `ZUNE_INPUTS` - Path to the directory containing copies of `spec.inputs`.
    ---
    --- ```lua
    --- b.execute("steps/stamp.luau", {
    ---     inputs = { archive },
    --- })
    --- ```
    ---
    --- @param script - Path to the Luau script to run.
    --- @param spec - Optional execution settings.
    --- @return The output node for the execute step.
    execute: (script: string, spec: ExecuteSpec?) -> Node.Node,

    --- Returns a node for the zune executable of this target.
    ---
    --- The host target uses the executable running the build. Another target uses
    --- the zune executable.
    ---
    --- ```lua
    --- local exe = b.runtime()
    --- ```
    ---
    --- @return The runtime executable node.
    runtime: () -> Node.Node,

    --- Returns a node for a system library file, or nil when that file is not on disk.
    ---
    --- The library search only works on the host platform. Ideally you should only use this to detect libraries.
    --- Searches for file as `lib<name>.so`, `lib<name>.dylib`, or `<name>.dll` depending on platform.
    ---
    --- ```lua
    --- local lib = b.findSystemLibrary("library")
    --- if not lib then
    ---     error("install library first with your system package manager")
    --- end
    --- ```
    ---
    --- @param name - Library name.
    --- @return The library file node.
    findSystemLibrary: (name: string) -> Node.Node?,

    --- Returns a node for the bundled `zune` standard library.
    ---
    --- Extracted to `./.zune/std` during install if missing. You usually bind it as the `zune`
    --- alias in `b.bind`.
    ---
    --- ```lua
    --- b.bind({
    ---     luau = {
    ---         aliases = {
    ---             zune = b.std(),
    ---         },
    ---     },
    --- })
    --- ```
    ---
    --- @return The standard library directory node.
    std: () -> Node.Node,

    --- Returns the target platform being resolved for this build.
    ---
    --- `arch`, `os`, and `abi` combine as `<arch>-<os>` or `<arch>-<os>-<abi>`
    --- (`x86_64-linux`, `x86_64-linux-gnu`). Those strings are the `b.switch` keys.
    --- `abi` is set when the target names one, such as `gnu` or `musl`.
    ---
    --- ```lua
    --- local host = b.target()
    --- print(`{host.arch}-{host.os}`)
    --- ```
    ---
    --- @return Table of target information, sometimes not host's target.
    target: () -> { arch: string, os: string, abi: string? },

    --- Selects a value matching the current build target.
    ---
    --- Looks up the full target, then `<arch>-<os>` when that target names an abi,
    --- then `default`. Throws an error if none of those is present.
    ---
    --- ```lua
    --- local file = b.switch({
    ---     ["x86_64-linux-musl"] = "libsample-musl.so",
    ---     ["x86_64-linux"] = "libsample.so",
    ---     ["x86_64-windows"] = "sample.dll",
    ---     default = "libsample.so",
    --- })
    --- b.export("bin", lib:path(file))
    --- ```
    ---
    --- @param spec - Map of `<arch>-<os>` or `<arch>-<os>-<abi>` keys to values, with an optional `default`.
    --- @return The resolved value for the current target.
    switch: (spec: { [string]: any }) -> any,
}

export type Options = {
    dir: string?,
    target: string?,
    zune_bin: string?,
    yes: boolean?,
    reporter: Reporter?,
    out: string?,
    debug: boolean?,
    unused: boolean?,
    cache: number?,
    env: boolean?,
    reset: boolean?,
    options: { [string]: any }?,
}

export type AddResult = {
    name: string,
    hash: string,
    line: string,
    file: string,
    wrote: boolean,
}

export type InstallResult = {
    root: string,
    dir: string,
    target: string,
    aliases: { [string]: string },
}

local CHUNK = 65536
local FETCH_CAP = 8
local LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

local SHORT_HASH = 22
local function shortHash(hash: string): string
    if #hash <= SHORT_HASH then
        return hash
    end
    return `{string.sub(hash, 1, SHORT_HASH)}...`
end

local function display(node: Node.Node): string
    local hash = node.info.hash
    if hash and hash ~= "" then
        return shortHash(hash)
    end
    if node.info.place and node.info.place ~= "" then
        return node.info.place
    end
    if node.info.url and node.info.url ~= "" then
        return node.info.url
    end
    return "package"
end

local function quote(text: string): string
    local parts: { string } = {}
    for i = 1, #text do
        local byte = string.byte(text, i) :: number
        if byte == 92 or byte == 34 then
            table.insert(parts, `\\{string.char(byte)}`)
        elseif ascii.isControl(byte) then
            error("package name has a control character", 0)
        else
            table.insert(parts, string.char(byte))
        end
    end
    return table.concat(parts)
end

local package = {}

function package.hostTarget(): string
    local arch = zune.platform.cpu.arch
    local os_name = zune.platform.os
    local abi = zune.platform.abi
    if abi == "gnu" or abi == "musl" then
        return `{arch}-{os_name}-{abi}`
    end
    return `{arch}-{os_name}`
end

-- `<arch>-<os>` or `<arch>-<os>-<abi>`
local function splitTarget(target: string): (string, string, string?)
    local arch, os_name, abi = string.match(target, "^([^%-]+)%-([^%-]+)%-([^%-]+)$")
    if arch and os_name and abi then
        return os_name, arch, abi
    end
    arch, os_name = string.match(target, "^([^%-]+)%-([^%-]+)$")
    if not arch or not os_name then
        error(`bad target {target}`, 0)
    end
    return os_name, arch, nil
end

local library_root: string? = nil

local textSpec = spec.intersection(spec.string, spec.minLength(1))
function package.setLibraryRoot(dir: string?)
    if not textSpec(dir) then
        library_root = nil
        return
    end
    library_root = dir
end

local function splitPathList(value: any): { string }
    local list: { string } = {}
    if not textSpec(value) then
        return list
    end
    local sep: number = if zune.platform.os == "windows" then 59 else 58 -- ';', ':'
    local pos = 0
    while pos <= #value do
        local found = mem.findScalarPos(value, pos, sep)
        local entry = string.sub(value, pos + 1, if found then found else #value)
        if #entry > 0 then
            table.insert(list, entry)
        end
        if not found then
            break
        end
        pos = found + 1
    end
    return list
end

local function libraryFile(name: string): string
    if zune.platform.os == "windows" then
        return `{name}.dll`
    end
    if zune.platform.os == "macos" then
        return `lib{name}.dylib`
    end
    return `lib{name}.so`
end

local function libraryDirs(): { string }
    local list: { string } = {}
    if library_root then
        table.insert(list, library_root)
    end
    local os_name = zune.platform.os
    if os_name == "windows" then
        local raw = process.env.PATH or process.env.Path
        for _, dir in splitPathList(raw) do
            table.insert(list, dir)
        end
        local root = process.env.SystemRoot or process.env.SYSTEMROOT
        if root and root ~= "" then
            table.insert(list, fs.path.join(root, "System32"))
        end
        return list
    end
    if os_name == "macos" then
        for _, dir in splitPathList(process.env.DYLD_LIBRARY_PATH) do
            table.insert(list, dir)
        end
        table.insert(list, "/opt/homebrew/lib")
        table.insert(list, "/usr/local/lib")
        table.insert(list, "/usr/lib")
        return list
    end
    if os_name == "linux" then
        for _, dir in splitPathList(process.env.LD_LIBRARY_PATH) do
            table.insert(list, dir)
        end
        local arch = zune.platform.cpu.arch
        table.insert(list, `/usr/lib/{arch}-linux-gnu`)
        table.insert(list, "/lib")
        table.insert(list, "/usr/lib")
        table.insert(list, "/usr/local/lib")
    end
    return list
end

local function isFile(path: string): boolean
    return fs.stat(path).kind == "file"
end

local function targetMatchesHost(target: string): boolean
    if target == package.hostTarget() then
        return true
    end
    local os_name, arch, abi = splitTarget(target)
    if abi then
        return false
    end
    local host_os, host_arch = splitTarget(package.hostTarget())
    return os_name == host_os and arch == host_arch
end

local function chooseTarget(map: any, target: string): any
    local chosen = map[target]
    if chosen ~= nil then
        return chosen
    end
    local os_name, arch, abi = splitTarget(target)
    if not abi then
        return nil
    end
    return map[`{arch}-{os_name}`]
end

local function keyText(key: string): string
    if string.match(key, "^[%a_][%w_]*$") then
        return key
    end
    return `["{quote(key)}"]`
end

local function indent(level: number): string
    return string.rep("    ", level)
end

local function appendSettings(lines: { string }, settings: LuauConfig, indentLevel: number)
    local mode = settings.languagemode
    if mode then
        table.insert(lines, `{indent(indentLevel)}languagemode = "{quote(mode)}",`)
    end
    local lint = settings.lint
    if lint then
        table.insert(lines, `{indent(indentLevel)}lint = \{`)
        local keys: { string } = {}
        for key in lint do
            table.insert(keys, key)
        end
        table.sort(keys)
        for _, key in keys do
            table.insert(lines, `{indent(indentLevel + 1)}{keyText(key)} = {if lint[key] then "true" else "false"},`)
        end
        table.insert(lines, `{indent(indentLevel)}\},`)
    end
    local lint_errors = settings.linterrors
    if lint_errors ~= nil then
        table.insert(lines, `{indent(indentLevel)}linterrors = {if lint_errors then "true" else "false"},`)
    end
    local type_errors = settings.typeerrors
    if type_errors ~= nil then
        table.insert(lines, `{indent(indentLevel)}typeerrors = {if type_errors then "true" else "false"},`)
    end
    local globals = settings.globals
    if globals then
        table.insert(lines, `{indent(indentLevel)}globals = \{`)
        for _, name in globals do
            table.insert(lines, `{indent(indentLevel + 1)}"{quote(name)}",`)
        end
        table.insert(lines, `{indent(indentLevel)}\},`)
    end
end

local function isZuneAlias(name: string): boolean
    return zune.ascii.eqlIgnoreCase(name, "zune")
end

local function takenAlias(map: { [string]: string }, name: string): boolean
    if isZuneAlias(name) then
        return true
    end
    for key in map do
        if zune.ascii.eqlIgnoreCase(key, name) then
            return true
        end
    end
    return false
end

local function withoutZuneAlias(aliases: { [string]: string }): { [string]: string }
    local kept: { [string]: string } = {}
    local conflicts: { string } = {}
    for key, path in aliases do
        if isZuneAlias(key) then
            table.insert(conflicts, key)
        else
            kept[key] = path
        end
    end
    table.sort(conflicts)
    for _, key in conflicts do
        local number = 1
        local next_name = `zune{number}`
        while takenAlias(kept, next_name) do
            number += 1
            next_name = `zune{number}`
        end
        kept[next_name] = aliases[key]
    end
    return kept
end

local denseList = spec.strict(spec.array(function(): (boolean, string?)
    return true, nil
end))
local stringList = spec.strict(spec.array(textSpec))

local function reject(check: (...any) -> (boolean, string?), value: any, label: string?)
    local pass, reason = check(value)
    if not pass then
        if label then
            error(`{label}: {reason}`, 0)
        end
        error(reason, 0)
    end
end

local function stringField(source: any, lower: string, camel: string): string?
    local value = source[lower]
    if not textSpec(value) then
        value = source[camel]
    end
    if textSpec(value) then
        return value
    end
    return nil
end

local function boolField(source: any, lower: string, camel: string): boolean?
    local value = source[lower]
    if not spec.boolean(value) then
        value = source[camel]
    end
    if spec.boolean(value) then
        return value
    end
    return nil
end

local function snapshotConfig(value: any): LuauConfig
    local config: LuauConfig = {
        aliases = {},
    }
    local luau = value.luau
    if not spec.table(luau) then
        return config
    end
    config.languagemode = stringField(luau, "languagemode", "languageMode")
    local lint = luau.lint
    if spec.table(lint) then
        local map: { [string]: boolean } = {}
        local any_rule = false
        for key, item in lint do
            if textSpec(key) and spec.boolean(item) then
                map[key] = item
                any_rule = true
            end
        end
        if any_rule then
            config.lint = map
        end
    end
    config.linterrors = boolField(luau, "linterrors", "lintErrors")
    config.typeerrors = boolField(luau, "typeerrors", "typeErrors")
    local globals = luau.globals
    if spec.table(globals) then
        local list: { string } = {}
        for i = 1, #globals do
            local item = globals[i]
            if textSpec(item) then
                table.insert(list, item)
            end
        end
        if #list > 0 then
            config.globals = list
        end
    end
    local aliases = luau.aliases
    if spec.table(aliases) then
        local map: { [string]: string } = config.aliases :: any
        for key, item in aliases do
            if textSpec(key) and textSpec(item) then
                map[key] = item
            end
        end
    end
    return config
end

local function compileConfig(path: string, source: string): (...any) -> ...any
    local bytecode = luau.compile(source, {
        debug_level = 0,
        optimization_level = 1,
    })
    local env = {
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        xpcall = xpcall,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        typeof = typeof,
        rawequal = rawequal,
        rawget = rawget,
        rawlen = rawlen,
        rawset = rawset,
        setmetatable = setmetatable,
        getmetatable = getmetatable,
        unpack = table.unpack,
        math = math,
        string = string,
        table = table,
        bit32 = bit32,
        utf8 = utf8,
        buffer = buffer,
        vector = vector,
        debug = debug,
        _VERSION = "Luau",
    }
    env._G = env
    return luau.load(bytecode, {
        env = env,
        chunk_name = path,
        native_code_gen = false,
    })
end

local function executeConfig(fn: (...any) -> ...any): any
    local ran, result: any = false, nil
    local thread = task.limit(2, luau.sync, function()
        local ok, value = pcall(fn)
        ran, result = ok, value
    end)
    if coroutine.status(thread) ~= "dead" then
        error("execution timeout", 0)
    end
    if not ran then
        error(tostring(result), 0)
    end
    if not spec.table(result) then
        error("config must return a table", 0)
    end
    return result
end

function package.bareSource(name: string, loaded: LuauConfig?): string
    if name == "" then
        error("package name is required", 0)
    end
    local config = loaded or {} :: LuauConfig
    local lines: { string } = {
        `local pkg = require("@zune/package")`,
        "",
        "return {",
        `{indent(1)}name = "{quote(name)}",`,
        `{indent(1)}version = "0.0.0",`,
        `{indent(1)}build = function(b: pkg.Build)`,
        `{indent(2)}b.bind(\{`,
        `{indent(3)}luau = \{`,
    }
    appendSettings(lines, config, 4)
    table.insert(lines, `{indent(4)}aliases = \{`)
    local aliases = config.aliases
    if aliases then
        local kept = withoutZuneAlias(aliases)
        local keys: { string } = {}
        for key in kept do
            table.insert(keys, key)
        end
        table.sort(keys)
        for _, key in keys do
            table.insert(lines, `{indent(5)}{keyText(key)} = "{quote(kept[key])}",`)
        end
    end
    table.insert(lines, `{indent(5)}zune = b.std(),`)
    table.insert(lines, `{indent(4)}},`)
    table.insert(lines, `{indent(3)}},`)
    table.insert(lines, `{indent(2)}})`)
    table.insert(lines, `{indent(1)}end,`)
    table.insert(lines, `}`)
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

function package.writeBare(dir: string, loaded: LuauConfig?): boolean
    local path = fs.path.join(dir, "package.luau")
    if fs.stat(path).kind == "file" then
        return false
    end
    local base = fs.path.basename(dir)
    if mem.findNone(base, LETTERS) then
        error("package name is required", 0)
    end
    slot.ensureDir(dir)
    fs.writeFile(path, package.bareSource(base, loaded))
    return true
end

function package.loadConfig(path: string): LuauConfig
    if not textSpec(path) then
        error("config path is required", 0)
    end
    if fs.stat(path).kind ~= "file" then
        error("config was not found", 0)
    end
    return snapshotConfig(executeConfig(compileConfig(path, fs.readFile(path))))
end

local function inside(path: string, root: string): boolean
    if path == root then
        return true
    end
    return not mem.startsWith(fs.path.relative(root, path), "../")
end

local function allow(ctx: Context, path: string): string
    local ok, real = pcall(fs.realPathFileAlloc, io.cwd(), path)
    if not ok then
        error(`path not found {path}`, 0)
    end
    if inside(real, ctx.workspace) then
        return real
    end
    local parent = fs.path.dirname(ctx.root_dir)
    if parent and inside(real, parent) then
        ctx.workspace = parent
        return real
    end
    error("path leaves the workspace", 0)
end

local function outputFile(ctx: Context, name: string): string
    local given = ctx.out
    if given == nil or given == "" then
        return fs.path.join(ctx.root_dir, ".zune", "out", name)
    end
    if fs.path.isAbsolute(given) then
        return given
    end
    return fs.path.resolve(ctx.root_dir, given)
end

local function outputDir(ctx: Context): string
    local given = ctx.out
    if given == nil or given == "" then
        return fs.path.join(ctx.root_dir, ".zune", "out")
    end
    local file = if fs.path.isAbsolute(given) then given else fs.path.resolve(ctx.root_dir, given)
    local found = fs.path.dirname(file)
    if not found or found == "" then
        error("output path is missing", 0)
    end
    return found
end

local function resolveRelative(ctx: Context, base: string, rel: string): string
    if fs.path.isAbsolute(rel) or slot.rooted(rel) then
        error("path must be relative", 0)
    end
    return allow(ctx, fs.path.join(base, rel))
end

local function aliasValue(from_dir: string, target: string): string
    local rel = fs.path.relative(from_dir, target)
    rel = string.gsub(rel, "\\", "/")
    if rel == "" or rel == "." then
        return "./"
    end
    if rel == ".." then
        return "../"
    end
    if mem.eqlSlice(rel, 0, "./", 0, 2) or mem.eqlSlice(rel, 0, "../", 0, 3) then
        return rel
    end
    return `./{rel}`
end

local function copyList(value: any, label: string): { string }?
    if value == nil then
        return nil
    end
    reject(stringList, value, label)

    local out: { string } = {}
    for i = 1, #value do
        out[i] = value[i]
    end
    return out
end

local function copyPaths(value: any, label: string, target: string): { string }?
    if value == nil then
        return nil
    end
    if denseList(value) then
        return copyList(value, label)
    end
    if not spec.table(value) then
        reject(stringList, value, label)
    end
    local chosen = chooseTarget(value, target)
    if chosen == nil then
        chosen = value.default
    end
    if chosen == nil then
        error(`no {target} paths`, 0)
    end
    return copyList(chosen, label)
end

local function checkUrl(url: string)
    if
        mem.eqlSlice(url, 0, "https://", 0, 8)
        or mem.eqlSlice(url, 0, "http://", 0, 7)
        or mem.eqlSlice(url, 0, "file://", 0, 7)
    then
        return
    end
    if mem.eqlSlice(url, 0, "git+https:", 0, 10) then
        return
    end
    error(`unsupported url {url}`, 0)
end

local function cutSuffix(text: string, from: number, to: number, suffix: string): number
    local count = #suffix
    if to - from >= count and mem.eqlSlice(text, to - count, suffix, 0, count) then
        return to - count
    end
    return to
end

local function nameFromUrl(url: string): string
    local from = 0
    local to = #url
    local hash = mem.findPos(url, 0, "#")
    if hash then
        to = hash
    end
    if to - from >= 4 and mem.eqlSlice(url, from, "git+", 0, 4) then
        from += 4
    end
    if to - from >= 4 and mem.eqlSlice(url, to - 4, ".git", 0, 4) then
        to -= 4
    end
    local start_at = from
    local end_at = to
    local matched = false
    local scan = from
    while scan < to do
        local slash = mem.findPos(url, scan, "/", to - scan)
        if not slash then
            break
        end
        local name_at = slash + 1
        local next_slash = if name_at < to then mem.findPos(url, name_at, "/", to - name_at) else nil
        if
            next_slash
            and next_slash > name_at
            and to - next_slash >= 9
            and mem.eqlSlice(url, next_slash, "/archive/", 0, 9)
        then
            start_at = name_at
            end_at = next_slash
            matched = true
            break
        end
        scan = slash + 1
    end
    if not matched then
        start_at = from
        local tail = from
        while tail < to do
            local slash = mem.findPos(url, tail, "/", to - tail)
            if not slash then
                break
            end
            start_at = slash + 1
            tail = slash + 1
        end
        end_at = to
    end
    end_at = cutSuffix(url, start_at, end_at, ".tar.gz")
    end_at = cutSuffix(url, start_at, end_at, ".tgz")
    end_at = cutSuffix(url, start_at, end_at, ".zip")
    end_at = cutSuffix(url, start_at, end_at, ".tar")
    if end_at <= start_at then
        return "package"
    end
    return string.sub(url, start_at + 1, end_at)
end

local function writeBufferFile(path: string, bytes: buffer)
    local parent = fs.path.dirname(path)
    if parent then
        slot.ensureDir(parent)
    end
    local file = io.cwd():createFile(path, { truncate = true })
    local writer = io.createPosWriter(file)
    local err = writer:writeAll(bytes)
    file:close()
    if err then
        error("write failed", 0)
    end
end

local function partialPath(): string
    slot.ensureDir(slot.cachePkgDir())
    local a = crypto.random.nextInteger(1, 1000000000)
    local b = crypto.random.nextInteger(1, 1000000000)
    return fs.path.join(slot.cachePkgDir(), `partial-{a}-{b}`)
end

local function download(
    url: string,
    expected: string?,
    node: Node.Node?,
    on_progress: ((number, number?) -> ())?,
    should_stop: (() -> boolean)?
): string
    if expected and expected ~= "" and slot.findArchive(expected) then
        return expected
    end
    checkUrl(url)
    local partial = partialPath()
    local hash: string
    local ok, err: any = pcall(function()
        if mem.eqlSlice(url, 0, "git+https:", 0, 10) or mem.eqlSlice(url, 0, "git+http:", 0, 9) then
            local spool = partialPath()
            local tar, got = git.archive(url, spool, {
                on_progress = on_progress,
                should_stop = should_stop,
            })
            writeBufferFile(partial, tar)
            hash = got
        else
            hash = fetch.toFile(url, partial, {
                on_progress = on_progress,
                should_stop = should_stop,
            }).hash
        end
    end)
    if not ok then
        pcall(fs.deleteFile, partial)
        error(`fetch failed for {url}: {err}`, 0)
    end
    if expected and expected ~= "" and expected ~= hash then
        pcall(fs.deleteFile, partial)
        if node then
            error(
                `{node.info.owner.file or "package.luau"}:{node.info.line}: hash mismatch for {display(node)}\n  expected {shortHash(
                    expected
                )}\n  got      {shortHash(hash)}`,
                0
            )
        end
        error(`hash mismatch for {url}`, 0)
    end
    if slot.findArchive(hash) then
        pcall(fs.deleteFile, partial)
    else
        fs.move(partial, slot.packedPath(slot.unnamedSlot(hash)))
    end
    return hash
end

local function pulled(ctx: Context, parent: string, child: string)
    ctx.known[child] = true
    if parent == "" or parent == child then
        return
    end
    local list = ctx.edges[child]
    if not list then
        list = {}
        ctx.edges[child] = list
    end
    for _, existing in list do
        if existing == parent then
            return
        end
    end
    table.insert(list, parent)
end

local function maskedEnv(): { [string]: any }
    local env: { [string]: any } = {
        zune = table.freeze({
            mem = zune.mem,
            fmt = zune.fmt,
            hash = zune.hash,
            debug = zune.debug,
            ascii = zune.ascii,
            serde = zune.serde,
            random = zune.random,
            crypto = zune.crypto,
            platform = zune.platform,
        }),
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        xpcall = xpcall,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        typeof = typeof,
        rawequal = rawequal,
        rawget = rawget,
        rawlen = rawlen,
        rawset = rawset,
        unpack = table.unpack,
        math = math,
        string = string,
        table = table,
        bit32 = bit32,
        utf8 = utf8,
        buffer = buffer,
        vector = vector,
        coroutine = coroutine,
        debug = debug,
        _VERSION = _VERSION,
        require = function(name: string)
            -- TODO: package require support
            -- ignore `@zune/package` -- for types
        end,
    }
    env._G = env
    return env
end

local function emptyPackage(name: string, dir: string): Package
    return {
        name = name,
        version = nil,
        dir = dir,
        file = nil,
        deps = {},
        entry = nil,
        scripts = {},
        embeds = {},
        paths = nil,
        config = nil,
        scheduled = {},
        state = {
            exported = {},
            installs = {},
            copies = {},
            modules = {},
            phase = "declare",
            dep_at = 1,
            given = nil,
            rerun = nil,
        },
    }
end

local function isPin(value: string): boolean
    return #value == 44 and string.match(value, "^[A-Za-z0-9_-]+=$") ~= nil
end

local function pinHash(value: any): string?
    if value == nil or value == "" then
        return nil
    end
    if not spec.string(value) or not isPin(value) then
        error("hash must be base64", 0)
    end
    return value
end

local function isHash(value: any): (boolean, string?)
    if value == nil or value == "" or (spec.string(value) and isPin(value)) then
        return true, nil
    end
    return false, nil
end

local maxSizeSpec = spec.strict(spec.minInteger(1))
local dependencySpec = spec.intersection(
    spec.strict(spec.struct({
        url = spec.optional(spec.reason(textSpec, "must be a string")),
        path = spec.optional(spec.reason(textSpec, "must be a string")),
        hash = spec.reason(isHash, "must be base64"),
        paths = spec.optional(spec.strict(spec.array(textSpec))),
        artifact = spec.optional(spec.reason(spec.boolean, "must be a boolean")),
        max_size = spec.optional(spec.reason(maxSizeSpec, "must be a positive integer")),
        options = spec.optional(spec.reason(spec.table, "must be a table")),
    })),
    spec.reason(function(value: any): (boolean, string?)
        if value.url and value.path then
            return false, nil
        end
        return true, nil
    end, "path and url cannot be set")
)
local function snapshotSpec(given: any, kind: string): (string?, string?, string?, { string }?, boolean, number?, any?)
    if not spec.table(given) then
        error(`{kind} expects a spec`, 0)
    end
    local pass, reason = dependencySpec(given)
    if not pass then
        error(reason, 0)
    end
    local url: string? = given.url
    local path: string? = given.path
    local hash = pinHash(given.hash)
    local paths = if given.paths ~= nil then copyList(given.paths, "paths") else nil
    local artifact = if given.artifact ~= nil then given.artifact else false
    local max_size: number? = given.max_size
    return url, path, hash, paths, artifact, max_size, given.options
end

local function recordNode(ctx: Context, pkg: Package, item: Node.Node)
    local kind = item.kind
    if kind ~= "export" then
        table.insert(pkg.scheduled, item)
        if kind == "dependency" then
            table.insert(pkg.deps, item)
            if not item.state.child then
                ctx.waiting[item] = pkg.name
            end
        end
    end
end

function createNode(ctx: Context, pkg: Package, kind: Node.Kind, name: string): Node.Node
    if not textSpec(name) or mem.findPos(name, 0, "\0") then
        error("name is required", 0)
    end
    if mem.findNone(name, LETTERS) then
        error("invalid name (cannot have special characters)", 0)
    end
    local traced, line = trace.capture()

    local id = ctx.next_id
    ctx.next_id += 1
    local created = setmetatable({
        id = id,
        kind = kind,
        name = name,
        ctx = ctx,
        info = {
            line = line,
            trace = traced,
            owner = pkg,
            artifact = false,
        },
        state = {},
    }, Node) :: Node.Node

    ctx.live[created] = true

    recordNode(ctx, pkg, created)

    return created
end

local keySpec = spec.union(spec.string, spec.number)
local function makeDependency(ctx: Context, pkg: Package): Build
    local state = pkg.state

    local function isNode(value: any): boolean
        return spec.table(value) and ctx.live[value] == true
    end

    local function nodeItem(value: any): (boolean, string?)
        if isNode(value) then
            return true, nil
        end
        return false, "must be a node"
    end
    local nodeSpec = spec.label("node", nodeItem)
    local nodeList = spec.strict(spec.array(nodeSpec))
    local placeSpec = spec.optional(spec.union(spec.string, nodeSpec))
    local installSpec = spec.strict(spec.struct({
        dir = placeSpec,
        name = spec.optional(textSpec),
    }))
    local copySpec = spec.strict(spec.struct({
        dir = placeSpec,
        name = spec.optional(textSpec),
        override = spec.optional(spec.boolean),
    }))
    local commandSpec = spec.strict(spec.struct({
        run = textSpec,
        inputs = spec.optional(nodeList),
        cache = spec.optional(spec.boolean),
    }))
    local executeSpec = spec.strict(spec.struct({
        inputs = spec.optional(nodeList),
        cache = spec.optional(spec.boolean),
    }))

    local function allow(): (boolean, string?)
        return true, nil
    end

    local lintSpec = spec.strict(spec.struct({
        [textSpec] = spec.boolean,
    }))

    local function aliasItem(value: any): (boolean, string?)
        if spec.string(value) then
            if value == "" then
                return false, "alias path is required"
            end
            return true, nil
        end
        if isNode(value) then
            return true, nil
        end
        return false, "alias must be a node or a string"
    end

    local aliasSpec = spec.strict(spec.struct({
        [textSpec] = aliasItem,
    }))

    local luauShape = {
        languagemode = spec.optional(textSpec),
        languageMode = spec.optional(textSpec),
        lint = spec.optional(lintSpec),
        linterrors = spec.optional(spec.boolean),
        lintErrors = spec.optional(spec.boolean),
        typeerrors = spec.optional(spec.boolean),
        typeErrors = spec.optional(spec.boolean),
        globals = spec.optional(stringList),
        aliases = spec.optional(aliasSpec),
        [spec.string] = allow,
    }
    local luauKnown: { [any]: boolean } = {}
    for key in luauShape do
        if not spec.fn(key) then
            luauKnown[key] = true
        end
    end
    local luauSpec = spec.strict(spec.struct(luauShape))

    local dep = {} :: Build

    function dep.dependency(spec: any): Dependency.Dependency
        if state.phase == "build" then
            local existing = pkg.deps[state.dep_at]
            state.dep_at += 1
            if not existing then
                error("build changed", 0)
            end
            table.insert(pkg.scheduled, existing)
            return (existing :: any) :: Dependency.Dependency
        end
        local url, path, hash, paths, artifact, max_size, options = snapshotSpec(spec, "dependency")
        if not path and not url then
            error("dependency needs a path or a url", 0)
        end
        local label = if hash and hash ~= "" then (string.gsub(hash, "=+$", "")) else `d{ctx.next_id}`
        local created: Dependency.Dependency = (
            setmetatable(createNode(ctx, pkg, "dependency", label), Dependency) :: any
        ) :: Dependency.Dependency

        created.info.url = url
        created.info.place = path
        created.info.hash = hash
        created.info.paths = paths
        created.info.artifact = artifact
        created.info.max_size = max_size
        created.info.options = options

        return created
    end

    local function rootOf(item: Node.Node): Node.Node
        local current = item
        while current.info.base do
            current = current.info.base
        end
        return current
    end

    local function anchored(item: Node.Node): string?
        local root = rootOf(item)
        local base: string? = nil
        if root.kind == "self" then
            local owner = root.info.owner
            if owner then
                local place = root.info.place
                if place and place ~= "" and place ~= "." then
                    base = fs.path.join(owner.dir, place)
                else
                    base = owner.dir
                end
            end
        elseif root.kind == "dependency" then
            if root.state.dir and root.state.dir ~= "" then
                base = root.state.dir
            elseif root.info.place and root.info.place ~= "" then
                base = fs.path.join(root.info.owner.dir, root.info.place)
            end
        elseif root.kind == "std" then
            base = fs.path.join(ctx.root_dir, ".zune", "std")
        elseif root.kind == "runtime" then
            base = process.getExePath()
        elseif root.state.dir and root.state.dir ~= "" then
            base = root.state.dir
        end
        if not base then
            return nil
        end
        if item ~= root and item.kind == "path" then
            local sub = item.info.sub
            if sub and sub ~= "" then
                return fs.path.join(base, sub)
            end
        end
        return base
    end

    local function leafName(item: Node.Node): string
        if item.kind == "path" then
            local sub = item.info.sub
            if sub and sub ~= "" then
                local base = fs.path.basename(sub)
                if base ~= "" and base ~= "." and base ~= ".." then
                    return base
                end
            end
        end
        if item.info.place and item.info.place ~= "" and item.info.place ~= "." then
            local base = fs.path.basename(item.info.place)
            if base ~= "" and base ~= "." and base ~= ".." then
                return base
            end
        end
        if item.state.dir and item.state.dir ~= "" then
            local base = fs.path.basename(item.state.dir)
            if base ~= "" and base ~= "." and base ~= ".." then
                return base
            end
        end
        return item.name
    end

    local function oneName(name: any): string
        if not textSpec(name) or name == "." or name == ".." then
            error("install name is not a file name", 0)
        end
        if mem.findScalar(name, 47) or mem.findScalar(name, 92) then -- '/' or '\'
            error("install name is not a file name", 0)
        end
        return name
    end

    local function claim(map: { [string]: Claim }, key: string, phrase: string)
        local previous = map[key]
        if previous then
            print(`{ansi.red}error{ansi.reset}: {phrase} ({previous.pkg.name}): {key}`)
            print(previous.trace)
            error(`{phrase} ({pkg.name}): {key}`, 0)
        end
        map[key] = {
            pkg = pkg,
            trace = trace.capture(),
        }
    end

    local function packageRelative(item: Node.Node): string
        if item.info.owner ~= pkg then
            error("path leaves the package", 0)
        end
        local root = rootOf(item)
        if root.kind ~= "self" or root.info.owner ~= pkg then
            error("path leaves the package", 0)
        end
        if item.kind == "self" then
            return ""
        end
        if item.kind ~= "path" then
            error("path leaves the package", 0)
        end
        return slot.noEscapes(item.info.sub or "", "path leaves the package")
    end

    local function acceptExport(value: any)
        if spec.fn(value) then
            error("export value is not writable", 0)
        end
    end

    function dep.export(name: string, value: any?)
        if not textSpec(name) then
            error("export name is required", 0)
        end
        if state.exported[name] ~= nil then
            error("export already set", 0)
        end
        acceptExport(value)
        state.exported[name] = { value = value }
    end

    function dep.option(name: string, description: string): any
        if not textSpec(name) then
            error("option name is required", 0)
        end
        if not textSpec(description) then
            error("option description is required", 0)
        end
        local given = state.given
        if not spec.table(given) then
            return nil
        end
        local value = given[name]
        if value == nil then
            return nil
        end
        if
            spec.string(value)
            or spec.boolean(value)
            or spec.buffer(value)
            or spec.number(value)
            or spec.vector(value)
        then
            return value
        end
        if spec.table(value) and not isNode(value) then
            return value
        end
        return nil
    end

    local function pendingName(value: any): boolean
        return state.phase ~= "build" and isNode(value) and value.kind == "export"
    end

    function dep.install(item: Node.Node, options: any?)
        if not isNode(item) then
            error("install expects a file or a directory", 0)
        end
        local settings = options or {}
        if spec.table(settings) and pendingName(settings.name) then
            return
        end
        reject(installSpec, settings)

        local renamed: string? = nil
        if settings.name ~= nil then
            renamed = oneName(settings.name)
        end
        local chosen = if renamed ~= nil then renamed else leafName(item)
        local dir_text: string? = nil
        local dir_node: Node.Node? = nil
        local folder = outputDir(ctx)
        local key: string
        if settings.dir == nil then
            key = fs.path.join(folder, chosen)
        elseif spec.string(settings.dir) then
            if settings.dir == "" or fs.path.isAbsolute(settings.dir) or slot.rooted(settings.dir) then
                error("install path must be relative", 0)
            end
            local rel = slot.noEscapes(fs.path.resolve(settings.dir), "install path leaves the output")
            dir_text = rel
            if rel == "" then
                key = fs.path.join(folder, chosen)
            else
                key = fs.path.join(folder, rel, chosen)
            end
        elseif isNode(settings.dir) then
            dir_node = settings.dir
            local place = anchored(dir_node)
            if not place then
                key = `id:{dir_node.id}/{chosen}`
            else
                local resolved = fs.path.resolve(place)
                if not inside(resolved, ctx.workspace) and not inside(resolved, ctx.root_dir) then
                    error("path leaves the workspace", 0)
                end
                key = fs.path.join(resolved, chosen)
            end
        else
            error("install expects a file or a directory", 0)
        end
        if item.kind == "export" and renamed == nil then
            return
        end
        if pkg.dir ~= ctx.root_dir then
            return
        end
        claim(ctx.install_at, key, "install path already used")
        table.insert(state.installs, {
            node = item,
            key = key,
            name = chosen,
            dir_text = dir_text,
            dir_node = dir_node,
        })
    end

    function dep.copy(item: Node.Node, options: any?): Node.Node?
        if not isNode(item) then
            error("copy path missing", 0)
        end
        local settings = options or {}
        if spec.table(settings) and pendingName(settings.name) then
            return nil
        end
        reject(copySpec, settings)

        local override = if settings.override ~= nil then settings.override else false
        local renamed: string? = nil
        if settings.name ~= nil then
            renamed = oneName(settings.name)
        end
        local chosen = if renamed ~= nil then renamed else leafName(item)
        if item.kind == "export" and renamed == nil then
            return nil
        end
        local rel = ""
        if settings.dir == nil then
            rel = ""
        elseif spec.string(settings.dir) then
            if settings.dir == "" or fs.path.isAbsolute(settings.dir) or slot.rooted(settings.dir) then
                error("copy path must be relative", 0)
            end
            rel = slot.noEscapes(fs.path.resolve(settings.dir), "path leaves the package")
        elseif isNode(settings.dir) then
            rel = packageRelative(settings.dir)
        else
            error("copy path must be relative", 0)
        end
        local dest = if rel == "" then fs.path.join(pkg.dir, chosen) else fs.path.join(pkg.dir, rel, chosen)
        local resolved = fs.path.resolve(dest)
        if not inside(resolved, pkg.dir) then
            error("path leaves the package", 0)
        end
        claim(ctx.copy_at, resolved, "copy path already used")
        table.insert(state.copies, {
            node = item,
            key = resolved,
            override = override,
        })
        if isNode(settings.dir) then
            return settings.dir:path(chosen)
        end
        local relative = if rel == "" then chosen else fs.path.join(rel, chosen)
        return dep.self():path(relative)
    end

    function dep.module(dest: Node.Node, value: any)
        if not isNode(dest) then
            error("path is required", 0)
        end
        local rel = packageRelative(dest)
        if rel == "" then
            error("path is required", 0)
        end
        for _, existing in state.modules do
            if packageRelative(existing.dest) == rel then
                error("module already set", 0)
            end
        end
        table.insert(state.modules, {
            dest = dest,
            value = value,
        })
    end

    function dep.entry(item: Node.Node)
        if not isNode(item) then
            error("entry expects a node", 0)
        end
        if pkg.entry then
            error("entry already set", 0)
        end
        pkg.entry = item
    end

    function dep.embedScript(item: Node.Node)
        if not isNode(item) then
            error("script expects a node", 0)
        end
        table.insert(pkg.scripts, item)
    end

    function dep.embedFile(item: Node.Node)
        if not isNode(item) then
            error("embed expects a node", 0)
        end
        table.insert(pkg.embeds, item)
    end

    local function copyPlain(value: any, label: string): any
        if spec.string(value) or spec.boolean(value) then
            return value
        end
        if spec.number(value) then
            if not spec.finite(value) then
                error(`{label} is not finite`, 0)
            end
            return value
        end
        if not spec.table(value) or isNode(value) then
            error(`{label} is not writable`, 0)
        end
        local out: { [any]: any } = {}
        for key, item in value do
            if not keySpec(key) then
                error(`{label} key must be a string or a number`, 0)
            end
            local child = if spec.string(key) then `{label}.{key}` else `{label}[{tostring(key)}]`
            out[key] = copyPlain(item, child)
        end
        return out
    end

    local function copyLuau(luau: any): any
        reject(luauSpec, luau)

        local out: { [string]: any } = {}
        local mode = stringField(luau, "languagemode", "languageMode")
        if mode then
            out.languagemode = mode
        end
        if luau.lint ~= nil then
            local map: { [string]: boolean } = {}
            for key, value in luau.lint do
                map[key] = value
            end
            out.lint = map
        end
        local lint_errors = boolField(luau, "linterrors", "lintErrors")
        if lint_errors ~= nil then
            out.linterrors = lint_errors
        end
        local type_errors = boolField(luau, "typeerrors", "typeErrors")
        if type_errors ~= nil then
            out.typeerrors = type_errors
        end
        if luau.globals ~= nil then
            local list: { string } = {}
            for i = 1, #luau.globals do
                list[i] = luau.globals[i]
            end
            out.globals = list
        end
        if luau.aliases ~= nil then
            local map: { [string]: any } = {}
            for key, value in luau.aliases do
                map[key] = value
            end
            out.aliases = map
        end
        for key, value in luau do
            if not luauKnown[key] then
                out[key] = copyPlain(value, key)
            end
        end
        return out
    end

    function dep.bind(given: any)
        if not spec.table(given) then
            error("bind expects a table", 0)
        end
        if pkg.config ~= nil then
            error("config already set", 0)
        end
        local stored: { [string]: any } = {}
        for key, value in given do
            if not spec.string(key) then
                error("config field must be a string", 0)
            end
            if key == "luau" then
                stored.luau = copyLuau(value)
            else
                stored[key] = copyPlain(value, key)
            end
        end
        pkg.config = stored
    end

    function dep.self(): Node.Node
        local created = createNode(ctx, pkg, "self", pkg.name)
        created.info.place = "."
        return created
    end

    function dep.command(given: CommandSpec): Node.Node
        reject(commandSpec, given)

        local created = createNode(ctx, pkg, "command", pkg.name)
        created.info.run = given.run
        created.info.cache = if given.cache == false then false else true

        local inputs: { Node.Node } = {}

        created.info.inputs = inputs

        if given.inputs ~= nil then
            for i = 1, #given.inputs do
                table.insert(inputs, given.inputs[i])
            end
        end
        return created
    end

    function dep.execute(script: string, given: ExecuteSpec?): Node.Node
        if not textSpec(script) then
            error("execute script is required", 0)
        end
        local options = given or {} :: ExecuteSpec
        reject(executeSpec, options)

        local created = createNode(ctx, pkg, "execute", pkg.name)
        created.info.script = script
        created.info.cache = if options.cache == false then false else true

        local inputs: { Node.Node } = {}

        created.info.inputs = inputs

        if options.inputs ~= nil then
            for i = 1, #options.inputs do
                table.insert(inputs, options.inputs[i])
            end
        end
        return created
    end

    function dep.runtime(): Node.Node
        return createNode(ctx, pkg, "runtime", "runtime")
    end

    function dep.findSystemLibrary(name: string): Node.Node?
        if not textSpec(name) or mem.findPos(name, 0, "\0") then
            error("library name is required", 0)
        end
        if mem.findNone(name, LETTERS) then
            error("invalid name (cannot have special characters)", 0)
        end
        if not targetMatchesHost(ctx.target) then
            return nil
        end
        local file = libraryFile(name)
        for _, dir in libraryDirs() do
            local path = fs.path.join(dir, file)
            if isFile(path) then
                local created = createNode(ctx, pkg, "library", name)
                created.info.place = path
                return created
            end
        end
        return nil
    end

    function dep.std(): Node.Node
        return createNode(ctx, pkg, "std", "std")
    end

    function dep.target(): { os: string, arch: string, abi: string? }
        local os_name, arch, abi = splitTarget(ctx.target)
        return {
            os = os_name,
            arch = arch,
            abi = abi,
        }
    end

    function dep.switch(given: any): any
        if not spec.table(given) then
            error("switch expects a table", 0)
        end
        local chosen = chooseTarget(given, ctx.target)
        if chosen == nil then
            chosen = given.default
        end
        if chosen == nil then
            error(`no {ctx.target} value`, 0)
        end
        return chosen
    end

    return dep
end

local function stripSourceFromError(src: string?, line: number?, err: string): string
    if src and line then
        local test = `{src}:{line}: `
        if mem.startsWith(err, test) then
            return err:sub(#test + 1)
        end
    end
    return err
end

local unpackHash: (hash: string, dest: string, paths: { string }?, url: string, quiet: boolean?) -> number

local function loadSource(ctx: Context, pkg: Package, source: string, call_build: boolean, node: Node.Node?): boolean
    local function ignoreLoad(): boolean
        if call_build then
            return false
        end
        local dir = if node then node.state.dir else nil
        local hash = if node then node.info.hash else nil
        if node and not ctx.settled[node] and node.info.paths == nil and hash and hash ~= "" and dir then
            unpackHash(hash, dir, nil, node.info.url or hash, nil, node.info.max_size)
        end
        return true
    end
    local ok, bytecode = pcall(function()
        return luau.compile(source, {
            debug_level = 2,
            optimization_level = 1,
        })
    end)
    if not ok then
        if ignoreLoad() then
            return false
        end
        error(`package.luau failed to compile: {tostring(bytecode)}`, 0)
    end
    local env = maskedEnv()
    local loaded = luau.load(bytecode, {
        env = env,
        chunk_name = `@{pkg.file}`,
        native_code_gen = false,
    })
    local dep = makeDependency(ctx, pkg)
    env.dep = dep
    env.print = function(...)
        local color = if pkg.state.phase == "declare" then ansi.red else ansi.blue
        print(
            `{ansi.dim}({ansi.reset}{color}{pkg.state.phase}{ansi.reset}{ansi.dim}){ansi.reset} {ansi.bold}{pkg.file}{ansi.reset}: {zune.fmt.format(
                ...
            )}`
        )
    end
    setmetatable(env, {
        __index = function(_self, key)
            error(`{tostring(key)} is not available`, 0)
        end,
        __newindex = function(_self, key)
            error(`{tostring(key)} is not available`, 0)
        end,
        __metatable = "This metatable is locked",
    })
    local status = "build did not initialize"
    local build_fn: any = nil
    local thread = coroutine.create(luau.sync)
    task.limit(2, thread, function()
        local ok, value: any = xpcall(loaded, function(err)
            if not call_build then
                return
            end
            local level, src, line, count = trace.findSourceTarget()
            print(
                `{ansi.red}error{ansi.reset}: {stripSourceFromError(
                    src,
                    line,
                    if spec.string(err) then err else tostring(err)
                )}{ansi.reset}`
            )
            print(zune.debug.dumpStacktrace(level, count))
        end)
        if not ok then
            status = "package.luau failed to load"
            return
        end
        if not spec.table(value) then
            status = "package.luau must return a table"
            return
        end
        if not textSpec(value.name) then
            status = "package name is required"
            return
        end
        if mem.findNone(value.name, LETTERS) then
            status = "invalid name (cannot have special characters)"
            return
        end
        if not textSpec(value.version) then
            status = "package version is required"
            return
        end
        if not SemanticVersion.parse(value.version) then
            status = "version must be semver"
            return
        end
        pkg.name = value.name
        pkg.version = value.version
        if value.paths ~= nil then
            local paths_ok, err = pcall(copyPaths, value.paths, "paths", ctx.target)
            if not paths_ok then
                status = tostring(err)
                return
            end
            pkg.paths = err
        end
        build_fn = value.build
        status = nil
    end)
    if status then
        if ignoreLoad() then
            return false
        end
        error(status, 0)
    end
    local dir = if node then node.state.dir else nil
    local hash = if node then node.info.hash else nil
    if node and not ctx.settled[node] and node.info.paths == nil and hash and hash ~= "" and dir then
        unpackHash(hash, dir, pkg.paths, node.info.url or hash, nil, node.info.max_size)
    end
    if not call_build then
        return true
    end
    if not spec.fn(build_fn) then
        error("package build is required", 0)
    end
    local state = pkg.state
    local running = false
    local function runOnce()
        if running then
            error("build is already running", 0)
        end
        running = true
        local build_ok, result = xpcall(build_fn, function(err)
            local level, src, line, count = trace.findSourceTarget()
            print(
                `{ansi.red}error{ansi.reset}: {stripSourceFromError(
                    src,
                    line,
                    if spec.string(err) then err else tostring(err)
                )}{ansi.reset}`
            )
            print(zune.debug.dumpStacktrace(level, count))
        end, dep)
        running = false
        if not build_ok then
            local text = if spec.string(result) then result else tostring(result)
            if text == "build changed" then
                status = "build changed"
            else
                status = ctx.failed
            end
            return
        end
        if result then
            status = "build must return nothing"
            return
        end
        if state.phase == "build" and state.dep_at ~= #pkg.deps + 1 then
            status = "build changed"
            return
        end
        status = nil
    end
    local function rerun()
        status = "build did not initialize"
        task.limit(2, luau.sync, runOnce)
        if status then
            error(status, 0)
        end
    end
    state.rerun = rerun
    rerun()
    return true
end

local function pointsAt(node: Node.Node, target: Node.Node): boolean
    local cursor: Node.Node? = node.info.base
    while cursor do
        if cursor == target then
            return true
        end
        cursor = cursor.info.base
    end
    return false
end

local function adoptName(ctx: Context, node: Node.Node, name: string)
    local previous = node.name
    if previous ~= name then
        node.name = name
        for live, _ in ctx.live do
            if live ~= node and live.name == previous and pointsAt(live, node) then
                live.name = name
            end
        end
    end
    local parent = ctx.waiting[node]
    if parent then
        pulled(ctx, parent, name)
        ctx.waiting[node] = nil
    end
    ctx.known[name] = true
end

local function samePath(a: string, b: string): boolean
    return a == b or fs.path.resolve(a) == fs.path.resolve(b)
end

local function publishArchive(hash: string, stem: string)
    local dest = slot.packedPath(stem)
    local current = slot.findArchive(hash)
    if not current then
        return
    end
    if not samePath(current, dest) then
        if fs.stat(dest).kind == "file" then
            pcall(fs.deleteFile, current)
        else
            local parent = fs.path.dirname(dest)
            if parent then
                slot.ensureDir(parent)
            end
            fs.move(current, dest)
        end
    end
    local plain = slot.packedPath(slot.unnamedSlot(hash))
    if not samePath(plain, dest) and fs.stat(plain).kind == "file" then
        pcall(fs.deleteFile, plain)
    end
    local legacy = slot.packedPath(hash)
    if not samePath(legacy, dest) and fs.stat(legacy).kind == "file" then
        pcall(fs.deleteFile, legacy)
    end
end

local function relocate(ctx: Context, node: Node.Node, pkg: Package)
    local hash = node.info.hash
    local version = pkg.version
    local current = node.state.dir
    if hash and hash ~= "" and version and current then
        local dest = fs.path.join(ctx.root_dir, ".zune", "pkg", slot.namedSlot(pkg.name, version, hash))
        if not samePath(current, dest) then
            if fs.stat(dest).kind ~= "directory" then
                local parent = fs.path.dirname(dest)
                if parent then
                    slot.ensureDir(parent)
                end
                fs.move(current, dest)
            elseif fs.stat(current).kind == "directory" then
                fs.deleteDir(current, true)
            end
            ctx.by_path[pkg.dir] = nil
            ctx.stack_path[pkg.dir] = nil
            local real = allow(ctx, dest)
            pkg.dir = real
            ctx.by_path[real] = pkg
            ctx.stack_path[real] = true
            for live, _ in ctx.live do
                if live.kind == "dependency" and live.info.hash == hash then
                    live.state.dir = real
                end
            end
        end
        publishArchive(hash, slot.namedSlot(pkg.name, version, hash))
    end
    node.state.dir = pkg.dir
    adoptName(ctx, node, pkg.name)
end

local openPackage: (ctx: Context, dir: string, call_build: boolean, node: Node.Node?) -> Package?

local function linkChildren(ctx: Context, pkg: Package)
    for _, dep in pkg.deps do
        if not dep.info.place then
            continue
        end
        local child_dir = resolveRelative(ctx, pkg.dir, dep.info.place)
        dep.state.dir = child_dir
        local child = openPackage(ctx, child_dir, not dep.info.artifact, dep)
        if child then
            dep.state.child = child
        end
    end
end

openPackage = function(ctx: Context, dir: string, call_build: boolean, node: Node.Node?): Package?
    local real = allow(ctx, dir)
    if ctx.stack_path[real] then
        error(`cycle on {fs.path.basename(real)}`, 0)
    end
    local existing = ctx.by_path[real]
    if existing then
        if node then
            relocate(ctx, node, existing)
        end
        return existing
    end
    local file = fs.path.join(real, "package.luau")
    if fs.stat(file).kind ~= "file" then
        return nil
    end
    ctx.stack_path[real] = true
    local pkg = emptyPackage("", real)
    pkg.file = file
    if node and node.info.options ~= nil then
        pkg.state.given = node.info.options
    elseif node == nil and ctx.given ~= nil then
        pkg.state.given = ctx.given
    end
    local managed = loadSource(ctx, pkg, fs.readFile(file), call_build, node)
    if not managed then
        ctx.stack_path[real] = nil
        return nil
    end
    ctx.known[pkg.name] = true
    ctx.by_path[real] = pkg
    table.insert(ctx.loaded, pkg)
    if node then
        relocate(ctx, node, pkg)
    end
    if call_build then
        linkChildren(ctx, pkg)
    end
    ctx.stack_path[pkg.dir] = nil
    ctx.stack_path[real] = nil
    return pkg
end

function unpackHash(
    hash: string,
    dest: string,
    paths: { string }?,
    url: string,
    quiet: boolean?,
    max_size: number?
): number
    local packed = slot.findArchive(hash)
    if not packed then
        error(`missing {url}`, 0)
    end
    local got = fetch.hashFile(packed)
    if got ~= hash then
        pcall(fs.deleteFile, packed)
        error(`cache does not match {hash}`, 0)
    end
    local parent = fs.path.dirname(dest)
    if parent then
        slot.ensureDir(parent)
    end
    return archive.unpackFile(packed, dest, {
        paths = paths,
        quiet = quiet,
        max_size = max_size,
    })
end

local DOWNLOAD_KEY = "packages"

local function packageKey(node: Node.Node): string
    local hash = node.info.hash
    if hash and hash ~= "" then
        return hash
    end
    local url = node.info.url
    if url and url ~= "" then
        return url
    end
    return `missing-{node.id}`
end

local function archiveCached(ctx: Context, node: Node.Node): boolean
    local hash = node.info.hash
    if not hash or hash == "" then
        return false
    end
    if slot.findSlot(ctx.root_dir, hash) then
        return true
    end
    return slot.findArchive(hash) ~= nil
end

local function downloadTotals(meter: Meter): (number, number)
    local got = 0
    local total = 0
    local pending_unknown = false
    for _, part in meter.parts do
        got += part.got
        if part.total and part.total >= 0 then
            total += part.total
        elseif part.got > 0 then
            pending_unknown = true
        end
    end
    if pending_unknown then
        return got, -1
    end
    return got, total
end

local function paintDownload(ctx: Context)
    if not ctx.meter.active then
        return
    end
    local got, total = downloadTotals(ctx.meter)
    if ctx.reporter then
        ctx.reporter:progress(DOWNLOAD_KEY, got, total, ctx.meter.done, ctx.meter.known)
    end
end

local function fetchWave(ctx: Context, nodes: { Node.Node })
    if ctx.no_fetch or #nodes == 0 then
        return
    end
    local groups: { [string]: { Node.Node } } = {}
    local order: { string } = {}
    for _, node in nodes do
        local key = packageKey(node)
        local cached = archiveCached(ctx, node)
        if not ctx.meter.seen[key] then
            ctx.meter.seen[key] = true
            ctx.meter.known += 1
            if cached then
                ctx.meter.done += 1
            end
        end
        if cached then
            continue
        end
        if groups[key] == nil then
            groups[key] = {}
            table.insert(order, key)
        end
        table.insert(groups[key], node)
    end
    if ctx.meter.active then
        paintDownload(ctx)
    end
    if #order == 0 then
        return
    end
    local first = not ctx.meter.active
    ctx.meter.active = true
    for _, key in order do
        if ctx.meter.parts[key] == nil then
            ctx.meter.parts[key] = {
                got = 0,
                total = nil,
            }
        end
    end
    if first then
        if ctx.reporter then
            ctx.reporter:message(`{ansi.bold}downloading dependencies...{ansi.reset}`)
        end
    end
    paintDownload(ctx)

    local stop = false
    local active = 0
    local failure: string? = nil
    local function shouldStop(): boolean
        return stop
    end
    local running = coroutine.running()
    local labels: { [string]: number } = {}
    for _, key in order do
        while active >= FETCH_CAP do
            zune.task.wait(1 / 24)
        end
        if stop then
            break
        end
        active += 1
        local primary = groups[key][1]
        local url = primary.info.url or ""
        local base = if url ~= "" then nameFromUrl(url) else display(primary)
        local seen = labels[base]
        local label = base
        if seen then
            label = `{base} ({seen + 1})`
            labels[base] = seen + 1
        else
            labels[base] = 1
        end
        zune.task.spawn(function()
            local ok, err = pcall(function()
                local pinned = primary.info.hash
                if pinned == "" then
                    pinned = nil
                end
                if ctx.reporter then
                    ctx.reporter:progress(label, 0, nil)
                end
                local got = download(
                    primary.info.url :: string,
                    pinned,
                    primary,
                    function(count: number, total: number?)
                        local part = ctx.meter.parts[key]
                        part.got = count
                        if total then
                            part.total = total
                        end
                        if ctx.reporter then
                            ctx.reporter:progress(label, count, total)
                        end
                        paintDownload(ctx)
                    end,
                    shouldStop
                )
                if not pinned then
                    error(
                        `{ansi.bold}{ansi.underline}package.luau:{primary.info.line}:{ansi.reset} hash for {label}\n  hash = "{got}",`,
                        0
                    )
                end
            end)
            if not ok then
                stop = true
                if not failure then
                    failure = tostring(err)
                end
                local where = if primary.info.url and primary.info.url ~= "" then `  {primary.info.url}` else ""
                if ctx.reporter then
                    ctx.reporter:message(`{ansi.red}  fail   {label}{where}{ansi.reset}`, label)
                end
            else
                local part = ctx.meter.parts[key]
                if part and not part.total then
                    part.total = part.got
                end
                ctx.meter.done += 1
                paintDownload(ctx)
                if ctx.reporter and part then
                    ctx.reporter:progress(label, part.got, part.total)
                    ctx.reporter:message("", label)
                end
            end
            active -= 1
            if active == 0 then
                task.spawn(running)
            end
        end)
    end
    if active > 0 then
        coroutine.yield()
    end
    if failure then
        error(failure, 0)
    end
end

local function materialize(ctx: Context, nodes: { Node.Node })
    local created: { [string]: boolean } = {}
    for _, node in nodes do
        local hash = node.info.hash
        if not hash or hash == "" then
            if ctx.no_fetch then
                continue
            end
            error(`package.luau:{node.info.line}: hash required for {display(node)}`, 0)
        end
        local found = slot.findSlot(ctx.root_dir, hash)
        if not found and ctx.no_unpack then
            continue
        end
        if found and not created[hash] then
            node.state.dir = found
            ctx.settled[node] = true
            if fs.path.basename(found) == slot.unnamedSlot(hash) then
                local packed = slot.findArchive(hash)
                if packed and fs.path.stem(packed) == hash then
                    publishArchive(hash, slot.unnamedSlot(hash))
                end
            end
            continue
        end
        local dest: string
        local stem: string? = nil
        if found then
            dest = found
        else
            local packed = slot.findArchive(hash)
            if not packed then
                if ctx.no_fetch then
                    table.insert(ctx.missing, node)
                    continue
                end
                error(`missing {node.info.url or hash}`, 0)
            end
            stem = fs.path.stem(packed)
            dest = fs.path.join(ctx.root_dir, ".zune", "pkg", if stem == hash then slot.unnamedSlot(hash) else stem)
        end
        if node.info.paths then
            unpackHash(hash, dest, node.info.paths, node.info.url or hash, nil, node.info.max_size)
        else
            local matched = unpackHash(hash, dest, { "package.luau" }, node.info.url or hash, true, node.info.max_size)
            if matched == 0 then
                unpackHash(hash, dest, nil, node.info.url or hash, nil, node.info.max_size)
            end
        end
        if not found and stem == hash then
            publishArchive(hash, slot.unnamedSlot(hash))
        end
        created[hash] = true
        node.state.dir = dest
    end
end

local function loadUrlPackage(ctx: Context, node: Node.Node)
    if node.kind ~= "dependency" or node.state.child then
        return
    end
    local dir = node.state.dir
    local hash = node.info.hash
    if (not dir or fs.stat(dir).kind ~= "directory") and hash and hash ~= "" then
        dir = slot.findSlot(ctx.root_dir, hash)
        node.state.dir = dir
    end
    if not dir then
        return
    end
    local child = openPackage(ctx, dir, not node.info.artifact, node)
    if child then
        node.state.child = child
    end
end

local function clearBuild(ctx: Context, pkg: Package)
    local state = pkg.state
    for _, item in state.copies do
        local found = ctx.copy_at[item.key]
        if found and found.pkg == pkg then
            ctx.copy_at[item.key] = nil
        end
    end
    for _, item in state.installs do
        local found = ctx.install_at[item.key]
        if found and found.pkg == pkg then
            ctx.install_at[item.key] = nil
        end
    end
    state.exported = {}
    state.installs = {}
    state.copies = {}
    state.modules = {}
    pkg.entry = nil
    pkg.scripts = {}
    pkg.embeds = {}
    pkg.scheduled = {}
    pkg.config = nil
end

local function finish(ctx: Context, pkg: Package)
    local state = pkg.state
    if state.phase ~= "declare" then
        return
    end
    state.phase = "build"
    for _, dep_node in pkg.deps do
        local child = dep_node.state.child
        if child then
            finish(ctx, child)
        end
    end
    if state.rerun then
        clearBuild(ctx, pkg)
        state.dep_at = 1
        state.rerun()
    end
    state.phase = "done"
end

local function resolveGraph(ctx: Context): Package
    local file = fs.path.join(ctx.root_dir, "package.luau")
    if fs.stat(file).kind ~= "file" then
        error("package.luau is missing", 0)
    end
    local root = openPackage(ctx, ctx.root_dir, true, nil)
    if not root then
        error("package.luau is missing", 0)
    end
    ctx.known[root.name] = true
    local seen: { [Node.Node]: boolean } = {}

    local function add(node: Node.Node, out: { Node.Node })
        if seen[node] or not node.info.url or node.info.place then
            return
        end
        if node.kind ~= "dependency" then
            return
        end
        seen[node] = true
        table.insert(out, node)
    end

    local guard = 0
    while guard < 64 do
        guard += 1
        local pending: { Node.Node } = {}
        for _, pkg in ctx.loaded do
            for _, node in pkg.scheduled do
                add(node, pending)
            end
        end
        if #pending == 0 then
            break
        end
        fetchWave(ctx, pending)
        materialize(ctx, pending)
        for _, node in pending do
            loadUrlPackage(ctx, node)
        end
    end
    if guard >= 64 then
        error("dependency graph is too deep", 0)
    end
    local color: { [Package]: number } = {}
    local function visit(pkg: Package)
        local state = color[pkg]
        if state == 1 then
            error(`cycle on {pkg.name}`, 0)
        end
        if state == 2 then
            return
        end
        color[pkg] = 1
        for _, dep in pkg.deps do
            if dep.state.child then
                visit(dep.state.child)
            end
        end
        color[pkg] = 2
    end
    for _, pkg in ctx.loaded do
        visit(pkg)
    end
    finish(ctx, root)
    return root
end

local function nodePlace(node: Node.Node): string
    local sub = node.info.sub
    if sub and sub ~= "" then
        return sub
    end
    local place = node.info.place
    if place and place ~= "" and place ~= "." then
        return place
    end
    return `{node.kind} {node.name}`
end

local function placeFixed(ctx: Context, pkg: Package)
    for _, node in pkg.scheduled do
        if node.kind == "self" and node.info.place then
            node.state.dir = resolveRelative(ctx, node.info.owner.dir, node.info.place)
        elseif node.kind == "std" then
            node.state.dir = fs.path.join(ctx.root_dir, ".zune", "std")
        elseif node.kind == "runtime" then
            local exe = ctx.zune_bin
            if not exe then
                if not targetMatchesHost(ctx.target) then
                    error(
                        `{ansi.red}error{ansi.reset}: runtime for {ctx.target} is not available\n{node.info.trace}`,
                        0
                    )
                end
                exe = process.getExePath()
            end
            node.state.dir = exe
        elseif node.kind == "library" then
            local place = node.info.place
            if not place or place == "" then
                error(
                    `{ansi.red}unresolved{ansi.reset}: unable to resolve path for ({nodePlace(node)})\n{node.info.trace}`,
                    0
                )
            end
            node.state.dir = place
        end
    end
    for _, node in pkg.scheduled do
        if node.kind ~= "path" then
            continue
        end
        local sub = node.info.sub
        local current = node.info.base
        while current and current.info.base do
            current = current.info.base
        end
        if
            current
            and current.kind == "self"
            and (not current.state.dir or current.state.dir == "")
            and current.info.owner
        then
            current.state.dir = resolveRelative(ctx, current.info.owner.dir, current.info.place or ".")
        end
        local root_dir = if current then current.state.dir else nil
        if sub == nil or not root_dir then
            error(
                `{ansi.red}unresolved{ansi.reset}: unable to resolve path for ({nodePlace(node)})\n{node.info.trace}`,
                0
            )
        end
        local parts: { string } = { root_dir }
        for segment in string.gmatch(sub, "[^/\\]+") do
            table.insert(parts, segment)
        end
        node.state.dir = fs.path.join(table.unpack(parts))
    end
end

local function importStd(root: string): string
    local dest = fs.path.join(root, ".zune", "std")
    local existing = "none"
    local found, stat = pcall(function()
        return io.cwd():statFile(dest, { follow_symlinks = false })
    end)
    if found then
        existing = stat.kind
    end
    if existing ~= "none" then
        return dest
    end
    local source = runtime.getStd()
    if not source then
        runtime.getStdPath()
        error("could not find the standard library", 0)
    end
    local parent = fs.path.dirname(dest)
    if parent then
        slot.ensureDir(parent)
    end
    local linked = pcall(function()
        fs.symlink(source, dest)
    end)
    if linked then
        return dest
    end
    fs.copy(source, dest, true)
    return dest
end

local function nodeDir(node: Node.Node): string
    local dir = node.state.dir
    if not dir or dir == "" then
        error(`{ansi.red}unresolved{ansi.reset}: could not get dir with node ({nodePlace(node)})\n{node.info.trace}`, 0)
    end
    return dir
end

local function hashInputs(script: string, inputs: { Node.Node }): string
    local hasher = crypto.createHash("blake3")
    hasher:update(script)
    hasher:update("\0")
    local function addFile(path: string, label: string)
        hasher:update(label)
        hasher:update("\0")
        local file = io.cwd():openFile(path, { mode = "r" })
        local reader = io.createPosReader(file)
        local scratch = buffer.create(CHUNK)
        while true do
            local got, err = reader:read(scratch)
            if err then
                file:close()
                error("short read", 0)
            end
            if got == 0 then
                break
            end
            hasher:update(mem.slice(scratch, 0, got))
        end
        file:close()
    end
    local function addTree(path: string, label: string)
        local kind = fs.stat(path).kind
        if kind == "file" then
            addFile(path, label)
            return
        end
        if kind ~= "directory" then
            return
        end
        local names: { string } = {}
        for _, entry in fs.entries(path) do
            table.insert(names, entry.name)
        end
        table.sort(names)
        for _, name in names do
            local child = if label == "" then name else `{label}/{name}`
            addTree(fs.path.join(path, name), child)
        end
    end
    for _, input in inputs do
        addTree(nodeDir(input), input.name)
    end
    return hasher:digest("hex") :: string
end

local function runStepsFixed(ctx: Context, packages: { Package })
    for _, pkg in packages do
        for _, step in pkg.scheduled do
            if step.kind == "execute" and step.info.script and not fs.path.isAbsolute(step.info.script) then
                step.info.script = resolveRelative(ctx, pkg.dir, step.info.script)
            end
        end
    end
    local seen: { [Package]: boolean } = {}
    local function walk(pkg: Package)
        if seen[pkg] then
            return
        end
        seen[pkg] = true
        for _, dep in pkg.deps do
            if dep.state.child then
                walk(dep.state.child)
            end
        end
        local index = 0
        for _, step in pkg.scheduled do
            if step.kind ~= "command" and step.kind ~= "execute" then
                continue
            end
            index += 1
            local inputs = step.info.inputs or {}
            local script_bytes = step.info.run or ""
            local script_path = step.info.script
            if step.kind == "execute" then
                if not script_path then
                    error("execute script is required", 0)
                end
                script_bytes = fs.readFile(script_path)
            end
            local stamped = step.info.cache ~= false and #inputs > 0
            local stamp = if stamped then hashInputs(script_bytes, inputs) else ""
            local work = if stamped
                then fs.path.join(ctx.root_dir, ".zune", "work", stamp)
                else fs.path.join(ctx.root_dir, ".zune", "work", pkg.name, tostring(index))
            step.state.dir = work
            local stamp_file = if stamped then fs.path.join(ctx.root_dir, ".zune", "cache", "s", stamp) else ""
            if stamped and fs.stat(stamp_file).kind == "file" and fs.stat(work).kind == "directory" then
                local reporter = ctx.reporter
                if reporter then
                    reporter:message(`{ansi.dim}skipping cached ({pkg.name}) command step{ansi.reset}`)
                end
                continue
            end
            local shown = if step.kind == "execute"
                then `execute {fs.path.basename(script_path or "")}`
                else (step.info.run or "")
            if not ctx.yes then
                local reporter = ctx.reporter
                if reporter and reporter:confirm("allow?", `run {pkg.name}: {shown}`) ~= true then
                    error("confirmation required", 0)
                end
            end
            slot.ensureDir(work)

            local lines: { string } = {}
            for _, input in inputs do
                table.insert(lines, nodeDir(input))
            end
            fs.writeFile(fs.path.join(work, "inputs"), `{table.concat(lines, "\n")}\n`)

            local env = process.loadEnv()
            env.ZUNE_OUT = work
            env.ZUNE_INPUTS = fs.path.join(work, "inputs")

            if step.kind == "execute" then
                local result = process.run(process.getExePath(), { "run", script_path :: string }, {
                    cwd = work,
                    env = env,
                    stdout = "inherit",
                    stderr = "inherit",
                })
                if not result.ok then
                    error(`execute failed ({result.code})`, 0)
                end
            else
                local result = process.run(step.info.run or "", {
                    shell = true,
                    cwd = work,
                    env = env,
                    stdout = "inherit",
                    stderr = "inherit",
                })
                if not result.ok then
                    error(`command failed ({result.code})`, 0)
                end
            end
            if stamped then
                slot.ensureDir(fs.path.join(ctx.root_dir, ".zune", "cache", "s"))
                fs.writeFile(stamp_file, `{stamp}\n`)
            end
        end
    end
    for _, pkg in packages do
        walk(pkg)
    end
end

local function emitValue(value: any, indentLevel: number): string
    if spec.string(value) then
        return `"{quote(value)}"`
    end
    if spec.number(value) then
        return tostring(value)
    end
    if spec.boolean(value) then
        return if value then "true" else "false"
    end
    if not spec.table(value) then
        error("config value is not writable", 0)
    end
    local count = if denseList(value) then #value else nil
    if count == 0 then
        return "{}"
    end
    local lines = { "{" }
    if count then
        for i = 1, count do
            table.insert(lines, `{indent(indentLevel + 1)}{emitValue(value[i], indentLevel + 1)},`)
        end
    else
        local names: { string } = {}
        local numbers: { number } = {}
        for key in value do
            if spec.string(key) then
                table.insert(names, key)
            elseif spec.number(key) then
                table.insert(numbers, key)
            end
        end
        table.sort(names)
        table.sort(numbers)
        for _, key in names do
            table.insert(lines, `{indent(indentLevel + 1)}{keyText(key)} = {emitValue(value[key], indentLevel + 1)},`)
        end
        for _, key in numbers do
            table.insert(
                lines,
                `{indent(indentLevel + 1)}[{tostring(key)}] = {emitValue(value[key], indentLevel + 1)},`
            )
        end
    end
    table.insert(lines, `{indent(indentLevel)}}`)
    return table.concat(lines, "\n")
end

local function emitConfig(value: any): string
    return `return {emitValue(value, 0)}\n`
end

local function writeText(path: string, text: string)
    if fs.stat(path).kind == "file" and fs.readFile(path) == text then
        return
    end
    fs.writeFile(path, text)
end

local function resolveValue(ctx: Context, dir: string, value: any): any
    if spec.table(value) then
        if ctx.live[value] == true then
            return aliasValue(dir, nodeDir(value))
        end
        local out: { [any]: any } = {}
        for key, item in value do
            out[key] = resolveValue(ctx, dir, item)
        end
        return out
    end
    return value
end

local function aliasStrings(resolved: any): { [string]: string }
    local map: { [string]: string } = {}
    if not spec.table(resolved) then
        return map
    end
    local luau = resolved.luau
    if not spec.table(luau) then
        return map
    end
    local aliases = luau.aliases
    if not spec.table(aliases) then
        return map
    end
    for key, value in aliases do
        if spec.string(key) and spec.string(value) then
            map[key] = value
        end
    end
    return map
end

function package.seedConfig(dir: string, loaded: LuauConfig?)
    local config = loaded or {} :: LuauConfig
    local dest = importStd(dir)
    local aliases: { [string]: string } = {}
    local from = config.aliases
    if from then
        for key, path in withoutZuneAlias(from) do
            aliases[key] = path
        end
    end
    aliases.zune = aliasValue(dir, dest)
    local luau: { [string]: any } = {
        aliases = aliases,
    }
    if config.languagemode then
        luau.languagemode = config.languagemode
    end
    if config.lint then
        luau.lint = config.lint
    end
    if config.linterrors ~= nil then
        luau.linterrors = config.linterrors
    end
    if config.typeerrors ~= nil then
        luau.typeerrors = config.typeerrors
    end
    if config.globals then
        luau.globals = config.globals
    end
    writeText(fs.path.join(dir, ".config.luau"), emitConfig({ luau = luau }))
end

local function writeConfigs(ctx: Context, packages: { Package }, ignore_status: boolean): { [string]: string }
    local root_map: { [string]: string } = {}
    local once = ignore_status
    for _, pkg in packages do
        local spec = pkg.config
        if spec == nil then
            continue
        end
        if not once then
            once = true
            if ctx.reporter then
                ctx.reporter:message(`{ansi.bold}setting up .config.luau...{ansi.reset}`)
            end
        end
        local resolved = resolveValue(ctx, pkg.dir, spec)
        if pkg.dir == ctx.root_dir then
            root_map = aliasStrings(resolved)
        end
        writeText(fs.path.join(pkg.dir, ".config.luau"), emitConfig(resolved))
    end
    return root_map
end

local function slashPath(path: string): string
    return (string.gsub(path, "\\", "/"))
end

local function scriptArg(node: Node.Node): string
    local node_kind = node.kind
    if node_kind == "glob" then
        local base = node.info.base
        if not base then
            error(`{ansi.red}unresolved{ansi.reset}: unknown node ({nodePlace(node)})\n{node.info.trace}`, 0)
        end
        local dir = nodeDir(base)
        if fs.stat(dir).kind ~= "directory" then
            error(`{ansi.red}unresolved{ansi.reset}: glob expects a directory ({dir})\n{node.info.trace}`, 0)
        end
        return `{slashPath(dir)}/{node.info.place}`
    end
    local dir = nodeDir(node)
    local kind = fs.stat(dir).kind
    if kind == "file" then
        return dir
    end
    if kind == "directory" then
        return `{slashPath(dir)}/**/*.luau`
    end
    error(`{ansi.red}unresolved{ansi.reset}: missing {dir}\n{node.info.trace}`, 0)
end

local function bundleExe(
    project: string,
    scripts: { string },
    files: { string },
    out: string,
    exe: string,
    debug: boolean
)
    local mode = if debug then "--debug" else "--release"
    local args = { "bundle", mode, "--no_home", `--out={out}`, `--exe={exe}` }
    for _, path in scripts do
        table.insert(args, path)
    end
    if #files > 0 then
        table.insert(args, "-f")
        for _, path in files do
            table.insert(args, path)
        end
    end
    local result = process.run(process.getExePath(), args, {
        cwd = project,
        stdout = "inherit",
        stderr = "inherit",
    })
    if not result.ok then
        error(`bundle failed ({result.code})`, 0)
    end
end

local function freshValue(ctx: Context, from_dir: string, value: any, seen: { [any]: boolean }): any
    if not spec.table(value) then
        return value
    end
    if ctx.live[value] == true then
        return aliasValue(from_dir, nodeDir(value))
    end
    if seen[value] then
        error("table circular reference", 0)
    end
    seen[value] = true
    local out: { [any]: any } = {}
    for key, item in value do
        out[key] = freshValue(ctx, from_dir, item, seen)
    end
    seen[value] = nil
    return out
end

local function writeModules(ctx: Context)
    for _, pkg in ctx.loaded do
        for _, item in pkg.state.modules do
            local dest = nodeDir(item.dest)
            local parent = fs.path.dirname(dest)
            if not parent or parent == "" then
                error("module path is missing", 0)
            end
            slot.ensureDir(parent)
            local fresh = freshValue(ctx, parent, item.value, {})
            local encoded = zune.serde.luau.encode(fresh, {
                sort = true,
            })
            writeText(dest, `return {encoded}\n`)
        end
    end
end

local function runCopies(ctx: Context)
    for _, pkg in ctx.loaded do
        for _, item in pkg.state.copies do
            local source = nodeDir(item.node)
            local kind = fs.stat(source).kind
            if kind ~= "file" and kind ~= "directory" then
                error("copy path missing", 0)
            end
            local target = item.key
            if not item.override then
                local existing = fs.stat(target).kind
                if existing == "file" or existing == "directory" then
                    continue
                end
            end
            local parent = fs.path.dirname(target)
            if parent then
                slot.ensureDir(parent)
            end
            fs.copy(source, target, true)
        end
    end
end

local function runInstalls(ctx: Context)
    local root: Package? = nil
    for _, pkg in ctx.loaded do
        if pkg.dir == ctx.root_dir then
            root = pkg
            break
        end
    end
    if not root then
        return
    end
    for _, item in root.state.installs do
        local source = nodeDir(item.node)
        local kind = fs.stat(source).kind
        if kind ~= "file" and kind ~= "directory" then
            error("install expects a file or a directory", 0)
        end
        local folder = outputDir(ctx)
        if item.dir_node then
            folder = nodeDir(item.dir_node)
            local dir_kind = fs.stat(folder).kind
            if dir_kind == "file" then
                error("install expects a file or a directory", 0)
            end
            if dir_kind == "none" then
                slot.ensureDir(folder)
            end
            local resolved = fs.path.resolve(folder)
            if not inside(resolved, ctx.workspace) and not inside(resolved, ctx.root_dir) then
                error("path leaves the workspace", 0)
            end
        elseif item.dir_text and item.dir_text ~= "" then
            folder = fs.path.join(outputDir(ctx), item.dir_text)
        end
        local target = fs.path.join(folder, item.name)
        if item.dir_node == nil then
            local base = fs.path.resolve(outputDir(ctx))
            if not inside(fs.path.resolve(target), base) then
                error("install path leaves the output", 0)
            end
        end
        local parent = fs.path.dirname(target)
        if parent then
            slot.ensureDir(parent)
        end
        fs.copy(source, target, true)
    end
end

local function makeContext(options: Options?): Context
    local opts = options or {} :: Options
    local dir = opts.dir or "."
    local ok, abs_dir = pcall(fs.realPathFileAlloc, io.cwd(), dir)
    if not ok then
        error(`path not found {dir}`, 0)
    end
    local target = opts.target or package.hostTarget()
    local _, _ = splitTarget(target)
    local ctx: Context = {
        root_dir = abs_dir,
        workspace = abs_dir,
        target = target,
        zune_bin = nil,
        yes = opts.yes == true,
        reporter = opts.reporter,
        edges = {},
        known = {},
        by_path = {},
        stack_path = {},
        loaded = {},
        live = {},
        waiting = {},
        settled = {},
        next_id = 1,
        meter = {
            seen = {},
            known = 0,
            done = 0,
            parts = {},
            active = false,
        },
        no_fetch = false,
        no_unpack = false,
        missing = {},
        copy_at = {},
        install_at = {},
        out = opts.out,
        failed = "build failed",
        given = opts.options,

        createNode = createNode,
    }
    return ctx
end

local function setup(ctx: Context, with_steps: boolean, ignore_config_status: boolean): (Package, { [string]: string })
    local resolved: Package? = nil
    local ok, err = pcall(function()
        resolved = resolveGraph(ctx)
    end)
    if ctx.meter.active then
        local reporter = ctx.reporter
        if reporter then
            if ok then
                reporter:message(`{ansi.bold}download finished{ansi.reset}`, DOWNLOAD_KEY)
            else
                reporter:message("", DOWNLOAD_KEY)
            end
        end
    end
    if not ok then
        error(tostring(err), 0)
    end
    if not resolved then
        error("package.luau is missing", 0)
    end
    local std_dir: string? = nil
    for _, pkg in ctx.loaded do
        for _, node in pkg.scheduled do
            if node.kind == "std" then
                if not std_dir then
                    std_dir = importStd(ctx.root_dir)
                end
                node.state.dir = std_dir
            end
        end
    end
    for _, pkg in ctx.loaded do
        placeFixed(ctx, pkg)
    end
    if with_steps then
        runCopies(ctx)
        writeModules(ctx)
    end
    local aliases = writeConfigs(ctx, ctx.loaded, ignore_config_status)
    if with_steps then
        runStepsFixed(ctx, ctx.loaded)
    end
    return resolved, aliases
end

function package.install(options: Options?): InstallResult
    local ctx = makeContext(options)
    ctx.failed = "install failed"
    local root, aliases = setup(ctx, true, false)
    runInstalls(ctx)
    if ctx.reporter then
        ctx.reporter:message("Nothing else to do")
    end
    return {
        root = root.name,
        dir = ctx.root_dir,
        target = ctx.target,
        aliases = aliases,
    }
end

local function dependencyList(ctx: Context, root: Package): { string }
    local lines: { string } = {}
    local order: { string } = {}
    local seen_name: { [string]: boolean } = {}
    local seen_pkg: { [Package]: boolean } = {}
    local hash_order: { string } = {}
    local hash_parents: { [string]: { string } } = {}

    local function walk(pkg: Package, indentLevel: number)
        for _, dep in pkg.deps do
            local child = dep.state.child
            local hash = dep.info.hash
            local name = dep.name
            local named = false
            if child ~= nil and child.name ~= "" then
                name = child.name
                named = true
            elseif hash ~= nil and hash ~= "" then
                name = `{ansi.dim}(unresolved) {hash}{ansi.reset}`
            end
            local suffix = ""
            if named then
                if hash ~= nil and hash ~= "" then
                    suffix =
                        ` {if child and #child.deps > 0 then `({#child.deps}) ` else ""}{ansi.dim}({hash}){ansi.reset}`
                elseif child and child.dir then
                    suffix = ` {ansi.dim}({child.dir}){ansi.reset}`
                end
            end
            table.insert(lines, `{string.rep("  ", indentLevel)}{name}{suffix}`)
            if named and not seen_name[name] then
                seen_name[name] = true
                table.insert(order, name)
            end
            if not named and hash ~= nil and hash ~= "" and pkg.name ~= "" and pkg.name ~= hash then
                local owners = hash_parents[hash]
                if not owners then
                    owners = {}
                    hash_parents[hash] = owners
                    table.insert(hash_order, hash)
                end
                local flag = false
                for _, existing in owners do
                    if existing == pkg.name then
                        flag = true
                        break
                    end
                end
                if not flag then
                    table.insert(owners, pkg.name)
                end
            end
            if child ~= nil and not seen_pkg[child] then
                seen_pkg[child] = true
                walk(child, indentLevel + 1)
            end
        end
    end

    local suffix = ""
    if #root.deps > 0 then
        suffix = ` ({#root.deps}):`
    end
    table.insert(lines, `{ansi.bold}{root.name}{suffix}{ansi.reset}`)
    walk(root, 1)

    local function parents(current: string, indentLevel: number, trail: { [string]: boolean })
        if trail[current] then
            return
        end
        local next_trail = table.clone(trail)
        next_trail[current] = true
        local list = ctx.edges[current]
        if not list then
            return
        end
        local dim = indentLevel > 3
        for _, parent in list do
            table.insert(
                lines,
                `{string.rep("  ", indentLevel)}{if dim then ansi.dim else ""}{parent}{if dim then ansi.reset else ""}`
            )
            parents(parent, indentLevel + 1, next_trail)
        end
    end

    local started = false
    local function begin(header: string?)
        if started then
            return
        end
        started = true
        table.insert(lines, "")
        if header then
            table.insert(lines, header)
        end
    end

    for i, name in order do
        if not ctx.edges[name] then
            continue
        end
        begin(`{ansi.bold}resolved dependents:{ansi.reset}`)
        table.insert(lines, ` {i}) {ansi.bold}{name}{ansi.reset}`)
        parents(name, 3, {})
    end
    started = false
    for i, hash in hash_order do
        begin(`{ansi.bold}unresolved dependents:{ansi.reset}`)
        table.insert(lines, ` {i}) {ansi.bold}{hash}{ansi.reset} {ansi.dim}(hash){ansi.reset}`)
        local owners = hash_parents[hash]
        for _, parent in owners do
            table.insert(lines, `    - {parent}`)
            parents(parent, 4, { [hash] = true })
        end
    end
    return lines
end

local function hashInfo(ctx: Context, hash: string): { string }
    local found: Node.Node? = nil
    for _, pkg in ctx.loaded do
        for _, dep in pkg.deps do
            if dep.info.hash == hash then
                found = dep
                break
            end
        end
        if found then
            break
        end
    end
    if not found then
        error(`unknown hash {hash}`, 0)
    end
    local dep = found :: Node.Node
    local lines: { string } = {}
    local child = dep.state.child
    if child and child.name ~= "" then
        local version = child.version
        if version and version ~= "" then
            table.insert(lines, `{child.name} {version}`)
        else
            table.insert(lines, child.name)
        end
    end
    table.insert(lines, `  hash: {hash}`)
    local url = dep.info.url
    if url and url ~= "" then
        table.insert(lines, `  url: {url}`)
    end
    local packed = slot.findArchive(hash)
    if packed then
        local stat = fs.stat(packed)
        if stat.kind == "file" then
            table.insert(lines, `  cache path: {packed} ({text.bytes(stat.size)})`)
        end
    end
    local unpacked = dep.state.dir
    if not unpacked or unpacked == "" then
        if child ~= nil then
            unpacked = child.dir
        end
    end
    if unpacked and unpacked ~= "" then
        table.insert(lines, `  unpacked path: {unpacked}`)
    end
    return lines
end

function package.why(hash: string?, options: Options?): { string }
    if hash == "" then
        error("hash is required", 0)
    end
    if hash then
        pinHash(hash)
    end
    local ctx = makeContext(options)
    local root, _aliases = setup(ctx, false, true)
    if not hash then
        return dependencyList(ctx, root)
    end
    return hashInfo(ctx, hash)
end

function package.add(url: string, options: Options?): AddResult
    if not textSpec(url) then
        error("url is required", 0)
    end
    checkUrl(url)
    local ctx = makeContext(options)
    local wrote = package.writeBare(ctx.root_dir)
    local label = nameFromUrl(url)
    if ctx.reporter then
        ctx.reporter:message(`  fetching  {label}`)
    end
    local hash = download(url, nil, nil, function(got: number, total: number?)
        if ctx.reporter then
            ctx.reporter:progress(label, got, total)
        end
    end, nil)
    if ctx.reporter then
        ctx.reporter:message(`{ansi.green}  ok     {shortHash(hash)}{ansi.reset}`, label)
    end
    local file = fs.path.join(ctx.root_dir, "package.luau")
    local line = `b.dependency(\{ url = "{quote(url)}", hash = "{hash}" \})`
    return {
        name = "",
        hash = hash,
        line = line,
        file = file,
        wrote = wrote,
    }
end

function package.build(options: Options?): string
    local opts = options or {} :: Options
    local ctx = makeContext(opts)
    if opts.zune_bin then
        if not textSpec(opts.zune_bin) then
            error("zune bin is required", 0)
        end
        local path = fs.path.resolve(ctx.root_dir, opts.zune_bin)
        if fs.stat(path).kind ~= "file" then
            error(`zune bin must be a file ({opts.zune_bin})`, 0)
        end
        ctx.zune_bin = path
    elseif not targetMatchesHost(ctx.target) then
        error(`{ansi.red}error{ansi.reset}: runtime for {ctx.target} is not available`, 0)
    end
    local root, _aliases = setup(ctx, true, true)
    local entry = root.entry
    if not entry then
        error(`{ansi.red}build{ansi.reset}: entry is required`, 0)
    end
    local entry_path = scriptArg(entry)
    if fs.stat(entry_path).kind ~= "file" then
        error(`{ansi.red}build{ansi.reset}: entry must be a file ({entry_path})\n{entry.info.trace}`, 0)
    end
    local scripts = { entry_path }
    for _, item in root.scripts do
        table.insert(scripts, scriptArg(item))
    end
    local files: { string } = {}
    for _, item in root.embeds do
        local kind = item.kind
        if kind == "glob" then
            table.insert(files, scriptArg(item))
            continue
        end
        local dir = nodeDir(item)
        if fs.stat(dir).kind ~= "file" then
            error(`{ansi.red}build{ansi.reset}: embed expects a file or a glob ({dir})\n{item.info.trace}`, 0)
        end
        table.insert(files, dir)
    end
    local out = outputFile(ctx, root.name)
    local exe = ctx.zune_bin or process.getExePath()
    bundleExe(ctx.root_dir, scripts, files, out, exe, opts.debug == true)
    runInstalls(ctx)
    if ctx.reporter then
        ctx.reporter:message(`built {out}`)
    end
    return out
end

local function say(ctx: Context, text: string)
    local reporter = ctx.reporter
    if not reporter then
        return
    end
    reporter:message(text)
end

local function depLabel(node: Node.Node): string
    local dir = node.state.dir
    if dir and dir ~= "" then
        local base = fs.path.basename(dir)
        if base ~= "" and base ~= "." and base ~= ".." then
            return base
        end
    end
    local hash = node.info.hash or ""
    local child = node.state.child
    if child ~= nil and child.name ~= "" and child.version ~= nil and child.version ~= "" then
        return slot.namedSlot(child.name, child.version, hash)
    end
    return hash
end

local function hashInName(name: string): string?
    if #name == 44 and isPin(name) then
        return name
    end
    if #name <= 45 then
        return nil
    end
    local hash = string.sub(name, #name - 43)
    if string.sub(name, #name - 44, #name - 44) == "-" and isPin(hash) then
        return hash
    end
    return nil
end

local function matchesArchive(name: string, hash: string): boolean
    if name == `{hash}.tar` or name == `{slot.unnamedSlot(hash)}.tar` then
        return true
    end
    local suffix = `-{hash}.tar`
    if #name <= #suffix or not mem.eqlSlice(name, #name - #suffix, suffix, 0, #suffix) then
        return false
    end
    return slot.namedHead(name, #name - #suffix)
end

type Removed = {
    name: string,
    ok: boolean,
}

local function deleteEntry(path: string, kind: string): boolean
    local ok = pcall(function()
        if kind == "directory" then
            fs.deleteDir(path, true)
        else
            fs.deleteFile(path)
        end
    end)
    return ok
end

local function entryList(dir: string): { { name: string, kind: string } }
    local list: { { name: string, kind: string } } = {}
    for _, entry in fs.entries(dir) do
        table.insert(list, {
            name = entry.name,
            kind = entry.kind,
        })
    end
    table.sort(list, function(a: { name: string, kind: string }, b)
        return a.name < b.name
    end)
    return list
end

local function reportRemoved(ctx: Context, banner: string, rows: { Removed }): boolean
    if #rows == 0 then
        return false
    end
    say(ctx, `{ansi.bold}{banner}{ansi.reset}`)
    for _, row in rows do
        if row.ok then
            say(ctx, `{ansi.dim}  {row.name}{ansi.reset}`)
        else
            say(ctx, `{ansi.dim}{ansi.red}  {row.name}{ansi.reset}`)
        end
    end
    say(ctx, `{ansi.bold}clean finished{ansi.reset}`)
    return true
end

local function referencedSet(ctx: Context): { [string]: string }
    local labels: { [string]: string } = {}
    for _, pkg in ctx.loaded do
        for _, dep in pkg.deps do
            local hash = dep.info.hash
            if hash and hash ~= "" then
                labels[hash] = depLabel(dep)
            end
        end
    end
    return labels
end

local function removeUnused(ctx: Context, labels: { [string]: string }): boolean
    local rows: { Removed } = {}
    local pkg_dir = fs.path.join(ctx.root_dir, ".zune", "pkg")
    if fs.stat(pkg_dir).kind == "directory" then
        for _, entry in entryList(pkg_dir) do
            local hash = hashInName(entry.name)
            if hash and labels[hash] then
                continue
            end
            local ok = deleteEntry(fs.path.join(pkg_dir, entry.name), entry.kind)
            table.insert(rows, {
                name = entry.name,
                ok = ok,
            })
        end
    end
    local artifacts = fs.path.join(ctx.root_dir, ".zune", "artifacts")
    local artifacts_stat = fs.stat(artifacts)
    if artifacts_stat.kind ~= "none" then
        local ok = deleteEntry(artifacts, artifacts_stat.kind)
        table.insert(rows, {
            name = "artifacts",
            ok = ok,
        })
    end
    return reportRemoved(ctx, "cleaning dependencies...", rows)
end

local function deleteLocal(ctx: Context): { Removed }
    local dir = fs.path.join(ctx.root_dir, ".zune")
    if fs.stat(dir).kind ~= "directory" then
        return {}
    end
    local rows: { Removed } = {}
    for _, entry in entryList(dir) do
        local ok = deleteEntry(fs.path.join(dir, entry.name), entry.kind)
        table.insert(rows, {
            name = entry.name,
            ok = ok,
        })
    end
    pcall(function()
        if fs.stat(dir).kind == "directory" and #fs.entries(dir) == 0 then
            fs.deleteDir(dir, false)
        end
    end)
    return rows
end

local function removeCache(ctx: Context, cache: number, labels: { [string]: string }): boolean
    local dir = slot.cachePkgDir()
    if fs.stat(dir).kind ~= "directory" then
        return false
    end
    local rows: { Removed } = {}
    for _, entry in entryList(dir) do
        local matched = cache >= 2
        if not matched then
            for hash in labels do
                if matchesArchive(entry.name, hash) then
                    matched = true
                    break
                end
            end
        end
        if not matched then
            continue
        end
        local ok = deleteEntry(fs.path.join(dir, entry.name), entry.kind)
        table.insert(rows, {
            name = entry.name,
            ok = ok,
        })
    end
    return reportRemoved(ctx, "cleaning cache...", rows)
end

local function reportMissing(ctx: Context, labels: { string })
    say(ctx, `{ansi.bold}missing dependencies:{ansi.reset}`)
    say(ctx, "")
    for _, label in labels do
        say(ctx, `{ansi.dim}  {label}{ansi.reset}`)
    end
    say(ctx, "")
    say(ctx, `{ansi.bold}download with {ansi.green}install{ansi.reset_color} command{ansi.reset}`)
end

function package.clean(options: Options?)
    local opts = options or {} :: Options
    local cache = math.max(0, opts.cache or 0)
    local unused = opts.unused == true
    local env = opts.env == true
    local reset = opts.reset == true
    if not unused and not env and not reset and cache == 0 then
        unused = true
    end

    local ctx = makeContext(opts)
    local labels: { [string]: string } = {}
    if unused or reset or cache == 1 then
        ctx.no_fetch = true
        ctx.no_unpack = true
        resolveGraph(ctx)
        labels = referencedSet(ctx)
    end

    local worked = false
    if unused then
        if removeUnused(ctx, labels) then
            worked = true
        end
    end
    if reset then
        deleteLocal(ctx)
        local again = makeContext(opts)
        again.no_fetch = true
        resolveGraph(again)
        local missing: { string } = {}
        local seen: { [string]: boolean } = {}
        for _, node in again.missing do
            local hash = node.info.hash or ""
            if hash ~= "" and not seen[hash] then
                seen[hash] = true
                local label = labels[hash]
                if not label or label == "" then
                    label = depLabel(node)
                end
                table.insert(missing, label)
            end
        end
        table.sort(missing)
        if #missing > 0 then
            reportMissing(again, missing)
        else
            say(again, `{ansi.bold}clean finished{ansi.reset}`)
        end
        worked = true
    elseif env then
        if reportRemoved(ctx, "cleaning .zune...", deleteLocal(ctx)) then
            worked = true
        end
    end
    if cache > 0 and removeCache(ctx, cache, labels) then
        worked = true
    end
    if not worked then
        say(ctx, "Nothing else to do")
    end
end

return package
