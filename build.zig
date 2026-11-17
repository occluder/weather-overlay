const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const gui = b.option(bool, "gui", "Build as a GUI app (no console window)") orelse false;

    const win_c = b.addTranslateC(.{
        .root_source_file = b.path("src/win.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "weather-overlay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "win", .module = win_c.createModule() },
            },
        }),
    });

    for ([_][]const u8{ "user32", "gdi32", "gdiplus", "winhttp", "kernel32", "advapi32" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    if (gui) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the overlay").dependOn(&run_cmd.step);
}


