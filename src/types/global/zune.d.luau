--  https://github.com/JohnnyMorganz/luau-lsp/issues/271

declare _FILE: {
    source: string,
    main: boolean,
}

--[======[ FileSystem ]======]--
export type MetadataKind = "file"
    | "directory"
    | "sym_link"
    | "door"
    | "character_device"
    | "unix_domain_socket"
    | "block_device"
    | "event_port"
    | "named_pipe"
    | "whiteout"
    | "unknown"

export type Metadata = {
    kind: MetadataKind,
    symlink: boolean,
    createdAt: number,
    modifiedAt: number,
    accessedAt: number,
    size: number,
    permissions: {
        readOnly: boolean,
    },
}

declare class FileHandle
    --[[
        Reads the contents of a file.

        *Optional: The amount of bytes to read, if nil, reads the whole till EOF or Luau limit.*

        @param amount The amount of bytes to read.
    ]]
    read:
        & ((self: FileHandle, amount: number?, useBuffer: false?) -> string)
        & ((self: FileHandle, amount: number?, useBuffer: true) -> buffer)

    --[[
        Reads the contents of a file.

        *Optional: The amount of bytes to read, if nil, reads the whole till EOF or Luau limit.*

        @param amount The amount of bytes to read.
    ]]
    readSync:
        & ((self: FileHandle, amount: number?, useBuffer: false?) -> string)
        & ((self: FileHandle, amount: number?, useBuffer: true) -> buffer)

    --[[
        Writes to a file.

        @param contents The contents to write to the file.
    ]]
    function write(self, contents: string | buffer): ()

    --[[
        Writes to a file.

        @param contents The contents to write to the file.
    ]]
    function writeSync(self, contents: string | buffer): ()

    --[[
        Appends to a file.

        @param contents The contents to append to the file.
    ]]
    function append(self, contents: string | buffer): ()

    --[[
        Appends to a file.

        @param contents The contents to append to the file.
    ]]
    function appendSync(self, contents: string | buffer): ()

    --[[
        Returns the size of the file. Based on current state of the file object.
    ]]
    function getSize(self): number

    --[[
        Returns the current position of the file.
    ]]
    function getSeekPosition(self): number

    --[[
        Seeks to a position in the file relative to the end.

        *Optional: The amount of bytes to seek, if nil, seeks to the end*

        @param amount The amount of bytes to seek.
    ]]
    function seekFromEnd(self, amount: number?): ()

    --[[
        Seeks to a position in the file absolute to the start.

        *Optional: The amount of bytes to seek, if nil, seeks to the start, 0*

        @param amount The amount of bytes to seek.
    ]]
    function seekTo(self, amount: number?): ()

    --[[
        Seeks to a position in the file relative to the current position.

        *Optional: The amount of bytes to seek, if nil, seeks to the next position, 1*

        *If `0` is provided, seek will not move.*

        @param amount The amount of bytes to seek.
    ]]
    function seekBy(self, amount: number?): ()

    --[[
        Locks the file.

        *Optional: The mode to lock the file, if nil, locks the file in exclusive mode.*

        @param lockMode The mode to lock the file.
    ]]
    function lock(self, lockMode: ("shared" | "exclusive" | "none")?): boolean

    --[[
        Unlocks the file.
    ]]
    function unlock(self): ()

    --[[
        Flushes the file. Writes the contents to the disk.

        Does not yield, **blocks** process.
    ]]
    function sync(self): ()

    --[[
        Returns whether the file is readonly.

        *Optional: Whether to set the file to readonly, if nil, returns the current state.*

        @param enabled Whether to set the file to readonly.
    ]]
    readonly:
        & ((self: FileHandle) -> boolean)
        & ((self: FileHandle, enabled: boolean) -> ())

    --[[
        Closes the file. (Will flush the file)
    ]]
    function close(self): ()
end

export type FileWatcher = {
    --[[
        Stops the watcher.
    ]]
    stop: (self: FileWatcher) -> (),
}

type CreateFileOptions = {
    --[[
        Whether to create the file in exclusive mode.

        *Default: false*
    ]]
    exclusive: boolean?,
}

type OpenFileOptions = {
    --[[
        The mode to open the file in.

        Available modes: `r`, `w`

        *Default: `rw`*
    ]]
    mode: string?,
}

type FileSystemLib = {
    --[[
        Creates a file.

        If exclusive is true, the operation will fail if the file already exists.

        @param path The path to the file.
        @param opts The options to create the file.
        @return `FileHandle` The file handle.
    ]]
    createFile: (path: string, opts: CreateFileOptions?) -> FileHandle,

    --[[
        Opens a file.

        *The file must exist*
        @param path The path to the file.
        @param opts The options to open the file.
        @return `FileHandle` The file handle.
        @error `ReadError`
    ]]
    openFile: (path: string, opts: OpenFileOptions?) -> FileHandle,

    --[[
        Reads the contents of a file.

        *The content could be limited*

        @param path The path to the file.
        @param useBuffer Whether to read the file as a buffer.
        @return `string | buffer` The contents of the file.
        @error
    ]]
    readFile:
        & ((path: string) -> string)
        & ((path: string, useBuffer: true) -> buffer),

    --[[
        Reads the contents of a directory.

        @param path The path to the directory.
        @return `{string} | string` The contents of the directory, or an error.
    ]]
    readDir: (path: string) -> { string },

    --[[
        Writes to a file.

        *The content could be limited*

        @param path The path to the file.
        @param contents The contents to write to the file.
        @return `FileWriteError` An error if the operation failed.
    ]]
    writeFile: (path: string, contents: string | buffer) -> (),

    --[[
        Creates a directory.

        @param path The path to the directory.
        @param recursive Whether to write recursively.
        @return `DirWriteError` An error if the operation failed.
    ]]
    writeDir:  (path: string, recursive: boolean?) -> (),

    --[[
        Deletes a file.

        @param path The path to the file.
        @return `FileRemoveError` An error if the operation failed.
    ]]
    removeFile: (path: string) -> (),

    --[[
        Deletes a directory.

        @param path The path to the directory.
        @param recursive Whether to delete recursively.
        @return `DirRemoveError` An error if the operation failed.
    ]]
    removeDir: (path: string, recursive: boolean?) -> (),

    --[[
        Returns the metadata of a file or directory.

        @param path The path to the file or directory.
        @return `Metadata` The metadata of the file or directory
    ]]
    metadata: (path: string) -> Metadata,

    --[[
        Checks if a directory exists.

        @param path The path to the directory.
        @return `boolean` Whether the directory exists.
    ]]
    isDir: (path: string) -> boolean,

    --[[
        Moves a file or directory to a new location.

        @param from The path to the file or directory.
        @param to The path to rename the file or directory to.
        @param overwrite Whether to overwrite the file or directory if it exists.
    ]]
    move: (from: string, to: string, overwrite: boolean?) -> (),

    --[[
        Copies a file or directory to a new location.

        @param from The path to the file or directory.
        @param to The path to copy the file or directory to.
        @param overwrite Whether to overwrite the file or directory if it exists.
    ]]
    copy: (from: string, to: string, overwrite: boolean?) -> (),

    --[[
        Creates a symbolic link.

        *Currently **not** supported on `Windows`*

        @param from The path to the file or directory.
        @param to The path to create the symbolic link to.
    ]]
    symlink: (from: string, to: string) -> (),

    getExePath: () -> string,
    realPath: (path: string) -> string,

    watch: (path: string, callback: (path: string, events: {"created" | "modified" | "moved" | "renamed" | "deleted" | "metadata"}) -> ()) -> FileWatcher,

    path: {
        join: (...string) -> string,
        relative: (from: string, to: string) -> string,
        resolve: (...string) -> string,
        dirname: (path: string) -> string?,
        basename: (path: string, ext: string?) -> string,
        stem: (path: string) -> string,
        extension: (path: string) -> string,
        isAbsolute: (path: string) -> boolean,
        globMatch: (path: string, pattern: string) -> boolean,
    },
}
--[======[ FileSystem ]======]--

--[======[ Process ]======]--
export type CPUArchitecture =
	| "aarch64"
	| "x86_64"
	-- | "x86"
	-- | "arm"
	-- | "aarch64_be"
	-- | "aarch64_32"
	-- | "riscv32"
	| "riscv64"
	-- | "wasm32"
	-- | "wasm64"
	-- | "armeb"
	-- | "arc"
	-- | "avr"
	-- | "bpfel"
	-- | "bpfeb"
	-- | "csky"
	-- | "dxil"
	-- | "hexagon"
	-- | "loongarch32"
	-- | "loongarch64"
	-- | "m68k"
	-- | "mips"
	-- | "mipsel"
	-- | "mips64"
	-- | "mips64el"
	-- | "msp430"
	-- | "powerpc"
	-- | "powerpcle"
	-- | "powerpc64"
	-- | "powerpc64le"
	-- | "r600"
	-- | "amdgcn"
	-- | "sparc"
	-- | "sparc64"
	-- | "sparcel"
	-- | "s390x"
	-- | "tce"
	-- | "tcele"
	-- | "thumb"
	-- | "thumbeb"
	-- | "xcore"
	-- | "xtensa"
	-- | "nvptx"
	-- | "nvptx64"
	-- | "le32"
	-- | "le64"
	-- | "amdil"
	-- | "amdil64"
	-- | "hsail"
	-- | "hsail64"
	-- | "spir"
	-- | "spir64"
	-- | "spirv"
	-- | "spirv32"
	-- | "spirv64"
	-- | "kalimba"
	-- | "shave"
	-- | "lanai"
	-- | "renderscript32"
	-- | "renderscript64"
	-- | "ve"
	-- | "spu_2"

export type OS =
	| "linux"
	| "windows"
	| "macos"
	-- | "freestanding"
	-- | "ananas"
	-- | "cloudabi"
	-- | "dragonfly"
	-- | "freebsd"
	-- | "fuchsia"
	-- | "ios"
	-- | "kfreebsd"
	-- | "lv2"
	-- | "netbsd"
	-- | "openbsd"
	-- | "solaris"
	-- | "uefi"
	-- | "zos"
	-- | "haiku"
	-- | "minix"
	-- | "rtems"
	-- | "nacl"
	-- | "aix"
	-- | "cuda"
	-- | "nvcl"
	-- | "amdhsa"
	-- | "ps4"
	-- | "ps5"
	-- | "elfiamcu"
	-- | "tvos"
	-- | "watchos"
	-- | "driverkit"
	-- | "visionos"
	-- | "mesa3d"
	-- | "contiki"
	-- | "amdpal"
	-- | "hermit"
	-- | "hurd"
	-- | "wasi"
	-- | "emscripten"
	-- | "shadermodel"
	-- | "liteos"
	-- | "serenity"
	-- | "opencl"
	-- | "glsl450"
	-- | "vulkan"
	-- | "plan9"
	-- | "illumos"
	-- | "other"

export type ProcessOptions = {
	cwd: string?,
	env: { [string]: string }?,
	shell: (boolean | string)?,
}

export type ProcessResult = {
	ok: boolean,
	code: number,
}

export type ProcessRunResult = ProcessResult & {
	stdout: string,
	stderr: string,
}

declare class ProcessChild
    stdin: FileHandle?
    stdout: FileHandle?
    stderr: FileHandle?

    --[[
        Waits for the process to exit. Calls system function.

        @return `ProcessResult`
    ]]
    function wait(self): ProcessResult
    --[[
        Kills process. Calls system function.

        @return `ProcessResult`
    ]]
    function kill(self): ProcessResult
end

type ProcessLib = {
    --[[
        The os the process is running on.
    ]]
    os: OS,

    --[[
        The architecture of the processor running.
    ]]
    arch: CPUArchitecture,

    --[[
        The arguments passed to the process.
    ]]
    args: { string },

    --[[
        The environment variables of the process.
        - Includes `.env` file in the current working directory.
        - Includes `.env.production` file in the current working directory. When LUAU_ENV is set to `PRODUCTION`.
        - Includes `.env.development` file in the current working directory. When LUAU_ENV is set to `DEVELOPMENT`.
        - Includes `.env.test` file in the current working directory. When LUAU_ENV is set to `TEST`.
        - Includes `.env.local` file in the current working directory.
    ]]
    env: { [string]: string },

    --[[
        Loads the environment variables of the process.
        - Includes `.env` file in the current working directory.
        - Includes `.env.production` file in the current working directory. When LUAU_ENV is set to `PRODUCTION`.
        - Includes `.env.development` file in the current working directory. When LUAU_ENV is set to `DEVELOPMENT`.
        - Includes `.env.test` file in the current working directory. When LUAU_ENV is set to `TEST`.
        - Includes `.env.local` file in the current working directory.

        @return `EnvironmentMap`
    ]]
    loadEnv: () -> { [string]: string },

    --[[
        Get current working directory of the process.
    ]]
    getCwd: () ->string,

    --[[
        Creates a new process.

        @param exec The executable to run.
        @param args The arguments to pass to the executable.
        @param procOpts The options for the process.
        @return `ProcessChild`
        @error `ProcessCreateError`
    ]]
    create: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> ProcessChild,

    --[[
        Runs a new process.

        Blocks the current process until the process has exited.

        We recommend using `process.create` for non-blocking process creation.

        @param exec The executable to run.
        @param args The arguments to pass to the executable.
        @param procOpts The options for the process.
        @return `ProcessRunResult`
        @error `ProcessRunError`
    ]]
    run: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> ProcessRunResult,

    --[[
        Exits the current process with the given exit code.

        @param code
    ]]
    exit: (code: number) -> never,

    --[[
        Registers a signal handler.

        @param signal The signal to handle.
        @param callback The callback to run when the signal is received.
    ]]
    onSignal: (signal: "INT", callback: () -> ()) -> (),
}
--[======[ Process ]======]--

--[======[ Testing ]======]--
type BasicCases = {
    --[[
        Expects the value to be equal to the expected value.

        @param expected The expected value.
    ]]
    toBe: (expected: any) -> (),
    --[[
        Expects the value to be defined.
    ]]
    toBeDefined: () -> (),
    --[[
        Expects the value to be close to the expected value.

        Formula: `abs(value - expected) < 10 ^ -precision`

        #### Example
        ```luau
        expect(1.1).toBeCloseTo(1, -1) -- Within 5
        expect(1.1).toBeCloseTo(1, 0) -- Within 0.5
        expect(1.1).toBeCloseTo(1, 1) -- Within 0.05
        expect(1.1).toBeCloseTo(1, 2) -- Within 0.005
        ```

        @param expected The expected value.
        @param precision The precision of the comparison.
    ]]
    toBeCloseTo: (expected: number, precision: number) -> (),
    --[[
        Expects the value to be greater than the expected value.

        @param expected The expected value.
    ]]
    toBeGreaterThan: (expected: number) -> (),
    --[[
        Expects the value to be greater than or equal to the expected value.

        @param expected The expected value.
    ]]
    toBeGreaterThanOrEqual: (expected: number) -> (),
    --[[
        Expects the value to be less than the expected value.

        @param expected The expected value.
    ]]
    toBeLessThan: (expected: number) -> (),
    --[[
        Expects the value to be less than or equal to the expected value.

        @param expected The expected value.
    ]]
    toBeLessThanOrEqual: (expected: number) -> (),
    --[[
        Expects the value to be nil.
    ]]
    toBeNil: () -> (),
    --[[
        Expects the value to be not a number.
    ]]
    toBeNan: () -> (),
    --[[
        Expect the length of the value to be equal to the expected length.

        - Tables
        - Strings

        @param expected The expected length
    ]]
    toHaveLength: (expected: number) -> (),
    --[[
        Expects the value to be falsy.

        False or nil.
    ]]
    toBeFalsy: () -> (),
    --[[
        Expects the value to be truthy.

        True or non nil.
    ]]
    toBeTruthy: () -> (),
}

type ExpectCases = BasicCases & {
    --[[
        never

        Flipped expectations.
    ]]
    never: BasicCases,
}

type FunctionalCases = ExpectCases & {
    --[[
        toThrow

        Expects a function to throw an error.

        Optionally, the error message can be checked.

        @param expected The expected error message.
    ]]
    toThrow: (expected: string?) -> (),
    --[[
        never

        Flipped expectations.
    ]]
    never: FunctionalCases,
}

type ExpectHandler = {
    --[[
        [Jest compatibliity]: `expect.any(type)`

        Recommend using `expect.type` instead.

        Expects a value to be a type.
    ]]
    any: (type: string) -> any,

    --[[
        Expects a value to be a type.
    ]]
    type: (type: "nil" | "boolean" | "number" | "string" | "function" | "table" | "userdata" | "thread" | "buffer" | "vector") -> any,

    --[[
        Expects a value to be similar to the expected table.

        @param expected The expected table.
    ]]
    similar: (expected: {[any]: any}) -> any,
}

type TestingLib = {
    --[[
        Whether the testing suite is running.
    ]]
    running: boolean,

    --[[
        [Internal]

        The number of tests that have failed.
    ]]
    _failed: number,

    --[[
        [Internal]

        The number of tests conducted.
    ]]
    _count: number,

    --[[
        [Internal]

        The number of tests that have passed.
    ]]
    _start: number,

    --[[
        Conducts a test.

        *Will be ignored if the testing suite is not running.*

        @param name The name of the test.
        @param callback The callback to run the test.
        @param timeout The timeout on how long a test should last.
    ]]
    test: (name: string, callback: () -> (), timeout: number?) -> (),

    --[[
        Describes a test suite.

        *Will be ignored if the testing suite is not running.*

        @param name The name of the suite.
        @param callback The callback to run the suite.
    ]]
    describe: (name: string, callback: () -> ()) -> (),

    --[[
        Defers a function.

        Deferred function will be executed after a test completes.
        Useful for cleaning up resources.

        @param callback The callback to defer.
    ]]
    defer: (fn: () -> ()) -> (),

    --[[
        Expects a value.

        @param value The value to expect.
        @return Handler for expectations.
    ]]
    expect: ((value: (...any) -> ...any) -> FunctionalCases) & ((value: any) -> ExpectCases) & ExpectHandler,

    --[[
        Expects a value to be true or non nil.

        Similar to `assert(value)`

        @param value The value to expect.
    ]]
    expected: (value: any) -> (),

    --[[
        Expects a value to equal another.

        Similar to `assert(value == expected, ...)`

        @param expected The expected value.
        @param value The value to test.
    ]]
    expectEqual: ((expected: any, value: any) -> ()),
}
--[======[ Testing ]======]--

--[======[ Task ]======]--
type TaskLib = {
    --[[
        Cancels a task.

        @param thread The task to cancel.
    ]]
    cancel: (thread: thread) -> (),

    --[[
        Defers a task.

        Runs on next frame.

        @param f The function to defer.
        @return `thread`
    ]]
    defer: <A..., R...>(f: ((A...) -> R...) | thread, A...) -> thread,

    --[[
        Delays a task.

        Runs after a certain amount of time.

        @param sec The time to delay.
        @param f The function to delay.
        @return `thread`
    ]]
    delay: <A..., R...>(sec: number, f: ((A...) -> (R...)) | thread, A...) -> thread,

    --[[
        Spawns a task.

        Runs immediately.

        @param f The function to spawn.
        @return `thread`
    ]]
    spawn: <A..., R...>(f: ((A...) -> (R...)) | thread, A...) -> thread,

    --[[
        Sleeps task.

        Yields caller.
        Resumes after a certain amount of time.

        @param sec The time to wait.
        @return `number`
    ]]
    wait: (sec: number?) -> number,

    --[[
        Counts the number of tasks.

        Optional kinds parameter to count a specific kind of task.

        Kinds:
        - `s` to count sleeping tasks.
        - `d` to count deferred tasks.
        - `w` to count awaiting tasks. (Zune backend)
        - `t` to count internal tasks. (Zune backend)

        #### Example

        ```luau
        task.defer(function() end)
        task.spawn(function() task.wait(1) end)
        print(task.count("sd")) -- 2
        print(task.count("d")) -- 1
        print(task.count()) -- 2
        ```

        @param kinds The kinds of tasks to count.
        @return `number` | `...number`
    ]]
    count: (() -> number) & ((kinds: string?) -> ...number),
}
--[======[ Task ]======]--

--[======[ Network ]======]--
declare class NetHttpWebSocket
    --[[
        Whether the websocket is connected.
    ]]
    function isConnected(self): boolean

    --[[
        Sends a message to the websocket.
    ]]
    function send(self, message: string | buffer): ()

    --[[
        Closes the websocket.
    ]]
    function close(self, code: number?): ()
end

declare class NetworkSocket
    function isOpen(self): boolean
    function send(self, data: string | buffer, offset: number?): number
    function sendMsg(self, port: number, address: string, data: string | buffer, offset: number?): number
    function recv(self, max_size: number?): buffer
    function recvMsg(self, max_size: number?): (NetworkAddress, buffer)
    function accept(self): NetworkSocket
    function connect(self, address: string, port: number): ()
    function listen(self, backlog: number?): ()
    function bindIp(self, address: string, port: number): ()
    function getName(self): NetworkAddress
    function setOption(self, level: number, optname: number, value: boolean | string | buffer): ()
    function close(self): ()
end

declare class NetHttpServer
     --[[
        Stops the server.
    ]]
    function stop(self): ()

    --[[
        The port the server is bound to.
    ]]
    function getPort(self): number

    --[[
        Checks if the server is running.
    ]]
    function isRunning(self): boolean
end

export type NetworkAddress = {
    family: number,
    port: number,
    address: string,
}

export type ServerRequest = {
    method: string,
    path: string,
    query: {[string]: string},
    headers: {[string]: string},
    body: string?,
}

export type ServerResponse = {
    statusCode: number,
    headers: {[string]: string}?,
    body: string | buffer,
}

export type ServerWebSocketHandlers = {
    --[[
        Function to check if the request should be upgraded to a websocket.
        Should return true if the request should be upgraded.
        @return `boolean`
    ]]
    upgrade: ((request: ServerRequest) -> boolean)?,

    --[[
        A function event for when a websocket is opened.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    open: ((websocket: NetHttpWebSocket) -> ())?,
    --[[
        A function event for when a websocket receives a message.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    message: ((websocket: NetHttpWebSocket, message: string) -> ())?,
    --[[
        A function event for when a websocket is closed.

        *`WebSocket` class will keep the same reference per connection*.
    ]]
    close: ((websocket: NetHttpWebSocket, code: number) -> ())?,
}

export type ServeOptions = {
    --[[
        The port to bind to.
    ]]
    port: number,

    --[[
        The address to bind to.
        - Default: `127.0.0.1`
    ]]
    address: string?,

    --[[
        Whether to reuse the address.
        - Useful for multi-threaded servers.

        Default: `false`
    ]]
    reuseAddress: boolean?,

    --[[
        The amount of connections to backlog
        - Default: `128`
    ]]
    backlog: number?,

    --[[
        The maximum body size to accept.
        - Default: `4096`
    ]]
    maxBodySize: number?,

    --[[
        The amount of seconds to wait before timing a client out.
        - `0` for no timeout.
        - Default: `60`
    ]]
    clientTimeout: number?,

    --[[
        The maximum number of connections to accept at a time.
        - `0` for no limit.
        - Default: `1024`
    ]]
    maxConnections: number?,

    --[[
        The function to handle requests.
    ]]
    request: (request: ServerRequest) -> string | buffer | ServerResponse,

    --[[
        Functions to handle websockets.
    ]]
    websocket: ServerWebSocketHandlers?,
}

export type Response = {
    ok: boolean,
    statusCode: number,
    statusReason: string,
    headers: {[string]: string},
    body: string,
}

type BareRequestOptions = {
    method: "GET",
    headers: {[string]: string}?,

    --[[
        Whether to follow redirects.
        - Default: `true`
    ]]
    allowRedirects: boolean?,

    --[[
        The maximum body size to accept.
        - Default: `2097152`
    ]]
    maxBodySize: number?,
}

type BodyRequestOptions = {
    method: "POST" | "PUT" | "DELETE",
    headers: {[string]: string}?,
    body: string,
}

export type RequestOptions = BareRequestOptions | BodyRequestOptions

export type WebSocketOptions = {
    --[[
        The protocols to use.
    ]]
    protocols: {string}?,
    --[[
        Timeout for the connection.

        *Default: 30*

        *Negative number for indefinite*
    ]]
    timeout: number?,
    --[[
        WebSocket accept event
    ]]
    accept: ((socket: NetHttpWebSocket, request: ServerResponse) -> boolean)?,
    --[[
        WebSocket open event.
    ]]
    open: ((socket: NetHttpWebSocket) -> ())?,
    --[[
        WebSocket close event.
    ]]
    close: ((socket: NetHttpWebSocket, close: number?) -> ())?,
    --[[
        WebSocket message event.
    ]]
    message: ((socket: NetHttpWebSocket, message: string) -> ())?,
}

type NetworkAddressFamily = {
    RDS: number,
    ROSE: number,
    BRIDGE: number,
    PHONET: number,
    SNA: number,
    FILE: number,
    MPLS: number,
    ROUTE: number,
    WANPIPE: number,
    UNSPEC: number,
    CAIF: number,
    NETROM: number,
    UNIX: number,
    INET: number,
    ATMSVC: number,
    MAX: number,
    NETLINK: number,
    IUCV: number,
    SMC: number,
    INET6: number,
    TIPC: number,
    KEY: number,
    QIPCRTR: number,
    VSOCK: number,
    IPX: number,
    ASH: number,
    IB: number,
    PACKET: number,
    KCM: number,
    DECnet: number,
    RXRPC: number,
    NETBEUI: number,
    NFC: number,
    ALG: number,
    IEEE802154: number,
    ISDN: number,
    XDP: number,
    LOCAL: number,
    BLUETOOTH: number,
    CAN: number,
    LLC: number,
    APPLETALK: number,
    PPPOX: number,
    ATMPVC: number,
    AX25: number,
    ECONET: number,
    IRDA: number,
    SECURITY: number,
    X25: number,
}

type NetworkSocketFlags = {
    DCCP: number,
    RAW: number,
    RDM: number,
    DGRAM: number,
    PACKET: number,
    STREAM: number,
    SEQPACKET: number,
    CLOEXEC: number,
    NONBLOCK: number,
}

type NetworkIPProtocols = {
    COMP: number,
    ICMP: number,
    ESP: number,
    IGMP: number,
    TCP: number,
    ICMPV6: number,
    MTP: number,
    GRE: number,
    SCTP: number,
    MAX: number,
    NONE: number,
    FRAGMENT: number,
    IDP: number,
    UDPLITE: number,
    HOPOPTS: number,
    MH: number,
    BEETPH: number,
    AH: number,
    IPIP: number,
    IPV6: number,
    PIM: number,
    DSTOPTS: number,
    UDP: number,
    DCCP: number,
    RAW: number,
    PUP: number,
    MPLS: number,
    ENCAP: number,
    RSVP: number,
    ROUTING: number,
    EGP: number,
    TP: number,
    IP: number,
}

type NetworkSocketOptionLevel = {
    PPPOL2TP: number,
    RDS: number,
    TIPC: number,
    ALG: number,
    PNPIPE: number,
    BLUETOOTH: number,
    PACKET: number,
    IPV6: number,
    KCM: number,
    RXRPC: number,
    NETBEUI: number,
    DECNET: number,
    TLS: number,
    ICMPV6: number,
    RAW: number,
    XDP: number,
    SOCKET: number,
    LLC: number,
    NFC: number,
    CAIF: number,
    IUCV: number,
    X25: number,
    AAL: number,
    NETLINK: number,
    DCCP: number,
    IRDA: number,
    ATM: number,
    IP: number,
}

type NetworkSocketOption = {
    ATTACH_FILTER: number,
    CNX_ADVICE: number,
    PEERCRED: number,
    LINGER: number,
    DEBUG: number,
    RXQ_OVFL: number,
    SNDBUF: number,
    DONTROUTE: number,
    ZEROCOPY: number,
    PASSCRED: number,
    DETACH_REUSEPORT_BPF: number,
    ATTACH_REUSEPORT_EBPF: number,
    MEMINFO: number,
    COOKIE: number,
    SNDBUFFORCE: number,
    PRIORITY: number,
    BSDCOMPAT: number,
    SNDTIMEO: number,
    BINDTODEVICE: number,
    OOBINLINE: number,
    BPF_EXTENSIONS: number,
    TIMESTAMP_NEW: number,
    NO_CHECK: number,
    WIFI_STATUS: number,
    PEERGROUPS: number,
    TYPE: number,
    NOFCS: number,
    DOMAIN: number,
    TIMESTAMPNS_NEW: number,
    SNDLOWAT: number,
    KEEPALIVE: number,
    PEEK_OFF: number,
    PEERSEC: number,
    PEERNAME: number,
    RCVBUF: number,
    REUSEPORT: number?,
    INCOMING_NAPI_ID: number,
    TIMESTAMPING_OLD: number,
    RCVBUFFORCE: number,
    REUSEADDR: number,
    MAX_PACING_RATE: number,
    MARK: number,
    RCVTIMEO_NEW: number,
    BUSY_POLL: number,
    TIMESTAMPING_NEW: number,
    BINDTOIFINDEX: number,
    TXTIME: number,
    SECURITY_ENCRYPTION_NETWORK: number,
    LOCK_FILTER: number,
    RCVLOWAT: number,
    SECURITY_ENCRYPTION_TRANSPORT: number,
    ATTACH_BPF: number,
    INCOMING_CPU: number,
    ERROR: number,
    SELECT_ERR_QUEUE: number,
    DETACH_BPF: number,
    SNDTIMEO_NEW: number,
    TIMESTAMPNS_OLD: number,
    PASSSEC: number,
    TIMESTAMP_OLD: number,
    GET_FILTER: number,
    DETACH_FILTER: number,
    ATTACH_REUSEPORT_CBPF: number,
    BROADCAST: number,
    SECURITY_AUTHENTICATION: number,
    PROTOCOL: number,
    ACCEPTCONN: number,
    RCVTIMEO: number,
}

type NetworkLib = {
    ADDRF: NetworkAddressFamily,
    SOCKF: NetworkSocketFlags,
    SOCKOPT: NetworkSocketOption,
    SOCKOPTLV: NetworkSocketOptionLevel,
    IPPROTO: NetworkIPProtocols,

    createSocket: (address_family: number, flags: number, protocol: number) -> NetworkSocket,
    getAddressList: (name: string, port: number) -> {NetworkAddress},

    http: {
        --[[
            Starts a server on the specified port.

            @param options The options for the server.
            @return `NetHttpServer` The server handle.
            @error `ServerStartError`
        ]]
        serve: (options: ServeOptions) -> NetHttpServer,

        --[[
            Makes a request to the specified host.

            Optional options, defaults to GET request.

            *TLS is supported.*

            @param host The host to make the request to.
            @param options The options for the request.
            @return `Response`
            @error `RequestError`
        ]]
        request: (host: string, options: RequestOptions?) -> Response,

        --[[
            Creates a websocket client.

            *TLS is supported.*

            @param host The host to connect to.
            @param opts The options for the websocket.
            @return `NetHttpWebSocket`
            @error `WebSocketError`
        ]]
        websocket: (host: string, opts: WebSocketOptions) -> NetHttpWebSocket,
    }
}
--[======[ Network ]======]--

--[======[ Luau ]======]--
export type CompileOptions = {
    debug_level: number?,
    optimization_level: number?,
    coverage_level: number?,
}

export type LoadOptions = {
    env: {[any]: any}?,
    chunkName: string?,
    nativeCodeGen: boolean?,
}

export type CoverageData = {
    name: string,
    line: number,
    depth: number,
    [number]: number,
};

export type ParseResult = {
    errors: {
        {
            message: string,
            location: string,
        }
    }
} | {
    root: {any},
    lines: number,
    commentLocations: {
        {
            type: string,
            location: string,
        }
    },
    hotcomments: {
        {
            header: boolean,
            content: string,
            location: string,
        }
    }
};

type LuauLib = {
    --[[
        Compiles Luau source code.

        @param source The source code to compile.
        @param options The options for the compilation.
        @return `string` The compiled code, or an error.
        @error `CompileError`
    ]]
    compile: (source: string, opts: CompileOptions?) -> string,

    --[[
        Loads Luau source code.

        *Notes:*
        - `nativeCodeGen` will be disabled if `env` field is not a regular table (non-metatable).
        - If `env` is not provided, it will default to the global environment.
            - If the global environment is an unsafe environment, `nativeCodeGen` will not work.
        - If `chunkName` is not provided, it will default to `(load)`.

        @param bytecode The bytecode to load.
        @param options The options for the load.
        @return `(...any) -> ...any` The loaded function.
    ]]
    load: (bytecode: string, opts: LoadOptions?) -> ((...any) -> ...any),

    coverage: (fn: (...any) -> ...any) -> {CoverageData},

    parse: (src: string) -> ParseResult,
    parseExpr: (src: string) -> ParseResult,
}
--[======[ Luau ]======]--

--[======[ Serde ]======]--
type JsonEncodeConfig = {
    --[[
        Pretty print indent level
    ]]
    prettyIndent: number,
}


type JsonDecodeConfig = {
    --[[
        Preserve null values
    ]]
    preserveNull: boolean,
}

type JsonEncoder = {
    --[[
        Encodes value to JSON/JSON5

        @param value The value to encode
        @param indent The indent level
        @return `string` The encoded JSON/JSON5
    ]]
    encode: (value: any, config: JsonEncodeConfig?) -> string,
    --[[
        Decodes JSON/JSON5

        @param json The JSON/JSON5 to decode
        @param config The configuration
        @return `any` The decoded value
    ]]
    decode: (json: string, config: JsonDecodeConfig?) -> any,

    --[[
        IndentKind for Pretty Printing
    ]]
    Indents: {
        None: number,
        TwoSpaces: number,
        FourSpaces: number,
        Tabs: number,
    },

    --[[
        Special values
    ]]
    Values: {
        Null: any,
    }
}

type TomlEncoder = {
    --[[
        Encodes table to TOML

        @param object The table to encode
        @return `string` The encoded TOML
    ]]
    encode: (object: {[string]: any}) -> string,
    --[[
        Decodes TOML

        @param toml The TOML to decode
        @return `table` The decoded table
    ]]
    decode: (toml: string) -> {[string]: any},
}

type YamlEncoder = {
    --[[
        Encodes table to YAML

        @param object The table to encode
        @return `string` The encoded YAML
    ]]
    encode: (object: {[string]: any}) -> string,
    --[[
        Decodes YAML

        @param yaml The YAML to decode
        @return `table` The decoded table
    ]]
    decode: (yaml: string) -> {[string]: any},
}

type Base64Encoder = {
    --[[
        Encodes table to Base64

        @param value The value to encode
        @return `string` The encoded Base64
    ]]
    encode: (value: string) -> string,
    --[[
        Decodes Base64

        @param base64 The Base64 to decode
        @return `string` The decoded value
    ]]
    decode: (base64: string) -> string,
}

type GenericCompressionOptions = {
    --[[
        The compression level.
    ]]
    level: number?,
}

type CompressionFn =
& ((raw: string) -> string)
& ((raw: buffer) -> buffer)

type AdvancedCompressionFn =
& ((raw: string, options: GenericCompressionOptions?) -> string)
& ((raw: buffer, options: GenericCompressionOptions?) -> buffer)

type DecompressionFn =
& ((compressed: string) -> string)
& ((compressed: buffer) -> buffer)

type GenericCompressor = {
    --[[
        Compresses a string.
    ]]
    compress : AdvancedCompressionFn,
    --[[
        Decompresses a string.
    ]]
    decompress : DecompressionFn,
}

type SerdeLib = {
    --[[
        JSON encoder and decoder.
    ]]
    json: JsonEncoder,

    --[[
        JSON5 encoder and decoder.
    ]]
    json5: JsonEncoder,

    --[[
        TOML encoder and decoder.
    ]]
    toml: TomlEncoder,

    --[[
        YAML encoder and decoder.
    ]]
    yaml: YamlEncoder,

    --[[
        BASE64 encoder and decoder.
    ]]
    base64: Base64Encoder,

    --[[
        GZIP compressor and decompressor.
    ]]
    gzip: GenericCompressor,

    --[[
        ZLIB compressor and decompressor.
    ]]
    zlib: GenericCompressor,

    --[[
        LZ4 compressor and decompressor.
    ]]
    lz4: {
        --[[
            Compresses a string.
        ]]
        compress : CompressionFn,
        --[[
            Compresses a string as a lz4 frame.
        ]]
        compressFrame : AdvancedCompressionFn,
        --[[
            Decompresses a string.
        ]]
        decompress :
            & ((compressed: string, size: number) -> string)
            & ((compressed: buffer, size: number) -> buffer),
        --[[
            Decompresses a string as a lz4 frame.
        ]]
        decompressFrame : DecompressionFn,
    },

    --[[
        ZSTD compressor and decompressor.
    ]]
    zstd: GenericCompressor,
}
--[======[ Serde ]======]--

--[======[ Io ]======]--
declare class IoReadable
    read:
    & ((self: IoReadable, amount: number?, bytes: true?) -> buffer)
    & ((self: IoReadable, amount: number?, bytes: false) -> string)

    function readu8(self): number
    function readu16(self): number
    function readu32(self): number
    function readi8(self): number
    function readi16(self): number
    function readi32(self): number
    function readf32(self): number
    function readf64(self): number
end

declare class IoWritable
    function write(self, data: string | buffer): ()
    function writeu8(self, value: number): ()
    function writeu16(self, value: number): ()
    function writeu32(self, value: number): ()
    function writei8(self, value: number): ()
    function writei16(self, value: number): ()
    function writei32(self, value: number): ()
    function writef32(self, value: number): ()
    function writef64(self, value: number): ()
end

declare class BufferStream
    read:
        & ((self: BufferStream, amount: number?, bytes: true?) -> buffer?)
        & ((self: BufferStream, amount: number?, bytes: false) -> string?)

    function write(self, data: string | buffer): ()
    function pos(self): number
    function size(self): number
    function seekTo(self, pos: number): ()
    function seekBy(self, offset: number): ()
    function canRead(self, amount: number?): ()
    function writer(self): IoWritable
    function reader(self): IoReadable
end

declare class BufferSink
    --[[
        Written length
    ]]
    len: boolean
    closed: boolean

    flush:
        & ((self: BufferSink) -> buffer)
        & ((self: BufferSink, true) -> buffer)
        & ((self: BufferSink, false) -> string)

    function write(self, data: string | buffer): ()
    function writer(self): IoWritable
    function close(self): ()
end

export type Terminal = {
    --[[
        Whether the terminal is a TTY.
    ]]
    isTTY: boolean,

    --[[
        Get current saved mode.
    ]]
    getCurrentMode: () -> "normal" | "raw",

    --[[
        Enable raw mode.

        On unix: Will attempt to change terminal mode.
        On windows: Will attempt to change console mode.

        @return `boolean` Whether the mode was successfully changed.
    ]]
    enableRawMode: () -> boolean,

    --[[
        Restore terminal mode.

        On unix: Will attempt to restore the original terminal mode.
        On windows: Will attempt to restore the original console mode.

        @return `boolean` Whether the mode was successfully restored.
    ]]
    restoreMode: () -> boolean,


    --[[
        Get the terminal size.

        *Will return `nil` if the terminal is not TTY.*
        *Will **error** if there was an issue getting the terminal size.*

        @return `number` The width of the terminal.
        @return `number` The height of the terminal.
    ]]
    getSize: () -> (number, number),
}

type BufferSinkOptions = {
    --[[
        The maximum size of the buffer.
        - Default: `1073741824`
    ]]
    limit: number?,
}

type IoLib = {
    MAX_READ: number,

    --[[
        Formats input to a readable string.

        @param ... The arguments to format.
        @return `string`
    ]]
    format: (...any) -> string,

    --[[
        Creates a buffer sink.

        @param opts The options for the buffer sink.
        @return `BufferSink`
    ]]
    createBufferSink: (opts: BufferSinkOptions?) -> BufferSink,

    --[[
        Creates a buffer stream with provided lua buffer.

        @param buffer The lua buffer to use.
        @return `BufferStream`
    ]]
    createFixedBufferStream: (buffer: buffer) -> BufferStream,

    --[[
        Terminal.
    ]]
    terminal: Terminal,
    --[[
        stdout handle.
    ]]
    stdout: FileHandle,
    --[[
        stderr handle.
    ]]
    stderr: FileHandle,
    --[[
        stdin handle.
    ]]
    stdin: FileHandle,
}
--[======[ Io ]======]--

--[======[ Crypto ]======]--
declare class CryptoHash
    digest:
        & ((self: CryptoHash) -> buffer)
        & ((self: CryptoHash, encoding: "binary") -> buffer)
        & ((self: CryptoHash, encoding: "hex" | "base64") -> string)
    function update(self, value: string | buffer): ()
    function copy(self): CryptoHash
end

declare class TlsCertBundle
end

declare class TlsCertKeyPair
end

type HashAlgorithms =
    | "sha1"
    | "md5"
    | "blake3"
    | "sha224"
    | "sha256"
    | "sha384"
    | "sha512"
    | "sha3_224"
    | "sha3_256"
    | "sha3_384"
    | "sha3_512"
    | "blake2b128"
    | "blake2b160"
    | "blake2b256"
    | "blake2b384"
    | "blake2b512"
    | "blake2s128"
    | "blake2s160"
    | "blake2s224"
    | "blake2s256"

type BcryptPasswordOptions = {
    --- Default: "argon2d"
    algorithm: "bcrypt"?,
    --[[
        Default: 4

        Only between 4 and 31
    ]]
    cost: number?,
}

type Argon2PasswordOptions = {
    --- Default: "argon2d"
    algorithm: ("argon2d" | "argon2i" | "argon2id")?,
    --- Default: 2
    timeCost: number?,
    --- Default: 65536
    memoryCost: number?,
    --- Default: 1
    threads: number?,
}

type PasswordOptions = BcryptPasswordOptions | Argon2PasswordOptions

type EncryptedData = {
    cipher: buffer,
    tag: buffer,
}

type Aead = {
    encrypt: (data: string | buffer, key: string | buffer, nonce: string | buffer, ad: (string | buffer)?) -> EncryptedData,
    decrypt: (cipher: string | buffer, tag: string | buffer, key: string | buffer, nonce: string | buffer, ad: (string | buffer)?) -> string,
}

type CryptoLib = {
    createHash: (algorithm: HashAlgorithms, secret: string?) -> CryptoHash,

    --[[
        Password hashing function
    ]]
    password: {
        hash: (password: string, options: PasswordOptions?) -> string,
        verify: (password: string, hash: string) -> boolean,
    },

    --[[
        Cryptographically secure random number generation.
    ]]
    random: {
        --[[
            Generates a random number (f64), if no arguments are provided, it will generate a number between 0 and 1.
        ]]
        nextNumber:
            & (() -> number)
            & ((min: number, max: number) -> number),
        --[[
            Generates a random integer (i32), if no arguments are provided,

            it will generate a number between the limits of a signed 32-bit integer.
        ]]
        nextInteger:
            & (() -> number)
            & ((min: number, max: number) -> number),

        --[[
            Generates a random boolean.
        ]]
        nextBoolean: () -> boolean,

        --[[
            Writes random bytes to the buffer.
        ]]
        fill: (buffer: buffer, offset: number, length: number) -> (),
    },

    aead: {
        aes_gcm: {
            Aes128Gcm: Aead,
            Aes256Gcm: Aead,
        },
        aes_ocb: {
            Aes128Ocb: Aead,
            Aes256Ocb: Aead,
        },
        aegis: {
            Aegis128X4: Aead,
            Aegis128X2: Aead,
            Aegis128L: Aead,
            Aegis256X4: Aead,
            Aegis256X2: Aead,
            Aegis256: Aead,
            Aegis128X4_256: Aead,
            Aegis128X2_256: Aead,
            Aegis128L_256: Aead,
            Aegis256X4_256: Aead,
            Aegis256X2_256: Aead,
            Aegis256_256: Aead,
        },
        chacha_poly: {
            ChaCha8Poly1305: Aead,
            ChaCha12Poly1305: Aead,
            ChaCha20Poly1305: Aead,
            XChaCha8Poly1305: Aead,
            XChaCha12Poly1305: Aead,
            XChaCha20Poly1305: Aead,
        },
        salsa_poly: {
            XSalsa20Poly1305: Aead,
        },
        isap: {
            IsapA128A: Aead,
        },
    },

    tls: {
        bundleFromSystem: () -> TlsCertBundle,
        bundleFromFile: (file: string) -> TlsCertBundle,
        keyPairFromFile: (certFile: string, keyFile: string) -> TlsCertKeyPair,
        setupClient: (socket: NetworkSocket, { host: string, ca: TlsCertBundle }) -> (),
        setupServer: (socket: NetworkSocket, { auth: TlsCertKeyPair }) -> (),
    },
}
--[======[ Crypto ]======]--

--[======[ Regex ]======]--
export type RegexMatch = {
    --[[
        The captured group.
    ]]
    string: string,
    --[[
        The index of the group.
    ]]
    index: number,
}

export type Regex = {
    --[[
        Match a string.

        @param str String to match
    ]]
    match: (self: Regex, str: string) -> {RegexMatch}?,
    --[[
        Search a string.

        @param str String to search
    ]]
    search: (self: Regex, str: string) -> {RegexMatch}?,
    --[[
        Capture a string.

        *If global is nil, it will default to false.*

        @param str String to capture
        @param global Whether to capture globally
        @return `{{RegexMatch}}`
    ]]
    captures: (self: Regex, str: string, global: boolean?) -> {{RegexMatch}},
    --[[
        Check if a string matches the pattern.

        @param str String to check
    ]]
    isMatch: (self: Regex, str: string) -> boolean,
    --[[
        Format a string.

        @param str String to format
        @param format Format to use
    ]]
    format: (self: Regex, str: string, format: string) -> string,
    --[[
        Replace the first occurrence of a string.

        @param str String to replace
        @param replacement String to replace with
    ]]
    replace: (self: Regex, str: string, replacement: string) -> string,
    --[[
        Replace all occurrences of a string.

        @param str String to replace
        @param replacement String to replace with
    ]]
    replaceAll: (self: Regex, str: string, replacement: string) -> string,
}

type RegexLib = {
    --[[
        Create a new regex object.

        Flags:
          - `i`: Case insensitive
          - `m`: Multiline

        @param pattern Pattern to use
        @param flags Flags to use
    ]]
    create: (pattern: string, flags: string?) -> Regex,
}
--[======[ Regex ]======]--

--[======[ Datetime ]======]--
export type TimeDictionary = {
    year: number,
    month: number,
    day: number,
    hour: number,
    minute: number,
    second: number,
    millisecond: number,
}

export type DateTime = {
    unixTimestamp: number,
    unixTimestampMillis: number,

    UnixTimestamp: number,
    UnixTimestampMillis: number,

    toLocalTime: (self: DateTime) -> TimeDictionary,
    ToLocalTime: (self: DateTime) -> TimeDictionary,

    toUniversalTime: (self: DateTime) -> TimeDictionary,
    ToUniversalTime: (self: DateTime) -> TimeDictionary,

    toIsoDate: (self: DateTime) -> string,
    ToIsoDate: (self: DateTime) -> string,

    formatLocalTime: (self: DateTime, format: string) -> string,
    FormatLocalTime: (self: DateTime, format: string) -> string,

    formatUniversalTime: (self: DateTime, format: string) -> string,
    FormatUniversalTime: (self: DateTime, format: string) -> string,
}

type DatetimeLib = {
    now: () -> DateTime,

    fromIsoDate: (date: string) -> DateTime,
    fromUnixTimestamp: (timestamp: number) -> DateTime,
    fromUnixTimestampMillis: (timestamp: number) -> DateTime,
    fromLocalTime: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime,
    fromUniversalTime: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime,

    parse: (date: string) -> DateTime,
}
--[======[ Datetime ]======]--

--[======[ FFI ]======]--
export type FFILibrary = {
    getSymbol: (self: FFILibrary, symbol: string) -> FFIPointer,
    [string]: (...any) -> any,
}

declare class FFIDataType
    function size(self): number
    function alignment(self): number
end

declare class FFIStructureType extends FFIDataType
    function offset(self, field: string): number
    function new(self, fields: {{ [string]: buffer | number }}): buffer
end

declare class FFIPointerType extends FFIDataType
    function tag(self): number
    function newTag(self, tag: string | buffer): FFIPointerType
end

type AnyDataType = FFIDataType | FFIStructureType | FFIPointerType

export type FFIFunctionDef = {
    returns: AnyDataType,
    args: { AnyDataType }
}

export type FFIPointer = {
    release: (self: FFIPointer) -> FFIPointer,
    retain: (self: FFIPointer) -> FFIPointer,
    setTag: (self: FFIPointer, tag: number) -> FFIPointer,
    getTag: (self: FFIPointer) -> number,
    drop: (self: FFIPointer) -> FFIPointer,
    offset: (self: FFIPointer, offset: number) -> FFIPointer,
    read: (self: FFIPointer, srcOffset: number, dest: buffer | FFIPointer, destOffset: number, count: number) -> buffer,
    write: (self: FFIPointer, destOffset: number, src: buffer | FFIPointer, srcOffset: number, count: number) -> (),
    readi8: (self: FFIPointer, offset: number?) -> number,
    readu8: (self: FFIPointer, offset: number?) -> number,
    readi16: (self: FFIPointer, offset: number?) -> number,
    readu16: (self: FFIPointer, offset: number?) -> number,
    readi32: (self: FFIPointer, offset: number?) -> number,
    readu32: (self: FFIPointer, offset: number?) -> number,
    readi64: (self: FFIPointer, offset: number?) -> buffer,
    readu64: (self: FFIPointer, offset: number?) -> buffer,
    readf32: (self: FFIPointer, offset: number?) -> number,
    readf64: (self: FFIPointer, offset: number?) -> number,
    readPtr: (self: FFIPointer, offset: number?) -> FFIPointer,
    writei8: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu8: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writei16: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu16: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writei32: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu32: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writei64: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu64: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writef32: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writef64: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writePtr: (self: FFIPointer, offset: number, value: FFIPointer) -> (),
    isNull: (self: FFIPointer) -> boolean,
    setSize: (self: FFIPointer, size: number) -> (),
    getSize: (self: FFIPointer) -> number,
    setAlignment: (self: FFIPointer, alignment: number) -> (),
    getAlignment: (self: FFIPointer) -> number,
    span: (self: FFIPointer, offset: number?) -> buffer,
}

type FFILib = {
    supported: boolean,

    prefix: string,
    suffix: string,

    types: {
        void: FFIDataType,
        i8: FFIDataType,
        u8: FFIDataType,
        i16: FFIDataType,
        u16: FFIDataType,
        i32: FFIDataType,
        u32: FFIDataType,
        i64: FFIDataType,
        u64: FFIDataType,
        float: FFIDataType,
        double: FFIDataType,
        pointer: FFIPointerType,
    },

    createPtr: (src: buffer) -> FFIPointer,
    getRef: (src: FFIPointer) -> FFIPointer,

    getLuaState: (mainthread: boolean?) -> FFIPointer,

    alloc: (size: number, alignment: number?) -> FFIPointer,
    free: (src: FFIPointer) -> (),
    dupe: (src: buffer | FFIPointer) -> FFIPointer,
    len: (src: buffer | FFIPointer) -> number?,
    copy: (dest: buffer | FFIPointer, destOffset: number, src: buffer | FFIPointer, srcOffset: number, count: number) -> (),

    tagName: (tag: number) -> string,

    struct: (fields: {{ [string]: AnyDataType }}) -> FFIStructureType,
    fn: (definition: FFIFunctionDef, srcPtr: FFIPointer) -> ((...any) -> any),
    closure: (definition: FFIFunctionDef, handler: (...any) -> any) -> FFIPointer,
    dlopen: (path: string, { [string]: FFIFunctionDef }) -> FFILibrary,
}
--[======[ FFI ]======]--

--[======[ SQLite ]======]--

export type SQLite3Values = {[string]: number | string | buffer};
export type SQLite3Result = {
    lastInsertRowId: number,
    changes: number,
}

declare class SQLite3Statement
    function run(self, args: SQLite3Values?): SQLite3Result
    function get(self, args: SQLite3Values?): SQLite3Values?
    function all(self, args: SQLite3Values?): {SQLite3Values}
    function finalize(self): ()
end

declare class SQLite3Database
    function transaction(self, callback: (...any) -> (), kind: ("deferred" | "immediate" | "exclusive")?): ((...any) -> ())
    function query(self, query: string): SQLite3Statement
    function exec(self, query: string, args: SQLite3Values?): ()
    function close(self): ()
end

export type SQLiteLib = {
    --[[
        Opens a database.

        *Default: `:memory:`*

        @param path The path to the database.
        @return `SQLite3Database`
        @error `SQLite3Error`
    ]]
    open: (path: string?) -> SQLite3Database,
}
--[======[ SQLite ]======]--

--[======[ Require ]======]--
export type RequireLib = {
    navigate: (path: string, from: string?, config: string?) -> string,
    getCached: (resolvedPath: string) -> any?,
}
--[======[ Require ]======]--

--[======[ Random ]======]--
declare class Random
    nextNumber:
        & ((self: Random) -> number)
        & ((self: Random, min: number, max: number) -> number)
    NextNumber:
        & ((self: Random) -> number)
        & ((self: Random, min: number, max: number) -> number)
    function nextInteger(self, min: number, max: number): number
    function NextInteger(self, min: number, max: number): number
    function clone(self): Random
    function Clone(self): Random
end

type RandomConstructor = {
    new: (seed: number) -> Random,
}

export type RandomLib = RandomConstructor & {
    LuauPcg32: RandomConstructor,
    Pcg32: RandomConstructor,
    Isaac64: RandomConstructor,
    Pcg32: RandomConstructor,
    Xoroshiro128: RandomConstructor,
    Xoshiro256: RandomConstructor,
    Sfc64: RandomConstructor,
    RomuTrio: RandomConstructor,
}
--[======[ Random ]======]--

--[======[ Thread ]======]--
declare class Thread
    function start(self): ()
    function join(self): ()
    function status(self): "ready" | "running" | "dead"
    function receive(self): (...any)
    function send(self, ...: any): ()
end

type ThreadLoadOptions = {
    chunkName: string?,
    nativeCodeGen: boolean?,
}

export type ThreadLib = {
    fromModule: (module: string) -> Thread,
    fromBytecode: (bytecode: string | buffer, options: ThreadLoadOptions?) -> Thread,
    receive: (self: Thread) -> ...any,
    send: (self: Thread, ...any) -> (),
    getCpuCount: () -> number,
}
--[======[ Thread ]======]--

declare zune: {
    compiled: {
        optimize: number,
        debug: number,
    }?,

    fs: FileSystemLib,
    process: ProcessLib,
    testing: TestingLib,
    task: TaskLib,
    net: NetworkLib,
    luau: LuauLib,
    serde: SerdeLib,
    io: IoLib,
    crypto: CryptoLib,
    regex: RegexLib,
    datetime: DatetimeLib,
    ffi: FFILib,
    sqlite: SQLiteLib,
    require: RequireLib,
    random: RandomLib,
    thread: ThreadLib,
}
