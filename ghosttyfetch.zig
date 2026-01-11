const std = @import("std");
const builtin = @import("builtin");
const types = @import("src/types.zig");
const config = @import("src/config.zig");
const frames = @import("src/frames.zig");
const sysinfo = @import("src/sysinfo.zig");
const ui = @import("src/ui.zig");
const shell = @import("src/shell.zig");
const resize = @import("src/resize.zig");

const Allocator = types.Allocator;
const clear_screen = types.clear_screen;
const config_file = types.config_file;
const posix = std.posix;

// Global state for signal handler
var global_term_mode: ?*shell.TerminalMode = null;

fn signalHandler(_: c_int) callconv(.c) void {
    // Restore terminal mode if active
    if (global_term_mode) |tm| {
        tm.restore();
    }
    // Exit immediately
    std.process.exit(130); // 128 + SIGINT(2)
}

fn installSignalHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.debug.print("Warning: Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var exit_status: ?u8 = null;
    defer if (exit_status) |code| std.process.exit(code);

    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    // Check if running interactively (stdin is a TTY)
    const is_interactive = stdin_file.isTty();

    const cfg = config.loadConfig(allocator) catch |err| {
        if (err == error.MissingConfig) {
            std.debug.print("Config file '{s}' not found.\n", .{config_file});
            std.debug.print("Searched in: ~/.config/ghosttyfetch/, /usr/share/ghosttyfetch/, and next to executable.\n", .{});
        }
        return err;
    };
    defer config.freeConfig(allocator, cfg);

    resize.install();

    var term_size = types.TerminalSize.detect(stdout_file) catch
        types.TerminalSize{ .width = 120, .height = 40 };

    var layout = frames.calculateLayout(term_size);

    const fps = try config.resolveFps(allocator, cfg);
    const prefs = try config.colorPreferences(allocator, cfg, stdout_file.isTty(), fps);
    defer config.freeColorPreferences(allocator, prefs);

    const sysinfo_lines = try sysinfo.loadSystemInfoLines(allocator, cfg.sysinfo);
    defer sysinfo.freeSystemInfoLines(allocator, sysinfo_lines);

    const raw_frames = try frames.loadRawFrames(allocator);
    defer frames.freeFrames(allocator, raw_frames);

    const orig_dims = frames.getFrameDimensions(raw_frames[0]);

    var styled_info = try ui.stylizeInfoLines(allocator, sysinfo_lines, layout.info_width, prefs);
    defer sysinfo.freeSystemInfoLines(allocator, styled_info);

    if (cfg.match_info_height orelse false) {
        layout.art_height = @max(10, styled_info.len);
        layout.constrainToAspectRatio(orig_dims.width, orig_dims.height);
    }

    var frame_cache = try frames.LazyFrameCache.init(
        allocator,
        raw_frames,
        layout.art_width,
        layout.art_height,
        prefs,
    );
    defer frame_cache.deinit();

    // Get first frame to calculate initial width
    const first_frame = try frame_cache.getFrame(0);
    var frame_width = frames.frameVisibleWidth(first_frame);
    var info_start_col = frame_width + 4;
    const delay_ns = frames.fpsToDelayNs(fps);

    const info_colors = ui.resolveInfoColors(prefs);
    const prompt_prefix = try shell.buildPromptPrefix(allocator, prefs);
    defer allocator.free(prompt_prefix);

    var input_buffer = std.ArrayList(u8).empty;
    defer input_buffer.deinit(allocator);

    // Only enable raw mode if running interactively
    var term_mode: ?shell.TerminalMode = null;
    if (is_interactive) {
        term_mode = try shell.TerminalMode.enable(stdin_file);
        global_term_mode = &term_mode.?;
        installSignalHandlers();
    }
    defer if (term_mode) |*tm| {
        tm.restore();
        global_term_mode = null;
    };

    var submitted_command: ?[]u8 = null;
    defer if (submitted_command) |cmd| allocator.free(cmd);

    var keep_running = true;
    var frame_index: usize = 0;

    while (keep_running) {
        frame_index = 0;
        while (frame_index < frame_cache.frameCount()) : (frame_index += 1) {
            if (is_interactive and submitted_command == null) {
                submitted_command = try shell.captureInput(allocator, stdin_file, &input_buffer);
            }

            const prompt_line = try shell.renderPromptLine(allocator, prompt_prefix, input_buffer.items, info_colors);
            defer allocator.free(prompt_line);

            // Get frame lazily - scales on first access, cached thereafter
            const frame = try frame_cache.getFrame(frame_index);

            const combined = try ui.combineFrameAndInfo(allocator, frame, styled_info, info_start_col);
            defer allocator.free(combined);

            const with_prompt = try ui.appendPromptLines(allocator, combined, prompt_line);
            defer allocator.free(with_prompt);

            try stdout_file.writeAll(clear_screen);
            try stdout_file.writeAll(with_prompt);

            if (submitted_command != null) {
                keep_running = false;
                break;
            }

            // Non-interactive mode: just show one full animation cycle and exit
            if (!is_interactive and frame_index + 1 >= frame_cache.frameCount()) {
                keep_running = false;
                break;
            }

            if (resize.checkAndClear()) {
                const new_term_size = types.TerminalSize.detect(stdout_file) catch
                    types.TerminalSize{ .width = 120, .height = 40 };
                var new_layout = frames.calculateLayout(new_term_size);

                const new_styled = try ui.stylizeInfoLines(allocator, sysinfo_lines, new_layout.info_width, prefs);
                sysinfo.freeSystemInfoLines(allocator, styled_info);
                styled_info = new_styled;

                if (cfg.match_info_height orelse false) {
                    new_layout.art_height = @max(10, styled_info.len);
                    new_layout.constrainToAspectRatio(orig_dims.width, orig_dims.height);
                }

                frame_cache.resize(new_layout.art_width, new_layout.art_height);

                term_size = new_term_size;
                layout = new_layout;

                // Recalculate frame width from first frame after resize
                const resized_frame = try frame_cache.getFrame(0);
                frame_width = frames.frameVisibleWidth(resized_frame);
                info_start_col = frame_width + 4;

                break; // Restart frame loop with new size
            }

            std.Thread.sleep(delay_ns);
        }
    }

    // Restore terminal before running command
    if (term_mode) |*tm| {
        tm.restore();
        global_term_mode = null;
    }

    if (submitted_command) |cmd| {
        const command = std.mem.trim(u8, cmd, " \t\r\n");
        if (command.len == 0) return;

        try stdout_file.writeAll(clear_screen);
        try stdout_file.writeAll(prompt_prefix);
        try stdout_file.writeAll(command);
        try stdout_file.writeAll("\n");

        const code = try shell.runCommandInShell(allocator, command);
        exit_status = @as(u8, @intCast(code));
    }
}
