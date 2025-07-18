const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const VM = luau.VM;

pub fn load(L: *VM.lua.State) !void {
    try @import("server/lib.zig").lua_load(L);
    try @import("websocket/lib.zig").lua_load(L);
    try L.Zpushvalue(.{
        .serve = @import("server/lib.zig").lua_serve,
        .request = @import("client.zig").lua_request,
        .websocket = @import("websocket/lib.zig").lua_websocket,
    });
    L.setreadonly(-1, true);
}
