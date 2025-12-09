const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const darwin = if (builtin.os.tag == .macos) @import("../platform/darwin.zig") else undefined;
const linux = if (builtin.os.tag == .linux) @import("../platform/linux.zig") else undefined;

/// Get GPU info in format "Apple M2 Pro (19)" or "NVIDIA GeForce RTX 3080"
pub fn getGPU(allocator: Allocator) !?[]const u8 {
    if (builtin.os.tag == .macos) {
        return try getGPUDarwin(allocator);
    } else if (builtin.os.tag == .linux) {
        return try getGPULinux(allocator);
    }
    return null;
}

fn getGPUDarwin(allocator: Allocator) !?[]const u8 {
    // Use IOKit to get real GPU information
    if (darwin.getGPUInfo(allocator)) |info| {
        if (info.core_count > 0) {
            return try std.fmt.allocPrint(allocator, "{s} ({d})", .{ info.name, info.core_count });
        }
        return try allocator.dupe(u8, info.name);
    }

    // Fallback for Intel Macs or if IOKit fails
    return try allocator.dupe(u8, "Unknown GPU");
}

fn getGPULinux(allocator: Allocator) !?[]const u8 {
    // Try DRM subsystem
    if (try getGPUFromDRM(allocator)) |gpu| {
        return gpu;
    }

    return null;
}

fn getGPUFromDRM(allocator: Allocator) !?[]const u8 {
    // Try to read GPU info from /sys/class/drm/
    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Look for card0, card1, etc.
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        if (std.mem.indexOf(u8, entry.name, "-") != null) continue; // Skip card0-DP-1 etc.

        var path_buf: [256]u8 = undefined;

        // Try vendor ID
        const vendor_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/device/vendor", .{entry.name}) catch continue;
        const vendor = linux.readSysFile(allocator, vendor_path) catch continue;
        defer allocator.free(vendor);

        // Try device ID
        const device_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/device/device", .{entry.name}) catch continue;
        const device = linux.readSysFile(allocator, device_path) catch continue;
        defer allocator.free(device);

        // Map vendor/device to name
        const gpu_name = mapPCIToGPUName(vendor, device);
        if (gpu_name) |name| {
            return try allocator.dupe(u8, name);
        }

        // Fallback: return raw vendor
        return try std.fmt.allocPrint(allocator, "GPU ({s}:{s})", .{ vendor, device });
    }

    return null;
}

fn mapPCIToGPUName(vendor: []const u8, device: []const u8) ?[]const u8 {
    _ = device;

    // Common vendor IDs
    if (std.mem.eql(u8, vendor, "0x10de")) return "NVIDIA GPU";
    if (std.mem.eql(u8, vendor, "0x1002")) return "AMD GPU";
    if (std.mem.eql(u8, vendor, "0x8086")) return "Intel GPU";

    return null;
}
