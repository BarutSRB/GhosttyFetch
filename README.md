# GhosttyFetch

<p align="center">
  <img src="demo.png" alt="GhosttyFetch Demo">
</p>

An animated system information display tool for the Ghostty terminal emulator. Perfect for terminal enthusiasts and the ricing community who want to showcase their terminal setup while maintaining functionality.

## Overview

GhosttyFetch combines visual appeal with practical utility, displaying an animated Ghostty logo alongside real-time system information. Designed specifically for the terminal ricing community, it provides an eye-catching splash screen that's also a functional system monitoring tool and command launcher.

**Key Features:**
- 235-frame smooth ASCII art animation
- Real-time system information display via native Zig collectors (no fastfetch)
- Highly customizable colors and gradients
- Interactive command prompt with live input
- Built in Zig for performance and efficiency
- Perfect for terminal startup scripts

## Demo

<p align="center">
  <img src="demo.gif" alt="GhosttyFetch in Action">
</p>

## What It Does

GhosttyFetch creates an engaging terminal experience by:

1. Loading configuration from `config.json` and environment variables (FPS, colors, gradient settings, system info modules)
2. Gathering system information natively using platform APIs (sysctl, /proc, CoreGraphics, etc.)
3. Loading `animation.json` containing 235 frames of ASCII art with color markup
4. Rendering the animation with:
   - Custom brand colors for highlighted elements
   - Vertical gradient effects for the ASCII art
   - Optional scrolling gradient animation
5. Displaying a formatted system information panel with bordered layout
6. Enabling non-blocking keyboard input while the animation plays
7. Showing a live command prompt at the bottom
8. Executing your command when you press Enter
9. Exiting with your command's exit code

It's ideal for adding visual flair to your terminal while providing quick access to system information and seamless command execution.

## Requirements

Before installation, ensure you have:

- **Operating System:** macOS or Linux (POSIX-compliant systems)
- **Zig:** Version 0.15.x required (tested with 0.15.2). Not compatible with 0.16.0+ due to API changes.
- **System utilities (optional):** Some modules call platform tools if present (e.g., `xrandr` for X11 display info, `gsettings` on GNOME).

## Installation

### Quick Start

```bash
# Clone the repository
git clone https://github.com/BarutSRB/GhosttyFetch.git
cd GhosttyFetch

# Build the application
zig build

# For optimized build
zig build -Doptimize=ReleaseFast

# Run (must be in directory with config.json and animation.json)
./zig-out/bin/ghosttyfetch
```

### File Structure

The executable requires these files in the same directory:

```
GhosttyFetch/
├── ghosttyfetch          # Compiled binary
├── config.json           # Configuration (required)
└── animation.json        # Animation frames (required)
```

## Configuration

### config.json Settings

All configuration is managed through `config.json`, with environment variable overrides available.

#### Display Settings

```json
{
  "fps": 30.0,
  "color": "#3551f3",
  "force_color": false,
  "no_color": false
}
```

**Options:**
- `fps` (float): Animation frame rate. Range: 1.0-120.0. Default: 20.0
- `color` (string): Brand color for highlighted elements
  - Hex format: `#rrggbb` or `rrggbb`
  - ANSI format: `38;5;n` or `38;2;r;g;b`
  - Disable: `"off"`, `"0"`, `"false"`, `"none"`
- `force_color` (boolean): Force color output even when not detected as TTY
- `no_color` (boolean): Disable all color output

#### Gradient Settings

```json
{
  "white_gradient_colors": [
    "#d7ff9e", "#c3f364", "#f2e85e", "#f5c95c",
    "#f17f5b", "#f45c82", "#de6fd2", "#b07cf4",
    "#8b8cf8", "#74a4ff", "#78b8ff"
  ],
  "white_gradient_scroll": true,
  "white_gradient_scroll_speed": 20.0
}
```

**Options:**
- `white_gradient_colors` (array): Colors applied top-to-bottom to non-branded ASCII art. Empty array disables gradient.
- `white_gradient_scroll` (boolean): Enable animated gradient scrolling
- `white_gradient_scroll_speed` (float): Scroll speed in lines per second

#### System Info Configuration

```json
{
  "sysinfo": {
    "enabled": true,
    "modules": [
      "OS", "Host", "Kernel", "CPU", "GPU",
      "Memory", "Disk", "LocalIp"
    ]
  }
}
```

**Options:**
- `enabled` (boolean): Enable/disable system information panel
- `modules` (array): List of modules to display
  - Available: Title, OS, Host, Kernel, Uptime, Packages, Shell, Display, Terminal, TerminalFont, WM, WMTheme, Cursor, CPU, GPU, Memory, Swap, Disk, LocalIp

### Environment Variables

Environment variables override config.json settings:

```bash
# Override FPS
GHOSTTY_FPS=60 ./ghosttyfetch

# Override color
GHOSTTY_COLOR=#ff0066 ./ghosttyfetch

# Force color output
FORCE_COLOR=1 ./ghosttyfetch

# Disable colors
NO_COLOR=1 ./ghosttyfetch
```

**Available Variables:**
- `GHOSTTY_FPS`: Override frame rate
- `GHOSTTY_COLOR`: Override brand color
- `FORCE_COLOR`: Force color output
- `NO_COLOR`: Disable all colors
- `SHELL`: Shell for command execution
- `PS1`: Custom prompt format (supports \u, \h, \w, \$)

## Usage

### Running the Application

```bash
# Basic execution
./ghosttyfetch

# With environment overrides
GHOSTTY_FPS=60 GHOSTTY_COLOR=#ff0066 ./ghosttyfetch
```

### What to Expect

When you run GhosttyFetch, you'll see:

1. **Animation (left):** 235 frames of Ghostty logo animation cycling continuously
2. **System Info (right):** Bordered panel showing your selected system information
3. **Command Prompt (bottom):** Interactive prompt where you can type commands

### Interacting with the Prompt

- **Type:** Any regular characters (letters, numbers, symbols)
- **Backspace/Delete:** Remove the last character
- **Enter:** Execute your command and exit the application

The application exits with your command's exit code, making it suitable for shell integration.

### Integration with Shell Startup

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
# Run GhosttyFetch on terminal startup
if [[ $- == *i* ]]; then
  /path/to/ghosttyfetch
fi
```

### Customization Examples

```bash
# High frame rate for smooth animation
GHOSTTY_FPS=90 ./ghosttyfetch

# Custom color theme
GHOSTTY_COLOR=#ff0066 ./ghosttyfetch

# Minimal system info (edit config.json)
{
  "sysinfo": {
    "modules": ["OS", "Kernel", "CPU", "Memory"]
  }
}
```

## Popular Color Themes

Here are some community-favorite color schemes:

**Dracula:**
```json
{
  "color": "#bd93f9",
  "white_gradient_colors": ["#8be9fd", "#50fa7b", "#f1fa8c", "#ffb86c", "#ff79c6", "#bd93f9"]
}
```

**Nord:**
```json
{
  "color": "#88c0d0",
  "white_gradient_colors": ["#8fbcbb", "#88c0d0", "#81a1c1", "#5e81ac"]
}
```

**Gruvbox:**
```json
{
  "color": "#fe8019",
  "white_gradient_colors": ["#b8bb26", "#fabd2f", "#fe8019", "#fb4934", "#d3869b", "#83a598"]
}
```

**Tokyo Night:**
```json
{
  "color": "#7aa2f7",
  "white_gradient_colors": ["#9ece6a", "#0db9d7", "#7aa2f7", "#bb9af7"]
}
```

## Troubleshooting

### Common Issues

**System info fields are empty**
- Some modules rely on platform data being available (e.g., `/proc` on Linux, CoreGraphics on macOS).
- Ensure optional helpers exist for richer output: `xrandr` on X11, `gsettings` on GNOME.

**"Failed to load config.json"**
- Ensure the file exists in the working directory
- Validate JSON syntax: `jq . config.json`
- Check file permissions: `chmod 644 config.json`

**Colors not displaying**
- Check `NO_COLOR` environment variable: `env | grep NO_COLOR`
- Set `force_color: true` in config.json
- Verify terminal supports ANSI colors: `echo -e "\x1b[31mRED\x1b[0m"`

**Animation issues**
- Verify `animation.json` exists and is readable
- Check file size (expected: ~476KB)
- Try adjusting FPS value in config

**Command execution fails**
- Verify `SHELL` environment variable: `echo $SHELL`
- Ensure shell is executable: `ls -l $SHELL`
- Test shell manually: `$SHELL -c "echo test"`

## Contributing

Contributions are welcome! We appreciate bug fixes, new features, documentation improvements, and creative enhancements.

### How to Contribute

1. Fork the repository: `https://github.com/BarutSRB/GhosttyFetch`
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Test thoroughly: `zig build && ./zig-out/bin/ghosttyfetch`
5. Submit a pull request with a clear description

**Contribution Ideas:**
- Additional color themes and presets
- Animation effects and transitions
- Layout customization options
- Performance improvements
- Documentation enhancements
- Bug fixes and quality of life improvements

## Technical Details

**Built With:**
- Language: Zig 0.15.2
- Dependencies: Zig standard library plus platform APIs (sysctl, CoreGraphics, /proc)
- Runtime Requirement: None beyond optional helper utilities for richer system info

**Key Features:**
- Non-blocking terminal I/O for smooth animation
- Raw terminal mode for keystroke capture
- ANSI escape code rendering for colors and positioning
- JSON parsing for configuration and animation data
- Native system information collectors; limited helper commands (e.g., `xrandr`, `gsettings`) when available
- Smart text wrapping and alignment

**Animation Format:**
- 235 frames, 21 lines per frame
- HTML-style `<span class="b">` markup for brand colors
- Vertical gradient application to unmarked text
- Optional scrolling gradient effect

## License

MIT License

Copyright (c) 2024 BarutSRB

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Acknowledgments

- Animation sourced from [ghostty.org](https://ghostty.org)
- Built for the Ghostty terminal emulator by Mitchell Hashimoto
- System information collected natively in Zig
- Created for the terminal ricing and customization community

## Support

- **Issues & Bug Reports:** `https://github.com/BarutSRB/GhosttyFetch/issues`
- **Discussions & Questions:** `https://github.com/BarutSRB/GhosttyFetch/discussions`
- **Documentation:** This README and inline code comments

---

Enjoy customizing your terminal experience with GhosttyFetch!
