const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// C imports for macOS system calls
const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_host.h");
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
    // IOKit for hardware detection
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

pub const Timeval = struct {
    tv_sec: i64,
    tv_usec: i32,
};

pub const VMStatistics = struct {
    free_count: u64,
    active_count: u64,
    inactive_count: u64,
    wire_count: u64,
    speculative_count: u64,
    compressor_page_count: u64,
    purgeable_count: u64,
    external_page_count: u64,
    page_size: u64,
};

pub const ProcessInfo = struct {
    pid: i32,
    ppid: i32,
    name: [16]u8,
    name_len: usize,
};

/// Read a string value from sysctl by name (e.g., "kern.ostype", "hw.model")
pub fn sysctlString(allocator: Allocator, name: [:0]const u8) ![]u8 {
    var size: usize = 0;

    // First call to get the size
    if (c.sysctlbyname(name.ptr, null, &size, null, 0) != 0) {
        return error.SysctlFailed;
    }

    if (size == 0) {
        return error.EmptyResult;
    }

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    // Second call to get the actual value
    if (c.sysctlbyname(name.ptr, buffer.ptr, &size, null, 0) != 0) {
        return error.SysctlFailed;
    }

    // Trim null terminator and trailing whitespace
    var end = size;
    while (end > 0 and (buffer[end - 1] == 0 or buffer[end - 1] == ' ' or buffer[end - 1] == '\n')) {
        end -= 1;
    }

    if (end == 0) {
        allocator.free(buffer);
        return error.EmptyResult;
    }

    // Resize to actual content length
    if (end < buffer.len) {
        const result = try allocator.realloc(buffer, end);
        return result;
    }

    return buffer[0..end];
}

/// Read a u64 value from sysctl by name
pub fn sysctlU64(name: [:0]const u8) !u64 {
    var value: u64 = 0;
    var size: usize = @sizeOf(u64);

    if (c.sysctlbyname(name.ptr, &value, &size, null, 0) != 0) {
        return error.SysctlFailed;
    }

    return value;
}

/// Read an i32 value from sysctl by name
pub fn sysctlI32(name: [:0]const u8) !i32 {
    var value: i32 = 0;
    var size: usize = @sizeOf(i32);

    if (c.sysctlbyname(name.ptr, &value, &size, null, 0) != 0) {
        return error.SysctlFailed;
    }

    return value;
}

/// Read a timeval struct from sysctl (e.g., kern.boottime)
pub fn sysctlTimeval(name: [:0]const u8) !Timeval {
    var tv: c.struct_timeval = undefined;
    var size: usize = @sizeOf(c.struct_timeval);

    if (c.sysctlbyname(name.ptr, &tv, &size, null, 0) != 0) {
        return error.SysctlFailed;
    }

    return Timeval{
        .tv_sec = @intCast(tv.tv_sec),
        .tv_usec = @intCast(tv.tv_usec),
    };
}

/// Get VM statistics using Mach API (for memory info)
pub fn hostVMStatistics64() !VMStatistics {
    var vm_stat: c.vm_statistics64_data_t = undefined;
    var count: c.mach_msg_type_number_t = @sizeOf(c.vm_statistics64_data_t) / @sizeOf(c.natural_t);

    const host_port = c.mach_host_self();
    defer _ = c.mach_port_deallocate(c.mach_task_self(), host_port);

    const result = c.host_statistics64(
        host_port,
        c.HOST_VM_INFO64,
        @ptrCast(&vm_stat),
        &count,
    );

    if (result != c.KERN_SUCCESS) {
        return error.MachCallFailed;
    }

    // Get page size
    var page_size: c.vm_size_t = 0;
    if (c.host_page_size(host_port, &page_size) != c.KERN_SUCCESS) {
        page_size = 4096; // Default fallback
    }

    return VMStatistics{
        .free_count = vm_stat.free_count,
        .active_count = vm_stat.active_count,
        .inactive_count = vm_stat.inactive_count,
        .wire_count = vm_stat.wire_count,
        .speculative_count = vm_stat.speculative_count,
        .compressor_page_count = vm_stat.compressor_page_count,
        .purgeable_count = vm_stat.purgeable_count,
        .external_page_count = vm_stat.external_page_count,
        .page_size = page_size,
    };
}

/// Get process info by PID using libproc
pub fn getProcessInfo(pid: i32) !ProcessInfo {
    var info: c.struct_proc_bsdinfo = undefined;

    const size = c.proc_pidinfo(
        pid,
        c.PROC_PIDTBSDINFO,
        0,
        &info,
        @sizeOf(c.struct_proc_bsdinfo),
    );

    if (size <= 0) {
        return error.ProcInfoFailed;
    }

    var result = ProcessInfo{
        .pid = @intCast(info.pbi_pid),
        .ppid = @intCast(info.pbi_ppid),
        .name = undefined,
        .name_len = 0,
    };

    // Copy process name
    const name_slice = std.mem.sliceTo(&info.pbi_name, 0);
    const copy_len = @min(name_slice.len, result.name.len);
    @memcpy(result.name[0..copy_len], name_slice[0..copy_len]);
    result.name_len = copy_len;

    return result;
}

/// Get the hostname
pub fn getHostname(allocator: Allocator) ![]u8 {
    return sysctlString(allocator, "kern.hostname");
}

/// Get the username from environment
pub fn getUsername(allocator: Allocator) ![]u8 {
    const user = std.process.getEnvVarOwned(allocator, "USER") catch {
        return try allocator.dupe(u8, "unknown");
    };
    return user;
}

// ============================================================================
// IOKit Functions for Apple Silicon hardware detection
// ============================================================================

pub const GPUInfo = struct {
    name: []const u8,
    core_count: u32,
    vendor_id: u32,
};

/// Get Apple Silicon CPU P-core frequency from IOKit pmgr service
/// Returns frequency in MHz, or null if detection fails
pub fn getAppleSiliconCPUFrequency() ?u32 {
    // Find pmgr service by iterating through AppleARMIODevice services
    const matching = c.IOServiceMatching("AppleARMIODevice");
    if (matching == null) return null;

    var iterator: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(0, matching, &iterator) != c.kIOReturnSuccess) {
        return null;
    }
    defer _ = c.IOObjectRelease(iterator);

    // Find the pmgr service
    var pmgr_service: c.io_service_t = 0;
    while (true) {
        const service = c.IOIteratorNext(iterator);
        if (service == 0) break;

        // Check if this service has the voltage-states5-sram property (indicates pmgr)
        const key = c.CFStringCreateWithCString(null, "voltage-states5-sram", c.kCFStringEncodingUTF8);
        if (key != null) {
            const property = c.IORegistryEntryCreateCFProperty(service, key, c.kCFAllocatorDefault, 0);
            c.CFRelease(key);

            if (property != null) {
                // Found the pmgr service
                pmgr_service = service;
                c.CFRelease(property);
                break;
            }
        }
        _ = c.IOObjectRelease(service);
    }

    if (pmgr_service == 0) return null;
    defer _ = c.IOObjectRelease(pmgr_service);

    // Read voltage-states5-sram property (P-core frequencies)
    const key = c.CFStringCreateWithCString(null, "voltage-states5-sram", c.kCFStringEncodingUTF8);
    if (key == null) return null;
    defer c.CFRelease(key);

    const property = c.IORegistryEntryCreateCFProperty(pmgr_service, key, c.kCFAllocatorDefault, 0);
    if (property == null) return null;
    defer c.CFRelease(property);

    // Verify it's CFData
    if (c.CFGetTypeID(property) != c.CFDataGetTypeID()) return null;

    const data: c.CFDataRef = @ptrCast(property);
    const length = c.CFDataGetLength(data);

    // Data contains pairs of (frequency, voltage) as u32 values
    if (length == 0 or @mod(length, 8) != 0) return null;

    const bytes = c.CFDataGetBytePtr(data);
    if (bytes == null) return null;

    // Find maximum frequency in the array
    const num_pairs: usize = @intCast(@divExact(length, 8));
    var max_freq: u32 = 0;

    for (0..num_pairs) |i| {
        const offset = i * 8;
        const freq_ptr: *align(1) const u32 = @ptrCast(bytes + offset);
        const freq = freq_ptr.*;
        if (freq > max_freq and freq > 0) {
            max_freq = freq;
        }
    }

    if (max_freq == 0) return null;

    // Convert to MHz
    // M1-M3: frequency is in Hz, so divide by 1,000,000
    // M4+: frequency might be in kHz, so divide by 1,000
    if (max_freq > 100_000_000) {
        // Hz -> MHz
        return max_freq / 1_000_000;
    } else {
        // kHz -> MHz
        return max_freq / 1_000;
    }
}

/// Get GPU information from IOKit IOAccelerator
/// Returns GPU info or null if detection fails
pub fn getGPUInfo(allocator: Allocator) ?GPUInfo {
    // Create matching dictionary for IOAccelerator
    const matching = c.IOServiceMatching("IOAccelerator");
    if (matching == null) return null;

    var iterator: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(0, matching, &iterator) != c.kIOReturnSuccess) {
        return null;
    }
    defer _ = c.IOObjectRelease(iterator);

    // Get first accelerator
    const service = c.IOIteratorNext(iterator);
    if (service == 0) return null;
    defer _ = c.IOObjectRelease(service);

    // Get properties dictionary
    var properties: c.CFMutableDictionaryRef = null;
    if (c.IORegistryEntryCreateCFProperties(service, &properties, c.kCFAllocatorDefault, 0) != c.kIOReturnSuccess) {
        return null;
    }
    defer c.CFRelease(properties);

    var result = GPUInfo{
        .name = "Unknown GPU",
        .core_count = 0,
        .vendor_id = 0,
    };

    // Try to get model name
    const model_key = c.CFStringCreateWithCString(null, "model", c.kCFStringEncodingUTF8);
    if (model_key != null) {
        defer c.CFRelease(model_key);

        if (c.CFDictionaryGetValue(properties, model_key)) |model_value| {
            // model can be CFString or CFData
            if (c.CFGetTypeID(model_value) == c.CFStringGetTypeID()) {
                const str: c.CFStringRef = @ptrCast(model_value);
                var buffer: [256]u8 = undefined;
                if (c.CFStringGetCString(str, &buffer, buffer.len, c.kCFStringEncodingUTF8) != 0) {
                    const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse buffer.len;
                    result.name = allocator.dupe(u8, buffer[0..len]) catch "Unknown GPU";
                }
            } else if (c.CFGetTypeID(model_value) == c.CFDataGetTypeID()) {
                const data: c.CFDataRef = @ptrCast(model_value);
                const len: usize = @intCast(c.CFDataGetLength(data));
                const bytes = c.CFDataGetBytePtr(data);
                if (bytes != null and len > 0) {
                    // Find null terminator or use full length
                    const str_bytes: [*]const u8 = @ptrCast(bytes);
                    const str_len = std.mem.indexOfScalar(u8, str_bytes[0..len], 0) orelse len;
                    result.name = allocator.dupe(u8, str_bytes[0..str_len]) catch "Unknown GPU";
                }
            }
        } else {
            // Try parent entry for model
            var parent: c.io_registry_entry_t = 0;
            if (c.IORegistryEntryGetParentEntry(service, c.kIOServicePlane, &parent) == c.kIOReturnSuccess) {
                defer _ = c.IOObjectRelease(parent);

                var parent_props: c.CFMutableDictionaryRef = null;
                if (c.IORegistryEntryCreateCFProperties(parent, &parent_props, c.kCFAllocatorDefault, 0) == c.kIOReturnSuccess) {
                    defer c.CFRelease(parent_props);

                    if (c.CFDictionaryGetValue(parent_props, model_key)) |model_value| {
                        if (c.CFGetTypeID(model_value) == c.CFDataGetTypeID()) {
                            const data: c.CFDataRef = @ptrCast(model_value);
                            const len: usize = @intCast(c.CFDataGetLength(data));
                            const bytes = c.CFDataGetBytePtr(data);
                            if (bytes != null and len > 0) {
                                const str_bytes: [*]const u8 = @ptrCast(bytes);
                                const str_len = std.mem.indexOfScalar(u8, str_bytes[0..len], 0) orelse len;
                                result.name = allocator.dupe(u8, str_bytes[0..str_len]) catch "Unknown GPU";
                            }
                        }
                    }
                }
            }
        }
    }

    // Get gpu-core-count
    const cores_key = c.CFStringCreateWithCString(null, "gpu-core-count", c.kCFStringEncodingUTF8);
    if (cores_key != null) {
        defer c.CFRelease(cores_key);

        if (c.CFDictionaryGetValue(properties, cores_key)) |cores_value| {
            if (c.CFGetTypeID(cores_value) == c.CFNumberGetTypeID()) {
                const num: c.CFNumberRef = @ptrCast(cores_value);
                var cores: i32 = 0;
                if (c.CFNumberGetValue(num, c.kCFNumberSInt32Type, &cores) != 0) {
                    result.core_count = @intCast(cores);
                }
            }
        }
    }

    // Get vendor-id
    const vendor_key = c.CFStringCreateWithCString(null, "vendor-id", c.kCFStringEncodingUTF8);
    if (vendor_key != null) {
        defer c.CFRelease(vendor_key);

        if (c.CFDictionaryGetValue(properties, vendor_key)) |vendor_value| {
            if (c.CFGetTypeID(vendor_value) == c.CFNumberGetTypeID()) {
                const num: c.CFNumberRef = @ptrCast(vendor_value);
                var vendor: i32 = 0;
                if (c.CFNumberGetValue(num, c.kCFNumberSInt32Type, &vendor) != 0) {
                    result.vendor_id = @intCast(vendor);
                }
            } else if (c.CFGetTypeID(vendor_value) == c.CFDataGetTypeID()) {
                const data: c.CFDataRef = @ptrCast(vendor_value);
                if (c.CFDataGetLength(data) >= 4) {
                    const bytes = c.CFDataGetBytePtr(data);
                    if (bytes != null) {
                        const vendor_ptr: *align(1) const u32 = @ptrCast(bytes);
                        result.vendor_id = vendor_ptr.*;
                    }
                }
            }
        }
    }

    return result;
}
