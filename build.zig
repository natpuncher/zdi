const std = @import("std");

pub fn build(build_settings: *std.Build) void {
    const optimize = build_settings.standardOptimizeOption(.{});
    const target = build_settings.standardTargetOptions(.{});

    _ = build_settings.addModule("zdi", .{
        .root_source_file = build_settings.path("zdi.zig"),
    });

    const tests = build_settings.addTest(.{
        .root_module = build_settings.createModule(.{
            .root_source_file = build_settings.path("tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = build_settings.step("test", "Run zdi tests");
    const run_tests = build_settings.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
