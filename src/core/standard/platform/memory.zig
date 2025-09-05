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
            if (std.os.linux.E.init(result) != .SUCCESS) {
                return error.UnknownTotalSystemMemory;
            }
            return info.totalram * info.mem_unit;
        },
        .freebsd => {
            var physmem: c_ulong = undefined;
            var len: usize = @sizeOf(c_ulong);
            posix.sysctlbynameZ("hw.physmem", &physmem, &len, null, 0) catch |err| switch (err) {
                error.NameTooLong, error.UnknownName => unreachable,
                else => return error.UnknownTotalSystemMemory,
            };
            return @as(usize, @intCast(physmem));
        },
        // whole Darwin family
        .driverkit, .ios, .macos, .tvos, .visionos, .watchos => {
            // "hw.memsize" returns uint64_t
            var physmem: u64 = undefined;
            var len: usize = @sizeOf(u64);
            posix.sysctlbynameZ("hw.memsize", &physmem, &len, null, 0) catch |err| switch (err) {
                error.PermissionDenied => unreachable, // only when setting values,
                error.SystemResources => unreachable, // memory already on the stack
                error.UnknownName => unreachable, // constant, known good value
                else => return error.UnknownTotalSystemMemory,
            };
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
        .windows => {
            var sbi: windows.SYSTEM_BASIC_INFORMATION = undefined;
            const rc = windows.ntdll.NtQuerySystemInformation(
                .SystemBasicInformation,
                &sbi,
                @sizeOf(windows.SYSTEM_BASIC_INFORMATION),
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
            if (std.os.linux.E.init(result) != .SUCCESS) {
                return error.UnknownFreeSystemMemory;
            }
            return info.freeram * info.mem_unit;
        },
        .freebsd => {
            var free: c_int = undefined;
            var len: usize = @sizeOf(c_int);
            posix.sysctlbynameZ("vm.stats.vm.v_free_count", &free, &len, null, 0) catch |err| switch (err) {
                error.NameTooLong, error.UnknownName => unreachable,
                else => return error.UnknownFreeSystemMemory,
            };
            return @as(usize, @intCast(free)) * std.heap.pageSize();
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

            return @as(u64, stats.free_count) * std.heap.pageSize();
        },
        .windows => {
            var sbi: windows.SYSTEM_BASIC_INFORMATION = undefined;
            const rc = windows.ntdll.NtQuerySystemInformation(
                .SystemBasicInformation,
                &sbi,
                @sizeOf(windows.SYSTEM_BASIC_INFORMATION),
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
