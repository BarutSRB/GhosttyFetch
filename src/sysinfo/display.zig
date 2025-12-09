const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// CoreGraphics C imports for macOS
const c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
}) else undefined;

/// Get display info in format "Built-in: 3024x1964 @ 120 Hz"
pub fn getDisplay(allocator: Allocator) !?[]const u8 {
    if (builtin.os.tag == .macos) {
        return try getDisplayDarwin(allocator);
    } else if (builtin.os.tag == .linux) {
        return try getDisplayLinux(allocator);
    }
    return null;
}

fn getDisplayDarwin(allocator: Allocator) !?[]const u8 {
    // Get main display
    const main_display = c.CGMainDisplayID();

    const width = c.CGDisplayPixelsWide(main_display);
    const height = c.CGDisplayPixelsHigh(main_display);

    if (width == 0 or height == 0) return null;

    // Get refresh rate from display mode
    const mode = c.CGDisplayCopyDisplayMode(main_display);
    if (mode == null) {
        return try std.fmt.allocPrint(allocator, "{d}x{d}", .{ width, height });
    }
    defer c.CGDisplayModeRelease(mode);

    const refresh = c.CGDisplayModeGetRefreshRate(mode);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.writer(allocator).print("{d}x{d}", .{ width, height });

    if (refresh > 0) {
        try out.writer(allocator).print(" @ {d:.0} Hz", .{refresh});
    }

    return try out.toOwnedSlice(allocator);
}

fn getDisplayLinux(allocator: Allocator) !?[]const u8 {
    // Try reading from DRM
    if (try getDisplayFromDRM(allocator)) |display| {
        return display;
    }

    // Try X11 environment
    if (try getDisplayFromXrandr(allocator)) |display| {
        return display;
    }

    return null;
}

fn getDisplayFromDRM(allocator: Allocator) !?[]const u8 {
    // Read from /sys/class/drm/card*-*/modes
    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Look for card0-HDMI-1, card0-eDP-1, etc.
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        if (std.mem.indexOf(u8, entry.name, "-") == null) continue;

        var path_buf: [256]u8 = undefined;

        // Check if enabled
        const enabled_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/enabled", .{entry.name}) catch continue;
        const enabled = std.fs.cwd().readFileAlloc(allocator, enabled_path, 16) catch continue;
        defer allocator.free(enabled);

        if (!std.mem.startsWith(u8, std.mem.trim(u8, enabled, " \t\r\n"), "enabled")) continue;

        // Read modes (first line is current mode)
        const modes_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/modes", .{entry.name}) catch continue;
        const modes = std.fs.cwd().readFileAlloc(allocator, modes_path, 4096) catch continue;
        defer allocator.free(modes);

        var lines = std.mem.splitScalar(u8, modes, '\n');
        const first_mode = lines.next() orelse continue;
        if (first_mode.len == 0) continue;

        // Parse "1920x1080" format
        return try allocator.dupe(u8, first_mode);
    }

    return null;
}

fn getDisplayFromXrandr(allocator: Allocator) !?[]const u8 {
    // Check if X11 is running (non-allocating check)
    const has_display = std.process.hasEnvVar(allocator, "DISPLAY") catch return null;
    if (!has_display) return null;

    // Run xrandr and parse output
    var child = std.process.Child.init(&.{ "xrandr", "--current" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout = child.stdout orelse return null;
    const output = stdout.readToEndAlloc(allocator, 64 * 1024) catch return null;
    defer allocator.free(output);

    _ = child.wait() catch {};

    // Parse xrandr output for connected displays
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Look for " connected " and resolution with "*" (current)
        if (std.mem.indexOf(u8, line, " connected") != null) {
            // Next lines contain resolutions, look for one with *
            while (lines.next()) |res_line| {
                if (res_line.len == 0 or res_line[0] != ' ') break;
                if (std.mem.indexOf(u8, res_line, "*") == null) continue;

                // Parse "   1920x1080     60.00*+"
                const trimmed = std.mem.trim(u8, res_line, " \t");
                var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
                const resolution = parts.next() orelse continue;
                const refresh_str = parts.next();

                if (refresh_str) |r| {
                    // Remove * and + from refresh
                    var refresh = r;
                    while (refresh.len > 0 and (refresh[refresh.len - 1] == '*' or refresh[refresh.len - 1] == '+')) {
                        refresh = refresh[0 .. refresh.len - 1];
                    }
                    return try std.fmt.allocPrint(allocator, "{s} @ {s} Hz", .{ resolution, refresh });
                }
                return try allocator.dupe(u8, resolution);
            }
        }
    }

    return null;
}
