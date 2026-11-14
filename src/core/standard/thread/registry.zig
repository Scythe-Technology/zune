const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Scripting = Zune.Runtime.Scripting;

const VM = luau.VM;

pub fn Of(comptime Entry: type) type {
    return struct {
        pub var map: std.hash_map.StringHashMapUnmanaged(*Entry) = .empty;
        pub threadlocal var refs: std.hash_map.StringHashMapUnmanaged(Scripting.Reference) = .empty;
        pub var mutex: std.Io.Mutex = .init;

        pub fn reserve(allocator: std.mem.Allocator, name: []const u8) !*Entry {
            if (map.get(name)) |entry| {
                _ = entry.ref_count.fetchAdd(1, .acq_rel);
                return entry;
            }

            const key = try allocator.dupe(u8, name);
            errdefer allocator.free(key);

            const entry = try allocator.create(Entry);
            errdefer allocator.destroy(entry);

            entry.* = .{
                .name = key,
                .ref_count = .init(1),
            };

            try map.put(allocator, key, entry);

            return entry;
        }

        pub fn release(entry: *Entry) void {
            const allocator = Zune.DEFAULT_ALLOCATOR;

            mutex.lockUncancelable(Zune.io());
            defer mutex.unlock(Zune.io());

            const previous = entry.ref_count.fetchSub(1, .acq_rel);

            std.debug.assert(previous > 0);

            if (previous != 1)
                return;

            const name = entry.name;

            std.debug.assert(map.remove(name));

            allocator.free(name);

            if (@hasDecl(Entry, "deinit"))
                entry.deinit();
            allocator.destroy(entry);

            if (map.count() == 0) {
                map.deinit(allocator);
                map = .empty;
            }
        }

        pub fn deinit(L: *VM.lua.State) void {
            if (refs.count() == 0)
                return;

            const current = std.Thread.getCurrentId();
            mutex.lockUncancelable(Zune.io());

            var it = refs.iterator();
            while (it.next()) |kv| {
                const entry = map.get(kv.key_ptr.*) orelse continue;
                entry.abandon(current);
            }
            mutex.unlock(Zune.io());

            var pending = refs;

            refs = .empty;

            var ref_it = pending.valueIterator();
            while (ref_it.next()) |lua_ref|
                lua_ref.deref(L);

            pending.deinit(Zune.DEFAULT_ALLOCATOR);
        }
    };
}
