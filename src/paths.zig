const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const SearchResult = struct {
    path: []u8,
    source: Source,

    pub const Source = enum {
        xdg_config,
        xdg_data,
        system,
        executable_relative,
    };
};

/// Search for a file in standard locations (XDG + fallbacks)
/// Search order:
/// 1. XDG_CONFIG_HOME or ~/.config/ghosttyfetch/
/// 2. XDG_DATA_HOME or ~/.local/share/ghosttyfetch/
/// 3. System locations: /usr/local/share/ghosttyfetch/, /usr/share/ghosttyfetch/
/// 4. Relative to executable
pub fn findDataFile(allocator: Allocator, filename: []const u8) !?SearchResult {
    // 1. XDG_CONFIG_HOME or ~/.config/ghosttyfetch/
    if (try searchXdgConfig(allocator, filename)) |path| {
        return .{ .path = path, .source = .xdg_config };
    }

    // 2. XDG_DATA_HOME or ~/.local/share/ghosttyfetch/
    if (try searchXdgData(allocator, filename)) |path| {
        return .{ .path = path, .source = .xdg_data };
    }

    // 3. System locations
    if (try searchSystemPaths(allocator, filename)) |path| {
        return .{ .path = path, .source = .system };
    }

    // 4. Relative to executable
    if (try searchRelativeToExe(allocator, filename)) |path| {
        return .{ .path = path, .source = .executable_relative };
    }

    return null;
}

fn searchXdgConfig(allocator: Allocator, filename: []const u8) !?[]u8 {
    const config_home = getXdgConfigHome(allocator) catch return null;
    defer allocator.free(config_home);

    const path = try std.fs.path.join(allocator, &.{ config_home, "ghosttyfetch", filename });
    errdefer allocator.free(path);

    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn searchXdgData(allocator: Allocator, filename: []const u8) !?[]u8 {
    const data_home = getXdgDataHome(allocator) catch return null;
    defer allocator.free(data_home);

    const path = try std.fs.path.join(allocator, &.{ data_home, "ghosttyfetch", filename });
    errdefer allocator.free(path);

    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn searchSystemPaths(allocator: Allocator, filename: []const u8) !?[]u8 {
    const system_dirs = [_][]const u8{
        "/usr/local/share/ghosttyfetch",
        "/usr/share/ghosttyfetch",
        "/opt/ghosttyfetch",
    };

    for (system_dirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ dir, filename });
        errdefer allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return null;
}

fn searchRelativeToExe(allocator: Allocator, filename: []const u8) !?[]u8 {
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch return null;

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;

    // Try same directory as executable
    const path = try std.fs.path.join(allocator, &.{ exe_dir, filename });
    errdefer allocator.free(path);

    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn getXdgConfigHome(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |config_home| {
        return config_home;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return try std.fs.path.join(allocator, &.{ home, ".config" });
        },
        else => return err,
    }
}

fn getXdgDataHome(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |data_home| {
        return data_home;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return try std.fs.path.join(allocator, &.{ home, ".local", "share" });
        },
        else => return err,
    }
}
