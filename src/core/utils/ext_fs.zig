const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const linux = std.os.linux;
const windows = std.os.windows;

const File = std.fs.File;
const Mode = std.fs.File.Mode;
const Kind = std.fs.File.Kind;

const ChmodError = std.fs.File.ChmodError;

pub const SetPermissionsError = ChmodError;

/// Cross-platform representation of permissions on a file.
/// The `readonly` and `setReadonly` are the only methods available across all platforms.
/// Platform-specific functionality is available through the `inner` field.
pub const Permissions = std.fs.File.Permissions;
pub const PermissionsWindows = std.fs.File.PermissionsWindows;
pub const PermissionsUnix = std.fs.File.PermissionsUnix;

/// Sets permissions according to the provided `Permissions` struct.
/// This method is *NOT* available on WASI
pub fn setPermissions(self: File, permissions: Permissions) SetPermissionsError!void {
    switch (builtin.os.tag) {
        .windows => {
            var io_status_block: windows.IO_STATUS_BLOCK = undefined;
            var info = windows.FILE_BASIC_INFORMATION{
                .CreationTime = 0,
                .LastAccessTime = 0,
                .LastWriteTime = 0,
                .ChangeTime = 0,
                .FileAttributes = permissions.inner.attributes,
            };
            const rc = windows.ntdll.NtSetInformationFile(
                self.handle,
                &io_status_block,
                &info,
                @sizeOf(windows.FILE_BASIC_INFORMATION),
                .FileBasicInformation,
            );
            switch (rc) {
                .SUCCESS => return,
                .INVALID_HANDLE => unreachable,
                .ACCESS_DENIED => return error.AccessDenied,
                else => return windows.unexpectedStatus(rc),
            }
        },
        .wasi => @compileError("Unsupported OS"), // Wasi filesystem does not *yet* support chmod
        else => {
            try self.chmod(permissions.inner.mode);
        },
    }
}

/// Cross-platform representation of file metadata.
/// Platform-specific functionality is available through the `inner` field.
pub const Metadata = struct {
    /// Exposes platform-specific functionality.
    inner: switch (builtin.os.tag) {
        .windows => MetadataWindows,
        .linux => MetadataLinux,
        .wasi => MetadataWasi,
        else => MetadataUnix,
    },

    const Self = @This();

    /// Returns the size of the file
    pub fn size(self: Self) u64 {
        return self.inner.size();
    }

    /// Returns a `Permissions` struct, representing the permissions on the file
    pub fn permissions(self: Self) Permissions {
        return self.inner.permissions();
    }

    /// Returns the `Kind` of file.
    /// On Windows, can only return: `.file`, `.directory`, `.sym_link` or `.unknown`
    pub fn kind(self: Self) Kind {
        return self.inner.kind();
    }

    /// Returns the last time the file was accessed in nanoseconds since UTC 1970-01-01
    pub fn accessed(self: Self) i128 {
        return self.inner.accessed();
    }

    /// Returns the time the file was modified in nanoseconds since UTC 1970-01-01
    pub fn modified(self: Self) i128 {
        return self.inner.modified();
    }

    /// Returns the time the file was created in nanoseconds since UTC 1970-01-01
    /// On Windows, this cannot return null
    /// On Linux, this returns null if the filesystem does not support creation times
    /// On Unices, this returns null if the filesystem or OS does not support creation times
    /// On MacOS, this returns the ctime if the filesystem does not support creation times; this is insanity, and yet another reason to hate on Apple
    pub fn created(self: Self) ?i128 {
        return self.inner.created();
    }
};

pub const MetadataUnix = struct {
    stat: posix.Stat,

    const Self = @This();

    /// Returns the size of the file
    pub fn size(self: Self) u64 {
        return @intCast(self.stat.size);
    }

    /// Returns a `Permissions` struct, representing the permissions on the file
    pub fn permissions(self: Self) Permissions {
        return .{ .inner = .{ .mode = self.stat.mode } };
    }

    /// Returns the `Kind` of the file
    pub fn kind(self: Self) Kind {
        if (builtin.os.tag == .wasi and !builtin.link_libc) return switch (self.stat.filetype) {
            .BLOCK_DEVICE => .block_device,
            .CHARACTER_DEVICE => .character_device,
            .DIRECTORY => .directory,
            .SYMBOLIC_LINK => .sym_link,
            .REGULAR_FILE => .file,
            .SOCKET_STREAM, .SOCKET_DGRAM => .unix_domain_socket,
            else => .unknown,
        };

        const m = self.stat.mode & posix.S.IFMT;

        switch (m) {
            posix.S.IFBLK => return .block_device,
            posix.S.IFCHR => return .character_device,
            posix.S.IFDIR => return .directory,
            posix.S.IFIFO => return .named_pipe,
            posix.S.IFLNK => return .sym_link,
            posix.S.IFREG => return .file,
            posix.S.IFSOCK => return .unix_domain_socket,
            else => {},
        }

        if (builtin.os.tag.isSolarish()) switch (m) {
            posix.S.IFDOOR => return .door,
            posix.S.IFPORT => return .event_port,
            else => {},
        };

        return .unknown;
    }

    /// Returns the last time the file was accessed in nanoseconds since UTC 1970-01-01
    pub fn accessed(self: Self) i128 {
        const atime = self.stat.atime();
        return @as(i128, atime.sec) * std.time.ns_per_s + atime.nsec;
    }

    /// Returns the last time the file was modified in nanoseconds since UTC 1970-01-01
    pub fn modified(self: Self) i128 {
        const mtime = self.stat.mtime();
        return @as(i128, mtime.sec) * std.time.ns_per_s + mtime.nsec;
    }

    /// Returns the time the file was created in nanoseconds since UTC 1970-01-01.
    /// Returns null if this is not supported by the OS or filesystem
    pub fn created(self: Self) ?i128 {
        if (!@hasDecl(@TypeOf(self.stat), "birthtime")) return null;
        const birthtime = self.stat.birthtime();

        // If the filesystem doesn't support this the value *should* be:
        // On FreeBSD: nsec = 0, sec = -1
        // On NetBSD and OpenBSD: nsec = 0, sec = 0
        // On MacOS, it is set to ctime -- we cannot detect this!!
        switch (builtin.os.tag) {
            .freebsd => if (birthtime.sec == -1 and birthtime.nsec == 0) return null,
            .netbsd, .openbsd => if (birthtime.sec == 0 and birthtime.nsec == 0) return null,
            .macos => {},
            else => @compileError("Creation time detection not implemented for OS"),
        }

        return @as(i128, birthtime.sec) * std.time.ns_per_s + birthtime.nsec;
    }
};

/// `MetadataUnix`, but using Linux's `statx` syscall.
pub const MetadataLinux = struct {
    statx: std.os.linux.Statx,

    const Self = @This();

    /// Returns the size of the file
    pub fn size(self: Self) u64 {
        return self.statx.size;
    }

    /// Returns a `Permissions` struct, representing the permissions on the file
    pub fn permissions(self: Self) Permissions {
        return Permissions{ .inner = PermissionsUnix{ .mode = self.statx.mode } };
    }

    /// Returns the `Kind` of the file
    pub fn kind(self: Self) Kind {
        const m = self.statx.mode & posix.S.IFMT;

        switch (m) {
            posix.S.IFBLK => return .block_device,
            posix.S.IFCHR => return .character_device,
            posix.S.IFDIR => return .directory,
            posix.S.IFIFO => return .named_pipe,
            posix.S.IFLNK => return .sym_link,
            posix.S.IFREG => return .file,
            posix.S.IFSOCK => return .unix_domain_socket,
            else => {},
        }

        return .unknown;
    }

    /// Returns the last time the file was accessed in nanoseconds since UTC 1970-01-01
    pub fn accessed(self: Self) i128 {
        return @as(i128, self.statx.atime.sec) * std.time.ns_per_s + self.statx.atime.nsec;
    }

    /// Returns the last time the file was modified in nanoseconds since UTC 1970-01-01
    pub fn modified(self: Self) i128 {
        return @as(i128, self.statx.mtime.sec) * std.time.ns_per_s + self.statx.mtime.nsec;
    }

    /// Returns the time the file was created in nanoseconds since UTC 1970-01-01.
    /// Returns null if this is not supported by the filesystem, or on kernels before than version 4.11
    pub fn created(self: Self) ?i128 {
        if (self.statx.mask & std.os.linux.STATX_BTIME == 0) return null;
        return @as(i128, self.statx.btime.sec) * std.time.ns_per_s + self.statx.btime.nsec;
    }
};

pub const MetadataWasi = struct {
    stat: std.os.wasi.filestat_t,

    pub fn size(self: @This()) u64 {
        return self.stat.size;
    }

    pub fn permissions(self: @This()) Permissions {
        return .{ .inner = .{ .mode = self.stat.mode } };
    }

    pub fn kind(self: @This()) Kind {
        return switch (self.stat.filetype) {
            .BLOCK_DEVICE => .block_device,
            .CHARACTER_DEVICE => .character_device,
            .DIRECTORY => .directory,
            .SYMBOLIC_LINK => .sym_link,
            .REGULAR_FILE => .file,
            .SOCKET_STREAM, .SOCKET_DGRAM => .unix_domain_socket,
            else => .unknown,
        };
    }

    pub fn accessed(self: @This()) i128 {
        return self.stat.atim;
    }

    pub fn modified(self: @This()) i128 {
        return self.stat.mtim;
    }

    pub fn created(self: @This()) ?i128 {
        return self.stat.ctim;
    }
};

pub const MetadataWindows = struct {
    attributes: windows.DWORD,
    reparse_tag: windows.DWORD,
    _size: u64,
    access_time: i128,
    modified_time: i128,
    creation_time: i128,

    const Self = @This();

    /// Returns the size of the file
    pub fn size(self: Self) u64 {
        return self._size;
    }

    /// Returns a `Permissions` struct, representing the permissions on the file
    pub fn permissions(self: Self) Permissions {
        return .{ .inner = .{ .attributes = self.attributes } };
    }

    /// Returns the `Kind` of the file.
    /// Can only return: `.file`, `.directory`, `.sym_link` or `.unknown`
    pub fn kind(self: Self) Kind {
        if (self.attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
            if (self.reparse_tag & windows.reparse_tag_name_surrogate_bit != 0) {
                return .sym_link;
            }
        } else if (self.attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) {
            return .directory;
        } else {
            return .file;
        }
        return .unknown;
    }

    /// Returns the last time the file was accessed in nanoseconds since UTC 1970-01-01
    pub fn accessed(self: Self) i128 {
        return self.access_time;
    }

    /// Returns the time the file was modified in nanoseconds since UTC 1970-01-01
    pub fn modified(self: Self) i128 {
        return self.modified_time;
    }

    /// Returns the time the file was created in nanoseconds since UTC 1970-01-01.
    /// This never returns null, only returning an optional for compatibility with other OSes
    pub fn created(self: Self) ?i128 {
        return self.creation_time;
    }
};

pub const MetadataError = posix.FStatError;

pub fn metadata(self: File) MetadataError!Metadata {
    return .{
        .inner = switch (builtin.os.tag) {
            .windows => blk: {
                var io_status_block: windows.IO_STATUS_BLOCK = undefined;
                var info: windows.FILE_ALL_INFORMATION = undefined;

                const rc = windows.ntdll.NtQueryInformationFile(self.handle, &io_status_block, &info, @sizeOf(windows.FILE_ALL_INFORMATION), .FileAllInformation);
                switch (rc) {
                    .SUCCESS => {},
                    // Buffer overflow here indicates that there is more information available than was able to be stored in the buffer
                    // size provided. This is treated as success because the type of variable-length information that this would be relevant for
                    // (name, volume name, etc) we don't care about.
                    .BUFFER_OVERFLOW => {},
                    .INVALID_PARAMETER => unreachable,
                    .ACCESS_DENIED => return error.AccessDenied,
                    else => return windows.unexpectedStatus(rc),
                }

                const reparse_tag: windows.DWORD = reparse_blk: {
                    if (info.BasicInformation.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
                        var tag_info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
                        const tag_rc = windows.ntdll.NtQueryInformationFile(self.handle, &io_status_block, &tag_info, @sizeOf(windows.FILE_ATTRIBUTE_TAG_INFO), .FileAttributeTagInformation);
                        switch (tag_rc) {
                            .SUCCESS => {},
                            // INFO_LENGTH_MISMATCH and ACCESS_DENIED are the only documented possible errors
                            // https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/d295752f-ce89-4b98-8553-266d37c84f0e
                            .INFO_LENGTH_MISMATCH => unreachable,
                            .ACCESS_DENIED => return error.AccessDenied,
                            else => return windows.unexpectedStatus(rc),
                        }
                        break :reparse_blk tag_info.ReparseTag;
                    }
                    break :reparse_blk 0;
                };

                break :blk .{
                    .attributes = info.BasicInformation.FileAttributes,
                    .reparse_tag = reparse_tag,
                    ._size = @as(u64, @bitCast(info.StandardInformation.EndOfFile)),
                    .access_time = windows.fromSysTime(info.BasicInformation.LastAccessTime),
                    .modified_time = windows.fromSysTime(info.BasicInformation.LastWriteTime),
                    .creation_time = windows.fromSysTime(info.BasicInformation.CreationTime),
                };
            },
            .linux => blk: {
                var stx = std.mem.zeroes(linux.Statx);

                // We are gathering information for Metadata, which is meant to contain all the
                // native OS information about the file, so use all known flags.
                const rc = linux.statx(
                    self.handle,
                    "",
                    linux.AT.EMPTY_PATH,
                    linux.STATX_BASIC_STATS | linux.STATX_BTIME,
                    &stx,
                );

                switch (linux.E.init(rc)) {
                    .SUCCESS => {},
                    .ACCES => unreachable,
                    .BADF => unreachable,
                    .FAULT => unreachable,
                    .INVAL => unreachable,
                    .LOOP => unreachable,
                    .NAMETOOLONG => unreachable,
                    .NOENT => unreachable,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => unreachable,
                    else => |err| return posix.unexpectedErrno(err),
                }

                break :blk .{
                    .statx = stx,
                };
            },
            .wasi => .{ .stat = try std.os.fstat_wasi(self.handle) },
            else => .{ .stat = try posix.fstat(self.handle) },
        },
    };
}
