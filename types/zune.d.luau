-- This file was auto-generated with "zune-docs"

--[[ serde ]]
export type SerdeJsonEncodeConfig = {
    pretty_indent: number?, 
}
export type SerdeJsonDecodeConfig = {
    preserve_null: boolean?, 
}
type YamlInput = string | number | boolean | {
    [string]: YamlInput
}
type YamlOutput = string | {
    [string]: YamlOutput
}
export type _zune_serde_json = {
    encode: (value: any, config: SerdeJsonEncodeConfig?) -> string,
    decode: (json: string, config: SerdeJsonDecodeConfig?) -> any,
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
export type _zune_serde_json5 = {
    encode: (value: any, config: SerdeJsonEncodeConfig?) -> string,
    decode: (json: string, config: SerdeJsonDecodeConfig?) -> any,
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
export type _zune_serde_toml = {
    encode: (object: {[string]: any}) -> string,
    decode: (toml: string | buffer) -> {[string]: any}, 
}
export type _zune_serde_yaml = {
    encode: (object: YamlInput) -> string,
    decode: (yaml: string | buffer) -> YamlOutput, 
}
export type _zune_serde_base64 = {
    calcSize: (len: number) -> number,
    encode: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number,
    decode: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number, 
}
export type _zune_serde_gzip = {
    calcSize: (len: number) -> number,
    compress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?, level: number?) -> number,
    decompress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number, 
}
export type _zune_serde_flate = {
    calcSize: (len: number) -> number,
    compress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?, level: number?) -> number,
    decompress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number, 
}
export type _zune_serde_zlib = {
    calcSize: (len: number) -> number,
    compress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?, level: number?) -> number,
    decompress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number, 
}
export type _zune_serde_zstd = {
    calcSize: (len: number) -> number,
    compress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?, level: number?) -> number,
    decompress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number, 
}
export type _zune_serde_lz4 = {
    calcSize: (len: number) -> number,
    compress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number,
    decompress: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number,
    calcFrameSize: (len: number) -> number,
    compressFrame: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?, level: number?) -> number,
    decompressFrame: (dest: buffer, destOffset: number, src: string | buffer, srcOffset: number, count: number?) -> number, 
}
export type _zune_serde = {
    json: _zune_serde_json,
    json5: _zune_serde_json5,
    toml: _zune_serde_toml,
    yaml: _zune_serde_yaml,
    base64: _zune_serde_base64,
    gzip: _zune_serde_gzip,
    flate: _zune_serde_flate,
    zlib: _zune_serde_zlib,
    zstd: _zune_serde_zstd,
    lz4: _zune_serde_lz4, 
}
--[[ c ]]
export type DynamicLibrary = {
    getSymbol: (self: DynamicLibrary, symbol: string) -> CPointer?, 
}
declare extern type CType with
    size: (self: CType) -> number
    alignment: (self: CType) -> number
    array: (self: CType, count: number) -> CArrayType 
end
declare extern type CVectorType extends CType with
    offset: (self: CVectorType, index: number) -> number 
end
declare extern type CStructureType extends CType with
    offset: (self: CStructureType, field: string) -> number
    new: (self: CStructureType, fields: {[string]: buffer | number | CPointer | vector}) -> buffer 
end
declare extern type CArrayType extends CType with
    new: (self: CArrayType, values: {[number]: buffer | number | CPointer | vector}) -> buffer 
end
declare extern type CPointerType extends CType with
    tag: (self: CPointerType) -> number
    newTag: (self: CPointerType, tag: string | buffer) -> CPointerType 
end
export type AnyCType = CType | CStructureType | CArrayType | CPointerType | CVectorType
export type _zune_c_types = {
    void: CType,
    int8: CType,
    uint8: CType,
    int16: CType,
    uint16: CType,
    int32: CType,
    uint32: CType,
    int64: CType,
    uint64: CType,
    float: CType,
    double: CType,
    pointer: CPointerType,
    vector2_32: CVectorType,
    vector3_32: CVectorType, 
}
declare extern type CPointer with
    release: (self: CPointer) -> CPointer
    retain: (self: CPointer) -> CPointer
    tag: 
        & ((self: CPointer) -> number)
        & ((self: CPointer, tag: number) -> CPointer)
    drop: (self: CPointer) -> CPointer
    offset: (self: CPointer, offset: number) -> CPointer
    read: (self: CPointer, srcOffset: number, dest: buffer | CPointer, destOffset: number, count: number) -> buffer
    write: (self: CPointer, destOffset: number, src: buffer | CPointer, srcOffset: number, count: number) -> ()
    readi8: (self: CPointer, offset: number?) -> number
    readi16: (self: CPointer, offset: number?) -> number
    readi32: (self: CPointer, offset: number?) -> number
    readi64: (self: CPointer, offset: number?) -> buffer
    readu8: (self: CPointer, offset: number?) -> number
    readu16: (self: CPointer, offset: number?) -> number
    readu32: (self: CPointer, offset: number?) -> number
    readu64: (self: CPointer, offset: number?) -> buffer
    readf32: (self: CPointer, offset: number?) -> number
    readf64: (self: CPointer, offset: number?) -> number
    readptr: (self: CPointer, offset: number?) -> CPointer
    writei8: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writei16: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writei32: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writei64: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writeu8: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writeu16: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writeu32: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writeu64: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writef32: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writef64: (self: CPointer, offset: number, value: number | buffer | boolean) -> ()
    writeptr: (self: CPointer, offset: number, value: CPointer) -> ()
    size: 
        & ((self: CPointer) -> number?)
        & ((self: CPointer, size: number) -> ())
    alignment: 
        & ((self: CPointer) -> number?)
        & ((self: CPointer, alignment: number) -> ())
    span: (self: CPointer, offset: number?) -> buffer 
end
export type _zune_c = {
    prefix: string,
    suffix: string,
    types: _zune_c_types,
    null: () -> CPointer,
    ptr: (src: CPointer) -> CPointer,
    ptrFromAddress: (src: buffer) -> CPointer,
    getLuaState: (mainthread: boolean?) -> CPointer,
    alloc: (size: number, alignment: number?) -> CPointer,
    create: (type: AnyCType) -> CPointer,
    free: (src: CPointer) -> (),
    dupe: (src: buffer | CPointer | vector) -> CPointer,
    tagName: (tag: number) -> string?,
    struct: (fields: {{[string]: AnyCType}}, alignment: number?) -> CStructureType,
    fn: (returns: AnyCType, args: {AnyCType}, srcPtr: CPointer) -> ((...any) -> any),
    closure: (returns: AnyCType, args: {AnyCType}, handler: (...any) -> any) -> CPointer,
    dlopen: (path: string) -> DynamicLibrary, 
}
--[[ fs ]]
export type DescriptorKind = 
    | "block_device"
    | "character_device"
    | "directory"
    | "named_pipe"
    | "sym_link"
    | "file"
    | "unix_domain_socket"
    | "whiteout"
    | "door"
    | "event_port"
    | "unknown"
export type FileWatchEvent = 
    | "created"
    | "deleted"
    | "modified"
    | "renamed"
    | "moved"
    | "metadata"
export type DirectoryEntry = {
    name: string,
    kind: DescriptorKind, 
}
export type DescriptorStat = {
    kind: DescriptorKind,
    mode: number,
    block_size: number,
    changed_at: number,
    modified_at: number,
    accessed_at: number,
    size: number, 
}
export type OpenDirOptions = {
    iterate: boolean?,
    follow_symlinks: boolean?, 
}
export type OpenFileOptions = {
    mode: string?,
    follow_symlinks: boolean?,
    allow_directory: boolean?,
    nonblocking: boolean?,
    path_only: boolean?,
    allow_ctty: boolean?,
    resolve_beneath: boolean?, 
}
export type CreateFileOptions = {
    read: boolean?,
    truncate: boolean?,
    exclusive: boolean?,
    nonblocking: boolean?,
    resolve_beneath: boolean?,
    permissions: number?, 
}
export type CopyFileOptions = {
    permissions: number?,
    make_path: boolean?,
    replace: boolean?, 
}
export type FileResolveOptions = {
    follow_symlinks: boolean?, 
}
export type CreateSymLinkOptions = {
    is_directory: boolean?, 
}
export type DirAccessOptions = {
    follow_symlinks: boolean?,
    read: boolean?,
    write: boolean?,
    execute: boolean?, 
}
export type CreateTempDirOptions = {
    cleanup: boolean?,
    iterate: boolean?, 
}
declare extern type Descriptor with
    setPermissions: (self: Descriptor, mode: number) -> ()
    setOwner: (self: Descriptor, owner: number, group: number) -> ()
    realPath: (self: Descriptor, dest: buffer, destOffset: number?, count: number?) -> number
    stat: (self: Descriptor) -> DescriptorStat
    close: (self: Descriptor) -> () 
end
declare extern type File extends Descriptor with
    size: (self: File) -> number
    setSize: (self: File, size: number) -> ()
    setTimestamps: (self: File, accessedTime: number, modifiedTime: number) -> ()
    read: (self: File, dest: buffer, destOffset: number?, count: number?) -> (number, string?)
    readPositional: (self: File, offset: number, dest: buffer, destOffset: number?, count: number?) -> (number, string?)
    write: (self: File, src: string | buffer, srcOffset: number?, count: number?) -> (number, string?)
    writePositional: (self: File, offset: number, src: string | buffer, srcOffset: number?, count: number?) -> (number, string?)
    lock: (self: File, lockMode: ("shared" | "exclusive" | "none")?) -> boolean
    unlock: (self: File) -> ()
    isTty: (self: File) -> boolean
    sync: (self: File) -> () 
end
declare extern type Dir extends Descriptor with
    openDir: (self: Dir, path: string | buffer, opts: OpenDirOptions?) -> Dir
    openFile: (self: Dir, path: string | buffer, opts: OpenFileOptions?) -> File
    copyFile: (self: Dir, srcPath: string | buffer, destDir: Dir, destPath: string | buffer, opts: CopyFileOptions) -> ()
    setFilePermissions: (self: Dir, path: string | buffer, mode: number, opts: FileResolveOptions?) -> ()
    setFileOwner: (self: Dir, path: string | buffer, owner: number, group: number, opts: FileResolveOptions?) -> ()
    setFileTimestamps: (self: Dir, path: string | buffer, accessedTime: number, modifiedTime: number, opts: FileResolveOptions?) -> ()
    statFile: (self: Dir, path: string | buffer, opts: FileResolveOptions?) -> DescriptorStat
    symLink: (self: Dir, target: string | buffer, sym_link: string | buffer, opts: CreateSymLinkOptions?) -> ()
    readLink: (self: Dir, path: string | buffer, dest: buffer, destOffset: number?, count: number?) -> number
    access: (self: Dir, path: string | buffer, opts: DirAccessOptions) -> boolean
    realPathFile: (self: Dir, path: string | buffer, dest: buffer, destOffset: number?, count: number?) -> number
    createDir: (self: Dir, path: string | buffer, mode: number?) -> ()
    createFile: (self: Dir, path: string | buffer, opts: CreateFileOptions?) -> File
    createDirPath: (self: Dir, path: string | buffer) -> ()
    rename: (self: Dir, oldPath: string | buffer, newDir: Dir, newPath: string | buffer) -> ()
    renamePreserve: (self: Dir, oldPath: string | buffer, newDir: Dir, newPath: string | buffer) -> ()
    deleteFile: (self: Dir, path: string | buffer) -> ()
    deleteDir: (self: Dir, path: string | buffer) -> ()
    deleteTree: (self: Dir, path: string | buffer) -> ()
    entries: (self: Dir) -> {DirectoryEntry} 
end
export type _zune_fs_path = {
    max_path_bytes: number,
    join: (...string) -> string,
    relative: (from: string, to: string) -> string,
    resolve: (...string) -> string,
    dirname: (path: string) -> string?,
    basename: (path: string) -> string,
    stem: (path: string) -> string,
    extension: (path: string) -> string,
    isAbsolute: (path: string) -> boolean,
    globMatch: (path: string, pattern: string) -> boolean, 
}
declare extern type FileWatcher with
    add: (self: FileWatcher, path: string, recursive: boolean?) -> ()
    remove: (self: FileWatcher, path: string) -> ()
    drain: (self: FileWatcher) -> ()
    next: (self: FileWatcher) -> (string, FileWatchEvent)
    stop: (self: FileWatcher) -> () 
end
export type _zune_fs = {
    embedFile: (path: string) -> buffer,
    embeddedFiles: () -> {string},
    embeddedScripts: () -> {string},
    createTempDir: (opts: CreateTempDirOptions?) -> Dir,
    createWatcher: () -> FileWatcher,
    path: _zune_fs_path, 
}
--[[ crypto ]]
type Input = string | buffer
declare extern type CryptoHash with
    digest: 
        & ((self: CryptoHash) -> buffer)
        & ((self: CryptoHash, encoding: "binary") -> buffer)
        & ((self: CryptoHash, encoding: "hex" | "base64") -> string)
        & ((self: CryptoHash, encoding: string) -> string | buffer)
    update: (self: CryptoHash, value: string | buffer) -> ()
    copy: (self: CryptoHash) -> CryptoHash 
end
declare extern type CryptoTls with
    established: boolean
    handshake: (self: CryptoTls, recv: string | buffer, recvOffset: number?, recvCount: number?, send: buffer, sendOffset: number?, sendCount: number?) -> (boolean, number, number)
    encrypt: (self: CryptoTls, cleartext: string | buffer, cleartextOffset: number?, cleartextCount: number?, ciphertext: buffer, ciphertextOffset: number?, ciphertextCount: number?) -> (number, number)
    decrypt: (self: CryptoTls, ciphertext: string | buffer, ciphertextOffset: number?, ciphertextCount: number?, cleartext: buffer, cleartextOffset: number?, cleartextCount: number?) -> (number, number, boolean)
    close: (self: CryptoTls, ciphertext: string | buffer, ciphertextOffset: number?, ciphertextCount: number?) -> () 
end
declare extern type TlsCertBundle with

end
declare extern type TlsCertKeyPair with

end
export type CryptoHashAlgorithms = 
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
export type CryptoPasswordOptions = BcryptPasswordOptions | Argon2PasswordOptions
type EncryptedData = {
    cipher: buffer,
    tag: buffer, 
}
export type CreateTlsClientOptions = {
    host: string,
    ca: TlsCertBundle, 
}
export type _zune_crypto_password = {
    hash: (password: string | buffer, opts: CryptoPasswordOptions?) -> string,
    verify: (password: string | buffer, hash: string | buffer) -> boolean, 
}
export type _zune_crypto_uuid = {
    v4: () -> string,
    v7: () -> string, 
}
export type _zune_crypto_random = {
    nextNumber: 
        & (() -> number)
        & ((min: number, max: number) -> number),
    nextInteger: 
        & (() -> number)
        & ((min: number, max: number) -> number),
    nextBoolean: () -> boolean,
    fill: (buffer: buffer, offset: number, length: number) -> (), 
}
export type _zune_crypto_aead = {
    aes_gcm: {
        Aes128Gcm: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aes256Gcm: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        }, 
    },
    aes_ocb: {
        Aes128Ocb: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aes256Ocb: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        }, 
    },
    aegis: {
        Aegis128X4: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis128X2: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis128L: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis256X4: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis256X2: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis128X4_256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis128X2_256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis128L_256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis256X4_256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis256X2_256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        Aegis256_256: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        }, 
    },
    chacha_poly: {
        ChaCha8Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        ChaCha12Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        ChaCha20Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        XChaCha8Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        XChaCha12Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        },
        XChaCha20Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        }, 
    },
    salsa_poly: {
        XSalsa20Poly1305: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        }, 
    },
    isap: {
        IsapA128A: {
            encrypt: (data: Input, key: Input, nonce: Input, ad: Input?) -> EncryptedData,
            decrypt: (cipher: Input, tag: Input, key: Input, nonce: Input, ad: Input?) -> string, 
        }, 
    }, 
}
export type _zune_crypto_tls = {
    MAX_RECORD_SIZE: number,
    bundleFromSystem: () -> TlsCertBundle,
    bundleFromFile: (file: string) -> TlsCertBundle,
    keyPairFromFile: (certFile: string, keyFile: string) -> TlsCertKeyPair,
    createClient: (socket: Socket, opts: CreateTlsClientOptions) -> CryptoTls,
    createServer: (socket: Socket, opts: CreateTlsServerOptions) -> CryptoTls, 
}
export type CreateTlsServerOptions = {
    auth: TlsCertKeyPair, 
}
export type _zune_crypto = {
    createHash: (algorithm: CryptoHashAlgorithms, secret: string | buffer?) -> CryptoHash,
    password: _zune_crypto_password,
    uuid: _zune_crypto_uuid,
    random: _zune_crypto_random,
    aead: _zune_crypto_aead,
    tls: _zune_crypto_tls, 
}
--[[ thread ]]
declare extern type Thread with
    start: (self: Thread) -> ()
    join: (self: Thread) -> ()
    status: (self: Thread) -> "ready" | "running" | "dead"
    receive: (self: Thread) -> ...any
    send: (self: Thread, ...any) -> () 
end
declare extern type ThreadMutex with
    lock: (self: ThreadMutex) -> ()
    unlock: (self: ThreadMutex) -> () 
end
declare extern type ThreadLane with
    send: (self: ThreadLane, ...any) -> ()
    receive: (self: ThreadLane) -> ...any 
end
declare extern type ThreadValue with
    set: (self: ThreadValue, value: any) -> ()
    get: (self: ThreadValue) -> any
    update: (self: ThreadValue, callback: (current: any) -> any) -> () 
end
export type ThreadLoadOptions = {
    chunk_name: string?,
    native_code_gen: boolean?, 
}
export type _zune_thread = {
    fromModule: (module: string) -> Thread,
    fromBytecode: (bytecode: string | buffer, opts: ThreadLoadOptions?) -> Thread,
    receive: () -> ...any,
    send: (...any) -> (),
    getCpuCount: () -> number,
    isThread: boolean,
    createMutex: (name: string) -> ThreadMutex,
    createHardMutex: (name: string) -> ThreadMutex,
    createLane: (name: string) -> ThreadLane,
    createValue: (name: string) -> ThreadValue, 
}
--[[ time ]]
export type TimeDictionary = {
    year: number,
    month: number,
    day: number,
    hour: number,
    minute: number,
    second: number,
    millisecond: number, 
}
export type _zune_time_date = {
    now: () -> DateTime,
    parse: (date: string) -> DateTime,
    fromIsoDate: (date: string) -> DateTime,
    fromUnixTimestamp: (timestamp: number) -> DateTime,
    fromUnixTimestampMillis: (timestamp: number) -> DateTime,
    fromLocalTime: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime,
    fromUniversalTime: (year: number, month: number, day: number, hour: number, minute: number, second: number, millisecond: number) -> DateTime, 
}
export type _zune_time_instant = {
    now: () -> buffer, 
}
declare extern type DateTime with
    timestamp: number
    timestamp_millis: number
    toLocalTime: (self: DateTime) -> TimeDictionary
    toUniversalTime: (self: DateTime) -> TimeDictionary
    toIsoDate: (self: DateTime) -> string
    formatLocalTime: (self: DateTime, format: string) -> string
    formatUniversalTime: (self: DateTime, format: string) -> string 
end
export type _zune_time = {
    date: _zune_time_date,
    instant: _zune_time_instant,
    timestamp: () -> number,
    timestampMillis: () -> number, 
}
--[[ process ]]
export type ProcessOptions = {
    cwd: string?,
    env: {
        [string]: string
    }?,
    shell: (boolean | string)?,
    stdin: ("inherit" | "pipe" | "ignore")?,
    stdout: ("inherit" | "pipe" | "ignore")?,
    stderr: ("inherit" | "pipe" | "ignore")?, 
}
export type ProcessResult = {
    ok: boolean,
    code: number, 
}
export type ProcessRunResult = ProcessResult & {
    stdout: buffer?,
    stderr: buffer?, 
}
export type _zune_process_env = {
    [string]: string
}
declare extern type ProcessChild with
    pid: number
    stdin: File?
    stdout: File?
    stderr: File?
    wait: (self: ProcessChild) -> ProcessResult
    kill: (self: ProcessChild) -> ProcessResult 
end
export type _zune_process = {
    getExePath: () -> string,
    openExeFile: (opts: OpenFileOptions?) -> File,
    args: {string},
    env: _zune_process_env,
    loadEnv: () -> {[string]: string},
    pid: () -> number,
    create: (exec: string, args: {string}?, opts: ProcessOptions?) -> ProcessChild,
    run: (exec: string, args: {string}?, opts: ProcessOptions?) -> ProcessRunResult,
    exit: (code: number) -> never,
    onSignal: (signal: "INT", callback: () -> ()) -> (), 
}
--[[ ascii ]]
export type _zune_ascii = {
    eqlIgnoreCase: (a: MemReadableSlice, b: MemReadableSlice) -> boolean,
    eqlIgnoreCaseSlice: (a: MemReadableSlice, aOffset: number, b: MemReadableSlice, bOffset: number, count: number?) -> boolean,
    startsWithIgnoreCase: (slice: MemReadableSlice, needle: MemReadableSlice) -> boolean,
    endsWithIgnoreCase: (slice: MemReadableSlice, needle: MemReadableSlice) -> boolean,
    findIgnoreCase: (slice: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findIgnoreCasePos: (slice: MemReadableSlice, offset: number, needle: MemReadableSlice, count: number?) -> number?,
    lessThanIgnoreCase: (a: MemReadableSlice, b: MemReadableSlice) -> boolean,
    lessThanIgnoreCaseSlice: (a: MemReadableSlice, aOffset: number, b: MemReadableSlice, bOffset: number, count: number?) -> boolean, 
}
--[[ regex ]]
export type RegexMatch = {
    string: string,
    index: number, 
}
declare extern type Regex with
    match: (self: Regex, input: string | buffer) -> {RegexMatch}?
    search: (self: Regex, input: string | buffer) -> {RegexMatch}?
    captures: (self: Regex, input: string | buffer, global: boolean?) -> {{RegexMatch}}
    split: (self: Regex, input: string | buffer, global: boolean?) -> {string}
    isMatch: (self: Regex, input: string | buffer) -> boolean
    format: (self: Regex, str: string, format: string) -> string
    replace: (self: Regex, str: string, replacement: string) -> string
    replaceAll: (self: Regex, str: string, replacement: string) -> string 
end
export type _zune_regex = {
    create: (pattern: string | buffer, flags: string?) -> Regex, 
}
--[[ random ]]
declare extern type Random with
    nextNumber: 
        & ((self: Random) -> number)
        & ((self: Random, min: number, max: number) -> number)
    nextInteger: (self: Random, min: number, max: number) -> number
    nextBoolean: (self: Random) -> boolean
    clone: (self: Random) -> Random 
end
type RandomNewFn = (seed: number?) -> Random
export type _zune_random_LuauPcg32 = {
    new: (seed: number?) -> Random, 
}
export type _zune_random_Isaac64 = {
    new: (seed: number?) -> Random, 
}
export type _zune_random_Pcg32 = {
    new: (seed: number?) -> Random, 
}
export type _zune_random_Xoroshiro128 = {
    new: (seed: number?) -> Random, 
}
export type _zune_random_Xoshiro256 = {
    new: (seed: number?) -> Random, 
}
export type _zune_random_Sfc64 = {
    new: (seed: number?) -> Random, 
}
export type _zune_random_RomuTrio = {
    new: (seed: number?) -> Random, 
}
export type _zune_random = {
    new: (seed: number?) -> Random,
    LuauPcg32: _zune_random_LuauPcg32,
    Isaac64: _zune_random_Isaac64,
    Pcg32: _zune_random_Pcg32,
    Xoroshiro128: _zune_random_Xoroshiro128,
    Xoshiro256: _zune_random_Xoshiro256,
    Sfc64: _zune_random_Sfc64,
    RomuTrio: _zune_random_RomuTrio, 
}
--[[ testing ]]
export type TestingResults = {
    start: number,
    finish: number,
    failed: number,
    skipped: number,
    total: number, 
}
export type _zune_testing = {
    stepCheckReferences: (scope: string) -> (),
    consumeResults: () -> TestingResults,
    addFailed: (amt: number?) -> (),
    addSkipped: (amt: number?) -> (),
    addCount: (amt: number?) -> (),
    onComplete: (callback: (result: TestingResults) -> boolean?) -> (),
    start: () -> (), 
}
--[[ luau ]]
export type LuauCompileOptions = {
    debug_level: number?,
    optimization_level: number?,
    coverage_level: number?,
    type_info_level: number?, 
}
export type LuauLoadOptions = {
    env: {
        [any]: any
    }?,
    chunk_name: string?,
    native_code_gen: boolean?, 
}
export type LuauCoverageData = {
    name: string,
    line: number,
    depth: number,
    [number]: number, 
}
type Position = {
    line: number,
    column: number, 
}
export type Location = {
    begin: Position,
    ["end"]: Position, 
}
export type ParseResult = {
    errors: {{
        message: string,
        location: Location, 
    }}?,
    root: {any},
    eof: {
        text: "",
        position: Position,
        tag: "eof"
    },
    lines: number,
    line_offsets: {number},
    hotcomments: {{
        header: boolean,
        content: string,
        location: Location, 
    }}, 
}
export type LuauFFlagBoolean = {
    name: string,
    type: "boolean",
    value: boolean,
    dynamic: boolean, 
}
export type LuauFFlagInteger = {
    name: string,
    type: "integer",
    value: number,
    dynamic: boolean, 
}
export type _zune_luau_fflag = {
    get: (name: string) -> LuauFFlag,
    set: (name: string, value: boolean | number) -> (),
    list: () -> {LuauFFlag}
}
export type LuauFFlag = LuauFFlagBoolean | LuauFFlagInteger
export type _zune_luau = {
    compile: (source: string | buffer, opts: LuauCompileOptions?) -> buffer,
    load: (bytecode: string | buffer, opts: LuauLoadOptions?) -> ((...any) -> ...any),
    coverage: (fn: (...any) -> ...any) -> {LuauCoverageData},
    sync: <R...,  A...>((A...) ->  R...,  A...) ->  R...,
    garbagecollect: (step: boolean?) -> (),
    fflag: _zune_luau_fflag,
    parse: (src: string | buffer) -> ParseResult,
    parseExpr: (src: string | buffer) -> any, 
}
--[[ platform ]]
export type PlatformCPUArchitecture = 
    | "aarch64"
    | "x86_64"
    | "riscv64"
    | "powerpc64le"
export type PlatformOS = 
    | "linux"
    | "windows"
    | "macos"
    | "freebsd"
export type _zune_platform_cpu = {
    arch: PlatformCPUArchitecture,
    endian: "big" | "little", 
}
export type PlatformABI = 
    | "none"
    | "gnu"
    | "gnuabin32"
    | "gnuabi64"
    | "gnueabi"
    | "gnueabihf"
    | "gnuf32"
    | "gnusf"
    | "gnux32"
    | "code16"
    | "eabi"
    | "eabihf"
    | "ilp32"
    | "android"
    | "androideabi"
    | "musl"
    | "muslabin32"
    | "muslabi64"
    | "musleabi"
    | "musleabihf"
    | "muslf32"
    | "muslsf"
    | "muslx32"
    | "msvc"
    | "itanium"
    | "cygnus"
    | "simulator"
    | "macabi"
    | "ohos"
    | "ohoseabi"
export type _zune_platform = {
    os: PlatformOS,
    abi: PlatformABI,
    cpu: _zune_platform_cpu,
    async: "io_uring" | "epoll" | "kqueue" | "iocp",
    getFreeMemory: () -> number,
    getTotalMemory: () -> number,
    getPageSize: () -> number,
    getKernelVersion: () -> string,
    getHostName: () -> string, 
}
--[[ debug ]]
export type _zune_debug = {
    dumpStacktrace: (level: number, limit: number?) -> string, 
}
--[[ net ]]
export type NetworkVec = {string | buffer | number}
declare extern type Socket with
    open: boolean
    send: (self: Socket, src: string | buffer, srcOffset: number?, count: number?, timeout: number?) -> (number, string?)
    sendVec: (self: Socket, src: {string | buffer | NetworkVec}, srcOffset: number?, count: number?, timeout: number?) -> (number, string?)
    sendToAddress: (self: Socket, address: string, port: number, src: string | buffer, srcOffset: number?, count: number?, timeout: number?) -> (number, string?)
    sendToUnix: (self: Socket, unix: string, src: string | buffer, srcOffset: number?, count: number?, timeout: number?) -> (number, string?)
    recv: (self: Socket, dest: buffer, destOffset: number?, count: number?, timeout: number?) -> (number, string?)
    recvFrom: (self: Socket, dest: buffer, destOffset: number?, count: number?, timeout: number?) -> (number, NetworkAddress?, string?)
    accept: (self: Socket) -> Socket
    connectAddress: (self: Socket, address: string, port: number) -> ()
    connectUnix: (self: Socket, path: string) -> ()
    listen: (self: Socket, backlog: number?) -> ()
    bindAddress: (self: Socket, address: string, port: number) -> ()
    bindUnix: (self: Socket, path: string) -> ()
    setReuseAddress: (self: Socket, enable: boolean) -> ()
    setReusePort: (self: Socket, enable: boolean) -> ()
    setKeepAlive: (self: Socket, enable: boolean) -> ()
    setNoDelay: (self: Socket, enable: boolean) -> ()
    setSendBufferSize: (self: Socket, size: number) -> ()
    setReceiveBufferSize: (self: Socket, size: number) -> ()
    getSendBufferSize: (self: Socket) -> number
    getReceiveBufferSize: (self: Socket) -> number
    shutdown: (self: Socket) -> ()
    close: (self: Socket) -> ()
    address: (self: Socket) -> NetworkAddress 
end
export type NetworkAddress = {
    address: string,
    port: number?, 
}
type NetDomain = 
    | "unspec"
    | "ipv4"
    | "ipv6"
    | "unix"
type NetType = 
    | "stream"
    | "dgram"
    | "raw"
    | "seqpacket"
    | "rdm"
type NetProtocol = 
    | "ip"
    | "icmp"
    | "tcp"
    | "udp"
    | "ipv6"
    | "icmpv6"
    | "raw"
export type _zune_net_ADDRF = {
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
export type _zune_net_SOCK = {
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
export type _zune_net_IPPROTO = {
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
export type _zune_net = {
    ADDRF: _zune_net_ADDRF,
    SOCK: _zune_net_SOCK,
    IPPROTO: _zune_net_IPPROTO,
    openSocket: (domain: number | NetDomain, type: number | NetType, protocol: number | NetProtocol) -> Socket,
    getAddressList: (name: string, port: number) -> {NetworkAddress}, 
}
--[[ io ]]
declare extern type BufferArray with
    len: number
    offset: number
    seekTo: (self: BufferArray, offset: number) -> ()
    grow: (self: BufferArray, size: number) -> ()
    append: (self: BufferArray, src: buffer | string, srcOffset: number?, count: number?) -> (number, string?)
    read: (self: BufferArray, dest: buffer, destOffset: number?, count: number?) -> (number, string?)
    readPositional: (self: BufferArray, offset: number, dest: buffer, destOffset: number?, count: number?) -> (number, string?)
    write: (self: BufferArray, src: buffer | string, srcOffset: number?, count: number?) -> (number, string?)
    writePositional: (self: BufferArray, offset: number, src: buffer | string, srcOffset: number?, count: number?) -> (number, string?)
    clear: (self: BufferArray) -> () 
end
export type _zune_io_terminal = {
    isTty: () -> boolean,
    getCurrentMode: () -> "normal" | "raw",
    enableRawMode: () -> boolean,
    restoreMode: () -> boolean,
    getSize: () -> (number, number), 
}
export type BufferArrayOptions = {
    limit: number?,
    size: number?, 
}
export type _zune_io = {
    cwd: () -> Dir,
    createPipe: () -> File,
    createBufferArray: (opts: BufferArrayOptions?) -> BufferArray,
    terminal: _zune_io_terminal,
    stdout: File,
    stderr: File,
    stdin: File, 
}
--[[ gpio ]]
declare extern type GPIOLine with
    read: (self: GPIOLine) -> boolean
    write: (self: GPIOLine, value: boolean) -> ()
    close: (self: GPIOLine) -> () 
end
export type GPIOChip = {
    name: string,
    label: string,
    lines: number, 
}
export type GPIOLineInfo = {
    offset: number,
    name: string,
    consumer: string,
    used: boolean,
    direction: "in" | "out" | "unknown",
    active_low: boolean, 
}
export type GPIORequestOptions = {
    chip: number | string,
    offset: number,
    direction: "in" | "out",
    consumer: string,
    initial: boolean, 
}
export type _zune_gpio = {
    available: () -> boolean,
    chips: () -> {GPIOChip},
    chip: (index: number | string) -> GPIOChip,
    line: (index: number | string, offset: number) -> GPIOLineInfo,
    request: (opts: GPIORequestOptions) -> GPIOLine, 
}
--[[ config ]]
export type ZuneConfiguration = {
    runtime: {
        use_detailed_error: boolean,
        luau: {
            default_ncg: boolean,
            jit_enabled: boolean,
            debug_level: number,
            optimization_level: number,
            coverage_level: number, 
        },
        features: {
            io: boolean,
            mem: boolean,
            fmt: boolean,
            luau: boolean,
            task: boolean,
            debug: boolean,
            ascii: boolean,
            serde: boolean,
            regex: boolean,
            config: boolean,
            crypto: boolean,
            random: boolean,
            require: boolean,
            testing: boolean,
            process: boolean,
            platform: boolean,
            fs: boolean,
            c: boolean,
            gpio: boolean,
            net: boolean,
            time: boolean,
            thread: boolean, 
        }, 
    },
    format: {
        enabled: boolean,
        max_depth: number,
        use_color: boolean,
        table_address: boolean,
        recursive_table: boolean,
        buffer_max_display: number, 
    },
    workspace: {
        run_path: string?,
        scripts: {
            [string]: string
        }, 
    }
}
export type _zune_config = {
    get: () -> ZuneConfiguration,
    loadFromFile: (dir: Dir, path: string | buffer) -> (),
    loadFromToml: (toml: string | buffer) -> (),
    getFromFile: (dir: Dir, path: string | buffer) -> ZuneConfiguration,
    getFromToml: (toml: string | buffer) -> ZuneConfiguration, 
}
--[[ fmt ]]
export type _zune_fmt = {
    format: (...any) -> string,
    useColors: () -> boolean,
    setEnabled: (enabled: boolean) -> (),
    setIndent: (indent: number) -> (),
    setMaxDepth: (depth: number) -> (),
    setUseColor: (enabled: boolean) -> (),
    setTableAddress: (enabled: boolean) -> (),
    setRecursiveTable: (enabled: boolean) -> (),
    setBufferMaxDisplay: (max: number) -> (), 
}
--[[ require ]]
export type _zune_require = {
    navigate: (path: string | buffer, from: (string | buffer)?, config: string | buffer?) -> string,
    getCached: (resolvedPath: string) -> any?, 
}
--[[ mem ]]
export type MemWritableSlice = buffer | CPointer
export type MemReadableSlice = string | buffer | CPointer
export type _zune_mem = {
    MAX_SIZE: number,
    len: (src: MemReadableSlice) -> number?,
    copy: (dest: MemWritableSlice, destOffset: number, src: MemReadableSlice, srcOffset: number, count: number?) -> (),
    slice: (src: MemReadableSlice, offset: number, count: number?) -> buffer,
    eqlSlice: (a: MemReadableSlice, aOffset: number, b: MemReadableSlice, bOffset: number, count: number?) -> boolean,
    eql: (a: MemReadableSlice, b: MemReadableSlice) -> boolean,
    startsWith: (slice: MemReadableSlice, needle: MemReadableSlice) -> boolean,
    endsWith: (slice: MemReadableSlice, needle: MemReadableSlice) -> boolean,
    trim: (src: MemReadableSlice, values_to_strip: MemReadableSlice) -> buffer,
    trimStart: (src: MemReadableSlice, values_to_strip: MemReadableSlice) -> buffer,
    trimEnd: (src: MemReadableSlice, values_to_strip: MemReadableSlice) -> buffer,
    find: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findPos: (src: MemReadableSlice, offset: number, needle: MemReadableSlice, count: number?) -> number?,
    findLast: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findScalar: (src: MemReadableSlice, char: number) -> number?,
    findScalarPos: (src: MemReadableSlice, offset: number, char: number, count: number?) -> number?,
    findScalarLast: (src: MemReadableSlice, char: number) -> number?,
    findAny: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findAnyPos: (src: MemReadableSlice, offset: number, needle: MemReadableSlice, count: number?) -> number?,
    findAnyLast: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findNone: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findNonePos: (src: MemReadableSlice, offset: number, needle: MemReadableSlice, count: number?) -> number?,
    findNoneLast: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findDiff: (src: MemReadableSlice, needle: MemReadableSlice) -> number?,
    findDiffPos: (src: MemReadableSlice, offset: number, needle: MemReadableSlice, needleOffset: number?, count: number?) -> number?,
    findMax: (src: MemReadableSlice, offset: number?, count: number?) -> number,
    findMin: (src: MemReadableSlice, offset: number?, count: number?) -> number,
    findMinMax: (src: MemReadableSlice, offset: number?, count: number?) -> (number, number),
    cutPrefix: (src: MemReadableSlice, prefix: MemReadableSlice) -> buffer?,
    cutSuffix: (src: MemReadableSlice, suffix: MemReadableSlice) -> buffer?,
    cut: (src: MemReadableSlice, needle: MemReadableSlice) -> (buffer?, buffer?),
    cutLast: (src: MemReadableSlice, needle: MemReadableSlice) -> (buffer?, buffer?),
    cutScalar: (src: MemReadableSlice, char: number) -> (buffer?, buffer?),
    cutScalarLast: (src: MemReadableSlice, char: number) -> (buffer?, buffer?),
    replaceScalar: (src: MemWritableSlice, char: number, replacement: number, offset: number?, count: number?) -> (),
    max: (src: MemReadableSlice, offset: number?, count: number?) -> number,
    min: (src: MemReadableSlice, offset: number?, count: number?) -> number,
    reverse: (src: MemWritableSlice, offset: number?, count: number?) -> (),
    rotate: (src: MemWritableSlice, amount: number, offset: number?, count: number?) -> (),
    set: (dest: MemWritableSlice, value: number, offset: number?, count: number?) -> (),
    readvectorf32x2: (src: MemReadableSlice, offset: number?) -> vector,
    readvectorf32x3: (src: MemReadableSlice, offset: number?) -> vector,
    writevectorf32x2: (dest: MemWritableSlice, offset: number?, vec: vector) -> (),
    writevectorf32x3: (dest: MemWritableSlice, offset: number?, vec: vector) -> (),
    readu64: (src: MemReadableSlice, offset: number?) -> number,
    writeu64: (dest: MemWritableSlice, offset: number?, value: number) -> (),
    readi64: (src: MemReadableSlice, offset: number?) -> number,
    writei64: (dest: MemWritableSlice, offset: number?, value: number) -> (), 
}
--[[ task ]]
export type _zune_task = {
    cancel: (thread: thread) -> (),
    defer: <A...,  R...>(f: ((A...) ->  R...) | thread,  A...) -> thread,
    delay: <A...,  R...>(sec: number, f: ((A...) ->  R...) | thread,  A...) -> thread,
    spawn: <A...,  R...>(f: ((A...) ->  R...) | thread,  A...) -> thread,
    limit: <A...,  R...>(sec: number, f: ((A...) ->  R...) | thread,  A...) -> thread,
    wait: (sec: number?) -> number,
    count: (() -> number) & ((kinds: string) -> ...number), 
}
declare zune: {
    compiled: {
        optimize: number,
        debug: number,
        mode: "debug" | "release", 
    }?,
    fs: _zune_fs,
    process: _zune_process,
    testing: _zune_testing,
    task: _zune_task,
    net: _zune_net,
    luau: _zune_luau,
    serde: _zune_serde,
    io: _zune_io,
    crypto: _zune_crypto,
    regex: _zune_regex,
    time: _zune_time,
    c: _zune_c,
    require: _zune_require,
    random: _zune_random,
    thread: _zune_thread,
    mem: _zune_mem,
    platform: _zune_platform,
    config: _zune_config,
    debug: _zune_debug,
    fmt: _zune_fmt,
    gpio: _zune_gpio,
    ascii: _zune_ascii, 
}
declare _RUNTIME: {
    name: "zune",
    version: {
        display: string,
        semantic: {
            major: number,
            minor: number,
            patch: number,
            build: string?, 
        }
    }, 
}
declare _FILE: {
    main: boolean, 
}
declare _LUAU: {
    version: {
        display: string,
        major: number,
        minor: number, 
    }, 
}