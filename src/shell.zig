const std = @import("std");
const types = @import("types.zig");
const ui = @import("ui.zig");

const Allocator = types.Allocator;
const ColorPreferences = types.ColorPreferences;
const InfoColors = types.InfoColors;
const max_command_length = types.max_command_length;
const posix = types.posix;

const resolveInfoColors = ui.resolveInfoColors;

pub const TerminalMode = struct {
    fd: posix.fd_t,
    original: posix.termios,
    active: bool,

    pub fn enable(file: std.fs.File) !TerminalMode {
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

    pub fn restore(self: *TerminalMode) void {
        if (!self.active) return;
        _ = posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

pub fn buildPromptPrefix(allocator: Allocator, prefs: ColorPreferences) ![]const u8 {
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

pub fn renderPromptLine(allocator: Allocator, prefix: []const u8, input: []const u8, colors: InfoColors) ![]const u8 {
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

pub fn captureInput(allocator: Allocator, stdin_file: std.fs.File, buffer: *std.ArrayList(u8)) !?[]u8 {
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

pub fn runCommandInShell(allocator: Allocator, command: []const u8) !u8 {
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
