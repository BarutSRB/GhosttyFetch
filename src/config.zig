const std = @import("std");
const types = @import("types.zig");
const paths = @import("paths.zig");

const Allocator = types.Allocator;
const Config = types.Config;
const ColorPreferences = types.ColorPreferences;
const GradientPreferences = types.GradientPreferences;
const config_file = types.config_file;
const default_sysinfo_modules = types.default_sysinfo_modules;
const default_rgb = types.default_rgb;

pub fn resolveFps(allocator: Allocator, config: Config) !f64 {
    const env = std.process.getEnvVarOwned(allocator, "GHOSTTY_FPS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env) |fps_env| {
        defer allocator.free(fps_env);
        return try std.fmt.parseFloat(f64, fps_env);
    }

    if (config.fps) |configured| return configured;

    return 20.0;
}

pub fn loadConfig(allocator: Allocator) !Config {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const raw = std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.MissingConfig,
        else => return err,
    };
    defer allocator.free(raw);

    const RawSysInfo = struct {
        enabled: ?bool = null,
        modules: ?[]const []const u8 = null,
    };

    const RawConfig = struct {
        fps: ?f64 = null,
        color: ?[]const u8 = null,
        force_color: ?bool = null,
        no_color: ?bool = null,
        white_gradient_colors: ?[]const []const u8 = null,
        white_gradient_scroll: ?bool = null,
        white_gradient_scroll_speed: ?f64 = null,
        sysinfo: ?RawSysInfo = null,
    };

    const parsed = try std.json.parseFromSlice(RawConfig, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var config = Config{};
    config.sysinfo.modules = try dupDefaultSysInfoModules(allocator);

    if (parsed.value.fps) |v| config.fps = v;
    if (parsed.value.force_color) |v| config.force_color = v;
    if (parsed.value.no_color) |v| config.no_color = v;
    if (parsed.value.color) |c| config.color = try allocator.dupe(u8, c);
    if (parsed.value.white_gradient_colors) |colors| {
        config.white_gradient_colors = try dupStringSlice(allocator, colors);
    }
    if (parsed.value.white_gradient_scroll) |scroll| config.white_gradient_scroll = scroll;
    if (parsed.value.white_gradient_scroll_speed) |speed| config.white_gradient_scroll_speed = speed;
    if (parsed.value.sysinfo) |si| {
        if (si.enabled) |v| config.sysinfo.enabled = v;
        if (si.modules) |mods| {
            freeSysInfoModules(allocator, config.sysinfo.modules);
            config.sysinfo.modules = try dupStringSlice(allocator, mods);
        }
    }

    return config;
}

pub fn freeConfig(allocator: Allocator, config: Config) void {
    if (config.color) |c| allocator.free(c);
    if (config.white_gradient_colors) |colors| freeStringSliceOwned(allocator, colors);
    freeSysInfoModules(allocator, config.sysinfo.modules);
}

fn dupDefaultSysInfoModules(allocator: Allocator) ![]const []const u8 {
    return try dupStringSlice(allocator, &default_sysinfo_modules);
}

fn dupStringSlice(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }

    for (values) |value| {
        out[initialized] = try allocator.dupe(u8, value);
        initialized += 1;
    }

    return out;
}

fn freeSysInfoModules(allocator: Allocator, modules: []const []const u8) void {
    freeStringSliceOwned(allocator, modules);
}

fn freeStringSliceOwned(allocator: Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn configPath(allocator: Allocator) ![]u8 {
    if (try paths.findDataFile(allocator, config_file)) |result| {
        return result.path;
    }
    return error.MissingConfig;
}

pub fn colorPreferences(allocator: Allocator, config: Config, is_tty: bool, fps: f64) !ColorPreferences {
    const color_code = try resolveColorCode(allocator, config);
    const gradient = try resolveGradientPreferences(allocator, config, fps);

    const force_env = try std.process.hasEnvVar(allocator, "FORCE_COLOR");
    const no_color_env = try std.process.hasEnvVar(allocator, "NO_COLOR");

    const force = if (force_env) true else config.force_color orelse false;
    const no_color = if (no_color_env) true else config.no_color orelse false;

    const enable = color_code != null and !no_color and (is_tty or force);

    return .{
        .enable = enable,
        .color_code = color_code,
        .gradient = gradient,
    };
}

pub fn freeColorPreferences(allocator: Allocator, prefs: ColorPreferences) void {
    if (prefs.color_code) |code| allocator.free(code);
    freeGradientColors(allocator, prefs.gradient.colors);
}

fn freeGradientColors(allocator: Allocator, colors: []const []const u8) void {
    freeStringSliceOwned(allocator, colors);
}

fn resolveColorCode(allocator: Allocator, config: Config) !?[]const u8 {
    const env_color = std.process.getEnvVarOwned(allocator, "GHOSTTY_COLOR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_color) |raw_env| {
        defer allocator.free(raw_env);
        return try parseColorString(allocator, raw_env);
    }

    if (config.color) |value| {
        return try parseColorString(allocator, value);
    }

    const code = try defaultColorCode(allocator);
    return code;
}

fn resolveGradientPreferences(allocator: Allocator, config: Config, fps: f64) !GradientPreferences {
    const colors = try resolveGradientColors(allocator, config.white_gradient_colors);
    const scroll = config.white_gradient_scroll orelse false;
    const scroll_speed = normalizeScrollSpeed(config.white_gradient_scroll_speed, fps);
    return .{
        .colors = colors,
        .scroll = scroll,
        .scroll_speed = scroll_speed,
        .fps = fps,
    };
}

fn resolveGradientColors(allocator: Allocator, configured: ?[]const []const u8) ![]const []const u8 {
    if (configured) |raw| {
        return try parseGradientList(allocator, raw);
    }
    return try defaultGradientColors(allocator);
}

fn normalizeScrollSpeed(configured: ?f64, fps: f64) f64 {
    const safe_fps = if (fps > 0) fps else 20.0;
    const chosen = configured orelse safe_fps;
    if (chosen <= 0) return safe_fps;
    return chosen;
}

fn parseColorString(allocator: Allocator, input: []const u8) !?[]const u8 {
    if (input.len == 0) {
        const code = try defaultColorCode(allocator);
        return code;
    }

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const lowered = try allocator.alloc(u8, trimmed.len);
    defer allocator.free(lowered);
    _ = std.ascii.lowerString(lowered, trimmed);

    if (isOffValue(lowered)) return null;

    var value = lowered;
    if (value.len > 0 and value[0] == '#') {
        value = value[1..];
    }

    if (value.len == 6) {
        const r = std.fmt.parseInt(u8, value[0..2], 16) catch return try rawColorCode(allocator, trimmed);
        const g = std.fmt.parseInt(u8, value[2..4], 16) catch return try rawColorCode(allocator, trimmed);
        const b = std.fmt.parseInt(u8, value[4..6], 16) catch return try rawColorCode(allocator, trimmed);
        return try rgbColorCode(allocator, r, g, b);
    }

    return try rawColorCode(allocator, trimmed);
}

fn parseGradientList(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    var parsed = std.ArrayList([]const u8).empty;
    errdefer freeStringSliceOwned(allocator, parsed.items);

    for (values) |value| {
        const code = try parseColorString(allocator, value);
        if (code) |c| try parsed.append(allocator, c);
    }

    return try parsed.toOwnedSlice(allocator);
}

fn isOffValue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "none");
}

fn defaultColorCode(allocator: Allocator) ![]const u8 {
    return try rgbColorCode(allocator, default_rgb[0], default_rgb[1], default_rgb[2]);
}

fn defaultGradientColors(allocator: Allocator) ![]const []const u8 {
    const palette = [_][]const u8{
        "#d7ff9e",
        "#c3f364",
        "#f2e85e",
        "#f5c95c",
        "#f17f5b",
        "#f45c82",
        "#de6fd2",
        "#b07cf4",
        "#8b8cf8",
        "#74a4ff",
        "#78b8ff",
    };
    return try parseGradientList(allocator, &palette);
}

fn rgbColorCode(allocator: Allocator, r: u8, g: u8, b: u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
}

fn rawColorCode(allocator: Allocator, raw: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "\x1b[{s}m", .{raw});
}
