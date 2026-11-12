const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");

const Zune = @import("zune");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const MAX_EVENTS = 8192;

const Watcher = @This();

impl: Impl,

pub const Impl = switch (builtin.os.tag) {
    .linux => InotifyImpl,
    .windows => WindowsImpl,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .freebsd,
    .openbsd,
    .netbsd,
    .dragonfly,
    => KqueueImpl,
    else => UnsupportedImpl,
};

pub const Event = struct {
    path: []u8,
    kind: Kind,

    pub const Kind = enum {
        created,
        deleted,
        modified,
        renamed,
        moved,
        metadata,
    };

    pub fn deinit(self: Event, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub fn init(allocator: Allocator) !Watcher {
    return .{
        .impl = try Impl.init(allocator),
    };
}

pub fn deinit(self: *Watcher, allocator: Allocator) void {
    self.impl.shutdown();
    self.impl.deinit(allocator);
}

pub const AddOptions = struct {
    recursive: bool = false,
};
pub fn add(self: *Watcher, allocator: Allocator, path: []const u8, opts: AddOptions) !void {
    return self.impl.add(allocator, path, opts);
}

pub fn remove(self: *Watcher, allocator: Allocator, path: []const u8) !void {
    return self.impl.remove(allocator, path);
}

pub fn drain(self: *Watcher, allocator: Allocator) !void {
    return self.impl.drain(allocator);
}

pub fn pop(self: *Watcher) ?Event {
    return self.impl.pop();
}

pub fn pollFd(self: *Watcher) std.posix.fd_t {
    return switch (comptime builtin.os.tag) {
        .linux,
        .macos,
        .ios,
        .tvos,
        .watchos,
        .visionos,
        .freebsd,
        .openbsd,
        .netbsd,
        .dragonfly,
        => self.impl.pollFd(),
        else => unreachable,
    };
}

pub fn setWake(self: *Watcher, ctx: *anyopaque, func: *const fn (*anyopaque) void) void {
    switch (comptime builtin.os.tag) {
        .windows => self.impl.setWake(ctx, func),
        else => {},
    }
}

pub const InotifyImpl = struct {
    nodes: std.ArrayList(?*Node) = .empty,
    free_nodes: std.ArrayList(u32) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    events: std.ArrayList(Event) = .empty,
    head: usize = 0,

    handle: i32 = -1,
    wd_map: std.AutoHashMapUnmanaged(i32, u32) = .empty,

    pub const Node = struct {
        path: [:0]u8,
        index: u32,
        owner: u32,
        parent: ?u32,
        user: bool,
        recursive: bool,
        alive: bool = false,
        death_emitted: bool = false,
        suppress_death: bool = false,
        wd: i32 = -1,
    };

    pub fn init(_: Allocator) !InotifyImpl {
        const flags: u32 = std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK;
        const fd = try inotifyRc(std.os.linux.inotify_init1(flags));
        return .{
            .handle = fd,
        };
    }

    pub fn shutdown(_: *InotifyImpl) void {}

    fn closeFd(fd: i32) void {
        _ = std.os.linux.close(fd);
    }

    pub fn deinit(self: *InotifyImpl, allocator: Allocator) void {
        deinitOwned(self, allocator);
        self.wd_map.deinit(allocator);
        if (self.handle >= 0)
            closeFd(self.handle);
        self.handle = -1;
    }

    pub fn add(self: *InotifyImpl, allocator: Allocator, path: []const u8, opts: AddOptions) !void {
        return addUser(self, allocator, path, opts);
    }

    pub fn remove(self: *InotifyImpl, allocator: Allocator, path: []const u8) !void {
        return removeUser(self, allocator, path);
    }

    pub fn drain(self: *InotifyImpl, allocator: Allocator) !void {
        const Raw = struct {
            wd: i32,
            mask: u32,
            name: []u8,
        };
        var raw: std.ArrayList(Raw) = .empty;
        defer {
            for (raw.items) |item|
                allocator.free(item.name);
            raw.deinit(allocator);
        }

        var buf: [8192]u8 align(@alignOf(InotifyEvent)) = undefined;
        while (true) {
            const n = std.posix.read(self.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => |e| return e,
            };
            if (n == 0)
                break;
            var offset: usize = 0;
            while (offset + @sizeOf(InotifyEvent) <= n) {
                const hdr: *const InotifyEvent = @ptrCast(@alignCast(buf[offset..].ptr));
                const next = offset + @sizeOf(InotifyEvent) + hdr.name_len;
                if (next > n)
                    break;
                const name_raw = buf[offset + @sizeOf(InotifyEvent) .. next];
                const name = std.mem.sliceTo(name_raw, 0);

                const copy = try allocator.dupe(u8, name);
                errdefer allocator.free(copy);

                try raw.append(allocator, .{
                    .wd = hdr.wd,
                    .mask = hdr.mask,
                    .name = copy,
                });
                offset = next;
            }
        }

        for (raw.items) |item|
            self.apply(allocator, item.wd, item.mask, item.name);
    }

    pub fn pop(self: *InotifyImpl) ?Event {
        return popEvent(self);
    }

    pub fn pollFd(self: *InotifyImpl) std.posix.fd_t {
        return self.handle;
    }

    pub fn arm(self: *InotifyImpl, allocator: Allocator, node: *Node) !void {
        const wd = try inotifyAdd(self.handle, node.path);
        errdefer _ = std.os.linux.inotify_rm_watch(self.handle, wd);
        node.wd = wd;
        try self.wd_map.put(allocator, wd, node.index);
    }

    pub fn disarm(self: *InotifyImpl, node: *Node, rm_os: bool) void {
        if (node.wd < 0)
            return;
        const wd = node.wd;
        _ = self.wd_map.remove(wd);
        node.wd = -1;
        if (!rm_os)
            return;
        const rc = std.os.linux.inotify_rm_watch(self.handle, wd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS, .INVAL => {},
            else => {},
        }
    }

    pub fn freeExtra(_: *InotifyImpl, _: Allocator, _: *Node) void {}

    fn apply(self: *InotifyImpl, allocator: Allocator, wd: i32, mask: u32, name: []const u8) void {
        const IN = std.os.linux.IN;
        if (mask & IN.Q_OVERFLOW != 0)
            return;
        const idx = self.wd_map.get(wd) orelse return;
        const node = nodeAt(self, idx) orelse return;
        if (!node.alive)
            return;

        if (name.len != 0) {
            const bits = [_]struct { bit: u32, kind: Event.Kind }{
                .{ .bit = IN.CREATE, .kind = .created },
                .{ .bit = IN.DELETE, .kind = .deleted },
                .{ .bit = IN.MODIFY, .kind = .modified },
                .{ .bit = IN.MOVED_FROM, .kind = .moved },
                .{ .bit = IN.MOVED_TO, .kind = .moved },
                .{ .bit = IN.ATTRIB, .kind = .metadata },
            };
            for (bits) |bit| {
                if (mask & bit.bit == 0)
                    continue;
                queueJoined(self, allocator, node.path, name, bit.kind);
            }
            if (mask & IN.CREATE != 0 and mask & IN.ISDIR != 0 and node.recursive)
                addChild(self, allocator, idx, name);
        }

        if (mask & IN.DELETE_SELF != 0) {
            emitSelf(self, allocator, idx, .deleted);
        } else if (mask & IN.MOVE_SELF != 0) {
            emitSelf(self, allocator, idx, .renamed);
        }

        if (mask & IN.IGNORED != 0)
            self.onIgnored(allocator, idx);
    }

    fn onIgnored(self: *InotifyImpl, allocator: Allocator, idx: u32) void {
        const node = nodeAt(self, idx) orelse return;
        if (!node.alive)
            return;
        emitSelf(self, allocator, idx, .deleted);
        const live = nodeAt(self, idx) orelse return;
        if (!live.alive)
            return;
        if (live.user) {
            self.dropIgnoredTree(allocator, live.owner);
        } else {
            destroyOwned(self, allocator, live, false);
        }
    }

    fn dropIgnoredTree(self: *InotifyImpl, allocator: Allocator, owner: u32) void {
        for (self.nodes.items) |n| {
            const node = n orelse continue;
            if (node.index != owner and node.owner != owner)
                continue;
            const rm = node.index != owner;
            destroyOwned(self, allocator, node, rm);
        }
    }

    fn inotifyAdd(fd: i32, path: [:0]const u8) !i32 {
        const IN = std.os.linux.IN;
        return inotifyRc(
            std.os.linux.inotify_add_watch(
                fd,
                path.ptr,
                IN.CREATE | IN.DELETE |
                    IN.DELETE_SELF |
                    IN.MODIFY |
                    IN.MOVE_SELF | IN.MOVED_FROM | IN.MOVED_TO |
                    IN.ATTRIB |
                    IN.ONLYDIR,
            ),
        );
    }

    fn inotifyRc(rc: usize) !i32 {
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOTDIR => error.NotDir,
            .NOENT => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            .NOSPC, .NOMEM => error.SystemResources,
            .NAMETOOLONG => error.NameTooLong,
            .LOOP => error.SymLinkLoop,
            .INVAL, .BADF => error.InvalidArgument,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    const InotifyEvent = extern struct {
        wd: i32,
        mask: u32,
        cookie: u32,
        name_len: u32,
    };
};

pub const KqueueImpl = struct {
    nodes: std.ArrayList(?*Node) = .empty,
    free_nodes: std.ArrayList(u32) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    events: std.ArrayList(Event) = .empty,
    head: usize = 0,

    handle: i32 = -1,
    fd_map: std.AutoHashMapUnmanaged(i32, FdRef) = .empty,

    pub const FdRef = struct {
        node: u32,
        file: ?[]u8,
    };

    pub const Node = struct {
        path: [:0]u8,
        index: u32,
        owner: u32,
        parent: ?u32,
        user: bool,
        recursive: bool,
        alive: bool = false,
        death_emitted: bool = false,
        suppress_death: bool = false,

        dir_fd: i32 = -1,
        files: std.StringHashMapUnmanaged(i32) = .empty,
        entries: std.StringHashMapUnmanaged(EntryKind) = .empty,

        pub const EntryKind = enum { file, dir };
    };

    pub fn init(_: Allocator) !KqueueImpl {
        const fd = std.c.kqueue();
        if (fd < 0)
            return error.SystemResources;
        return .{
            .handle = fd,
        };
    }

    pub fn shutdown(_: *KqueueImpl) void {}

    fn closeFd(fd: i32) void {
        _ = std.posix.system.close(fd);
    }

    pub fn deinit(self: *KqueueImpl, allocator: Allocator) void {
        deinitOwned(self, allocator);
        self.fd_map.deinit(allocator);
        if (self.handle >= 0)
            closeFd(self.handle);
        self.handle = -1;
    }

    pub fn add(self: *KqueueImpl, allocator: Allocator, path: []const u8, opts: AddOptions) !void {
        return addUser(self, allocator, path, opts);
    }

    pub fn remove(self: *KqueueImpl, allocator: Allocator, path: []const u8) !void {
        return removeUser(self, allocator, path);
    }

    pub fn drain(self: *KqueueImpl, allocator: Allocator) !void {
        var batch: std.ArrayList(std.c.Kevent) = .empty;
        defer batch.deinit(allocator);
        while (true) {
            var buf: [64]std.c.Kevent = undefined;
            var dummy = std.mem.zeroes(std.c.Kevent);
            var ts: std.c.timespec = .{
                .sec = 0,
                .nsec = 0,
            };
            const n = std.c.kevent(self.handle, @ptrCast(&dummy), 0, &buf, 64, &ts);
            if (n < 0)
                return error.Unexpected;
            if (n == 0)
                break;
            try batch.appendSlice(allocator, buf[0..@intCast(n)]);
        }

        const FileDead = struct {
            node: u32,
            name: []u8,
        };
        var file_dead: std.ArrayList(FileDead) = .empty;
        defer {
            for (file_dead.items) |item|
                allocator.free(item.name);
            file_dead.deinit(allocator);
        }
        var dir_dead: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer dir_dead.deinit(allocator);
        var dir_rescan: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer dir_rescan.deinit(allocator);

        for (batch.items) |ev| {
            if (ev.flags & std.c.EV.ERROR != 0)
                continue;
            if (ev.filter != std.c.EVFILT.VNODE)
                continue;
            const ident: i32 = std.math.cast(i32, ev.ident) orelse continue;
            const owner = self.fd_map.get(ident) orelse continue;
            const flags = ev.fflags;
            if (owner.file == null) {
                if (flags & (std.c.NOTE.DELETE | std.c.NOTE.REVOKE) != 0) {
                    try dir_dead.put(allocator, owner.node, {});
                    continue;
                }
                if (flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND | std.c.NOTE.LINK) != 0)
                    try dir_rescan.put(allocator, owner.node, {});
                if (flags & std.c.NOTE.RENAME != 0)
                    emitSelf(self, allocator, owner.node, .renamed);
                if (flags & std.c.NOTE.ATTRIB != 0) {
                    if (nodeAt(self, owner.node)) |node|
                        queueCopy(self, allocator, node.path, .metadata);
                }
            } else {
                const name = owner.file.?;
                if (flags & std.c.NOTE.DELETE != 0) {
                    const copy = try allocator.dupe(u8, name);
                    try file_dead.append(allocator, .{
                        .node = owner.node,
                        .name = copy,
                    });
                    continue;
                }
                const node = nodeAt(self, owner.node) orelse continue;
                if (flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND) != 0)
                    queueJoined(self, allocator, node.path, name, .modified);
                if (flags & std.c.NOTE.ATTRIB != 0)
                    queueJoined(self, allocator, node.path, name, .metadata);
                if (flags & (std.c.NOTE.RENAME | std.c.NOTE.LINK) != 0)
                    queueJoined(self, allocator, node.path, name, .renamed);
            }
        }

        for (file_dead.items) |item|
            self.retireFile(allocator, item.node, item.name);
        var dead_it = dir_dead.keyIterator();
        while (dead_it.next()) |key| {
            const node = nodeAt(self, key.*) orelse continue;
            emitSelf(self, allocator, key.*, .deleted);
            destroyOwned(self, allocator, node, true);
        }
        var scan_it = dir_rescan.keyIterator();
        while (scan_it.next()) |key| {
            const node = nodeAt(self, key.*) orelse continue;
            if (!node.alive)
                continue;
            self.rescan(allocator, key.*, true) catch {};
        }
    }

    pub fn pop(self: *KqueueImpl) ?Event {
        return popEvent(self);
    }

    pub fn pollFd(self: *KqueueImpl) std.posix.fd_t {
        return self.handle;
    }

    pub fn arm(self: *KqueueImpl, allocator: Allocator, node: *Node) !void {
        const fd = try openVnode(node.path, true);
        errdefer {
            node.dir_fd = fd;
            self.disarm(node, true);
            self.freeExtra(allocator, node);
            node.dir_fd = -1;
        }
        try self.vnodeRegister(fd);
        try self.fd_map.put(allocator, fd, .{
            .node = node.index,
            .file = null,
        });
        node.dir_fd = fd;
        try self.rescan(allocator, node.index, false);
    }

    pub fn disarm(self: *KqueueImpl, node: *Node, rm_os: bool) void {
        _ = rm_os;
        var fit = node.files.iterator();
        while (fit.next()) |entry| {
            _ = self.fd_map.remove(entry.value_ptr.*);
            closeFd(entry.value_ptr.*);
        }
        if (node.dir_fd >= 0) {
            _ = self.fd_map.remove(node.dir_fd);
            closeFd(node.dir_fd);
            node.dir_fd = -1;
        }
    }

    pub fn freeExtra(_: *KqueueImpl, allocator: Allocator, node: *Node) void {
        var it = node.entries.keyIterator();
        while (it.next()) |key|
            allocator.free(key.*);
        node.entries.deinit(allocator);
        var fit = node.files.keyIterator();
        while (fit.next()) |key|
            allocator.free(key.*);
        node.files.deinit(allocator);
    }

    fn vnodeRegister(self: *KqueueImpl, fd: i32) !void {
        var change = std.mem.zeroes(std.c.Kevent);
        change.ident = @intCast(fd);
        change.filter = std.c.EVFILT.VNODE;
        change.flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE;
        change.fflags =
            std.c.NOTE.DELETE |
            std.c.NOTE.WRITE |
            std.c.NOTE.RENAME |
            std.c.NOTE.ATTRIB |
            std.c.NOTE.EXTEND |
            std.c.NOTE.LINK |
            std.c.NOTE.REVOKE;
        var out = std.mem.zeroes(std.c.Kevent);
        const rc = std.c.kevent(self.handle, @ptrCast(&change), 1, @ptrCast(&out), 0, null);
        if (rc < 0)
            return error.Unexpected;
    }

    fn retireFile(self: *KqueueImpl, allocator: Allocator, idx: u32, name: []const u8) void {
        const node = nodeAt(self, idx) orelse return;
        if (!node.alive)
            return;
        const removed = node.entries.fetchRemove(name) orelse return;
        defer allocator.free(removed.key);

        queueJoined(self, allocator, node.path, name, .deleted);

        if (node.files.fetchRemove(name)) |kv| {
            _ = self.fd_map.remove(kv.value);
            closeFd(kv.value);
            allocator.free(kv.key);
        }
    }

    fn rescan(self: *KqueueImpl, allocator: Allocator, idx: u32, emit: bool) !void {
        const node = nodeAt(self, idx) orelse return;
        if (emit and !node.alive)
            return;
        var dir = try Io.Dir.cwd().openDir(Zune.io(), node.path, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer dir.close(Zune.io());

        var present: std.StringHashMapUnmanaged(Node.EntryKind) = .empty;
        defer {
            var it = present.keyIterator();
            while (it.next()) |key|
                allocator.free(key.*);
            present.deinit(allocator);
        }

        var iter = dir.iterate();
        while (try iter.next(Zune.io())) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, ".."))
                continue;
            const kind: Node.EntryKind = if (entry.kind == .directory) .dir else .file;

            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);

            try present.put(allocator, name, kind);
        }

        var created: std.ArrayList([]const u8) = .empty;
        defer created.deinit(allocator);

        var pit = present.iterator();
        while (pit.next()) |entry| {
            const current = nodeAt(self, idx) orelse return;
            if (current.entries.get(entry.key_ptr.*) != null)
                continue;
            try created.append(allocator, entry.key_ptr.*);
        }
        for (created.items) |name| {
            const kind = present.get(name).?;
            const current = nodeAt(self, idx) orelse return;
            if (emit)
                queueJoined(self, allocator, current.path, name, .created);

            const key = try allocator.dupe(u8, name);
            errdefer allocator.free(key);

            try current.entries.put(allocator, key, kind);

            if (kind == .file)
                self.openFileNode(allocator, idx, key) catch {};
            if (kind == .dir and current.recursive)
                addChild(self, allocator, idx, name);
        }

        var gone: std.ArrayList([]u8) = .empty;
        defer gone.deinit(allocator);

        const current = nodeAt(self, idx) orelse return;

        var eit = current.entries.iterator();
        while (eit.next()) |entry| {
            if (present.get(entry.key_ptr.*) != null)
                continue;
            try gone.append(allocator, entry.key_ptr.*);
        }
        for (gone.items) |name| {
            const live = nodeAt(self, idx) orelse return;
            const removed = live.entries.fetchRemove(name) orelse continue;
            if (emit)
                queueJoined(self, allocator, live.path, name, .deleted);
            if (removed.value == .file) {
                if (live.files.fetchRemove(name)) |kv| {
                    _ = self.fd_map.remove(kv.value);
                    closeFd(kv.value);
                    allocator.free(kv.key);
                }
            }
            allocator.free(removed.key);
        }
    }

    fn openFileNode(self: *KqueueImpl, allocator: Allocator, idx: u32, name: []const u8) !void {
        const node = nodeAt(self, idx) orelse return;

        const joined = try std.fs.path.join(allocator, &.{ node.path, name });
        defer allocator.free(joined);

        const path_z = try allocator.dupeSentinel(u8, joined, 0);
        defer allocator.free(path_z);

        const fd = try openVnode(path_z, false);
        errdefer closeFd(fd);

        try self.vnodeRegister(fd);

        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);

        try node.files.put(allocator, key, fd);
        errdefer _ = node.files.remove(key);

        try self.fd_map.put(allocator, fd, .{
            .node = idx,
            .file = key,
        });
    }

    fn openVnode(path: [:0]const u8, directory: bool) !i32 {
        const flags: std.posix.O = if (directory)
            dirOpenFlags()
        else
            fileOpenFlags();
        return std.posix.openatZ(std.posix.AT.FDCWD, path.ptr, flags, 0);
    }

    fn dirOpenFlags() std.posix.O {
        if (comptime builtin.os.tag.isDarwin()) {
            return .{ .EVTONLY = true, .DIRECTORY = true, .CLOEXEC = true };
        }
        return .{ .DIRECTORY = true, .CLOEXEC = true, .NONBLOCK = true };
    }

    fn fileOpenFlags() std.posix.O {
        if (comptime builtin.os.tag.isDarwin())
            return .{ .EVTONLY = true, .CLOEXEC = true, .NONBLOCK = true };
        return .{ .CLOEXEC = true, .NONBLOCK = true };
    }
};

pub const WindowsImpl = struct {
    nodes: std.ArrayList(?*Node) = .empty,
    free_nodes: std.ArrayList(u32) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    events: std.ArrayList(Event) = .empty,
    head: usize = 0,

    iocp: ?std.os.windows.HANDLE = null,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?*const fn (*anyopaque) void = null,
    mem: Allocator,

    pub const Node = struct {
        path: [:0]u8,
        index: u32,
        owner: u32,
        parent: ?u32,
        user: bool,
        recursive: bool,
        alive: bool = false,
        death_emitted: bool = false,
        suppress_death: bool = false,

        handle: ?std.os.windows.HANDLE = null,
        overlapped: WinApi.OVERLAPPED = .{},
        buffer: []align(8) u8 = &.{},
        inflight: bool = false,
    };

    pub fn init(allocator: Allocator) !WindowsImpl {
        const port = WinApi.CreateIoCompletionPort(
            std.os.windows.INVALID_HANDLE_VALUE,
            null,
            0,
            1,
        ) orelse return error.Unexpected;
        return .{
            .iocp = port,
            .mem = allocator,
        };
    }

    pub fn shutdown(self: *WindowsImpl) void {
        self.stop.store(true, .release);
        self.lock();
        for (self.nodes.items) |n| {
            const node = n orelse continue;
            if (node.handle) |handle|
                _ = WinApi.CancelIoEx(handle, &node.overlapped);
        }
        self.unlock();
        if (self.iocp) |iocp| {
            _ = WinApi.PostQueuedCompletionStatus(iocp, 0, 0, null);
        }
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *WindowsImpl, allocator: Allocator) void {
        deinitOwned(self, allocator);
        if (self.iocp) |iocp|
            std.os.windows.CloseHandle(iocp);
        self.iocp = null;
    }

    pub fn setWake(self: *WindowsImpl, ctx: *anyopaque, func: *const fn (*anyopaque) void) void {
        self.wake_ctx = ctx;
        self.wake_fn = func;
    }

    pub fn add(self: *WindowsImpl, allocator: Allocator, path: []const u8, opts: AddOptions) !void {
        return addUser(self, allocator, path, opts);
    }

    pub fn remove(self: *WindowsImpl, allocator: Allocator, path: []const u8) !void {
        const found = try findUser(self, allocator, path);
        self.destroyNode(allocator, found);
    }

    pub fn drain(_: *WindowsImpl, _: Allocator) !void {}

    pub fn pop(self: *WindowsImpl) ?Event {
        self.lock();
        defer self.unlock();
        return popEvent(self);
    }

    pub fn arm(self: *WindowsImpl, allocator: Allocator, node: *Node) !void {
        const handle = try openDirHandle(node.path);
        errdefer std.os.windows.CloseHandle(handle);
        const port = WinApi.CreateIoCompletionPort(
            handle,
            self.iocp,
            @as(std.os.windows.ULONG_PTR, node.index) + 1,
            0,
        ) orelse return error.Unexpected;
        _ = port;

        const buf = try allocator.alignedAlloc(u8, .@"8", 64 * 1024);
        errdefer allocator.free(buf);
        node.handle = handle;
        node.buffer = buf;
        errdefer {
            if (node.inflight) {
                _ = WinApi.CancelIoEx(handle, &node.overlapped);
                node.inflight = false;
            }
            node.handle = null;
            node.buffer = &.{};
        }

        try issueRead(node);
        try self.ensureThread();
    }

    pub fn disarm(_: *WindowsImpl, _: *Node, _: bool) void {}

    pub fn freeExtra(_: *WindowsImpl, allocator: Allocator, node: *Node) void {
        if (node.handle) |handle| {
            std.os.windows.CloseHandle(handle);
            node.handle = null;
        }
        if (node.buffer.len != 0) {
            allocator.free(node.buffer);
            node.buffer = &.{};
        }
    }

    fn issueRead(node: *Node) !void {
        const handle = node.handle orelse return error.Unexpected;
        node.inflight = true;
        const ok = WinApi.ReadDirectoryChangesW(
            handle,
            node.buffer.ptr,
            @intCast(node.buffer.len),
            std.os.windows.BOOL.fromBool(node.recursive),
            WinApi.notify_filter,
            null,
            &node.overlapped,
            null,
        );
        if (!ok.toBool()) {
            const err = std.os.windows.GetLastError();
            if (err != .IO_PENDING) {
                node.inflight = false;
                return error.Unexpected;
            }
        }
    }

    fn ensureThread(self: *WindowsImpl) !void {
        if (self.thread != null)
            return;
        self.thread = try std.Thread.spawn(.{}, iocpMain, .{self});
    }

    fn destroyNode(self: *WindowsImpl, allocator: Allocator, node: *Node) void {
        const idx = node.index;
        self.lock();
        if (nodeAt(self, idx) != node or !node.alive) {
            self.unlock();
            return;
        }
        node.alive = false;
        node.suppress_death = true;
        unlinkPath(self, node);
        if (node.handle) |handle|
            _ = WinApi.CancelIoEx(handle, &node.overlapped);
        self.unlock();

        while (true) {
            self.lock();
            if (nodeAt(self, idx) != node) {
                self.unlock();
                return;
            }
            const busy = node.inflight;
            self.unlock();
            if (!busy) break;
            std.Io.sleep(Zune.io(), .fromMilliseconds(1), .awake) catch {};
        }

        self.lock();
        if (nodeAt(self, idx) != node) {
            self.unlock();
            return;
        }
        freeOwned(self, allocator, node);
        self.unlock();
    }

    fn onIocp(self: *WindowsImpl, key: usize, nbytes: u32) void {
        if (key == 0)
            return;
        const allocator = self.mem;
        const idx: u32 = @intCast(key - 1);

        var queued: std.ArrayList(Event) = .empty;
        defer {
            for (queued.items) |item|
                item.deinit(allocator);
            queued.deinit(allocator);
        }

        self.lock();
        const node = nodeAt(self, idx) orelse {
            self.unlock();
            return;
        };
        node.inflight = false;
        if (!node.alive or self.stop.load(.acquire)) {
            self.unlock();
            return;
        }

        if (nbytes == 0) {
            if (node.user and !node.death_emitted and !node.suppress_death and !hasWatchedParent(self, node)) {
                node.death_emitted = true;
                const copy = allocator.dupe(u8, node.path) catch null;
                if (copy) |path| {
                    queued.append(allocator, .{
                        .path = path,
                        .kind = .deleted,
                    }) catch allocator.free(path);
                }
            }
            node.alive = false;
            unlinkPath(self, node);
            freeOwned(self, allocator, node);
            self.unlock();
            self.flushQueued(allocator, &queued);
            return;
        }

        self.collectNotify(allocator, node, nbytes, &queued);
        self.unlock();
        self.flushQueued(allocator, &queued);

        self.lock();
        defer self.unlock();
        const live = nodeAt(self, idx) orelse return;
        if (!live.alive or self.stop.load(.acquire))
            return;
        issueRead(live) catch {
            live.alive = false;
            unlinkPath(self, live);
            freeOwned(self, allocator, live);
        };
    }

    fn flushQueued(self: *WindowsImpl, allocator: Allocator, queued: *std.ArrayList(Event)) void {
        for (queued.items) |item|
            self.pushOwned(allocator, item.path, item.kind);
        queued.clearRetainingCapacity();
    }

    fn pushOwned(self: *WindowsImpl, allocator: Allocator, path: []u8, kind: Event.Kind) void {
        self.lock();
        defer self.unlock();
        queueOwned(self, allocator, path, kind);
    }

    const Notify = extern struct {
        next: u32,
        action: u32,
        name_len: u32,

        const added: u32 = 1;
        const removed: u32 = 2;
        const modified: u32 = 3;
        const renamed_old: u32 = 4;
        const renamed_new: u32 = 5;
    };

    fn collectNotify(self: *WindowsImpl, allocator: Allocator, node: *Node, nbytes: u32, queued: *std.ArrayList(Event)) void {
        var offset: usize = 0;
        while (offset + @sizeOf(Notify) <= nbytes and offset + @sizeOf(Notify) <= node.buffer.len) {
            const base = node.buffer[offset..];
            const hdr: *align(1) const Notify = @ptrCast(base.ptr);
            const name_end = offset + @sizeOf(Notify) + hdr.name_len;
            if (name_end > node.buffer.len)
                break;
            const name_u8 = node.buffer[offset + @sizeOf(Notify) .. name_end];
            if (name_u8.len % 2 == 0) {
                const name_u16 = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(name_u8)));
                const name = std.unicode.utf16LeToUtf8Alloc(allocator, name_u16) catch break;
                defer allocator.free(name);
                const full = std.fs.path.join(allocator, &.{ node.path, name }) catch name;
                defer if (full.ptr != name.ptr) allocator.free(full);
                if (!self.coveredByOther(full, node.index)) {
                    const kind: ?Event.Kind = switch (hdr.action) {
                        Notify.added => .created,
                        Notify.removed => .deleted,
                        Notify.modified => .modified,
                        Notify.renamed_old, Notify.renamed_new => .renamed,
                        else => null,
                    };
                    if (kind) |k|
                        queueSide(allocator, queued, full, k);
                }
            }
            if (hdr.next == 0)
                break;
            offset += hdr.next;
        }
    }

    fn coveredByOther(self: *WindowsImpl, event_real: []const u8, self_idx: u32) bool {
        var it = self.by_path.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == self_idx)
                continue;
            const prefix = entry.key_ptr.*;
            if (event_real.len <= prefix.len)
                continue;
            if (!std.mem.startsWith(u8, event_real, prefix))
                continue;
            const boundary = event_real[prefix.len];
            if (boundary == std.fs.path.sep or boundary == std.fs.path.sep_windows)
                return true;
        }
        return false;
    }

    fn lock(self: *WindowsImpl) void {
        self.mutex.lockUncancelable(Zune.io());
    }

    fn unlock(self: *WindowsImpl) void {
        self.mutex.unlock(Zune.io());
    }

    fn wake(self: *WindowsImpl) void {
        if (self.wake_fn) |func| {
            if (self.wake_ctx) |ctx|
                func(ctx);
        }
    }

    fn iocpMain(self: *WindowsImpl) void {
        const iocp = self.iocp orelse return;
        while (!self.stop.load(.acquire)) {
            var nbytes: std.os.windows.DWORD = 0;
            var key: std.os.windows.ULONG_PTR = 0;
            var overlapped: ?*WinApi.OVERLAPPED = null;
            const ok = WinApi.GetQueuedCompletionStatus(iocp, &nbytes, &key, &overlapped, WinApi.infinite);
            if (key == 0)
                break;
            if (!ok.toBool() and nbytes == 0) {
                self.onIocp(key, 0);
            } else {
                self.onIocp(key, nbytes);
            }
            self.wake();
        }
        while (true) {
            var nbytes: std.os.windows.DWORD = 0;
            var key: std.os.windows.ULONG_PTR = 0;
            var overlapped: ?*WinApi.OVERLAPPED = null;
            const ok = WinApi.GetQueuedCompletionStatus(iocp, &nbytes, &key, &overlapped, 0);
            if (!ok.toBool() and std.os.windows.GetLastError() == .WAIT_TIMEOUT)
                break;
            if (key == 0)
                continue;
            self.onIocp(key, if (ok.toBool()) nbytes else 0);
        }
    }

    fn openDirHandle(path: []const u8) !std.os.windows.HANDLE {
        const win = std.os.windows;
        var prefixed = try std.Io.Threaded.sliceToPrefixedFileW(Io.Dir.cwd().handle, path, .{});
        const span = prefixed.span();
        var name = prefixed.string();
        var attr = win.OBJECT.ATTRIBUTES{
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(span))
                null
            else
                Io.Dir.cwd().handle,
            .ObjectName = &name,
        };
        var handle: win.HANDLE = undefined;
        var io_status: win.IO_STATUS_BLOCK = undefined;
        const rc = win.ntdll.NtCreateFile(
            &handle,
            .{
                .SPECIFIC = .{
                    .FILE = .{
                        .READ_DATA = true,
                    },
                },
            },
            &attr,
            &io_status,
            null,
            .{},
            .VALID_FLAGS,
            .OPEN,
            .{
                .IO = .ASYNCHRONOUS,
                .DIRECTORY_FILE = true,
                .OPEN_FOR_BACKUP_INTENT = true,
            },
            null,
            0,
        );
        return switch (rc) {
            .SUCCESS => handle,
            .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
            .OBJECT_NAME_INVALID => error.BadPathName,
            .NOT_A_DIRECTORY => error.NotDir,
            .ACCESS_DENIED => error.AccessDenied,
            else => error.Unexpected,
        };
    }
    fn queueSide(allocator: Allocator, queued: *std.ArrayList(Event), path: []const u8, kind: Event.Kind) void {
        const copy = allocator.dupe(u8, path) catch return;
        queued.append(allocator, .{
            .path = copy,
            .kind = kind,
        }) catch allocator.free(copy);
    }
    const WinApi = struct {
        const w = std.os.windows;

        pub const OVERLAPPED = extern struct {
            Internal: usize = 0,
            InternalHigh: usize = 0,
            Offset: u32 = 0,
            OffsetHigh: u32 = 0,
            hEvent: ?w.HANDLE = null,
        };

        pub extern "kernel32" fn ReadDirectoryChangesW(
            hDirectory: w.HANDLE,
            lpBuffer: *anyopaque,
            nBufferLength: w.DWORD,
            bWatchSubtree: w.BOOL,
            dwNotifyFilter: w.DWORD,
            lpBytesReturned: ?*w.DWORD,
            lpOverlapped: *OVERLAPPED,
            lpCompletionRoutine: ?*anyopaque,
        ) callconv(.winapi) w.BOOL;

        pub extern "kernel32" fn CreateIoCompletionPort(
            FileHandle: w.HANDLE,
            ExistingCompletionPort: ?w.HANDLE,
            CompletionKey: w.ULONG_PTR,
            NumberOfConcurrentThreads: w.DWORD,
        ) callconv(.winapi) ?w.HANDLE;

        pub extern "kernel32" fn GetQueuedCompletionStatus(
            CompletionPort: w.HANDLE,
            lpNumberOfBytesTransferred: *w.DWORD,
            lpCompletionKey: *w.ULONG_PTR,
            lpOverlapped: *?*OVERLAPPED,
            dwMilliseconds: w.DWORD,
        ) callconv(.winapi) w.BOOL;

        pub extern "kernel32" fn PostQueuedCompletionStatus(
            CompletionPort: w.HANDLE,
            dwNumberOfBytesTransferred: w.DWORD,
            dwCompletionKey: w.ULONG_PTR,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) w.BOOL;

        pub extern "kernel32" fn CancelIoEx(
            hFile: w.HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) w.BOOL;

        pub const notify_filter: w.DWORD = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40;
        pub const infinite: w.DWORD = 0xFFFFFFFF;
    };
};

pub const UnsupportedImpl = struct {
    pub const Error = error{UnsupportedPlatform};

    pub fn init(_: Allocator) Error!UnsupportedImpl {
        return error.UnsupportedPlatform;
    }

    pub fn shutdown(_: *UnsupportedImpl) void {}

    pub fn deinit(_: *UnsupportedImpl, _: Allocator) void {}

    pub fn add(_: *UnsupportedImpl, _: Allocator, _: []const u8, _: AddOptions) Error!void {
        return error.UnsupportedPlatform;
    }

    pub fn remove(_: *UnsupportedImpl, _: Allocator, _: []const u8) Error!void {
        return error.UnsupportedPlatform;
    }

    pub fn drain(_: *UnsupportedImpl, _: Allocator) Error!void {
        return error.UnsupportedPlatform;
    }

    pub fn pop(_: *UnsupportedImpl) ?Event {
        return null;
    }
};

const NodeSpec = struct {
    path: [:0]u8,
    user: bool,
    recursive: bool,
    owner: ?u32,
    parent: ?u32,
};

fn realPathAlloc(allocator: Allocator, path: []const u8) ![:0]u8 {
    const trimmed = trimPath(path);
    if (trimmed.len == 0)
        return error.FileNotFound;
    return Io.Dir.cwd().realPathFileAlloc(Zune.io(), trimmed, allocator);
}

fn trimPath(path: []const u8) []const u8 {
    if (path.len <= 1)
        return path;
    const sep = std.fs.path.sep;
    var end = path.len;
    while (end > 1 and (path[end - 1] == sep or path[end - 1] == '/')) : (end -= 1) {}
    if (comptime builtin.os.tag == .windows) {
        if (end == 2 and path[1] == ':' and path.len >= 3 and (path[2] == '\\' or path[2] == '/'))
            return path[0..3];
    }
    return path[0..end];
}

fn nodeAt(impl: *Impl, idx: u32) ?*Impl.Node {
    if (idx >= impl.nodes.items.len)
        return null;
    return impl.nodes.items[idx];
}

fn allocSlot(impl: *Impl, allocator: Allocator) !u32 {
    if (impl.free_nodes.pop()) |idx|
        return idx;
    const idx: u32 = @intCast(impl.nodes.items.len);
    try impl.nodes.append(allocator, null);
    return idx;
}

fn releaseSlot(impl: *Impl, allocator: Allocator, idx: u32) void {
    impl.nodes.items[idx] = null;
    impl.free_nodes.append(allocator, idx) catch {};
}

fn unlinkPath(impl: *Impl, node: *Impl.Node) void {
    _ = impl.by_path.remove(node.path);
}

fn hasWatchedParent(impl: *Impl, node: *Impl.Node) bool {
    const parent = std.fs.path.dirname(node.path) orelse return false;
    const idx = impl.by_path.get(parent) orelse return false;
    const parent_node = nodeAt(impl, idx) orelse return false;
    return parent_node.alive;
}

fn queueOwned(impl: *Impl, allocator: Allocator, path: []u8, kind: Event.Kind) void {
    if (impl.events.items.len - impl.head >= MAX_EVENTS) {
        allocator.free(path);
        return;
    }
    impl.events.append(allocator, .{
        .path = path,
        .kind = kind,
    }) catch {
        allocator.free(path);
        return;
    };
}

fn queueCopy(impl: *Impl, allocator: Allocator, path: []const u8, kind: Event.Kind) void {
    const copy = allocator.dupe(u8, path) catch return;
    queueOwned(impl, allocator, copy, kind);
}

fn queueJoined(impl: *Impl, allocator: Allocator, parent: []const u8, name: []const u8, kind: Event.Kind) void {
    if (name.len == 0) {
        queueCopy(impl, allocator, parent, kind);
        return;
    }
    const joined = std.fs.path.join(allocator, &.{ parent, name }) catch return;
    queueOwned(impl, allocator, joined, kind);
}

fn popEvent(impl: *Impl) ?Event {
    if (impl.head >= impl.events.items.len) {
        impl.head = 0;
        impl.events.clearRetainingCapacity();
        return null;
    }
    const ev = impl.events.items[impl.head];
    impl.head += 1;
    if (impl.head > 64 and impl.head * 2 > impl.events.items.len) {
        const live = impl.events.items[impl.head..];
        std.mem.copyForwards(Event, impl.events.items[0..live.len], live);
        impl.events.shrinkRetainingCapacity(live.len);
        impl.head = 0;
    }
    return ev;
}

fn freeEventList(impl: *Impl, allocator: Allocator) void {
    for (impl.events.items[impl.head..]) |ev|
        allocator.free(ev.path);
    impl.events.deinit(allocator);
}

fn emitSelf(impl: *Impl, allocator: Allocator, idx: u32, kind: Event.Kind) void {
    const node = nodeAt(impl, idx) orelse return;
    if (!node.alive or !node.user)
        return;
    if (node.death_emitted or node.suppress_death)
        return;
    if (hasWatchedParent(impl, node))
        return;
    if (kind == .deleted)
        node.death_emitted = true;
    queueCopy(impl, allocator, node.path, kind);
}

fn findUser(impl: *Impl, allocator: Allocator, path: []const u8) !*Impl.Node {
    const trimmed = trimPath(path);
    if (trimmed.len == 0)
        return error.NotWatching;
    if (impl.by_path.get(trimmed)) |idx| {
        const found = nodeAt(impl, idx) orelse return error.NotWatching;
        if (!found.user or !found.alive)
            return error.NotWatching;
        return found;
    }
    const real = realPathAlloc(allocator, trimmed) catch return error.NotWatching;
    defer allocator.free(real);
    const idx = impl.by_path.get(real) orelse return error.NotWatching;
    const found = nodeAt(impl, idx) orelse return error.NotWatching;
    if (!found.user or !found.alive)
        return error.NotWatching;
    return found;
}

fn addUser(impl: *Impl, allocator: Allocator, path: []const u8, opts: AddOptions) !void {
    try impl.drain(allocator);

    const real = try realPathAlloc(allocator, path);
    _ = try addNode(impl, allocator, .{
        .path = real,
        .user = true,
        .recursive = opts.recursive,
        .owner = null,
        .parent = null,
    });
}

fn removeUser(impl: *Impl, allocator: Allocator, path: []const u8) !void {
    try impl.drain(allocator);

    const found = try findUser(impl, allocator, path);
    dropRegistration(impl, allocator, found.owner);
}

fn addNode(impl: *Impl, allocator: Allocator, spec: NodeSpec) !u32 {
    if (impl.by_path.get(spec.path)) |idx| {
        const existing = nodeAt(impl, idx);
        allocator.free(spec.path);
        if (spec.user or existing == null or !existing.?.alive)
            return error.AlreadyWatching;
        return idx;
    }

    const node = allocator.create(Impl.Node) catch |err| {
        allocator.free(spec.path);
        return err;
    };
    errdefer allocator.destroy(node);

    const idx = allocSlot(impl, allocator) catch |err| {
        allocator.free(spec.path);
        return err;
    };
    errdefer releaseSlot(impl, allocator, idx);

    node.* = .{
        .path = spec.path,
        .index = idx,
        .owner = spec.owner orelse idx,
        .parent = spec.parent,
        .user = spec.user,
        .recursive = spec.recursive,
    };
    impl.nodes.items[idx] = node;
    errdefer allocator.free(node.path);

    impl.by_path.put(allocator, node.path, idx) catch |err| return err;
    errdefer _ = impl.by_path.remove(node.path);

    try impl.arm(allocator, node);
    node.alive = true;

    switch (comptime builtin.os.tag) {
        .linux,
        .macos,
        .ios,
        .tvos,
        .watchos,
        .visionos,
        .freebsd,
        .openbsd,
        .netbsd,
        .dragonfly,
        => if (node.recursive)
            walkChildren(impl, allocator, idx) catch {},
        else => {},
    }
    return idx;
}

fn walkChildren(impl: *Impl, allocator: Allocator, idx: u32) !void {
    const node = nodeAt(impl, idx) orelse return;

    var dir = try Io.Dir.cwd().openDir(Zune.io(), node.path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(Zune.io());

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(Zune.io())) |entry| {
        if (entry.kind != .directory)
            continue;
        addChild(impl, allocator, idx, entry.path);
    }
}

fn addChild(impl: *Impl, allocator: Allocator, parent_idx: u32, name: []const u8) void {
    const parent = nodeAt(impl, parent_idx) orelse return;
    if (!parent.alive or !parent.recursive)
        return;

    const joined = std.fs.path.joinZ(allocator, &.{ parent.path, name }) catch return;
    _ = addNode(impl, allocator, .{
        .path = joined,
        .user = false,
        .recursive = true,
        .owner = parent.owner,
        .parent = parent_idx,
    }) catch {};
}

fn dropRegistration(impl: *Impl, allocator: Allocator, owner: u32) void {
    for (impl.nodes.items) |n| {
        const node = n orelse continue;
        if (node.index != owner and node.owner != owner)
            continue;
        node.suppress_death = true;

        destroyOwned(impl, allocator, node, true);
    }
}

fn destroyOwned(impl: *Impl, allocator: Allocator, node: *Impl.Node, rm_os: bool) void {
    if (!node.alive)
        return;
    node.alive = false;

    unlinkPath(impl, node);

    impl.disarm(node, rm_os);

    freeOwned(impl, allocator, node);
}

fn freeOwned(impl: *Impl, allocator: Allocator, node: *Impl.Node) void {
    impl.freeExtra(allocator, node);

    const idx = node.index;

    allocator.free(node.path);

    releaseSlot(impl, allocator, idx);

    allocator.destroy(node);
}

fn deinitOwned(impl: *Impl, allocator: Allocator) void {
    for (impl.nodes.items) |ptr| {
        const node = ptr orelse continue;
        if (node.alive) {
            node.alive = false;
            unlinkPath(impl, node);
            impl.disarm(node, true);
        }
        freeOwned(impl, allocator, node);
    }
    impl.nodes.deinit(allocator);
    impl.free_nodes.deinit(allocator);
    impl.by_path.deinit(allocator);
    freeEventList(impl, allocator);
}

const Fixture = struct {
    temporary: std.testing.TmpDir,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var self: Fixture = .{
            .temporary = std.testing.tmpDir(.{ .access_sub_paths = true, .iterate = true }),
        };
        errdefer self.deinit();
        try self.temporary.dir.createDir(Zune.io(), "fs-watch-test", .default_dir);
        self.root_len = try self.temporary.dir.realPathFile(Zune.io(), "fs-watch-test", &self.buf);
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.temporary.cleanup();
    }

    fn root(self: *const Fixture) []const u8 {
        return self.buf[0..self.root_len];
    }

    fn dir(self: *Fixture) Io.Dir {
        return self.temporary.dir;
    }
};

fn component(path: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, path, name))
        return true;
    if (!std.mem.endsWith(u8, path, name))
        return false;
    if (path.len == name.len)
        return true;
    const prev = path[path.len - name.len - 1];
    return prev == '/' or prev == '\\';
}

fn takeKind(watcher: *Watcher, allocator: Allocator, name: []const u8, kind: Event.Kind) !void {
    var n: u32 = 0;
    while (n < 80) : (n += 1) {
        try watcher.drain(allocator);
        if (watcher.pop()) |ev| {
            defer ev.deinit(allocator);
            if (!std.fs.path.isAbsolute(ev.path))
                return error.ExpectedAbsolute;
            if (ev.kind == .metadata)
                continue;
            if (ev.kind == kind and component(ev.path, name))
                return;
            std.log.warn("skip {s} {s}, waiting for {s} {s}", .{ @tagName(ev.kind), ev.path, @tagName(kind), name });
            continue;
        }
        try std.Io.sleep(Zune.io(), .fromMilliseconds(20), .awake);
    }
    return error.ExpectedEvent;
}

fn platformWatchEvents() !void {
    const allocator = std.testing.allocator;
    var fix = try Fixture.init();
    defer fix.deinit();
    const root = fix.root();

    var watcher = try Watcher.init(allocator);
    defer watcher.deinit(allocator);
    try watcher.add(allocator, root, .{});

    var loop: zio.ev.Loop = undefined;
    try loop.init(.{ .allocator = allocator });
    defer loop.deinit();

    var ready = std.atomic.Value(bool).init(false);
    var poller = zio.ev.PipePoll.init(watcher.pollFd(), .read);
    poller.c.userdata = &ready;
    poller.c.callback = struct {
        fn cb(_: *zio.ev.Loop, completion: *zio.ev.Completion) void {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(completion.userdata));
            flag.store(true, .release);
        }
    }.cb;
    loop.add(&poller.c);
    errdefer if (!ready.load(.acquire)) {
        loop.cancel(&poller.c);
        loop.poll(.fromMilliseconds(50)) catch {};
    };

    const file = try fix.dir().createFile(Zune.io(), "fs-watch-test/test.txt", .{});
    defer file.close(Zune.io());

    var spins: u32 = 0;
    while (!ready.load(.acquire) and spins < 30) : (spins += 1) {
        try loop.poll(.fromMilliseconds(100));
    }
    if (!ready.load(.acquire)) return error.Timeout;

    try takeKind(&watcher, allocator, "test.txt", .created);

    try file.writePositionalAll(Zune.io(), "Hello, world!\n", 0);
    try file.sync(Zune.io());
    try takeKind(&watcher, allocator, "test.txt", .modified);

    try fix.dir().deleteFile(Zune.io(), "fs-watch-test/test.txt");
    try takeKind(&watcher, allocator, "test.txt", .deleted);
}

test "Platform Watch events" {
    if (comptime builtin.os.tag == .linux) try platformWatchEvents();
}

fn platformWatchIndependentChild() !void {
    const allocator = std.testing.allocator;
    var fix = try Fixture.init();
    defer fix.deinit();
    try fix.dir().createDir(Zune.io(), "fs-watch-test/foo", .default_dir);
    const root = fix.root();
    const foo = try std.fs.path.join(allocator, &.{ root, "foo" });
    defer allocator.free(foo);

    var watcher = try Watcher.init(allocator);
    defer watcher.deinit(allocator);
    try watcher.add(allocator, foo, .{});
    try watcher.add(allocator, root, .{});
    try std.testing.expectError(error.AlreadyWatching, watcher.add(allocator, foo, .{}));

    try watcher.remove(allocator, root);
    const file = try fix.dir().createFile(Zune.io(), "fs-watch-test/foo/a.txt", .{});
    file.close(Zune.io());
    try takeKind(&watcher, allocator, "a.txt", .created);

    try watcher.remove(allocator, foo);
    try std.testing.expectError(error.NotWatching, watcher.remove(allocator, foo));
    try std.testing.expectError(error.NotWatching, watcher.remove(allocator, root));
}

test "Platform Watch independent child" {
    if (comptime builtin.os.tag == .linux) try platformWatchIndependentChild();
}

fn platformWatchDeleteTree() !void {
    const allocator = std.testing.allocator;
    var fix = try Fixture.init();
    defer fix.deinit();
    try fix.dir().createDir(Zune.io(), "fs-watch-test/foo", .default_dir);
    const root = fix.root();
    const foo = try std.fs.path.join(allocator, &.{ root, "foo" });
    defer allocator.free(foo);

    var watcher = try Watcher.init(allocator);
    defer watcher.deinit(allocator);
    try watcher.add(allocator, root, .{});
    try watcher.add(allocator, foo, .{});

    try fix.dir().deleteTree(Zune.io(), "fs-watch-test");
    try takeKind(&watcher, allocator, "foo", .deleted);
    try takeKind(&watcher, allocator, "fs-watch-test", .deleted);
    try std.testing.expectError(error.NotWatching, watcher.remove(allocator, root));
    try std.testing.expectError(error.NotWatching, watcher.remove(allocator, foo));

    try fix.dir().createDir(Zune.io(), "fs-watch-test", .default_dir);
    try watcher.add(allocator, root, .{});
}

test "Platform Watch delete tree" {
    if (comptime builtin.os.tag == .linux) try platformWatchDeleteTree();
}

fn platformWatchRecursive() !void {
    const allocator = std.testing.allocator;
    var fix = try Fixture.init();
    defer fix.deinit();
    try fix.dir().createDir(Zune.io(), "fs-watch-test/sub", .default_dir);
    const root = fix.root();

    var watcher = try Watcher.init(allocator);
    defer watcher.deinit(allocator);
    try watcher.add(allocator, root, .{ .recursive = true });

    const existing = try fix.dir().createFile(Zune.io(), "fs-watch-test/sub/old.txt", .{});
    existing.close(Zune.io());
    try takeKind(&watcher, allocator, "old.txt", .created);

    try fix.dir().createDir(Zune.io(), "fs-watch-test/sub2", .default_dir);
    try watcher.drain(allocator);
    const nested = try fix.dir().createFile(Zune.io(), "fs-watch-test/sub2/nested.txt", .{});
    nested.close(Zune.io());
    try takeKind(&watcher, allocator, "nested.txt", .created);
}

test "Platform Watch recursive" {
    if (comptime builtin.os.tag == .linux) try platformWatchRecursive();
}
