const TagNames: []const []const u8 = &.{
    // FS
    "FS_FILE",
    "FS_WATCHER",
    // NET
    "NET_SOCKET",
    "NET_HTTP_SERVER",
    "NET_HTTP_WEBSOCKET",
    "NET_HTTP_CLIENTWEBSOCKET",
    // IO
    "IO_STREAM",
    "IO_BUFFERSINK",
    "IO_BUFFERSTREAM",
    // DATETIME
    "DATETIME",
    // PROCESS
    "PROCESS_CHILD",
    // CRYPTO
    "CRYPTO_HASHER",
    "CRYPTO_TLS_CERTBUNDLE",
    "CRYPTO_TLS_CERTKEYPAIR",
    // RANDOM
    "RANDOM",
    // REGEX
    "REGEX_COMPILED",
    // FFI
    "FFI_LIBRARY",
    "FFI_POINTER",
    "FFI_DATATYPE",
    // SQLITE
    "SQLITE_DATABASE",
    "SQLITE_STATEMENT",
    // THREAD
    "THREAD",
};

pub const Tags = block_name: {
    const std = @import("std");

    var list: [TagNames.len]struct { []const u8, comptime_int } = undefined;

    for (TagNames, 0..) |name, i| {
        list[i] = .{ name, i + 1 };
    }

    break :block_name std.StaticStringMap(comptime_int).initComptime(list);
};
