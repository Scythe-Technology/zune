const std = @import("std");
const luau = @import("luau");
const lz4 = @import("lz4");

const Zune = @import("zune");

const Scheduler = Zune.Runtime.Scheduler;
const Scripting = Zune.Runtime.Scripting;

const Codec = @import("codec.zig");

const VM = luau.VM;

fn frameLevel(L: *VM.lua.State) !u32 {
    if (L.typeOf(6).isnoneornil())
        return 4;
    const num = try L.Zcheckvalue(i32, 6, null);
    if (num < 0)
        return L.Zerror("options 'level' must not be less than 0");
    return @intCast(num);
}

fn framePreferences(level: u32) lz4.Frame.Preferences {
    return .{
        .compressionLevel = @intCast(level),
        .frameInfo = .{
            .blockSizeID = @backingInt(lz4.Frame.BlockSize.Default),
            .blockMode = @backingInt(lz4.Frame.BlockMode.Independent),
            .contentChecksumFlag = @backingInt(lz4.Frame.ContentChecksum.Enabled),
            .frameType = @backingInt(lz4.Frame.FrameType.Frame),
            .dictID = 0,
            .blockChecksumFlag = @backingInt(lz4.Frame.BlockChecksum.Disabled),
        },
    };
}

pub fn lua_calcSize(L: *VM.lua.State) !i32 {
    const len = try L.Zcheckvalue(u32, 1, null);
    if (len > lz4.MAX_INPUT_SIZE)
        return L.Zerror("no space");

    const bound = lz4.Standard.compressBound(len);

    try L.Zpushvalue(bound);

    return 1;
}

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const src = try Codec.sourceWindow(L);
    const dest = try Codec.destTail(L);
    if (src.len > lz4.MAX_INPUT_SIZE)
        return L.Zerror("no space");
    const n = lz4.Standard.compressDefault(src, dest) catch |err| switch (err) {
        error.Failed => return L.Zerror("no space"),
    };

    try L.Zpushvalue(n);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const src = try Codec.sourceWindow(L);
    const dest = try Codec.destTail(L);

    const n = try lz4.Standard.decompressSafe(src, dest);

    try L.Zpushvalue(n);

    return 1;
}

pub fn lua_calcFrameSize(L: *VM.lua.State) !i32 {
    const len = try L.Zcheckvalue(u32, 1, null);
    const prefs = framePreferences(4);
    const bound = lz4.Frame.compressBound(len, &prefs);
    if (bound == 0)
        return L.Zerror("no space");
    try L.Zpushvalue(std.math.add(usize, bound, 4) catch return L.Zerror("no space"));
    return 1;
}

pub fn lua_compressFrame(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
    const src = try Codec.sourceWindow(L);
    const dest = try Codec.destTail(L);
    const level = try frameLevel(L);
    if (src.len > std.math.maxInt(u32) or dest.len < 4)
        return L.Zerror("no space");

    var encoder = try lz4.Encoder.init(allocator);
    defer encoder.deinit();
    _ = encoder.setLevel(level)
        .setContentChecksum(lz4.Frame.ContentChecksum.Enabled)
        .setBlockMode(lz4.Frame.BlockMode.Independent);

    const header: [4]u8 = @bitCast(@as(u32, @intCast(src.len)));
    @memcpy(dest[0..4], &header);

    var writer: std.Io.Writer = .fixed(dest[4..]);
    encoder.compressStream(&writer, src) catch |err| switch (err) {
        error.WriteFailed => return L.Zerror("no space"),
        else => return err,
    };

    try L.Zpushvalue(writer.end + 4);

    return 1;
}

pub fn lua_decompressFrame(L: *VM.lua.State) !i32 {
    const allocator = Scheduler.fromState(L).allocator();
    const src = try Codec.sourceWindow(L);
    const dest = try Codec.destTail(L);
    if (src.len < 4)
        return L.Zerror("invalid header");

    var header: [4]u8 = undefined;
    @memcpy(&header, src[0..4]);
    const size: u32 = @bitCast(header);
    if (size > Scripting.MAX_LUAU_SIZE)
        return L.Zerror("decompressed data exceeds maximum string/buffer size");
    if (size > dest.len)
        return L.Zerror("no space");

    var decoder = try lz4.Decoder.init(allocator);
    defer decoder.deinit();
    const plain = try decoder.decompress(src[4..], size);
    defer allocator.free(plain);
    @memcpy(dest[0..plain.len], plain);

    try L.Zpushvalue(plain.len);

    return 1;
}
