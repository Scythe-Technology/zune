const std = @import("std");
const builtin = @import("builtin");

const MAX_EVENTS = 1024 * 2;

const WatchEvent = struct {
    name: []const u8,
    event: Event,

    pub const Event = packed struct {
        created: bool = false,
        delete: bool = false,
        modify: bool = false,
        rename: bool = false,
        move_to: bool = false,
        move_from: bool = false,
        metadata: bool = false,
    };
};

pub const WatchInfo = struct {
    list: std.ArrayList(WatchEvent),

    pub fn deinit(self: WatchInfo, allocator: std.mem.Allocator) void {
        for (self.list.items) |e| allocator.free(e.name);
        allocator.free(self.list.allocatedSlice());
    }
};

const InotifyAttributes = struct {
    fd: ?i32 = null,
    fds: [1]std.posix.pollfd = undefined,

    const InotifyEventSize = @sizeOf(INotifyEvent);
    pub const INotifyEvent = extern struct {
        wd: c_int,
        mask: u32,
        cookie: u32,
        name_len: u32,

        pub fn name(this: *const INotifyEvent) [*:0]u8 {
            return @as([*:0]u8, @ptrFromInt(@intFromPtr(&this.name_len) + @sizeOf(u32)))[0.. :0];
        }
    };

    pub fn deinit(self: *InotifyAttributes) void {
        if (self.fd) |fd|
            std.posix.close(fd);
    }
};

const KqueueAttributes = struct {
    const kevent = std.c.Kevent;

    fd: ?i32 = null,
    dir: ?std.fs.Dir = null,
    named_fds: std.AutoArrayHashMapUnmanaged(usize, []const u8) = .empty,
    fds: std.StringArrayHashMapUnmanaged(FdInfo) = .empty,

    const FdInfo = struct {
        handle: usize,
        kind: std.fs.File.Kind,
    };

    const FileDifference = struct {
        name: []const u8,
        state: enum {
            created,
            deleted,
            modified,
            renamed,
        },

        fn deinit(self: *FileDifference, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
        }
    };

    pub fn scanDirectory(self: *KqueueAttributes, allocator: std.mem.Allocator) ![]FileDifference {
        const dir = &(self.dir orelse return error.WatcherNotStarted);

        var diff: std.ArrayList(FileDifference) = .empty;
        errdefer diff.deinit(allocator);
        errdefer for (diff.items) |item| allocator.free(item.name);

        {
            var named_fds: std.AutoArrayHashMapUnmanaged(usize, []const u8) = .empty;
            var temp_fds: std.StringArrayHashMapUnmanaged(FdInfo) = .empty;
            errdefer named_fds.deinit(allocator);
            errdefer temp_fds.deinit(allocator);
            var fds = self.fds;
            {
                errdefer for (temp_fds.keys()) |key| if (fds.get(key) == null) allocator.free(key);

                {
                    const key = fds.keys()[0];
                    const value = fds.values()[0];
                    try temp_fds.put(allocator, key, value);
                    try named_fds.put(allocator, value.handle, key);
                }

                var changes: u8 = 0;
                var changelist: [64]KqueueAttributes.kevent = std.mem.zeroes([64]KqueueAttributes.kevent);

                var iter = dir.iterate();
                while (try iter.next()) |entry| {
                    const exists = fds.getEntry(entry.name) orelse {
                        if (entry.kind == .file) {
                            const copy_path = try allocator.dupe(u8, entry.name);
                            errdefer allocator.free(copy_path);
                            const sub_file = try dir.openFile(entry.name, .{});

                            changelist[changes] = .{
                                .data = 0,
                                .udata = @intCast(sub_file.handle),
                                .ident = @intCast(sub_file.handle),
                                .filter = std.c.EVFILT.VNODE,
                                .flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE,
                                .fflags = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.ATTRIB | std.c.NOTE.RENAME | std.c.NOTE.LINK,
                            };
                            changes += 1;

                            if (changes == changelist.len) {
                                _ = std.posix.system.kevent(self.fd.?, &changelist, changes, &changelist, 0, null);
                                changes = 0;
                            }

                            try temp_fds.put(allocator, copy_path, .{
                                .handle = @intCast(sub_file.handle),
                                .kind = .file,
                            });
                            try named_fds.put(allocator, @intCast(sub_file.handle), copy_path);
                        } else if (entry.kind == .directory) {
                            const copy_path = try allocator.dupe(u8, entry.name);
                            errdefer allocator.free(copy_path);
                            const sub_dir = try dir.openDir(entry.name, .{
                                .iterate = false,
                            });
                            changelist[changes] = .{
                                .data = 0,
                                .udata = @intCast(sub_dir.fd),
                                .ident = @intCast(sub_dir.fd),
                                .filter = std.c.EVFILT.VNODE,
                                .flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE,
                                .fflags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.ATTRIB,
                            };
                            changes += 1;

                            if (changes == changelist.len) {
                                _ = std.posix.system.kevent(self.fd.?, &changelist, changes, &changelist, 0, null);
                                changes = 0;
                            }

                            try temp_fds.put(allocator, copy_path, .{
                                .handle = @intCast(sub_dir.fd),
                                .kind = .directory,
                            });
                            try named_fds.put(allocator, @intCast(sub_dir.fd), copy_path);
                        }
                        continue;
                    };
                    try temp_fds.put(allocator, exists.key_ptr.*, exists.value_ptr.*);
                }

                if (changes > 0) {
                    _ = std.posix.system.kevent(self.fd.?, &changelist, changes, &changelist, 0, null);
                    changes = 0;
                }

                self.fds = temp_fds;
                self.named_fds.deinit(allocator);
                self.named_fds = named_fds;
            }
            defer fds.deinit(allocator);
            defer for (fds.keys()) |key| if (temp_fds.get(key) == null) allocator.free(key);

            var fds_iter = fds.iterator();
            while (fds_iter.next()) |entry| {
                if (temp_fds.get(entry.key_ptr.*) != null)
                    continue;
                const name = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(name);
                try diff.append(allocator, .{
                    .name = name,
                    .state = .deleted,
                });
            }

            var temp_fds_iter = temp_fds.iterator();
            while (temp_fds_iter.next()) |entry| {
                if (fds.get(entry.key_ptr.*) != null)
                    continue;
                const name = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(name);
                try diff.append(allocator, .{
                    .name = name,
                    .state = .created,
                });
            }
        }

        return diff.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *KqueueAttributes, allocator: std.mem.Allocator) void {
        if (self.fd) |fd|
            std.posix.close(fd);
        if (self.dir) |*dir|
            dir.close();
        for (self.fds.keys()) |name|
            allocator.free(name);
        for (self.fds.values(), 0..) |info, i| {
            if (i > 0)
                std.posix.close(@intCast(info.handle));
        }
        self.fds.deinit(allocator);
        self.named_fds.deinit(allocator);
    }
};

const IOCPAttributes = struct {
    handle: ?std.os.windows.HANDLE = null,
    iocp: ?std.os.windows.HANDLE = null,
    overlapped: std.os.windows.OVERLAPPED = std.mem.zeroes(std.os.windows.OVERLAPPED),
    buf: [64 * 1024]u8 align(@alignOf(std.os.windows.FILE_NOTIFY_INFORMATION)) = undefined,
    active: bool = true,
    monitoring: bool = false,

    pub const Action = enum(std.os.windows.DWORD) {
        Added = std.os.windows.FILE_ACTION_ADDED,
        Removed = std.os.windows.FILE_ACTION_REMOVED,
        Modified = std.os.windows.FILE_ACTION_MODIFIED,
        RenamedOld = std.os.windows.FILE_ACTION_RENAMED_OLD_NAME,
        RenamedNew = std.os.windows.FILE_ACTION_RENAMED_NEW_NAME,
    };

    pub fn monitor(self: *IOCPAttributes) !void {
        const handle = self.handle orelse return error.WatcherNotStarted;
        if (self.monitoring)
            return;
        if (!self.active)
            return;
        if (std.os.windows.kernel32.ReadDirectoryChangesW(
            handle,
            &self.buf,
            self.buf.len,
            0,
            .{
                .creation = true,
                .dir_name = true,
                .file_name = true,
                .last_write = true,
            },
            null,
            &self.overlapped,
            null,
        ) == 0) {
            const err = std.os.windows.kernel32.GetLastError();
            std.debug.print("[Win32] Failed to start watcher: {s}\n", .{@tagName(err)});
            switch (err) {
                .PRIVILEGE_NOT_HELD, .ACCESS_DENIED => return error.AccessDenied,
                .INVALID_PARAMETER => @panic("[ReadDirectoryChangesW] Invalid parameter"),
                else => return error.UnknownError,
            }
        }
        self.monitoring = true;
    }

    pub fn deinit(self: *IOCPAttributes) void {
        if (self.handle) |handle|
            _ = std.os.windows.kernel32.CloseHandle(handle);
        if (self.iocp) |iocp|
            _ = std.os.windows.kernel32.CloseHandle(iocp);
    }
};

pub const FileSystemWatcher = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,

    backend: union(enum) {
        inotify: InotifyAttributes,
        kqueue: KqueueAttributes,
        iocp: IOCPAttributes,
    },

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, pathname: []const u8) FileSystemWatcher {
        return FileSystemWatcher{
            .allocator = allocator,
            .dir = dir,
            .path = pathname,
            .backend = switch (comptime builtin.os.tag) {
                .ios, .macos, .tvos, .visionos, .watchos => .{ .kqueue = .{} },
                .windows => .{ .iocp = .{} },
                .linux => .{ .inotify = .{} },
                .freebsd, .openbsd, .netbsd, .dragonfly => .{ .kqueue = .{} },
                else => @compileError("Unsupported platform"),
            },
        };
    }

    pub fn start(self: *FileSystemWatcher) !void {
        switch (comptime builtin.os.tag) {
            .linux => try self.startInotify(),
            .ios, .macos, .tvos, .visionos, .watchos => try self.startKqueue(),
            .freebsd, .openbsd, .netbsd, .dragonfly => try self.startKqueue(),
            .windows => try self.startIOCP(),
            else => return error.UnsupportedPlatform,
        }
    }

    pub fn next(self: *FileSystemWatcher) !?WatchInfo {
        switch (comptime builtin.os.tag) {
            .linux => return self.nextInotify(),
            .ios, .macos, .tvos, .visionos, .watchos => return self.nextKqueue(),
            .freebsd, .openbsd, .netbsd, .dragonfly => return self.nextKqueue(),
            .windows => return self.nextIOCP(),
            else => return error.UnsupportedPlatform,
        }
    }

    fn nextInotify(self: *FileSystemWatcher) !?WatchInfo {
        if (comptime builtin.os.tag != .linux)
            @compileError("Cannot call nextLinux on non-Linux platforms");

        const fd = self.backend.inotify.fd orelse return error.WatcherNotStarted;
        const nums = try std.posix.poll(&self.backend.inotify.fds, 1000);
        if (nums == 0)
            return null;
        if (nums < 0)
            std.debug.panic("Bad poll (2)", .{});

        var buffer: [8096]u8 = undefined;
        const bytes_read = std.posix.system.read(fd, @ptrCast(@alignCast(&buffer)), 8096);
        if (bytes_read == 0)
            return null;

        var watch_info: WatchInfo = .{
            .list = .empty,
        };
        errdefer watch_info.deinit(self.allocator);

        var i: u32 = 0;
        while (i < bytes_read) : (i += InotifyAttributes.InotifyEventSize) {
            const event: *InotifyAttributes.INotifyEvent = @ptrCast(@alignCast(buffer[i..][0..InotifyAttributes.InotifyEventSize]));
            i += event.name_len;

            try watch_info.list.append(self.allocator, .{
                .event = WatchEvent.Event{
                    .created = (event.mask & std.os.linux.IN.CREATE) > 0,
                    .delete = (event.mask & std.os.linux.IN.DELETE_SELF) > 0 or (event.mask & std.os.linux.IN.DELETE) > 0,
                    .modify = (event.mask & std.os.linux.IN.MODIFY) > 0,
                    .rename = (event.mask & std.os.linux.IN.MOVE_SELF) > 0,
                    .move_to = (event.mask & std.os.linux.IN.MOVED_TO) > 0,
                    .move_from = (event.mask & std.os.linux.IN.MOVED_FROM) > 0,
                },
                .name = try self.allocator.dupe(u8, std.mem.span(event.name())),
            });
            if (watch_info.list.items.len >= MAX_EVENTS)
                break;
        }

        return watch_info;
    }

    fn nextKqueue(self: *FileSystemWatcher) !?WatchInfo {
        if (comptime !builtin.os.tag.isBSD())
            @compileError("Cannot call nextKqueue on non-BSD platforms");

        const fd = self.backend.kqueue.fd orelse return error.WatcherNotStarted;

        var list_arr: [128]KqueueAttributes.kevent = std.mem.zeroes([128]KqueueAttributes.kevent);

        var timespec = std.posix.timespec{ .sec = 1, .nsec = 0 };
        const count = std.posix.system.kevent(fd, &list_arr, 0, &list_arr, 128, &timespec);
        if (count == 0)
            return null;
        if (count < 0)
            std.debug.panic("Bad kevent", .{});

        var watch_info: WatchInfo = .{
            .list = .empty,
        };
        errdefer watch_info.deinit(self.allocator);

        var root = false;
        var changes = list_arr[0..@as(usize, @intCast(count))];
        if (changes.len > 0) {
            try watch_info.list.ensureTotalCapacity(self.allocator, @intCast(count));
            for (changes[0..]) |event| {
                if (watch_info.list.items.len >= MAX_EVENTS)
                    break;
                if (event.udata == 0) {
                    if (root)
                        continue;
                    root = true;
                    const scandiff = try self.backend.kqueue.scanDirectory(self.allocator);
                    defer self.allocator.free(scandiff);
                    defer for (scandiff) |change| self.allocator.free(change.name);
                    for (scandiff) |change| {
                        if (change.state != .created and change.state != .deleted)
                            continue;
                        watch_info.list.appendAssumeCapacity(.{
                            .event = WatchEvent.Event{
                                .created = change.state == .created,
                                .delete = change.state == .deleted,
                            },
                            .name = try self.allocator.dupe(u8, change.name),
                        });
                        if (watch_info.list.items.len >= MAX_EVENTS)
                            break;
                    }
                    continue;
                }
                const name = self.backend.kqueue.named_fds.get(event.udata) orelse continue;
                if ((event.fflags & std.c.NOTE.DELETE) != 0)
                    continue;
                watch_info.list.appendAssumeCapacity(.{
                    .event = .{
                        .modify = (event.fflags & std.c.NOTE.WRITE) != 0,
                        .rename = (event.fflags & (std.c.NOTE.RENAME | std.c.NOTE.LINK)) != 0,
                        .metadata = (event.fflags & std.c.NOTE.ATTRIB) != 0,
                    },
                    .name = try self.allocator.dupe(u8, name),
                });
            }
        }

        return watch_info;
    }

    fn nextIOCP(self: *FileSystemWatcher) !?WatchInfo {
        if (comptime builtin.os.tag != .windows)
            @compileError("Cannot call nextIOCP on non-Windows platforms");

        const iocp = self.backend.iocp.iocp orelse return error.WatcherNotStarted;
        if (!self.backend.iocp.active)
            return error.WatcherNotActive;

        if (!self.backend.iocp.monitoring)
            try self.backend.iocp.monitor();

        var nbytes: std.os.windows.DWORD = 0;
        var key: std.os.windows.ULONG_PTR = 0;
        var overlapped: ?*std.os.windows.OVERLAPPED = null;
        while (true) {
            const rc = std.os.windows.kernel32.GetQueuedCompletionStatus(iocp, &nbytes, &key, &overlapped, 1000);
            if (rc == 0) {
                const err = std.os.windows.kernel32.GetLastError();
                if (err == .TIMEOUT or err == .WAIT_TIMEOUT) return null else {
                    std.debug.print("[Win32] Status failed: {s}\n", .{@tagName(err)});
                    return error.UnknownError;
                }
            }

            self.backend.iocp.monitoring = false;

            if (overlapped) |ptr| {
                if (ptr != &self.backend.iocp.overlapped)
                    continue;
                if (nbytes == 0) {
                    self.backend.iocp.active = false;
                    return error.Shutdown;
                }
                var watch_info: WatchInfo = .{
                    .list = .empty,
                };
                errdefer watch_info.deinit(self.allocator);

                var n = true;
                var offset: usize = 0;
                while (n) {
                    const info: *std.os.windows.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(self.backend.iocp.buf[offset..].ptr));
                    const name_ptr: [*]u16 = @ptrCast(@alignCast(self.backend.iocp.buf[offset + @sizeOf(std.os.windows.FILE_NOTIFY_INFORMATION) ..].ptr));
                    const filename: []u16 = name_ptr[0 .. info.FileNameLength / @sizeOf(u16)];

                    const name = try std.unicode.utf16LeToUtf8Alloc(self.allocator, filename);
                    errdefer self.allocator.free(name);

                    const action: IOCPAttributes.Action = @enumFromInt(info.Action);

                    if (info.NextEntryOffset == 0)
                        n = false
                    else
                        offset += @as(usize, info.NextEntryOffset);

                    try watch_info.list.append(self.allocator, .{
                        .event = WatchEvent.Event{
                            .created = action == .Added,
                            .delete = action == .Removed,
                            .modify = action == .Modified,
                            .rename = action == .RenamedOld or action == .RenamedNew,
                        },
                        .name = name,
                    });
                    if (watch_info.list.items.len >= MAX_EVENTS)
                        break;
                }

                return watch_info;
            } else {
                return error.INVAL;
            }
        }
    }

    fn startInotify(self: *FileSystemWatcher) !void {
        const fd = try std.posix.inotify_init1(std.os.linux.IN.CLOEXEC);
        errdefer std.posix.close(fd);

        const full_path = try self.dir.realpathAlloc(self.allocator, self.path);
        defer self.allocator.free(full_path);

        const wd = try std.posix.inotify_add_watch(
            fd,
            full_path,
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO | std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVE_SELF,
        );

        if (wd < 0)
            return error.InotifyAddWatchFailed;

        self.backend.inotify.fd = fd;
        self.backend.inotify.fds[0] = std.posix.pollfd{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR,
            .revents = 0,
        };
    }

    fn startKqueue(self: *FileSystemWatcher) !void {
        const fd = try std.posix.kqueue();
        if (fd == 0)
            return error.KQueueError;
        errdefer std.posix.close(fd);

        var dir = try self.dir.openDir(self.path, .{
            .access_sub_paths = false,
            .iterate = true,
        });
        errdefer dir.close();

        const copy_path = try self.allocator.dupe(u8, self.path);
        errdefer self.allocator.free(copy_path);

        try self.backend.kqueue.fds.put(self.allocator, copy_path, .{
            .handle = @intCast(dir.fd),
            .kind = .directory,
        });
        errdefer std.debug.assert(self.backend.kqueue.fds.orderedRemove(copy_path));
        try self.backend.kqueue.named_fds.put(self.allocator, @intCast(dir.fd), copy_path);
        errdefer std.debug.assert(self.backend.kqueue.named_fds.orderedRemove(@intCast(dir.fd)));

        var kevent: [1]KqueueAttributes.kevent = .{
            .{
                .data = 0,
                .udata = 0,
                .ident = @intCast(dir.fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE,
                .fflags = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.RENAME | std.c.NOTE.EXTEND | std.c.NOTE.ATTRIB,
            },
        };

        _ = std.posix.system.kevent(fd, &kevent, 1, &kevent, 0, null);

        self.backend.kqueue.fd = fd;
        self.backend.kqueue.dir = dir;
        errdefer self.backend.kqueue.dir = null;
        errdefer self.backend.kqueue.fd = null;

        self.allocator.free(try self.backend.kqueue.scanDirectory(self.allocator));
    }

    fn startIOCP(self: *FileSystemWatcher) !void {
        const wpath = try std.os.windows.sliceToPrefixedFileW(self.dir.fd, self.path);

        const ptr = wpath.span().ptr;
        const path_len_bytes = @as(u16, @intCast(std.mem.sliceTo(ptr, 0).len * 2));

        var nt_name = std.os.windows.UNICODE_STRING{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @constCast(ptr),
        };
        var attr = std.os.windows.OBJECT_ATTRIBUTES{
            .Length = @sizeOf(std.os.windows.OBJECT_ATTRIBUTES),
            .RootDirectory = self.dir.fd,
            .Attributes = 0,
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        var handle: std.os.windows.HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
        var io: std.os.windows.IO_STATUS_BLOCK = undefined;

        // This code is based on https://github.com/oven-sh/bun/blob/c2c204807242340b7dfe6537d84771bdff7bb85e/src/watcher.zig#L335
        const rc = std.os.windows.ntdll.NtCreateFile(
            &handle,
            std.os.windows.FILE_LIST_DIRECTORY,
            &attr,
            &io,
            null,
            0,
            std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE | std.os.windows.FILE_SHARE_DELETE,
            std.os.windows.FILE_OPEN,
            std.os.windows.FILE_DIRECTORY_FILE | std.os.windows.FILE_OPEN_FOR_BACKUP_INTENT,
            null,
            0,
        );
        if (rc != .SUCCESS) {
            std.debug.print("[Win32] Failed to open directory for watching: {s}\n", .{@tagName(rc)});
            return error.CreateFileFailed;
        }
        errdefer _ = std.os.windows.CloseHandle(handle);

        const iocp = try std.os.windows.CreateIoCompletionPort(handle, null, 0, 1);
        errdefer _ = std.os.windows.CloseHandle(iocp);

        self.backend.iocp.handle = handle;
        self.backend.iocp.iocp = iocp;

        try self.backend.iocp.monitor();
    }

    pub fn deinit(self: *FileSystemWatcher) void {
        switch (comptime builtin.os.tag) {
            .linux => self.backend.inotify.deinit(),
            .ios, .macos, .tvos, .visionos, .watchos => self.backend.kqueue.deinit(self.allocator),
            else => {},
        }
    }
};

test "Platform Watch" {
    const allocator = std.testing.allocator;

    var temporaryDir = std.testing.tmpDir(.{
        .access_sub_paths = true,
    });
    defer temporaryDir.cleanup();

    const tempDir = temporaryDir.dir;

    try tempDir.makeDir("fs-watch-test");

    var watcher = FileSystemWatcher.init(allocator, tempDir, "fs-watch-test");
    defer watcher.deinit();

    try watcher.start();

    {
        if (try watcher.next()) |i| {
            i.deinit(watcher.allocator);
            return error.UnexpectedEvent;
        }
    }

    { // Create file
        const file = try tempDir.createFile("fs-watch-test/test.txt", .{});
        defer file.close();

        {
            var info = try watcher.next() orelse return error.ExpectedEvent;
            defer info.deinit(watcher.allocator);
            try std.testing.expectEqual(1, info.list.items.len);
            try std.testing.expectEqualStrings("test.txt", info.list.items[0].name);
            try std.testing.expect(info.list.items[0].event.created);
            try std.testing.expect(!info.list.items[0].event.delete);
            try std.testing.expect(!info.list.items[0].event.modify);
            try std.testing.expect(!info.list.items[0].event.rename);
            try std.testing.expect(!info.list.items[0].event.move_to);
        }

        // Modify file
        try file.writeAll("Hello, world!\n");
        try file.sync();

        {
            var info = try watcher.next() orelse return error.ExpectedEvent;
            defer info.deinit(watcher.allocator);
            try std.testing.expectEqual(1, info.list.items.len);
            try std.testing.expectEqualStrings("test.txt", info.list.items[0].name);
            try std.testing.expect(!info.list.items[0].event.created);
            try std.testing.expect(!info.list.items[0].event.delete);
            try std.testing.expect(info.list.items[0].event.modify);
            try std.testing.expect(!info.list.items[0].event.rename);
            try std.testing.expect(!info.list.items[0].event.move_to);
        }
    }

    // Delete file
    try tempDir.deleteFile("fs-watch-test/test.txt");

    {
        var info = try watcher.next() orelse return error.ExpectedEvent;
        defer info.deinit(watcher.allocator);
        try std.testing.expectEqual(1, info.list.items.len);
        try std.testing.expectEqualStrings("test.txt", info.list.items[0].name);
        try std.testing.expect(!info.list.items[0].event.created);
        try std.testing.expect(info.list.items[0].event.delete);
        try std.testing.expect(!info.list.items[0].event.modify);
        try std.testing.expect(!info.list.items[0].event.rename);
        try std.testing.expect(!info.list.items[0].event.move_to);
    }
}
