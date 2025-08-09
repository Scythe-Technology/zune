--  https://github.com/JohnnyMorganz/luau-lsp/issues/271

declare _FILE: {
    source: string?,
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
    created_at: number,
    modified_at: number,
    accessed_at: number,
    size: number,
    permissions: {
        read_only: boolean,
    },
}

declare class FileHandle
    read:
        & ((self: FileHandle, amount: number?, useBuffer: false?) -> string)
        & ((self: FileHandle, amount: number?, useBuffer: true) -> buffer)
    readSync:
        & ((self: FileHandle, amount: number?, useBuffer: false?) -> string)
        & ((self: FileHandle, amount: number?, useBuffer: true) -> buffer)
    function write(self, contents: string | buffer): ()
    function writeSync(self, contents: string | buffer): ()
    function append(self, contents: string | buffer): ()
    function appendSync(self, contents: string | buffer): ()
    function getSize(self): number
    function getSeekPosition(self): number
    function seekFromEnd(self, amount: number?): ()
    function seekTo(self, amount: number?): ()
    function seekBy(self, amount: number?): ()
    function lock(self, lockMode: ("shared" | "exclusive" | "none")?): boolean
    function unlock(self): ()
    function sync(self): ()
    readonly:
        & ((self: FileHandle) -> boolean)
        & ((self: FileHandle, enabled: boolean) -> ())
    function close(self): ()
end

export type FileWatcher = {
    stop: (self: FileWatcher) -> (),
}

type CreateFileOptions = {
    exclusive: boolean?,
}

type OpenFileOptions = {
    mode: string?,
}

type DirectoryEntry = {
    name: string,
    kind: MetadataKind,
}

type FileSystemLib = {
    createFile: (path: string, opts: CreateFileOptions?) -> FileHandle,
    openFile: (path: string, opts: OpenFileOptions?) -> FileHandle,
    readFile:
        & ((path: string) -> string)
        & ((path: string, useBuffer: true) -> buffer),
    readDir: (path: string) -> { DirectoryEntry },
    writeFile: (path: string, contents: string | buffer) -> (),
    writeDir:  (path: string, recursive: boolean?) -> (),
    removeFile: (path: string) -> (),
    removeDir: (path: string, recursive: boolean?) -> (),
    metadata: (path: string) -> Metadata,
    isDir: (path: string) -> boolean,
    move: (from: string, to: string, overwrite: boolean?) -> (),
    copy: (from: string, to: string, overwrite: boolean?) -> (),
    symlink: (from: string, to: string) -> (),
    getExePath: () -> string,
    realPath: (path: string) -> string,
    watch: (path: string, callback: (path: string, events: {"created" | "modified" | "moved" | "renamed" | "deleted" | "metadata"}) -> ()) -> FileWatcher,
    embedFile: (path: string) -> buffer,
    embeddedFiles: () -> { string },
    embeddedScripts: () -> { string },

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
    stdio: ("inherit" | "pipe" | "ignore")?,
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
    function wait(self): ProcessResult
    function kill(self): ProcessResult
end

type ProcessLib = {
    os: OS,
    arch: CPUArchitecture,
    args: { string },
    env: { [string]: string },
    loadEnv: () -> { [string]: string },
    getCwd: () ->string,
    create: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> ProcessChild,
    run: (exec: string, args: {string}?, procOpts: ProcessOptions?) -> ProcessRunResult,
    exit: (code: number) -> never,
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
    similar: (expected: {[any]: any} | {any}) -> any,
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
    cancel: (thread: thread) -> (),
    defer: <A..., R...>(f: ((A...) -> R...) | thread, A...) -> thread,
    delay: <A..., R...>(sec: number, f: ((A...) -> (R...)) | thread, A...) -> thread,
    spawn: <A..., R...>(f: ((A...) -> (R...)) | thread, A...) -> thread,
    wait: (sec: number?) -> number,
    count: (() -> number) & ((kinds: string?) -> ...number),
}
--[======[ Task ]======]--

--[======[ Network ]======]--
declare class NetHttpWebSocket
    function isConnected(self): boolean
    function send(self, message: string | buffer): ()
    function close(self, code: number?): ()
end

declare class NetworkSocket
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
    function isOpen(self): boolean
end

declare class NetHttpServer
    function stop(self): ()
    function getPort(self): number
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
    status_code: number,
    headers: {[string]: string}?,
    body: string | buffer,
}

export type ServerWebSocketHandlers = {
    upgrade: ((request: ServerRequest) -> boolean)?,
    open: ((websocket: NetHttpWebSocket) -> ())?,
    message: ((websocket: NetHttpWebSocket, message: string) -> ())?,
    close: ((websocket: NetHttpWebSocket, code: number) -> ())?,
}

export type ServeOptions = {
    port: number,
    address: string?,
    reuse_address: boolean?,
    backlog: number?,
    max_body_size: number?,
    client_timeout: number?,
    max_connections: number?,
    request: (request: ServerRequest) -> string | buffer | ServerResponse,
    websocket: ServerWebSocketHandlers?,
}

export type Response<T> = {
    ok: boolean,
    status_code: number,
    status_reason: string,
    headers: {[string]: string},
    body: T,
}

export type RequestOptions = {
    headers: {[string]: string}?,
    method: ("GET" | "HEAD" | "POST" | "PUT" | "DELETE" | "CONNECT" | "OPTIONS" | "TRACE" | "PATCH")?,
    body: (string | buffer)?,
    allow_redirects: boolean?,
}

export type WebSocketOptions = {
    protocols: {string}?,
    timeout: number?,
    accept: ((socket: NetHttpWebSocket, request: ServerResponse) -> boolean)?,
    open: ((socket: NetHttpWebSocket) -> ())?,
    close: ((socket: NetHttpWebSocket, close: number?) -> ())?,
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
        serve: (opts: ServeOptions) -> NetHttpServer,
        request:
            & ((host: string, opts: (RequestOptions & { response_body_type: "string"? })?) -> Response<string>)
            & ((host: string, opts: (RequestOptions & { response_body_type: "buffer" })) -> Response<buffer>)
            & ((host: string, opts: (RequestOptions | { response_body_type: "string" | "buffer" | nil })?) -> Response<string | buffer>),
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
    chunk_name: string?,
    native_code_gen: boolean?,
}

export type CoverageData = {
    name: string,
    line: number,
    depth: number,
    [number]: number,
};

type Position = {
    line: number,
    column: number,
}

export type Location = {
    begin: Position,
    ["end"]: Position,
}

export type ParseResult = {
    errors: {
        {
            message: string,
            location: Location,
        }
    }
} | {
    root: {any},
    eof: { text: "", position: Position, tag: "eof" },
    lines: number,
    lineOffsets: {number},
    hotcomments: {
        {
            header: boolean,
            content: string,
            location: Location,
        }
    }
};

type LuauLib = {
    compile: (source: string, opts: CompileOptions?) -> string,
    load: (bytecode: string, opts: LoadOptions?) -> ((...any) -> ...any),
    coverage: (fn: (...any) -> ...any) -> {CoverageData},
    parse: (src: string) -> ParseResult,
    parseExpr: (src: string) -> any,
    garbagecollect: () -> (),
}
--[======[ Luau ]======]--

--[======[ Serde ]======]--
type JsonEncodeConfig = {
    pretty_indent: number,
}

type JsonDecodeConfig = {
    preserve_null: boolean,
}

type JsonEncoder = {
    encode: (value: any, config: JsonEncodeConfig?) -> string,
    decode: (json: string, config: JsonDecodeConfig?) -> any,
    indents: {
        none: number,
        two_spaces: number,
        four_spaces: number,
        tabs: number,
    },
    values: {
        null: any,
    }
}

type TomlEncoder = {
    encode: (object: {[string]: any}) -> string,
    decode: (toml: string) -> {[string]: any},
}

type YamlInput = string | number | boolean | {[string]: YamlInput}
type YamlOuput = string | {[string]: YamlOuput}

type YamlEncoder = {
    encode: (object: YamlInput) -> string,
    decode: (yaml: string) -> YamlOuput,
}

type Base64Encoder = {
    encode: (value: string) -> string,
    decode: (base64: string) -> string,
}

type GenericCompressionOptions = {
    level: number?,
}

type CompressionFn =
& ((raw: string) -> string)
& ((raw: buffer) -> buffer)

type AdvancedCompressionFn =
& ((raw: string, opts: GenericCompressionOptions?) -> string)
& ((raw: buffer, opts: GenericCompressionOptions?) -> buffer)

type DecompressionFn =
& ((compressed: string) -> string)
& ((compressed: buffer) -> buffer)

type GenericCompressor = {
    compress : AdvancedCompressionFn,
    decompress : DecompressionFn,
}

type SerdeLib = {
    json: JsonEncoder,
    json5: JsonEncoder,
    toml: TomlEncoder,
    yaml: YamlEncoder,
    base64: Base64Encoder,
    gzip: GenericCompressor,
    zlib: GenericCompressor,
    lz4: {
        compress : CompressionFn,
        compressFrame : AdvancedCompressionFn,
        decompress :
            & ((compressed: string, size: number) -> string)
            & ((compressed: buffer, size: number) -> buffer),
        decompressFrame : DecompressionFn,
    },
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
    len: number
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
    isTTY: boolean,
    getCurrentMode: () -> "normal" | "raw",
    enableRawMode: () -> boolean,
    restoreMode: () -> boolean,
    getSize: () -> (number?, number?),
}

type BufferSinkOptions = {
    limit: number?,
}

type IoLib = {
    MAX_READ: number,
    format: (...any) -> string,
    createBufferSink: (opts: BufferSinkOptions?) -> BufferSink,
    createFixedBufferStream: (buffer: buffer) -> BufferStream,
    terminal: Terminal,
    stdout: FileHandle,
    stderr: FileHandle,
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
    algorithm: "bcrypt"?,
    cost: number?,
}

type Argon2PasswordOptions = {
    algorithm: ("argon2d" | "argon2i" | "argon2id")?,
    time_cost: number?,
    memory_cost: number?,
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
    password: {
        hash: (password: string, opts: PasswordOptions?) -> string,
        verify: (password: string, hash: string) -> boolean,
    },
    random: {
        nextNumber:
            & (() -> number)
            & ((min: number, max: number) -> number),
        nextInteger:
            & (() -> number)
            & ((min: number, max: number) -> number),
        nextBoolean: () -> boolean,
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
        setupClient: (socket: NetworkSocket, config: { host: string, ca: TlsCertBundle }) -> (),
        setupServer: (socket: NetworkSocket, config: { auth: TlsCertKeyPair }) -> (),
    },
}
--[======[ Crypto ]======]--

--[======[ Regex ]======]--
export type RegexMatch = {
    string: string,
    index: number,
}

export type Regex = {
    match: (self: Regex, input: string | buffer) -> {RegexMatch}?,
    search: (self: Regex, input: string | buffer) -> {RegexMatch}?,
    captures: (self: Regex, input: string | buffer, global: boolean?) -> {{RegexMatch}},
    isMatch: (self: Regex, input: string | buffer) -> boolean,
    format: (self: Regex, str: string, format: string) -> string,
    replace: (self: Regex, str: string, replacement: string) -> string,
    replaceAll: (self: Regex, str: string, replacement: string) -> string,
}

type RegexLib = {
    create: (pattern: string | buffer, flags: string?) -> Regex,
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

declare class DateTime
    unixTimestamp: number
    unixTimestampMillis: number
    UnixTimestamp: number
    UnixTimestampMillis: number
    function toLocalTime(self): TimeDictionary
    function ToLocalTime(self): TimeDictionary
    function toUniversalTime(self): TimeDictionary
    function ToUniversalTime(self): TimeDictionary
    function toIsoDate(self): string
    function ToIsoDate(self): string
    function formatLocalTime(self, format: string): string
    function FormatLocalTime(self, format: string): string
    function formatUniversalTime(self, format: string): string
    function FormatUniversalTime(self, format: string): string
end

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
    getSymbol: (self: FFILibrary, symbol: string) -> FFIPointer?,
    [string]: (...any) -> any,
}

declare class FFICompiled
    function getSymbol(self, symbol: string): FFIPointer?
end

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
    readi16: (self: FFIPointer, offset: number?) -> number,
    readi32: (self: FFIPointer, offset: number?) -> number,
    readi64: (self: FFIPointer, offset: number?) -> buffer,
    readu8: (self: FFIPointer, offset: number?) -> number,
    readu16: (self: FFIPointer, offset: number?) -> number,
    readu32: (self: FFIPointer, offset: number?) -> number,
    readu64: (self: FFIPointer, offset: number?) -> buffer,
    readf32: (self: FFIPointer, offset: number?) -> number,
    readf64: (self: FFIPointer, offset: number?) -> number,
    readPtr: (self: FFIPointer, offset: number?) -> FFIPointer,
    writei8: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writei16: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writei32: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writei64: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu8: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu16: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu32: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writeu64: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writef32: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writef64: (self: FFIPointer, offset: number, value: number | buffer | boolean) -> (),
    writePtr: (self: FFIPointer, offset: number, value: FFIPointer) -> (),
    isNull: (self: FFIPointer) -> boolean,
    setSize: (self: FFIPointer, size: number) -> (),
    getSize: (self: FFIPointer) -> number?,
    setAlignment: (self: FFIPointer, alignment: number) -> (),
    getAlignment: (self: FFIPointer) -> number?,
    span: (self: FFIPointer, offset: number?) -> buffer,
}

type FFICompileOptions = {
    options: string?,
    files: {string}?,
    libraries: {string}?,
    includes: {string}?,
    sysincludes: {string}?,
    symbols: {[string]: FFIPointer}?,
}

type FFILib = {
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
    c: {
        compile: (src: string, opts: FFICompileOptions?) -> FFICompiled,
    },
    ptr: (src: FFIPointer) -> FFIPointer,
    ptrFromAddress: (src: buffer) -> FFIPointer,
    getLuaState: (mainthread: boolean?) -> FFIPointer,
    alloc: (size: number, alignment: number?) -> FFIPointer,
    free: (src: FFIPointer) -> (),
    dupe: (src: buffer | FFIPointer) -> FFIPointer,
    len: (src: buffer | FFIPointer) -> number?,
    copy: (dest: buffer | FFIPointer, destOffset: number, src: buffer | FFIPointer, srcOffset: number, count: number) -> (),
    tagName: (tag: number) -> string?,
    struct: (fields: {{ [string]: AnyDataType }}) -> FFIStructureType,
    fn: (definition: FFIFunctionDef, srcPtr: FFIPointer) -> ((...any) -> any),
    closure: (definition: FFIFunctionDef, handler: (...any) -> any) -> FFIPointer,
    dlopen: (path: string, { [string]: FFIFunctionDef }) -> FFILibrary,
}
--[======[ FFI ]======]--

--[======[ SQLite ]======]--
export type SQLite3Values = {[string]: number | string | buffer};
export type SQLite3Result = {
    last_insert_row_id: number,
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
    chunk_name: string?,
    native_code_gen: boolean?,
}

export type ThreadLib = {
    fromModule: (module: string) -> Thread,
    fromBytecode: (bytecode: string | buffer, opts: ThreadLoadOptions?) -> Thread,
    receive: () -> ...any,
    send: (...any) -> (),
    getCpuCount: () -> number,
    isThread: boolean,
}
--[======[ Thread ]======]--

declare zune: {
    compiled: {
        optimize: number,
        debug: number,
        mode: "debug" | "release",
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
