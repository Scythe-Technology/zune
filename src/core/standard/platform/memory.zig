const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const windows = std.os.windows;

pub const SystemMemoryError = std.process.TotalSystemMemoryError || error{
    UnknownFreeSystemMemory,
};

pub const BYTES_PER_MB = 1024 * 1024;

pub fn getTotalSystemMemory() SystemMemoryError!u64 {
    switch (comptime builtin.os.tag) {
        .linux => {
            var info: std.os.linux.Sysinfo = undefined;
            const result: usize = std.os.linux.sysinfo(&info);
            if (std.os.linux.errno(result) != .SUCCESS) {
                return error.UnknownTotalSystemMemory;
            }
            return info.totalram * info.mem_unit;
        },
        .freebsd => {
            var physmem: c_ulong = undefined;
            var len: usize = @sizeOf(c_ulong);
            switch (posix.errno(posix.system.sysctlbyname("hw.physmem", &physmem, &len, null, 0))) {
                .SUCCESS => {},
                .FAULT, .PERM, .NOMEM, .NOENT => unreachable,
                else => return error.UnknownTotalSystemMemory,
            }
            return @as(usize, @intCast(physmem));
        },
        // whole Darwin family
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => {
            // "hw.memsize" returns uint64_t
            var physmem: u64 = undefined;
            var len: usize = @sizeOf(u64);
            switch (posix.errno(posix.system.sysctlbyname("hw.memsize", &physmem, &len, null, 0))) {
                .SUCCESS => {},
                .FAULT, .PERM, .NOMEM, .NOENT => unreachable,
                else => return error.UnknownTotalSystemMemory,
            }
            return physmem;
        },
        .openbsd => {
            const mib: [2]c_int = [_]c_int{
                posix.CTL.HW,
                posix.HW.PHYSMEM64,
            };
            var physmem: i64 = undefined;
            var len: usize = @sizeOf(@TypeOf(physmem));
            posix.sysctl(&mib, &physmem, &len, null, 0) catch |err| switch (err) {
                error.NameTooLong => unreachable, // constant, known good value
                error.PermissionDenied => unreachable, // only when setting values,
                error.SystemResources => unreachable, // memory already on the stack
                error.UnknownName => unreachable, // constant, known good value
                else => return error.UnknownTotalSystemMemory,
            };
            std.debug.assert(physmem >= 0);
            return @as(u64, @bitCast(physmem));
        },
        .netbsd => {
            const CTL_HW: c_int = 6;
            const HW_PHYSMEM64: c_int = 13;
            const mib: [2]c_int = .{
                CTL_HW,
                HW_PHYSMEM64,
            };
            var physmem: i64 = undefined;
            var len: usize = @sizeOf(@TypeOf(physmem));
            posix.sysctl(&mib, &physmem, &len, null, 0) catch |err| switch (err) {
                error.NameTooLong => unreachable, // constant, known good value
                error.PermissionDenied => unreachable, // only when setting values
                error.SystemResources => unreachable, // memory already on the stack
                error.UnknownName => unreachable, // constant, known good value
                else => return error.UnknownTotalSystemMemory,
            };
            if (physmem < 0)
                return error.UnknownTotalSystemMemory;
            return @as(u64, @intCast(physmem));
        },
        .windows => {
            var sbi: windows.SYSTEM.BASIC_INFORMATION = undefined;
            const rc = windows.ntdll.NtQuerySystemInformation(
                .Basic,
                &sbi,
                @sizeOf(windows.SYSTEM.BASIC_INFORMATION),
                null,
            );
            if (rc != .SUCCESS) {
                return error.UnknownTotalSystemMemory;
            }
            return @as(u64, sbi.NumberOfPhysicalPages) * sbi.PageSize;
        },
        else => return error.UnknownTotalSystemMemory,
    }
}

pub fn getFreeMemory() SystemMemoryError!u64 {
    switch (comptime builtin.os.tag) {
        .linux => {
            var info: std.os.linux.Sysinfo = undefined;
            const result: usize = std.os.linux.sysinfo(&info);
            if (std.os.linux.errno(result) != .SUCCESS) {
                return error.UnknownFreeSystemMemory;
            }
            return info.freeram * info.mem_unit;
        },
        .freebsd => {
            var free: c_int = undefined;
            var len: usize = @sizeOf(c_int);
            switch (posix.errno(posix.system.sysctlbyname("vm.stats.vm.v_free_count", &free, &len, null, 0))) {
                .SUCCESS => {},
                .FAULT, .PERM, .NOMEM, .NOENT => unreachable,
                else => return error.UnknownFreeSystemMemory,
            }
            return @as(usize, @intCast(free)) * std.heap.pageSize();
        },
        .openbsd => {
            const VM_UVMEXP: c_int = 4;
            const UVMEXP_BUFFER = 1024;
            const mib: [2]c_int = .{
                posix.CTL.VM,
                VM_UVMEXP,
            };
            const Header = extern struct {
                page_size: c_int,
                page_mask: c_int,
                page_shift: c_int,
                npages: c_int,
                free: c_int,
            };
            var buf: [UVMEXP_BUFFER]u8 align(@alignOf(Header)) = undefined;
            var len: usize = buf.len;
            posix.sysctl(&mib, &buf, &len, null, 0) catch |err| switch (err) {
                error.NameTooLong => unreachable, // constant, known good value
                error.PermissionDenied => unreachable, // only when setting values
                error.UnknownName => unreachable, // constant, known good value
                else => return error.UnknownFreeSystemMemory,
            };
            if (len < @sizeOf(Header))
                return error.UnknownFreeSystemMemory;
            const header: *const Header = @ptrCast(&buf);
            if (header.page_size <= 0 or header.free < 0)
                return error.UnknownFreeSystemMemory;
            return @as(u64, @intCast(header.free)) * @as(u64, @intCast(header.page_size));
        },
        .netbsd => {
            const CTL_VM: c_int = 2;
            const VM_UVMEXP2: c_int = 5;
            const UVMEXP_BUFFER = 1024;
            const mib: [2]c_int = .{
                CTL_VM,
                VM_UVMEXP2,
            };
            const Header = extern struct {
                page_size: i64,
                page_mask: i64,
                page_shift: i64,
                npages: i64,
                free: i64,
            };
            var buf: [UVMEXP_BUFFER]u8 align(@alignOf(Header)) = undefined;
            var len: usize = buf.len;
            posix.sysctl(&mib, &buf, &len, null, 0) catch |err| switch (err) {
                error.NameTooLong => unreachable, // constant, known good value
                error.PermissionDenied => unreachable, // only when setting values
                error.UnknownName => unreachable, // constant, known good value
                else => return error.UnknownFreeSystemMemory,
            };
            if (len < @sizeOf(Header))
                return error.UnknownFreeSystemMemory;
            const header: *const Header = @ptrCast(&buf);
            if (header.page_size <= 0 or header.free < 0)
                return error.UnknownFreeSystemMemory;
            return @as(u64, @intCast(header.free)) * @as(u64, @intCast(header.page_size));
        },
        // whole Darwin family
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => {
            const mach = @import("mach.zig");
            var stats: mach.vm_statistics64 = undefined;
            var count: c_uint = @sizeOf(mach.vm_statistics64_data_t) / @sizeOf(c_int);

            const ret = mach.KernE.from(
                mach.host_statistics64(std.c.mach_host_self(), mach.HOST_VM_INFO64, @ptrCast(&stats), &count),
            );

            if (ret != .SUCCESS) {
                return error.UnknownFreeSystemMemory;
            }

            return @as(u64, stats.free_count + stats.inactive_count) * std.heap.pageSize();
        },
        .windows => {
            var sbi: windows.SYSTEM.BASIC_INFORMATION = undefined;
            const rc = windows.ntdll.NtQuerySystemInformation(
                .Basic,
                &sbi,
                @sizeOf(windows.SYSTEM.BASIC_INFORMATION),
                null,
            );
            if (rc != .SUCCESS) {
                return error.UnknownFreeSystemMemory;
            }
            return @as(u64, sbi.NumberOfPhysicalPages) * sbi.PageSize;
        },
        else => return error.UnknownFreeSystemMemory,
    }
}
