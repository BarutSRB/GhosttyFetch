const std = @import("std");

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
