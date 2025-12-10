const std = @import("std");
const builtin = @import("builtin");

comptime {
    const min_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 0 };
    const max_zig = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

    if (builtin.zig_version.order(min_zig) == .lt) {
        @compileError("GhosttyFetch requires Zig 0.15.x. Your version is too old.");
    }
    if (builtin.zig_version.order(max_zig) != .lt) {
        @compileError(
            \\GhosttyFetch requires Zig 0.15.x (tested with 0.15.2).
            \\Zig 0.16+ has breaking API changes (readFileAlloc moved to Io.Dir).
            \\
            \\Install Zig 0.15.2: https://ziglang.org/download/
            \\Or use zigup: zigup 0.15.2
        );
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ghosttyfetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ghosttyfetch.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link system libraries for native system info detection
    if (target.result.os.tag == .macos) {
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("CoreGraphics");
        exe.linkFramework("IOKit");
    }
    exe.linkLibC();

    b.installArtifact(exe);

    // Install data files to share directory for system-wide installs
    b.installFile("config.json", "share/ghosttyfetch/config.json");
    b.installFile("animation.json", "share/ghosttyfetch/animation.json");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ghosttyfetch");
    run_step.dependOn(&run_cmd.step);
}
