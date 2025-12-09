const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const posix = std.posix;

// Constants
pub const span_open = "<span class=\"b\">";
pub const span_close = "</span>";
pub const reset_code = "\x1b[0m";
pub const clear_screen = "\x1b[H\x1b[2J";
pub const data_file = "animation.json";
pub const config_file = "config.json";
pub const default_rgb = [_]u8{ 53, 81, 243 };
pub const max_command_length: usize = 2048;
pub const min_info_panel_width: usize = 44;

// Type definitions
pub const TerminalSize = struct {
    width: u16,
    height: u16,

    pub fn detect(file: std.fs.File) !TerminalSize {
        if (!file.isTty()) {
            return TerminalSize{ .width = 120, .height = 40 };
        }

        const TIOCGWINSZ: u32 = if (@import("builtin").target.os.tag == .macos or
            @import("builtin").target.os.tag == .ios or
            @import("builtin").target.os.tag == .watchos or
            @import("builtin").target.os.tag == .tvos)
            0x40087468
        else if (@import("builtin").target.os.tag == .linux)
            0x5413
        else if (@import("builtin").target.os.tag == .openbsd or
            @import("builtin").target.os.tag == .netbsd or
            @import("builtin").target.os.tag == .freebsd or
            @import("builtin").target.os.tag == .dragonfly)
            0x40087468
        else
            0x5413;

        const winsize = extern struct {
            ws_row: u16,
            ws_col: u16,
            ws_xpixel: u16,
            ws_ypixel: u16,
        };

        var ws: winsize = undefined;
        const rc = std.c.ioctl(file.handle, TIOCGWINSZ, @intFromPtr(&ws));

        if (rc == -1 or ws.ws_row == 0 or ws.ws_col == 0) {
            return TerminalSize{ .width = 120, .height = 40 };
        }

        return TerminalSize{
            .width = ws.ws_col,
            .height = ws.ws_row,
        };
    }
};

pub const FramesFile = struct {
    frames: []const []const u8,
};

pub const GradientPreferences = struct {
    colors: []const []const u8,
    scroll: bool,
    scroll_speed: f64,
    fps: f64,
};

pub const ColorPreferences = struct {
    enable: bool,
    color_code: ?[]const u8,
    gradient: GradientPreferences,
};

pub const InfoColors = struct {
    accent: []const u8,
    muted: []const u8,
    value: []const u8,
    strong: []const u8,
    reset: []const u8,
};

pub const SysInfoConfig = struct {
    enabled: bool = true,
    modules: []const []const u8 = &[_][]const u8{},
};

pub const Config = struct {
    fps: ?f64 = null,
    color: ?[]const u8 = null,
    force_color: ?bool = null,
    no_color: ?bool = null,
    white_gradient_colors: ?[]const []const u8 = null,
    white_gradient_scroll: ?bool = null,
    white_gradient_scroll_speed: ?f64 = null,
    sysinfo: SysInfoConfig = .{},
};

pub const default_sysinfo_modules = [_][]const u8{
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

pub const LayoutDimensions = struct {
    art_width: usize,
    art_height: usize,
    info_width: usize,
};
