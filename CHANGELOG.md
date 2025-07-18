# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Breaking Changes
- `fs`, `luau`, `process`, and `net` all functions that returns a boolean & result tuple, now returns only the results or throws a lua error instead.
- `ffi` api changes are not backwards compatible with `0.4.2`.
- namespaces have been shifted around, read docs to catch up.
- `require` is now based on **Amended Require Syntax and Resolution Semantics**, thus `require("module/init.luau")` would need to be `require("./module/init")`.
- `websocket` api changes are not backwards compatible.
- Zune libraries has been changed to a global variable instead of a module.
  - `require("@zcore/fs")` would be `zune.fs`.

### Added
- Added buffer support as arguments & closure returns for `zune.ffi`.
- Added memory leak detection for `zune test ...` command.
- Added buffer support to the formatter, now it can display the contents of a buffer as hex with a configurable display limit.
- Added `readErrAsync`, `readOutAsync` and `dead` to ProcessChild in `zune.process`.
- Added pointer objects to `zune.ffi`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/ffi)
  - Currently this is marked as experimental and may change in the future. Api may change.
  To enable this, you need to set `experimental.ffi` to `true` in `zune.toml`.
  Bugs may occur, please report them.
  - Example:
    ```luau
    local ffi = zune.ffi

    local ptr = ffi.alloc(12)
    print(ptr) -- <pointer: 0x12345678>
    print(ffi.len(ptr)) -- 12
    local data = buffer.create(12);
    buffer.writei32(data, 0, 123)
    buffer.writei32(data, 4, 456)
    buffer.writei32(data, 8, 789)

    ffi.copy(data, 0, ptr, 0, 12);
    ptr:write(0, data, 0, 12)
    ```
- Added support for encoding `Infinity` and `NaN` in `serde.json5`.
- Added non-blocking support for `process.run`.
- Added FFI support for `aarch64 macOs`.
- Added support for `.luaurc` in subdirectories from `.luaurc`.
- Added `format` in `zune.stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/stdio)
  - Example:
    ```luau
    local stdio = zune.stdio

    print(stdio.format({"Array"}, 123, newproxy())) -- ... custom output
    ```
- Added `maxBodySize` option to HTTP server in `zune.net.http`.
- Added `udpSocket` to `zune.net`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/net)
  - Example:
    ```luau
    local net = zune.net

    local udp = net.udpSocket({
      port = 8080,
      data = function(socket, msg, port, address)
        print(msg, port, address) -- print datagram received.
      end
    })

    udp:send("Hello World!", 12345, "ip address here") -- Send datagram to address
    ```
- Added `tcpConnect` & `tcpHost` to `zune.net`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/net)
  - Example:
    ```luau
    local net = zune.net

    local server = net.tcpHost({
      port = 8080,
      address = "127.0.0.1",
      open = function(socket)
        print("Client connected")
      end,
      data = function(socket, msg)
        print(msg) -- print message received.
      end,
      close = function(socket)
        print("Client disconnected")
      end,
    })

    local client = net.tcpConnect({
      port = 8080,
      address = "127.0.0.1",
      open = function(socket)
        print("Connected to server")
        socket:send("Hello World!")
      end,
      data = function(socket, msg)
        print(msg) -- print message received.
      end,
      close = function(socket)
        print("Disconnected from server")
      end,
    })
    ```
- Added `sqlite` to `zune`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/sqlite)
  - Currently this is marked as experimental and may change in the future.
  - Example:
    ```luau
    local sqlite = zune.sqlite

    local db = sqlite.open("test.db")
    db:exec("CREATE TABLE test(id INTEGER PRIMARY KEY, name TEXT)")
    db:exec("INSERT INTO test (name) VALUES ('Hello World!')")
    local stmt = db:query("SELECT * FROM test")
    for _, row in stmt:all() do
      print(row.id, row.name)
    end
    stmt:finalize() -- optional (can be handled by GC)
    db:close()-- optional (can be handled by GC)
    ```
- Added `serde.lz4.compress` and `serde.lz4.decompress` replacements for standard lz4 compression & decompression instead of frame encoding.
- Added `serde.zstd` to `zune`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/serde)
  - Example:
    ```luau
    local serde = zune.serde

    local compressed = serde.zstd.compress("Hello World!")
    local decompressed = serde.zstd.decompress(compressed)
    print(decompressed) -- "Hello World!"
    ```
- Added `-O<n>`, `-g<n>`, `--native`, `--no-native`, `--no-jit` flags to the run command.

### Changed
- Formatter now displays `__tostring` metamethods as plain text, instead of as strings.
- `intFromPtr` in `ffi` has been removed.
- indexing a ffi function from library should be more efficient.
- Changed `readErr` and `readOut` to non-blocking and return nil or string for ProcessChild in `process`.
- Changed `ffi`, removed buffers going through as memory blocks of its own, in favor of using the new ffi pointer objects, updated/removed FFI apis.
- Updated `luau` to `0.654`.
- `fs`, `luau`, `process`, and `net` all functions that returns a boolean & result tuple, now returns only the results or throws a lua error instead.
- Zune libraries has been changed to a global variable instead of a module with `require`.
- `require` is now based on **Amended Require Syntax and Resolution Semantics** [Luau RFC](https://rfcs.luau.org/amended-require-resolution.html).
- Zune types has moved all type information into one definition file & removed require directory aliases.
- `ffi.call` has been changed to `ffi.fn` to define a function pointer for better optimization.
  - `ffi.fn` returns a function, which can be used in lua to call like a normal function.
- `net.http.websocket` now only accepts the callbacks within the options table, `bindMessage` & etc have been removed.
- `net.http.serve` websocket upgrade callback is now async.
- `serde.lz4.compress` and `serde.lz4.decompress` renamed to `serde.lz4.compressFrame` and `serde.lz4.decompressFrame`.
- `net.serve`, `net.request` and `net.websocket` now has been moved to `net.http.serve`, `net.http.request` and `net.http.websocket`.

### Fixed
- Fixed `ffi` closures getting garbage collected.
- Fixed `zune.toml` crashing when integer values are negative.
- Fixed `ffi` closures reading structs and returning structs crashing.
- Fixed zune tasks `threads` getting garbage collected.

## `0.4.2` - October 14, 2024

### Added
- Added async support to require. You can now do yields in required modules.
- Added custom error logging, enabled with `runtime.debug.detailedError` in `zune.toml`.
  - Example:
  ```shell
  error: Zune
  example.luau:1
    |
  1 | error("Zune")
    | ^^^^^^^^^^^^^
  ```
- Added `useColor` and `showRecursiveTable` to `resolvers.formatter` in `zune.toml` for configurable output when using `print` and `warn`.
- Added `readAsync` method to stdin in `@zcore/stdio`.
- Added `json5`, null preservation & pretty print for `json` in `@zcore/serde`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/serde)
  - Example:
    ```lua
    local serde = require("@zcore/serde")

    local json = [[
      {
        "key": null
      }
    ]]

    -- Json5 and Json are very similar, just Json5 has a different decoder.
    -- serde.json.Values & serde.json.Indents are both the same for Json5, usable for in either one.
    local decoded = serde.json5.decode(json, {
        preserveNull = true -- Preserve null values as 'serde.json.Values.Null'
    })
    print(serde.json5.encode(decoded, {
        prettyIndent = serde.json5.Indents.TwoSpaces -- Pretty print with 2 spaces
    }))
    ```
- Added `@zcore/ffi` for FFI support. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/ffi)
  - Currently this is marked as experimental and may change in the future. Api may change.
  To enable this, you need to set `experimental.ffi` to `true` in `zune.toml`.
  It is also likely this might not work on all platforms.
  - Example:
    ```luau
    local ffi = require("@zcore/ffi")

    local lib = ffi.dlopen(`libsample.{ffi.suffix}`, {
        add = {
            returns = ffi.types.i32,
            args = {ffi.types.i32, ffi.types.i32},
        },
    })

    print(lib.add(1, 2))
    ```

### Changed
- Updated `luau` to `0.647`.
- Backend formatted print/warn can now call/read `__tostring` metamethods on userdata.
- Scheduler consumes less CPU.
- Zune for linux build now targets `gnu` instead of `musl`, riscv64 will stay as `musl`.

### Fixed
- Fixed `error.TlsBadRecordMac` error with websockets in `@zcore/net` when using `tls`.
- Fixed client websocket data sent unmasked in `@zcore/net`.
- Fixed websocket server not reading masked data properly in `@zcore/net`.

## `0.4.1` - September 26, 2024

### Added
- Added flags to `new` in regex. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/regex)
  - `i` - Case Insensitive
  - `m` - Multiline
- Added zune configuration support as `zune.toml`.
- Added `init` command to generate config files.
- Added `luau` command to display luau info.
- Added partial tls support for `websocket` to `@zcore/net`.
- Added `readonly` method to `FileHandle` in `@zcore/fs`.
  - Nil to get state, boolean to set state.
- Added adjustable response body size to `@zcore/net` while using request.
- Added profiler to `run` command with `--profile` flag.
  - Frequency of profiling can be set with `--profile=...` flag.
  - Default: `10000`.

### Changed
- Changed `captures` in regex to accept boolean instead of flags.
  - Boolean `true` is equivalent to `g` flag.
- Errors in required modules should now display their path relative to the current working directory.
- Updated required or ranned luau files to use optimization level 1, instead of 2.
- Updated `test` command to be like `run`.
  - If the first argument is `-`, it will read from stdin.
  - Fast search for file directly.
- Updated `luau` to `0.644`.
- Updated `help` command to display new commands.
- Updated `stdin` in `@zcore/stdio` to return nil if no data is available.
- Updated `websocket` in `@zcore/net` to properly return a boolean and an error string or userdata.
- Updated `request` in `@zcore/net` to timeout if request takes too long.

### Fixed
- Fixed `eval` requiring modules relative to the parent of the current working directory, instead of the current working directory.
- Fixed `require` causing an error when requiring a module that returns nil.
- Fixed `websockets` yielding forever.
- Fixed threads under scheduler getting garbage collected.
- Fixed `setup` panic on windows.

## `0.4.0` - September 17, 2024

### Added
- Added `watch`, `openFile`, and `createFile` to `@zcore/fs`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/fs)
  - Example:
    ```luau
    local fs = require("@zcore/fs")

    local watcher = fs.watch("file.txt", function(filename, events)
      print(filename, events)
    end)

    local ok, file = fs.createFile("file.txt", {
      exclusive = true -- false by default
    })
    assert(ok, file);
    file:close();
    local ok, file = fs.openFile("file.txt", {
      mode = "r" -- "rw" by default
    })
    assert(ok, file);
    file:close();

    watcher:stop();
    ```
- Added `eval` command. Evaluates the first argument as luau code.
  - Example:
    ```shell
    zune --eval "print('Hello World!')"
    -- OR --
    zune -e "print('Hello World!')"
    ```
- Added stdin input to `run` command if the first argument is `-`.
  - Example:
    ```shell
    echo "print('Hello World!')" | zune run -
    ```
- Added `--globals` flag to `repl` to load all zune libraries as globals too.
- Added `warn` global, similar to print but with a warning prefix.
- Added `random` and `aes` to `@zcore/crypto`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/crypto)
  - Example:
    ```luau
    local crypto = require("@zcore/crypto")

    -- Random
    print(crypto.random.nextNumber()) -- 0.0 <= x < 1.0
    print(crypto.random.nextNumber(-100, 100)) -- -100.0 <= x < 100.0
    print(crypto.random.nextInteger(1, 10)) -- 1 <= x <= 10
    print(crypto.random.nextBoolean()) -- true or false

    local buf = buffer.create(2)
    crypto.random.fill(buf, 0, 2)
    print(buffer.readi16(buf, 0))-- random 16-bit integer

    -- AES
    local message = "Hello World!"
    local key = "1234567890123456" -- 16 bytes
    local nonce = "123456789012" -- 12 bytes
    local encrypted = crypto.aes.aes128.encrypt(message, key, nonce)
    local decrypted = crypto.aes.aes128.decrypt(encrypted.cipher, encrypted.tag, key, nonce)
    print(decrypted) -- "Hello World!"
    ```
- Added `getSize` method to `terminal` in `@zcore/stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/serde)
  - Example:
    ```luau
    local stdio = require("@zcore/stdio")
    
    if (stdio.terminal.isTTY) then
      local cols, rows = stdio.terminal:getSize()
      print(cols, rows) -- 80   24
    end
    ```
- Added `base64` to `@zcore/serde`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/serde)
  - Example:
    ```luau
    local serde = require("@zcore/serde")

    local encoded = serde.base64.encode("Hello World!")
    local decoded = serde.base64.decode(encoded)
    print(decoded) -- "Hello World!"
    ```
- Added `.luaurc` support. Alias requires should work.
  - Example:
    ```json
    {
      "aliases": {
        "dev": "/path/to/dev",
        "globals": "/path/to/globals.luau"
      }
    }
    ```
    ```luau
    local module = require("@dev/module")
    local globals = require("@globals")
    ```
- Added `captures` method to `Regex` in `@zcore/regex`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/regex)
  - Flags
    - `g` - Global
    - `m` - Multiline
  - Example:
    ```luau
    local regex = require("@zcore/regex")

    local pattern = regex.new("[A-Za-z!]+")
    print(pattern:captures("Hello World!", 'g')) -- {{RegexMatch}, {RegexMatch}}
    ```
- Added `@zcore/datetime`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/datetime)
  - Example:
    ```luau
    local datetime = require("@zcore/datetime")

    print(datetime.now().unixTimestamp) -- Timestamp
    print(datetime.now():toIsoDate()) -- ISO Date
    ```
- Added `onSignal` to `@zcore/process`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/process)
  - Example:
    ```luau
    local process = require("@zcore/process")

    process.onSignal("INT", function()
      print("Received SIGINT")
    end)
    ```

### Changed
- Updated `luau` to `0.642`.
- Updated `@zcore/process` to lock changing variables & allowed changing `cwd`.
  - Changing cwd would affect the global process cwd (even `fs` library).
  - Supports Relative and Absolute paths. `../` or `/`.
    - Relative paths are relative to the current working directory.
- Updated `require` function to be able to require modules that return exactly 1 value, instead of only functions, tables, or nil.

### Fixed
- Fixed `@zcore/net` with serve using `reuseAddress` option not working.
- Fixed `REPL` requiring modules relative to the parent of the current working directory, instead of the current working directory.

## `0.3.0` - September 1, 2024

### Added
- Added `stdin`, `stdout`, and `stderr` to `@zcore/stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/stdio)
  - Example:
    ```luau
    local stdio = require("@zcore/stdio")

    stdio.stdin:read() -- read byte
    stdio.stdin:read(10) -- read 10 bytes
    stdio.stdout:write("Hello World!")
    stdio.stderr:write("Error!")
    ```
- Added `terminal` to `@zcore/stdio`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/stdio)
  - This should allow you to write more interactive terminal applications.
  - *note*: If you have weird terminal output in windows, we recommend you to use `enableRawMode` to enable windows console `Virtual Terminal Processing`.
  - Example:
    ```luau
    local stdio = require("@zcore/stdio")

    if (stdio.terminal.isTTY) then -- check if terminal is a TTY
      stdio.terminal.enableRawMode() -- enable raw mode
      stdio.stdin:read() -- read next input without waiting for newline
      stdio.terminal.restoreMode() -- return back to original mode before changes.
    end
    ```
- Added `@zcore/regex`. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/regex)
  - Example:
    ```luau
    local regex = require("@zcore/regex")

    local pattern = regex.new("([A-Za-z\\s!])+")
    local match = pattern:match("Hello World!")
    print(match) --[[<table: 0x12345678> {
        [1] = <table: 0x2ccee88> {
            index = 0, 
            string = "Hello World!", 
        }, 
        [2] = <table: 0x2ccee58> {
            index = 11, 
            string = "!", 
        }, 
    }]]
    ```

### Changed
- Switched from build optimization from ReleaseSafe to ReleaseFast to improve performance.
  - Luau should be faster now.
- REPL should now restore the terminal mode while executing lua code and return back to raw mode after execution.
- Removed `readIn`, `writeOut`, and `writeErr` functions in `@zcore/stdio`.

## `0.2.1` - August 31, 2024

### Added
- Added buffer support for `@net/server` body response. If a buffer is returned, it will be sent as the response body, works with `{ body = buffer, statusCode = 200 }`.
  - Example:
    ```luau
    local net = require("@net/net")

    net.serve({
      port = 8080,
      request = function(req)
        return buffer.fromstring("Hello World!")
      end
    })
    ```
- Added buffer support for `@net/serde` in compress/decompress. If a buffer is passed, it will return a new buffer.
  - Example:
    ```luau
    local serde = require("@net/serde")

    local compressed_buffer = serde.gzip.compress(buffer.fromstring("Zune"))
    print(compressed_buffer) -- <buffer: 0x12343567>
    ```

### Changed
- Updated backend luau module.

### Fixed
- Fixed Inaccurate luau types for `@zcore/net`.
- Fixed REPL not working after an error is thrown.

## `0.2.0` - August 30, 2024

### Added
- Added `repl` command.
  - Starts a REPL session.
  - Example:
    ```shell
    zune repl
    > print("Hello World!")
    ```
### Changed
- Updated `help` command to display the new `repl` command & updated `test` command description.

## `0.1.0` - August 29, 2024

### Added
- Added `@zcore/crypto` built-in library. [More Info](https://scythe-technology.github.io/zune-docs/docs/api/crypto)
  - Example:
    ```luau
    local crypto = require("@zcore/crypto")
    local hash = crypto.hash.sha2.sha256("Hello World!")
    local hmac = crypto.hmac.sha2.sha256("Hello World!", "private key")
    local pass_hash = crypto.password.hash("pass")

    print(crypto.password.verify("pass", pass_hash))
    ```

### Changed
- Partial backend code for print formatting.
- Internal package.

## `0.0.5` - August 29, 2024

### Changed
- `--version` & `-V` will now display the version of luau.
  - format: `<name>: <version...>\n`
- Updated `luau` to `0.640`.
- `_VERSION` now includes major and minor version of `luau`.
  - format: `Zune <major>.<minor>.<patch>+<major>.<minor>`
- Partial backend code has been changed for `stdio`, `process`, `fs` and `serde` to use new C-Call handler.
  - Behavior should not change.
  - Performance should not change.

## `0.0.4` - August 28, 2024

### Added
- Added type for `riscv64` architecture in process.

## `0.0.3` - August 28, 2024

### Added
- Builds for Linux-Riscv64.

## `0.0.2` - August 28, 2024

### Added
- `help`, `--help` and `-h` command/flags to display help message.

### Changed

- Test traceback line styles uses regular characters, instead of unicode for Windows.
  - Fixes weird characters in Windows terminal.
- Running zune without params would default to `help` command.

### Fixed

- Some Luau type documentation with incorrect definitions.

## `0.0.1` - August 26, 2024

Initial pre-release.
