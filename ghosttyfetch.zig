const std = @import("std");

const Allocator = std.mem.Allocator;
const posix = std.posix;

const span_open = "<span class=\"b\">";
const span_close = "</span>";
const reset_code = "\x1b[0m";
const clear_screen = "\x1b[H\x1b[2J";
const data_file = "animation.json";
const config_file = "config.json";
const default_rgb = [_]u8{ 53, 81, 243 };
const fastfetch_output_limit: usize = 4 * 1024 * 1024;
const info_column_width: usize = 80;
const shell_version_limit: usize = 8 * 1024;
const max_command_length: usize = 2048;

const FramesFile = struct {
    frames: []const []const u8,
};

const GradientPreferences = struct {
    colors: []const []const u8,
    scroll: bool,
    scroll_speed: f64,
    fps: f64,
};

const ColorPreferences = struct {
    enable: bool,
    color_code: ?[]const u8,
    gradient: GradientPreferences,
};

const InfoColors = struct {
    accent: []const u8,
    muted: []const u8,
    value: []const u8,
    strong: []const u8,
    reset: []const u8,
};

const FastfetchConfig = struct {
    enabled: bool = true,
    command: []const u8 = "fastfetch",
    modules: []const []const u8 = &[_][]const u8{},
    list_available: bool = false,
};

const Config = struct {
    fps: ?f64 = null,
    color: ?[]const u8 = null,
    force_color: ?bool = null,
    no_color: ?bool = null,
    white_gradient_colors: ?[]const []const u8 = null,
    white_gradient_scroll: ?bool = null,
    white_gradient_scroll_speed: ?f64 = null,
    fastfetch: FastfetchConfig = .{},
};

const FastfetchModule = struct {
    type: []const u8,
    result: ?std.json.Value = null,
    @"error": ?[]const u8 = null,
};

const default_fastfetch_modules = [_][]const u8{
    "Title",
    "OS",
    "Host",
    "Kernel",
    "CPU",
    "GPU",
    "Memory",
    "Disk",
    "LocalIp",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var exit_status: ?u8 = null;
    defer if (exit_status) |code| std.process.exit(code);

    const stdout_file = std.fs.File.stdout();
    const config = loadConfig(allocator) catch |err| {
        if (err == error.MissingConfig) {
            std.debug.print("Config file '{s}' is required. Please create it next to play_animation.zig.\n", .{config_file});
        }
        return err;
    };
    defer freeConfig(allocator, config);

    const fps = try resolveFps(allocator, config);
    const prefs = try colorPreferences(allocator, config, stdout_file.isTty(), fps);
    defer freeColorPreferences(allocator, prefs);

    const fastfetch_lines = try loadFastfetchLines(allocator, config.fastfetch);
    defer freeFastfetchLines(allocator, fastfetch_lines);
    const styled_info = try stylizeInfoLines(allocator, fastfetch_lines, info_column_width, prefs);
    defer freeFastfetchLines(allocator, styled_info);

    const frames = try loadFrames(allocator, prefs);
    defer freeFrames(allocator, frames);

    const frame_width = maxFrameVisibleWidth(allocator, frames) catch 0;
    const info_start_col = frame_width + 4;
    const delay_ns = fpsToDelayNs(fps);

    const info_colors = resolveInfoColors(prefs);
    const prompt_prefix = try buildPromptPrefix(allocator, prefs);
    defer allocator.free(prompt_prefix);

    var input_buffer = std.ArrayList(u8).empty;
    defer input_buffer.deinit(allocator);

    const stdin_file = std.fs.File.stdin();
    var term_mode = try TerminalMode.enable(stdin_file);
    defer term_mode.restore();

    var submitted_command: ?[]u8 = null;
    defer if (submitted_command) |cmd| allocator.free(cmd);

    var keep_running = true;
    while (keep_running) {
        for (frames) |frame| {
            if (submitted_command == null) {
                submitted_command = try captureInput(allocator, stdin_file, &input_buffer);
            }

            const prompt_line = try renderPromptLine(allocator, prompt_prefix, input_buffer.items, info_colors);
            defer allocator.free(prompt_line);

            const combined = try combineFrameAndInfo(allocator, frame, styled_info, info_start_col);
            defer allocator.free(combined);

            const with_prompt = try appendPromptLines(allocator, combined, prompt_line);
            defer allocator.free(with_prompt);

            try stdout_file.writeAll(clear_screen);
            try stdout_file.writeAll(with_prompt);

            if (submitted_command != null) {
                keep_running = false;
                break;
            }

            std.Thread.sleep(delay_ns);
        }
    }

    term_mode.restore();

    if (submitted_command) |cmd| {
        const command = std.mem.trim(u8, cmd, " \t\r\n");
        if (command.len == 0) return;

        try stdout_file.writeAll(clear_screen);
        try stdout_file.writeAll(prompt_prefix);
        try stdout_file.writeAll(command);
        try stdout_file.writeAll("\n");

        const code = try runCommandInShell(allocator, command);
        exit_status = @as(u8, @intCast(code));
    }
}

fn loadFrames(allocator: Allocator, prefs: ColorPreferences) ![]const []const u8 {
    const path = try animationPath(allocator);
    defer allocator.free(path);

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(FramesFile, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var frames = std.ArrayList([]const u8).empty;
    errdefer freeFrames(allocator, frames.items);

    for (parsed.value.frames, 0..) |frame_text, idx| {
        const rendered = try renderFrame(allocator, frame_text, prefs, idx);
        frames.append(allocator, rendered) catch |err| {
            allocator.free(rendered);
            return err;
        };
    }

    return try frames.toOwnedSlice(allocator);
}

fn freeFrames(allocator: Allocator, frames: []const []const u8) void {
    for (frames) |frame| allocator.free(frame);
    allocator.free(frames);
}

fn animationPath(allocator: Allocator) ![]u8 {
    const src_dir = std.fs.path.dirname(@src().file) orelse ".";
    return try std.fs.path.join(allocator, &.{ src_dir, data_file });
}

fn maxFrameVisibleWidth(_: Allocator, frames: []const []const u8) !usize {
    var max: usize = 0;
    for (frames) |frame| {
        var it = std.mem.splitScalar(u8, frame, '\n');
        while (it.next()) |line| {
            const w = visibleWidth(line);
            if (w > max) max = w;
        }
    }
    return max;
}

fn resolveFps(allocator: Allocator, config: Config) !f64 {
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

fn fpsToDelayNs(fps: f64) u64 {
    if (fps > 0) {
        const delay = @as(f64, @floatFromInt(std.time.ns_per_s)) / fps;
        return @as(u64, @intFromFloat(delay));
    }
    return 50 * std.time.ns_per_ms;
}

fn renderFrame(allocator: Allocator, frame: []const u8, prefs: ColorPreferences, frame_index: usize) ![]const u8 {
    const has_span = std.mem.indexOf(u8, frame, span_open) != null;
    const brand_color = if (prefs.enable and prefs.color_code != null) prefs.color_code.? else null;
    const gradient_active = prefs.enable and prefs.gradient.colors.len > 0;

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| try lines.append(allocator, line);

    const art_range = if (gradient_active) detectArtRange(lines.items) else ArtRange{ .start = 0, .end = 0, .height = 0, .has_content = false };

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (lines.items, 0..) |line, line_idx| {
        const line_gradient = if (gradient_active) gradientColorForLine(art_range, prefs.gradient, line_idx, frame_index) else null;
        const base_color = line_gradient orelse (if (!has_span and brand_color != null and prefs.enable) brand_color else null);

        var color_active = false;
        if (base_color) |code| {
            try out.appendSlice(allocator, code);
            color_active = true;
        }

        var j: usize = 0;
        while (j < line.len) : (j += 1) {
            if (std.mem.startsWith(u8, line[j..], span_open)) {
                if (brand_color) |code| {
                    try out.appendSlice(allocator, code);
                    color_active = true;
                }
                j += span_open.len - 1;
                continue;
            }

            if (std.mem.startsWith(u8, line[j..], span_close)) {
                if (base_color) |code| {
                    try out.appendSlice(allocator, code);
                    color_active = true;
                } else if (color_active) {
                    try out.appendSlice(allocator, reset_code);
                    color_active = false;
                }
                j += span_close.len - 1;
                continue;
            }

            try out.append(allocator, line[j]);
        }

        if (color_active) try out.appendSlice(allocator, reset_code);
        if (line_idx + 1 < lines.items.len) try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

const ArtRange = struct {
    start: usize,
    end: usize,
    height: usize,
    has_content: bool,
};

fn detectArtRange(lines: []const []const u8) ArtRange {
    var start: usize = 0;
    var found = false;
    for (lines, 0..) |line, idx| {
        if (lineHasArt(line)) {
            start = idx;
            found = true;
            break;
        }
    }
    if (!found) return .{ .start = 0, .end = 0, .height = 0, .has_content = false };

    var end: usize = start;
    var idx: usize = lines.len;
    while (idx > start) {
        idx -= 1;
        if (lineHasArt(lines[idx])) {
            end = idx;
            break;
        }
    }

    return .{ .start = start, .end = end, .height = end - start + 1, .has_content = true };
}

fn lineHasArt(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (std.mem.startsWith(u8, line[i..], span_open)) {
            i += span_open.len - 1;
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], span_close)) {
            i += span_close.len - 1;
            continue;
        }
        switch (line[i]) {
            ' ', '\t', '\r' => {},
            else => return true,
        }
    }
    return false;
}

fn gradientColorForLine(range: ArtRange, gradient: GradientPreferences, line_index: usize, frame_index: usize) ?[]const u8 {
    if (!range.has_content or gradient.colors.len == 0) return null;
    if (line_index < range.start or line_index > range.end) return null;
    if (range.height == 0) return null;

    const scroll_step = scrollOffset(range, gradient, frame_index);
    const relative = line_index - range.start;
    const shifted = if (range.height == 0) relative else (relative + range.height - scroll_step) % range.height;

    if (gradient.colors.len == 1 or range.height <= 1) return gradient.colors[0];

    const grad_idx = (shifted * (gradient.colors.len - 1)) / (range.height - 1);
    return gradient.colors[grad_idx];
}

fn scrollOffset(range: ArtRange, gradient: GradientPreferences, frame_index: usize) usize {
    if (!gradient.scroll or gradient.scroll_speed <= 0 or gradient.fps <= 0) return 0;
    if (range.height == 0) return 0;

    const elapsed = @as(f64, @floatFromInt(frame_index)) / gradient.fps;
    const steps_f = elapsed * gradient.scroll_speed;
    const steps = if (steps_f < 0) 0 else @as(usize, @intFromFloat(std.math.floor(steps_f)));
    if (steps == 0) return 0;
    return steps % range.height;
}

fn loadConfig(allocator: Allocator) !Config {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const raw = std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.MissingConfig,
        else => return err,
    };
    defer allocator.free(raw);

    const RawFastfetch = struct {
        enabled: ?bool = null,
        command: ?[]const u8 = null,
        modules: ?[]const []const u8 = null,
        list_available: ?bool = null,
    };

    const RawConfig = struct {
        fps: ?f64 = null,
        color: ?[]const u8 = null,
        force_color: ?bool = null,
        no_color: ?bool = null,
        white_gradient_colors: ?[]const []const u8 = null,
        white_gradient_scroll: ?bool = null,
        white_gradient_scroll_speed: ?f64 = null,
        fastfetch: ?RawFastfetch = null,
    };

    const parsed = try std.json.parseFromSlice(RawConfig, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var config = Config{};
    config.fastfetch.command = try allocator.dupe(u8, "fastfetch");
    config.fastfetch.modules = try dupDefaultFastfetchModules(allocator);

    if (parsed.value.fps) |v| config.fps = v;
    if (parsed.value.force_color) |v| config.force_color = v;
    if (parsed.value.no_color) |v| config.no_color = v;
    if (parsed.value.color) |c| config.color = try allocator.dupe(u8, c);
    if (parsed.value.white_gradient_colors) |colors| {
        config.white_gradient_colors = try dupStringSlice(allocator, colors);
    }
    if (parsed.value.white_gradient_scroll) |scroll| config.white_gradient_scroll = scroll;
    if (parsed.value.white_gradient_scroll_speed) |speed| config.white_gradient_scroll_speed = speed;
    if (parsed.value.fastfetch) |ff| {
        if (ff.enabled) |v| config.fastfetch.enabled = v;
        if (ff.list_available) |v| config.fastfetch.list_available = v;
        if (ff.command) |cmd| {
            allocator.free(config.fastfetch.command);
            config.fastfetch.command = try allocator.dupe(u8, cmd);
        }
        if (ff.modules) |mods| {
            freeFastfetchModules(allocator, config.fastfetch.modules);
            config.fastfetch.modules = try dupStringSlice(allocator, mods);
        }
    }

    return config;
}

fn freeConfig(allocator: Allocator, config: Config) void {
    if (config.color) |c| allocator.free(c);
    if (config.white_gradient_colors) |colors| freeFastfetchModules(allocator, colors);
    if (config.fastfetch.command.len > 0) allocator.free(config.fastfetch.command);
    freeFastfetchModules(allocator, config.fastfetch.modules);
}

fn dupDefaultFastfetchModules(allocator: Allocator) ![]const []const u8 {
    return try dupStringSlice(allocator, &default_fastfetch_modules);
}

fn dupStringSlice(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    errdefer {
        for (out) |item| allocator.free(item);
        if (out.len > 0) allocator.free(out);
    }

    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
    }

    return out;
}

fn freeFastfetchModules(allocator: Allocator, modules: []const []const u8) void {
    freeStringSliceOwned(allocator, modules);
}

fn freeStringSliceOwned(allocator: Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn configPath(allocator: Allocator) ![]u8 {
    const src_dir = std.fs.path.dirname(@src().file) orelse ".";
    return try std.fs.path.join(allocator, &.{ src_dir, config_file });
}

fn colorPreferences(allocator: Allocator, config: Config, is_tty: bool, fps: f64) !ColorPreferences {
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

fn freeColorPreferences(allocator: Allocator, prefs: ColorPreferences) void {
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

fn combineFrameAndInfo(allocator: Allocator, frame: []const u8, info_lines: []const []const u8, info_start_col: usize) ![]u8 {
    var art_lines = std.ArrayList([]const u8).empty;
    defer art_lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| {
        try art_lines.append(allocator, line);
    }

    const total = @max(art_lines.items.len, info_lines.len);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (0..total) |idx| {
        const art = if (idx < art_lines.items.len) art_lines.items[idx] else "";
        const info = if (idx < info_lines.len) info_lines[idx] else "";

        try out.appendSlice(allocator, art);
        const move_col = try std.fmt.allocPrint(allocator, "\x1b[{d}G", .{info_start_col});
        defer allocator.free(move_col);
        try out.appendSlice(allocator, move_col);
        try out.appendSlice(allocator, info);
        try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn appendPromptLines(allocator: Allocator, combined: []const u8, prompt_line: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, combined);
    try out.appendSlice(allocator, prompt_line);

    return try out.toOwnedSlice(allocator);
}

fn loadFastfetchLines(allocator: Allocator, config: FastfetchConfig) ![]const []const u8 {
    if (!config.enabled or config.modules.len == 0) {
        return try emptyStringList(allocator);
    }

    const result = runFastfetch(allocator, config.command) catch |err| {
        return try fastfetchErrorLines(allocator, @errorName(err), "");
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                return try fastfetchErrorLines(allocator, "fastfetch exited with non-zero status", result.stderr);
            }
        },
        else => return try fastfetchErrorLines(allocator, "fastfetch terminated unexpectedly", result.stderr),
    }

    const parsed = std.json.parseFromSlice([]FastfetchModule, allocator, result.stdout, .{ .ignore_unknown_fields = true }) catch {
        return try fastfetchErrorLines(allocator, "failed to parse fastfetch JSON", result.stderr);
    };
    defer parsed.deinit();

    if (config.list_available) {
        printFastfetchModules(parsed.value);
    }

    var lines = std.ArrayList([]const u8).empty;
    errdefer freeFastfetchLines(allocator, lines.items);

    for (config.modules) |module_name| {
        const mod = findFastfetchModule(parsed.value, module_name) orelse continue;
        if (mod.@"error") |err_text| {
            const trimmed = std.mem.trim(u8, err_text, " \t\r\n");
            if (trimmed.len != 0) continue;
        }

        if (mod.result == null) continue;

        const formatted = try formatFastfetchResult(allocator, module_name, mod.result.?);
        if (formatted) |value_str| {
            const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ module_name, value_str });
            allocator.free(value_str);
            try lines.append(allocator, line);
        }
    }

    return try lines.toOwnedSlice(allocator);
}

fn freeFastfetchLines(allocator: Allocator, lines: []const []const u8) void {
    for (lines) |line| allocator.free(line);
    if (lines.len > 0) allocator.free(lines);
}

fn printFastfetchModules(modules: []const FastfetchModule) void {
    std.debug.print("fastfetch modules (use config.json fastfetch.modules to choose): ", .{});
    var first = true;
    for (modules) |mod| {
        if (!first) std.debug.print(", ", .{});
        first = false;
        if (mod.result == null and mod.@"error" != null) {
            std.debug.print("{s}(error)", .{mod.type});
        } else {
            std.debug.print("{s}", .{mod.type});
        }
    }
    std.debug.print("\n", .{});
}

const FastfetchResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

fn runFastfetch(allocator: Allocator, command: []const u8) !FastfetchResult {
    var child = std.process.Child.init(&.{ command, "--format", "json" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout_stream = child.stdout orelse return error.FastfetchMissingStdout;
    const stderr_stream = child.stderr orelse return error.FastfetchMissingStderr;

    const stdout_bytes = try stdout_stream.readToEndAlloc(allocator, fastfetch_output_limit);
    const stderr_bytes = try stderr_stream.readToEndAlloc(allocator, 64 * 1024);

    const term = try child.wait();
    return .{ .stdout = stdout_bytes, .stderr = stderr_bytes, .term = term };
}

fn findFastfetchModule(modules: []const FastfetchModule, name: []const u8) ?*const FastfetchModule {
    for (modules) |*mod| {
        if (std.ascii.eqlIgnoreCase(mod.type, name)) return mod;
    }
    return null;
}

fn formatFastfetchResult(allocator: Allocator, module_name: []const u8, result: std.json.Value) !?[]const u8 {
    if (std.ascii.eqlIgnoreCase(module_name, "Theme")) return null;
    if (std.ascii.eqlIgnoreCase(module_name, "Font")) return null;
    if (std.ascii.eqlIgnoreCase(module_name, "Locale")) return null;

    if (std.ascii.eqlIgnoreCase(module_name, "Title")) return try formatTitle(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "OS")) return try formatOS(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Host")) return try formatHost(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Kernel")) return try formatKernel(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Uptime")) return try formatUptime(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Packages")) return try formatPackages(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "WMTheme")) return try formatPlainString(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Cursor")) return try formatCursor(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Shell")) return try formatShell(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Display")) return try formatDisplay(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Terminal")) return try formatTerminal(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "TerminalFont")) return try formatTerminalFont(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "WM")) return try formatWM(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "CPU")) return try formatCpu(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "GPU")) return try formatGpu(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Memory")) return try formatMemory(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Swap")) return try formatSwap(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "Disk")) return try formatDisk(allocator, result);
    if (std.ascii.eqlIgnoreCase(module_name, "LocalIp")) return try formatLocalIp(allocator, result);

    return try friendlyJsonValue(allocator, result);
}

fn formatTitle(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const user = stringField(obj, "userName") orelse return null;
    const host = stringField(obj, "hostName") orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}@{s}", .{ user, host });
}

fn formatOS(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    if (stringField(obj, "prettyName")) |pretty| {
        return try allocator.dupe(u8, pretty);
    }
    return null;
}

fn formatHost(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const name = stringField(obj, "name") orelse stringField(obj, "productName") orelse stringField(obj, "family");
    const version = stringField(obj, "productVersion") orelse stringField(obj, "version");
    const vendor = stringField(obj, "vendor");

    if (name != null and version != null and version.?.len > 0) {
        return try std.fmt.allocPrint(allocator, "{s} ({s})", .{ name.?, version.? });
    }
    if (name != null) return try allocator.dupe(u8, name.?);
    if (vendor != null) return try allocator.dupe(u8, vendor.?);
    return null;
}

fn formatKernel(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const name = stringField(obj, "name") orelse return null;
    const release = stringField(obj, "release");
    const arch = stringField(obj, "architecture");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, name);
    if (release) |rel| {
        try out.appendSlice(allocator, " ");
        try out.appendSlice(allocator, rel);
    }
    if (arch) |a| {
        if (!std.mem.containsAtLeast(u8, out.items, 1, a)) {
            try out.appendSlice(allocator, " ");
            try out.appendSlice(allocator, a);
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn formatUptime(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const days = parseI64Field(obj, "days") orelse 0;
    const hours = parseI64Field(obj, "hours") orelse 0;
    const minutes = parseI64Field(obj, "minutes") orelse 0;

    var parts = std.ArrayList([]const u8).empty;
    errdefer {
        for (parts.items) |item| allocator.free(item);
        parts.deinit(allocator);
    }

    if (days > 0) try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} days", .{days}));
    if (hours > 0) try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} hours", .{hours}));
    if (minutes > 0) try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} mins", .{minutes}));

    if (parts.items.len == 0) {
        parts.deinit(allocator);
        return null;
    }

    const joined = try std.mem.join(allocator, ", ", parts.items);
    for (parts.items) |item| allocator.free(item);
    parts.deinit(allocator);
    return joined;
}

fn formatPackages(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const brew = parseI64Field(obj, "brew") orelse 0;
    const brew_cask = parseI64Field(obj, "brewCask") orelse 0;

    if (brew == 0 and brew_cask == 0) return null;

    if (brew > 0 and brew_cask > 0) {
        return try std.fmt.allocPrint(allocator, "{d} (brew), {d} (brew-cask)", .{ brew, brew_cask });
    }
    if (brew > 0) {
        return try std.fmt.allocPrint(allocator, "{d} (brew)", .{brew});
    }
    return try std.fmt.allocPrint(allocator, "{d} (brew-cask)", .{brew_cask});
}

fn formatCursor(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const theme = stringField(obj, "theme") orelse return null;
    const size = stringField(obj, "size");

    if (size) |sz| {
        return try std.fmt.allocPrint(allocator, "{s} ({s}px)", .{ theme, sz });
    }
    return try allocator.dupe(u8, theme);
}

fn formatShell(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const env_shell = std.process.getEnvVarOwned(allocator, "SHELL") catch null;
    defer if (env_shell) |s| allocator.free(s);

    const env_name = blk: {
        if (env_shell) |path| {
            const base = std.fs.path.basename(path);
            if (base.len > 0 and isPrintableAscii(base) and !isUnhelpfulShellName(base)) break :blk base;
        }
        break :blk null;
    };

    var name = blk: {
        const direct = stringField(obj, "prettyName") orelse stringField(obj, "processName") orelse stringField(obj, "exeName") orelse stringField(obj, "exe") orelse stringField(obj, "exePath");
        if (direct != null) {
            if (isPrintableAscii(direct.?) and !isUnhelpfulShellName(direct.?)) break :blk direct.?;
        }
        break :blk null;
    };

    if (name == null) name = env_name;
    if (name == null) return null;

    var version_owned: ?[]u8 = null;
    if (stringField(obj, "version")) |ver| {
        version_owned = try cleanVersionString(allocator, ver);
    }

    if (version_owned == null) {
        if (env_shell) |path| {
            const raw = try shellVersionFromPath(allocator, path) orelse null;
            if (raw) |raw_ver| {
                version_owned = try cleanVersionString(allocator, raw_ver);
                allocator.free(raw_ver);
            }
        }
    }

    if (version_owned) |ver| {
        defer allocator.free(ver);
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ name.?, ver });
    }
    return try allocator.dupe(u8, name.?);
}

fn formatTerminal(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const name = stringField(obj, "prettyName") orelse return null;
    const version = stringField(obj, "version");

    if (version) |ver| {
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ name, ver });
    }
    return try allocator.dupe(u8, name);
}

fn formatWM(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const pretty = stringField(obj, "prettyName") orelse stringField(obj, "processName");
    const version = stringField(obj, "version");

    if (pretty == null and version == null) return null;
    if (pretty != null and version != null and version.?.len > 0) {
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ pretty.?, version.? });
    }
    if (pretty != null) return try allocator.dupe(u8, pretty.?);
    return try allocator.dupe(u8, version.?);
}

fn formatTerminalFont(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const font_val = obj.get("font") orelse return null;
    const font_obj = switch (font_val) {
        .object => |o| o,
        else => return null,
    };
    const primary = stringField(font_obj, "pretty") orelse return null;

    // Only show the primary font, omit fallbacks.
    return try allocator.dupe(u8, primary);
}

fn formatDisplay(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const arr = switch (value) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;

    const chosen = blk: {
        var primary: ?std.json.ObjectMap = null;
        for (arr.items) |item| {
            if (item != .object) continue;
            if (boolField(item.object, "primary") orelse false) break :blk item.object;
            if (primary == null) primary = item.object;
        }
        if (primary) |obj| break :blk obj;
        return null;
    };

    const name = stringField(chosen, "name") orelse "Display";
    _ = stringField(chosen, "type"); // suppress type marker such as "(External)"

    const dim_obj = blk: {
        const prefer = chosen.get("preferred");
        if (prefer != null and prefer.? == .object) break :blk prefer.?.object;
        const output = chosen.get("output");
        if (output != null and output.? == .object) break :blk output.?.object;
        const scaled = chosen.get("scaled");
        if (scaled != null and scaled.? == .object) break :blk scaled.?.object;
        break :blk null;
    };

    const width = if (dim_obj) |d| parseI64Field(d, "width") else null;
    const height = if (dim_obj) |d| parseI64Field(d, "height") else null;
    const refresh = if (dim_obj) |d| parseF64Field(d, "refreshRate") else null;
    const scale = if (dim_obj == null) null else blk: {
        const scaled_obj = chosen.get("scaled");
        if (scaled_obj != null and scaled_obj.? == .object) {
            const sw = parseI64Field(scaled_obj.?.object, "width");
            if (sw != null and width != null and sw.? > width.?) {
                break :blk @as(f64, @floatFromInt(sw.?)) / @as(f64, @floatFromInt(width.?));
            }
        }
        break :blk null;
    };

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, name);

    if (width != null and height != null) {
        try out.appendSlice(allocator, ": ");
        try out.writer(allocator).print("{d}x{d}", .{ width.?, height.? });
        if (scale) |s| {
            if (s > 1.01) try out.writer(allocator).print(" @ {d:.1}x", .{s});
        }
    }
    if (refresh) |hz| {
        if (hz > 0) {
            try out.appendSlice(allocator, " @ ");
            try out.writer(allocator).print("{d:.0} Hz", .{hz});
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn formatCpu(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const name = stringField(obj, "name") orelse stringField(obj, "cpu") orelse return null;

    var freq_mhz: ?f64 = parseF64Field(obj, "frequency");
    if (freq_mhz == null) {
        if (obj.get("frequency")) |freq_val| {
            if (freq_val == .object) {
                const max = parseF64Field(freq_val.object, "max");
                const base = parseF64Field(freq_val.object, "base");
                freq_mhz = max orelse base;
            }
        }
    }

    var cores: ?i64 = parseI64Field(obj, "coreCount");
    if (cores == null) {
        if (obj.get("cores")) |core_val| {
            if (core_val == .object) {
                const phys = parseI64Field(core_val.object, "physical");
                const logical = parseI64Field(core_val.object, "logical");
                cores = phys orelse logical;
            }
        }
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, name);
    if (cores) |c| {
        try out.appendSlice(allocator, " ");
        try out.writer(allocator).print("({d})", .{c});
    }
    if (freq_mhz) |f| {
        try out.appendSlice(allocator, " @ ");
        try out.writer(allocator).print("{d:.2} GHz", .{f / 1000.0});
    }

    return try out.toOwnedSlice(allocator);
}

fn formatGpu(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const arr = switch (value) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;

    const first = arr.items[0];
    const obj = switch (first) {
        .object => |o| o,
        else => return null,
    };

    const name = stringField(obj, "name");
    const freq_mhz = parseF64Field(obj, "frequency");
    const cores = parseI64Field(obj, "coreCount");
    _ = stringField(obj, "type"); // skip kind such as "[Integrated]"

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (name) |n| try out.appendSlice(allocator, n);
    if (cores) |c| {
        if (out.items.len > 0) try out.appendSlice(allocator, " ");
        try out.writer(allocator).print("({d})", .{c});
    }
    if (freq_mhz) |f| {
        if (out.items.len > 0) try out.appendSlice(allocator, " ");
        try out.writer(allocator).print("@ {d:.2} GHz", .{f / 1000.0});
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }

    return try out.toOwnedSlice(allocator);
}

fn formatMemory(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const total_val = obj.get("total") orelse return null;
    const used_val = obj.get("used") orelse return null;

    const total = parseU64(total_val) orelse return null;
    const used = parseU64(used_val) orelse return null;

    return try formatBytes(allocator, used, total);
}

fn formatSwap(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };

    const total_val = obj.get("total") orelse return null;
    const used_val = obj.get("used") orelse return null;

    const total = parseU64(total_val) orelse return null;
    const used = parseU64(used_val) orelse return null;

    return try formatBytes(allocator, used, total);
}

fn formatDisk(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const arr = switch (value) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;

    const chosen = blk: {
        var preferred: ?std.json.ObjectMap = null;
        for (arr.items) |item| {
            if (item != .object) continue;
            const mp = stringField(item.object, "mountpoint");
            if (mp != null and std.mem.eql(u8, mp.?, "/")) break :blk item.object;
            if (preferred == null) preferred = item.object;
        }
        if (preferred) |p| break :blk p;
        return null;
    };

    const bytes_val = chosen.get("bytes") orelse return null;
    const bytes_obj = switch (bytes_val) {
        .object => |o| o,
        else => return null,
    };

    const total = parseU64Field(bytes_obj, "total") orelse return null;
    const used = parseU64Field(bytes_obj, "used") orelse return null;

    const base = try formatBytes(allocator, used, total);

    return base; // omit filesystem/volume details
}

fn formatLocalIp(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    const arr = switch (value) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;

    const first = arr.items[0];
    const obj = switch (first) {
        .object => |o| o,
        else => return null,
    };

    const addr = stringField(obj, "address") orelse return null;
    const iface = stringField(obj, "interfaceName");

    if (iface) |i| {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ addr, i });
    }
    return try allocator.dupe(u8, addr);
}

fn formatPlainString(allocator: Allocator, value: std.json.Value) !?[]const u8 {
    switch (value) {
        .string => |s| return try allocator.dupe(u8, std.mem.trim(u8, s, " \t\r\n")),
        else => {},
    }
    return null;
}

fn friendlyJsonValue(allocator: Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .string => |s| return try allocator.dupe(u8, std.mem.trim(u8, s, " \t\r\n")),
        .number_string => |s| return try allocator.dupe(u8, std.mem.trim(u8, s, " \t\r\n")),
        .bool => |b| return try std.fmt.allocPrint(allocator, "{s}", .{if (b) "true" else "false"}),
        .integer => |i| return try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .array => |arr| {
            var items = std.ArrayList([]const u8).empty;
            errdefer {
                for (items.items) |item| allocator.free(item);
                items.deinit(allocator);
            }
            for (arr.items) |item| {
                const rendered = try friendlyJsonValue(allocator, item);
                try items.append(allocator, rendered);
            }
            const joined = try std.mem.join(allocator, ", ", items.items);
            for (items.items) |item| allocator.free(item);
            items.deinit(allocator);
            return joined;
        },
        .object => {
            return try std.fmt.allocPrint(
                allocator,
                "{f}",
                .{std.json.fmt(value, .{ .whitespace = .minified })},
            );
        },
        .null => return try allocator.dupe(u8, "null"),
    }
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        switch (v) {
            .string => |s| return std.mem.trim(u8, s, " \t\r\n"),
            .number_string => |s| return std.mem.trim(u8, s, " \t\r\n"),
            else => return null,
        }
    }
    return null;
}

fn parseI64Field(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj.get(key)) |v| return parseI64(v);
    return null;
}

fn parseF64Field(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    if (obj.get(key)) |v| return parseF64(v);
    return null;
}

fn parseU64Field(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    if (obj.get(key)) |v| return parseU64(v);
    return null;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    if (obj.get(key)) |v| {
        switch (v) {
            .bool => |b| return b,
            else => return null,
        }
    }
    return null;
}

fn parseI64(value: std.json.Value) ?i64 {
    switch (value) {
        .integer => |i| return i,
        .float => |f| return @as(i64, @intFromFloat(f)),
        .number_string => |s| return std.fmt.parseInt(i64, s, 10) catch null,
        else => return null,
    }
}

fn parseF64(value: std.json.Value) ?f64 {
    switch (value) {
        .float => |f| return f,
        .integer => |i| return @as(f64, @floatFromInt(i)),
        .number_string => |s| return std.fmt.parseFloat(f64, s) catch null,
        else => return null,
    }
}

fn parseU64(value: std.json.Value) ?u64 {
    switch (value) {
        .integer => |i| {
            if (i < 0) return null;
            return @as(u64, @intCast(i));
        },
        .float => |f| {
            if (f < 0) return null;
            return @as(u64, @intFromFloat(f));
        },
        .number_string => |s| return std.fmt.parseInt(u64, s, 10) catch null,
        else => return null,
    }
}

fn formatBytes(allocator: Allocator, used: u64, total: u64) ![]const u8 {
    if (total == 0) return try allocator.dupe(u8, "n/a");
    const percent = @as(u8, @intFromFloat((@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total))) * 100.0));
    return try std.fmt.allocPrint(allocator, "{d:.2} GiB / {d:.2} GiB ({d}%)", .{ bytesToGiB(used), bytesToGiB(total), percent });
}

fn bytesToGiB(value: u64) f64 {
    const div = @as(f64, @floatFromInt(1024 * 1024 * 1024));
    return @as(f64, @floatFromInt(value)) / div;
}

fn emptyStringList(allocator: Allocator) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    return try list.toOwnedSlice(allocator);
}

fn fastfetchErrorLines(allocator: Allocator, message: []const u8, stderr_output: []const u8) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer freeFastfetchLines(allocator, lines.items);

    try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}", .{message}));

    const trimmed_err = std.mem.trim(u8, stderr_output, " \t\r\n");
    if (trimmed_err.len > 0) {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "stderr: {s}", .{trimmed_err}));
    }

    return try lines.toOwnedSlice(allocator);
}

fn stylizeInfoLines(allocator: Allocator, lines: []const []const u8, width: usize, prefs: ColorPreferences) ![]const []const u8 {
    if (lines.len == 0) return try emptyStringList(allocator);

    const colors = resolveInfoColors(prefs);
    const panel_width = normalizePanelWidth(width);
    const inner_width = if (panel_width > 4) panel_width - 4 else panel_width;

    const max_label_width = blk: {
        if (inner_width > 28) break :blk inner_width - 20;
        if (inner_width > 14) break :blk inner_width - 10;
        break :blk inner_width / 2;
    };
    var label_width = computeLabelColumnWidth(lines, max_label_width);
    if (label_width < 6) label_width = 6;

    const prefix_width = 2 + label_width + 2;
    const value_width = if (inner_width > prefix_width) inner_width - prefix_width else 1;

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    try out.append(allocator, try buildBorderLine(allocator, panel_width, "▛", "▜", "▀", colors));
    try out.append(allocator, try renderBannerLine(allocator, panel_width, inner_width, colors));
    try out.append(allocator, try buildBorderLine(allocator, panel_width, "█", "█", "┈", colors));

    for (lines) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        var label_text: []const u8 = "";
        var value_text = trimmed;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |idx| {
            label_text = std.mem.trimRight(u8, trimmed[0..idx], " \t");
            value_text = std.mem.trimLeft(u8, trimmed[idx + 1 ..], " \t");
        }

        var wrapped = std.ArrayList([]const u8).empty;
        errdefer {
            for (wrapped.items) |item| allocator.free(item);
            wrapped.deinit(allocator);
        }
        try wrapLineTo(&wrapped, allocator, value_text, value_width);
        if (wrapped.items.len == 0) {
            try wrapped.append(allocator, try allocator.dupe(u8, ""));
        }

        for (wrapped.items, 0..) |part, idx| {
            const label_for_row = if (idx == 0) label_text else "";
            const row = try renderInfoRow(allocator, panel_width, inner_width, label_for_row, part, label_width, colors);
            try out.append(allocator, row);
        }

        for (wrapped.items) |item| allocator.free(item);
        wrapped.deinit(allocator);
    }

    try out.append(allocator, try buildBorderLine(allocator, panel_width, "▙", "▟", "▄", colors));

    return try out.toOwnedSlice(allocator);
}

fn normalizePanelWidth(width: usize) usize {
    const min_width: usize = 44;
    if (width == 0) return min_width;
    return if (width < min_width) min_width else width;
}

fn computeLabelColumnWidth(lines: []const []const u8, max_width: usize) usize {
    var width: usize = 0;
    for (lines) |line| {
        if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
            const label = std.mem.trim(u8, line[0..idx], " \t");
            const w = visibleWidth(label);
            if (w > width) width = w;
        }
    }
    if (width == 0) width = 6;
    if (width > max_width) width = max_width;
    return width;
}

fn resolveInfoColors(prefs: ColorPreferences) InfoColors {
    if (prefs.enable and prefs.color_code != null) {
        return .{
            .accent = prefs.color_code.?,
            .muted = "\x1b[38;5;245m",
            .value = "\x1b[38;5;252m",
            .strong = "\x1b[1m",
            .reset = reset_code,
        };
    }
    return .{ .accent = "", .muted = "", .value = "", .strong = "", .reset = "" };
}

fn buildBorderLine(allocator: Allocator, width: usize, left: []const u8, right: []const u8, fill: []const u8, colors: InfoColors) ![]const u8 {
    const panel_width = normalizePanelWidth(width);
    const fill_count = if (panel_width > 2) panel_width - 2 else panel_width;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (colors.accent.len > 0) try out.appendSlice(allocator, colors.accent);
    try out.appendSlice(allocator, left);
    try appendRepeatGlyph(&out, allocator, fill, fill_count);
    try out.appendSlice(allocator, right);
    if (colors.reset.len > 0) try out.appendSlice(allocator, colors.reset);

    return try out.toOwnedSlice(allocator);
}

fn renderBannerLine(allocator: Allocator, panel_width: usize, inner_width: usize, colors: InfoColors) ![]const u8 {
    var banner = std.ArrayList(u8).empty;
    errdefer banner.deinit(allocator);

    if (colors.accent.len > 0) try banner.appendSlice(allocator, colors.accent);
    if (colors.strong.len > 0) try banner.appendSlice(allocator, colors.strong);
    try banner.appendSlice(allocator, "Ghostty Fetch");
    if (colors.reset.len > 0) try banner.appendSlice(allocator, colors.reset);

    try banner.appendSlice(allocator, " ");
    if (colors.muted.len > 0) try banner.appendSlice(allocator, colors.muted);
    try banner.appendSlice(allocator, "// System Info");
    if (colors.reset.len > 0) try banner.appendSlice(allocator, colors.reset);

    const content = try banner.toOwnedSlice(allocator);
    defer allocator.free(content);
    return try frameContentLine(allocator, panel_width, inner_width, content, colors);
}

fn frameContentLine(allocator: Allocator, panel_width: usize, inner_width: usize, content: []const u8, colors: InfoColors) ![]const u8 {
    var row = std.ArrayList(u8).empty;
    errdefer row.deinit(allocator);

    const safe_inner = if (inner_width == 0) panel_width else inner_width;
    const content_width = visibleWidth(content);
    const pad = if (safe_inner > content_width) safe_inner - content_width else 0;

    if (colors.accent.len > 0) try row.appendSlice(allocator, colors.accent);
    try row.appendSlice(allocator, "█");
    if (colors.reset.len > 0) try row.appendSlice(allocator, colors.reset);
    try row.append(allocator, ' ');
    try row.appendSlice(allocator, content);
    try appendSpaces(&row, allocator, pad);
    try row.append(allocator, ' ');
    if (colors.accent.len > 0) try row.appendSlice(allocator, colors.accent);
    try row.appendSlice(allocator, "█");
    if (colors.reset.len > 0) try row.appendSlice(allocator, colors.reset);

    return try row.toOwnedSlice(allocator);
}

fn renderInfoRow(allocator: Allocator, panel_width: usize, inner_width: usize, label: []const u8, value: []const u8, label_width: usize, colors: InfoColors) ![]const u8 {
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(allocator);

    const label_visible = visibleWidth(label);
    try content.append(allocator, ' ');

    if (label_visible > 0) {
        if (colors.accent.len > 0) try content.appendSlice(allocator, colors.accent);
        if (colors.strong.len > 0) try content.appendSlice(allocator, colors.strong);
        try content.appendSlice(allocator, label);
        if (colors.reset.len > 0) try content.appendSlice(allocator, colors.reset);
        const pad = if (label_visible < label_width) label_width - label_visible else 0;
        try appendSpaces(&content, allocator, pad);
    } else {
        try appendSpaces(&content, allocator, label_width);
    }

    if (colors.accent.len > 0) {
        try content.appendSlice(allocator, colors.accent);
    } else if (colors.muted.len > 0) {
        try content.appendSlice(allocator, colors.muted);
    }
    try content.appendSlice(allocator, "│ ");
    if (colors.reset.len > 0) try content.appendSlice(allocator, colors.reset);

    if (colors.value.len > 0) try content.appendSlice(allocator, colors.value);
    try content.appendSlice(allocator, value);
    if (colors.reset.len > 0) try content.appendSlice(allocator, colors.reset);

    const content_slice = try content.toOwnedSlice(allocator);
    defer allocator.free(content_slice);
    return try frameContentLine(allocator, panel_width, inner_width, content_slice, colors);
}

fn wrapInfoLines(allocator: Allocator, lines: []const []const u8, width: usize) ![]const []const u8 {
    if (width == 0) return try dupStringSlice(allocator, lines);

    var out = std.ArrayList([]const u8).empty;
    errdefer freeFastfetchLines(allocator, out.items);

    for (lines) |line| {
        try wrapLineTo(&out, allocator, line, width);
    }

    return try out.toOwnedSlice(allocator);
}

fn wrapLineTo(out: *std.ArrayList([]const u8), allocator: Allocator, line: []const u8, width: usize) !void {
    var remaining = std.mem.trim(u8, line, " \t");
    if (visibleWidth(remaining) <= width or width == 0) {
        const duped = try allocator.dupe(u8, remaining);
        try out.append(allocator, duped);
        return;
    }

    while (remaining.len > 0) {
        var cut: usize = if (remaining.len < width) remaining.len else width;
        if (cut < remaining.len) {
            var space_idx: ?usize = null;
            var i: usize = cut;
            while (i > 0) : (i -= 1) {
                if (remaining[i - 1] == ' ') {
                    space_idx = i - 1;
                    break;
                }
            }
            if (space_idx) |s| cut = s;
        }
        const chunk = std.mem.trimRight(u8, remaining[0..cut], " ");
        if (chunk.len > 0) {
            try out.append(allocator, try allocator.dupe(u8, chunk));
        }
        remaining = std.mem.trimLeft(u8, remaining[cut..], " ");
        if (visibleWidth(remaining) <= width) {
            if (remaining.len > 0) try out.append(allocator, try allocator.dupe(u8, remaining));
            break;
        }
    }
}

fn isUnhelpfulShellName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "play_animation") or std.ascii.eqlIgnoreCase(name, "codex") or std.ascii.eqlIgnoreCase(name, "sh") or std.ascii.eqlIgnoreCase(name, "env");
}

fn isPrintableAscii(s: []const u8) bool {
    for (s) |ch| {
        if (ch < 0x20 or ch > 0x7e) return false;
    }
    return true;
}

fn shellVersionFromPath(allocator: Allocator, shell_path: []const u8) !?[]const u8 {
    var child = std.process.Child.init(&.{ shell_path, "--version" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout_stream = child.stdout orelse return null;
    const stdout_bytes = stdout_stream.readToEndAlloc(allocator, shell_version_limit) catch return null;

    const term = child.wait() catch {
        allocator.free(stdout_bytes);
        return null;
    };
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(stdout_bytes);
                return null;
            }
        },
        else => {
            allocator.free(stdout_bytes);
            return null;
        },
    }

    const trimmed = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(stdout_bytes);
        return null;
    }
    return stdout_bytes;
}

fn cleanVersionString(allocator: Allocator, raw: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (iter.next()) |tok| {
        var has_digit = false;
        for (tok) |ch| {
            if (std.ascii.isDigit(ch)) {
                has_digit = true;
                break;
            }
        }
        if (has_digit) {
            return try allocator.dupe(u8, tok);
        }
    }
    return null;
}

fn visibleWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = if (len > 1 and i + len <= text.len) len else 1;
        i += step;
        w += 1;
    }
    return w;
}

fn appendSpaces(list: *std.ArrayList(u8), allocator: Allocator, count: usize) !void {
    if (count == 0) return;
    const buf = try allocator.alloc(u8, count);
    defer allocator.free(buf);
    @memset(buf, ' ');
    try list.appendSlice(allocator, buf);
}

fn appendRepeatGlyph(list: *std.ArrayList(u8), allocator: Allocator, glyph: []const u8, count: usize) !void {
    if (count == 0) return;
    for (0..count) |_| try list.appendSlice(allocator, glyph);
}

fn buildPromptPrefix(allocator: Allocator, prefs: ColorPreferences) ![]const u8 {
    return promptPrefixInternal(allocator, prefs) catch allocator.dupe(u8, "$ ");
}

fn promptPrefixInternal(allocator: Allocator, prefs: ColorPreferences) ![]const u8 {
    const pieces = try promptPieces(allocator);
    defer freePromptPieces(allocator, pieces);

    const ps1 = std.process.getEnvVarOwned(allocator, "PS1") catch null;
    if (ps1) |ps1_value| {
        defer allocator.free(ps1_value);
        if (try expandPs1(allocator, ps1_value, pieces)) |expanded| {
            return expanded;
        }
    }

    const colors = resolveInfoColors(prefs);
    return try defaultPromptPrefix(allocator, pieces, colors);
}

fn buildPromptHint(allocator: Allocator, colors: InfoColors) ![]const u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);

    if (colors.muted.len > 0) try line.appendSlice(allocator, colors.muted);
    try line.appendSlice(allocator, "Type a command and press Enter to run it");
    if (colors.reset.len > 0) try line.appendSlice(allocator, colors.reset);

    return try line.toOwnedSlice(allocator);
}

fn renderPromptLine(allocator: Allocator, prefix: []const u8, input: []const u8, colors: InfoColors) ![]const u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);

    try line.appendSlice(allocator, prefix);
    if (input.len > 0) {
        try line.appendSlice(allocator, input);
    } else {
        if (colors.muted.len > 0) try line.appendSlice(allocator, colors.muted);
        try line.appendSlice(allocator, "_");
        if (colors.reset.len > 0) try line.appendSlice(allocator, colors.reset);
    }

    return try line.toOwnedSlice(allocator);
}

fn captureInput(allocator: Allocator, stdin_file: std.fs.File, buffer: *std.ArrayList(u8)) !?[]u8 {
    var temp: [64]u8 = undefined;
    var in_escape = false;

    while (true) {
        const count = stdin_file.read(&temp) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (count == 0) break;

        for (temp[0..count]) |byte| {
            if (in_escape) {
                if ((byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z')) {
                    in_escape = false;
                }
                continue;
            }

            switch (byte) {
                0x1b => {
                    in_escape = true;
                },
                '\r', '\n' => {
                    return try allocator.dupe(u8, buffer.items);
                },
                0x7f, 0x08 => {
                    if (buffer.items.len > 0) _ = buffer.pop();
                },
                else => {
                    if (byte >= 0x20 and byte <= 0x7e and buffer.items.len < max_command_length) {
                        try buffer.append(allocator, byte);
                    }
                },
            }
        }
    }

    return null;
}

fn runCommandInShell(allocator: Allocator, command: []const u8) !u8 {
    if (command.len == 0) return 0;

    const shell_path = try resolveShellPath(allocator);
    defer allocator.free(shell_path);
    const shell_name = std.fs.path.basename(shell_path);

    const flag: []const u8 = blk: {
        if (std.ascii.eqlIgnoreCase(shell_name, "zsh")) break :blk "-lic";
        if (std.ascii.eqlIgnoreCase(shell_name, "bash")) break :blk "-lc";
        if (std.ascii.eqlIgnoreCase(shell_name, "fish")) break :blk "-lic";
        break :blk "-c";
    };

    const argv = [_][]const u8{ shell_path, flag, command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();

    return switch (term) {
        .Exited => |code| @as(u8, @intCast(code)),
        .Signal => |_| 128,
        else => 1,
    };
}

fn resolveShellPath(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "SHELL") catch null) |shell_env| return shell_env;
    if (std.process.getEnvVarOwned(allocator, "ZSH") catch null) |zsh| return zsh;
    if (std.process.getEnvVarOwned(allocator, "BASH") catch null) |bash| return bash;
    return try allocator.dupe(u8, "/bin/sh");
}

const PromptPieces = struct {
    username: []u8,
    hostname: []u8,
    cwd_display: []u8,
    prompt_char: u8,
};

fn promptPieces(allocator: Allocator) !PromptPieces {
    const username = try currentUsername(allocator);
    errdefer allocator.free(username);

    const hostname = try currentHostname(allocator);
    errdefer allocator.free(hostname);

    const cwd_display = try currentWorkingDirDisplay(allocator);
    errdefer allocator.free(cwd_display);

    return .{
        .username = username,
        .hostname = hostname,
        .cwd_display = cwd_display,
        .prompt_char = if (isRootUser()) '#' else '$',
    };
}

fn freePromptPieces(allocator: Allocator, pieces: PromptPieces) void {
    allocator.free(pieces.username);
    allocator.free(pieces.hostname);
    allocator.free(pieces.cwd_display);
}

fn currentUsername(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "USER") catch null) |user| return user;
    if (std.process.getEnvVarOwned(allocator, "LOGNAME") catch null) |user| return user;
    return try allocator.dupe(u8, "user");
}

fn currentHostname(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOSTNAME") catch null) |host| return host;
    if (std.process.getEnvVarOwned(allocator, "HOST") catch null) |host| return host;
    return try allocator.dupe(u8, "localhost");
}

fn currentWorkingDirDisplay(allocator: Allocator) ![]u8 {
    const real = std.fs.cwd().realpathAlloc(allocator, ".") catch return allocator.dupe(u8, ".");
    defer allocator.free(real);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |h| allocator.free(h);

    if (home != null and real.len >= home.?.len and std.mem.startsWith(u8, real, home.?)) {
        return try std.fmt.allocPrint(allocator, "~{s}", .{real[home.?.len..]});
    }

    return try allocator.dupe(u8, real);
}

fn expandPs1(allocator: Allocator, raw: []const u8, pieces: PromptPieces) !?[]const u8 {
    if (raw.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (ch == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'u' => try out.appendSlice(allocator, pieces.username),
                'h' => {
                    const host = pieces.hostname;
                    if (std.mem.indexOfScalar(u8, host, '.')) |dot_idx| {
                        try out.appendSlice(allocator, host[0..dot_idx]);
                    } else {
                        try out.appendSlice(allocator, host);
                    }
                },
                'H' => try out.appendSlice(allocator, pieces.hostname),
                'w' => try out.appendSlice(allocator, pieces.cwd_display),
                'W' => try out.appendSlice(allocator, std.fs.path.basename(pieces.cwd_display)),
                '$' => try out.append(allocator, pieces.prompt_char),
                '\\' => try out.append(allocator, '\\'),
                'e' => try out.append(allocator, 0x1b),
                '[' => {},
                ']' => {},
                'n' => try out.append(allocator, '\n'),
                'r' => try out.append(allocator, '\r'),
                else => try out.append(allocator, raw[i]),
            }
            continue;
        }

        try out.append(allocator, ch);
    }

    const rendered = try out.toOwnedSlice(allocator);
    if (std.mem.trim(u8, rendered, " \t\r\n").len == 0) {
        allocator.free(rendered);
        return null;
    }
    return rendered;
}

fn defaultPromptPrefix(allocator: Allocator, pieces: PromptPieces, colors: InfoColors) ![]const u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);

    if (colors.accent.len > 0) try line.appendSlice(allocator, colors.accent);
    try line.appendSlice(allocator, pieces.username);
    try line.append(allocator, '@');
    try line.appendSlice(allocator, pieces.hostname);
    if (colors.reset.len > 0) try line.appendSlice(allocator, colors.reset);

    try line.append(allocator, ' ');
    if (colors.value.len > 0) try line.appendSlice(allocator, colors.value);
    try line.appendSlice(allocator, pieces.cwd_display);
    if (colors.reset.len > 0) try line.appendSlice(allocator, colors.reset);

    try line.append(allocator, ' ');
    try line.append(allocator, pieces.prompt_char);
    try line.append(allocator, ' ');

    return try line.toOwnedSlice(allocator);
}

fn isRootUser() bool {
    return posix.getuid() == 0;
}

const TerminalMode = struct {
    fd: posix.fd_t,
    original: posix.termios,
    active: bool,

    fn enable(file: std.fs.File) !TerminalMode {
        const fd = file.handle;
        const original = try posix.tcgetattr(fd);
        var raw = original;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);

        return .{ .fd = fd, .original = original, .active = true };
    }

    fn restore(self: *TerminalMode) void {
        if (!self.active) return;
        _ = posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
        self.active = false;
    }
};
