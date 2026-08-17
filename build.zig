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

    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/non_struct_container.zig",
        "zdi container type must be a struct, found 'u8'",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/unknown_config_field.zig",
        "zdi config field 'external' is not supported",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/invalid_externals.zig",
        "zdi config externals must be a tuple or struct",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/duplicate_externals.zig",
        "zdi external type 'u8' is duplicated",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/invalid_observer.zig",
        "zdi observer must be a function with signature",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/invalid_init_return.zig",
        "zdi init for field 'service' must return",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/invalid_dependency_pointer.zig",
        "zdi dependency '[]invalid_dependency_pointer.Item' for field 'consumer' must be a single-item pointer or external value",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/invalid_deinit.zig",
        "zdi deinit for type 'invalid_deinit.Service' must have signature",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/duplicate_components.zig",
        "zdi component type 'duplicate_components.Service' is duplicated",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/missing_default.zig",
        "zdi field 'value' of type 'u8' has no init and no default value",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/generic_init.zig",
        "zdi init for field 'service' cannot be generic or variadic",
    );
    addCompileErrorTest(
        build_settings,
        test_step,
        "test/compile_errors/missing_auto_dependency.zig",
        "zdi can't resolve dependency '*missing_auto_dependency.Missing' for field 'consumer.missing'",
    );
}

fn addCompileErrorTest(
    build_settings: *std.Build,
    test_step: *std.Build.Step,
    fixture: []const u8,
    expected_error: []const u8,
) void {
    const run = build_settings.addSystemCommand(&.{
        build_settings.graph.zig_exe,
        "test",
        "--dep",
        "zdi",
    });
    run.addArg(build_settings.fmt("-Mroot={s}", .{fixture}));
    run.addArg("-Mzdi=zdi.zig");
    run.setCwd(build_settings.path("."));
    run.expectExitCode(1);
    run.expectStdErrMatch(expected_error);
    test_step.dependOn(&run.step);
}
