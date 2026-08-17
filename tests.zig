const std = @import("std");
const testing = std.testing;
const zdi = @import("zdi.zig");

var lifecycle_log: [16]u8 = undefined;
var lifecycle_log_len: usize = 0;

fn resetLifecycleLog() void {
    lifecycle_log_len = 0;
}

fn logLifecycle(value: u8) void {
    lifecycle_log[lifecycle_log_len] = value;
    lifecycle_log_len += 1;
}

const Settings = struct {
    volume: u8 = 7,
};

const Renderer = struct {
    settings: *Settings,

    pub fn init(settings: *Settings) Renderer {
        logLifecycle(1);
        return .{ .settings = settings };
    }

    pub fn deinit(_: *Renderer) void {
        logLifecycle(4);
    }
};

const UI = struct {
    renderer: *Renderer,
    allocator: std.mem.Allocator,

    pub fn init(renderer: *Renderer, allocator: std.mem.Allocator) UI {
        logLifecycle(2);
        return .{ .renderer = renderer, .allocator = allocator };
    }

    pub fn deinit(_: *UI) void {
        logLifecycle(3);
    }
};

const Container = struct {
    settings: Settings,
    renderer: Renderer,
    ui: UI,
};

test "initializes fields in declaration order and injects prior dependencies" {
    resetLifecycleLog();

    const container = try zdi.init(testing.allocator, Container, .{});
    defer zdi.deinit(testing.allocator, container);

    try testing.expectEqual(@as(u8, 7), container.settings.volume);
    try testing.expect(container.renderer.settings == &container.settings);
    try testing.expect(container.ui.renderer == &container.renderer);
    try testing.expect(container.ui.allocator.ptr == testing.allocator.ptr);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, lifecycle_log[0..lifecycle_log_len]);
}

test "deinitializes fields in reverse declaration order" {
    resetLifecycleLog();

    const container = try zdi.init(testing.allocator, Container, .{});
    zdi.deinit(testing.allocator, container);

    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, lifecycle_log[0..lifecycle_log_len]);
}

const FallibleService = struct {
    value: u8,

    pub fn init() !FallibleService {
        return .{ .value = 42 };
    }
};

test "supports error-returning initializers" {
    const FallibleContainer = struct {
        service: FallibleService,
    };

    const container = try zdi.init(testing.allocator, FallibleContainer, .{});
    defer zdi.deinit(testing.allocator, container);

    try testing.expectEqual(@as(u8, 42), container.service.value);
}

var rollback_deinit_count: usize = 0;

const RollbackService = struct {
    pub fn init() RollbackService {
        return .{};
    }

    pub fn deinit(_: *RollbackService) void {
        rollback_deinit_count += 1;
    }
};

const FailingService = struct {
    pub fn init() !FailingService {
        return error.InitializationFailed;
    }
};

test "rolls back initialized fields when a later initializer fails" {
    const FailingContainer = struct {
        initialized: RollbackService,
        failing: FailingService,
    };

    rollback_deinit_count = 0;
    try testing.expectError(error.InitializationFailed, zdi.init(testing.allocator, FailingContainer, .{}));
    try testing.expectEqual(@as(usize, 1), rollback_deinit_count);
}

test "returns OutOfMemory when container allocation fails" {
    const NonZeroContainer = struct {
        service: DefaultOnlyService,
    };
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });

    try testing.expectError(
        error.OutOfMemory,
        zdi.init(failing_allocator.allocator(), NonZeroContainer, .{}),
    );
}

const ReadOnlySettingsConsumer = struct {
    settings: *const Settings,

    pub fn init(settings: *const Settings) ReadOnlySettingsConsumer {
        return .{ .settings = settings };
    }
};

test "injects mutable fields through const pointers" {
    const ReadOnlyContainer = struct {
        settings: Settings,
        consumer: ReadOnlySettingsConsumer,
    };

    const container = try zdi.init(testing.allocator, ReadOnlyContainer, .{});
    defer zdi.deinit(testing.allocator, container);

    try testing.expect(container.consumer.settings == &container.settings);
    try testing.expectEqual(@as(u8, 7), container.consumer.settings.volume);
}

const DefaultOnlyService = struct {
    enabled: bool = true,
    retries: u8 = 3,
};

test "default-initializes struct fields without init declarations" {
    const DefaultContainer = struct {
        service: DefaultOnlyService,
    };

    const container = try zdi.init(testing.allocator, DefaultContainer, .{});
    defer zdi.deinit(testing.allocator, container);

    try testing.expect(container.service.enabled);
    try testing.expectEqual(@as(u8, 3), container.service.retries);
}

const RuntimeValue = struct {
    seed: u64,
};

const RuntimeConsumer = struct {
    seed: u64,

    pub fn init(runtime: RuntimeValue) RuntimeConsumer {
        return .{ .seed = runtime.seed };
    }
};

test "injects exact values supplied through externals" {
    const ExternalContainer = struct {
        consumer: RuntimeConsumer,
    };

    const container = try zdi.init(testing.allocator, ExternalContainer, .{
        .externals = .{RuntimeValue{ .seed = 1234 }},
    });
    defer zdi.deinit(testing.allocator, container);

    try testing.expectEqual(@as(u64, 1234), container.consumer.seed);
}

var observed_fields: [4][]const u8 = undefined;
var observed_field_count: usize = 0;

const ObservedContainer = struct {
    settings: Settings,
    renderer: Renderer,
    ui: UI,

    pub fn observeInit(_: *ObservedContainer, comptime field_name: []const u8) void {
        observed_fields[observed_field_count] = field_name;
        observed_field_count += 1;
    }
};

test "calls observer after each successfully initialized field" {
    observed_field_count = 0;
    resetLifecycleLog();

    const container = try zdi.init(testing.allocator, ObservedContainer, .{
        .observer = ObservedContainer.observeInit,
    });
    defer zdi.deinit(testing.allocator, container);

    try testing.expectEqual(@as(usize, 3), observed_field_count);
    try testing.expectEqualStrings("settings", observed_fields[0]);
    try testing.expectEqualStrings("renderer", observed_fields[1]);
    try testing.expectEqualStrings("ui", observed_fields[2]);
}

test "does not observe a field whose initializer fails" {
    const ObservedFailingContainer = struct {
        initialized: RollbackService,
        failing: FailingService,

        pub fn observeInit(_: *@This(), comptime field_name: []const u8) void {
            observed_fields[observed_field_count] = field_name;
            observed_field_count += 1;
        }
    };

    observed_field_count = 0;
    rollback_deinit_count = 0;

    try testing.expectError(
        error.InitializationFailed,
        zdi.init(testing.allocator, ObservedFailingContainer, .{
            .observer = ObservedFailingContainer.observeInit,
        }),
    );
    try testing.expectEqual(@as(usize, 1), observed_field_count);
    try testing.expectEqualStrings("initialized", observed_fields[0]);
}

const AutoWiredRenderer = struct {
    settings: *Settings,
    runtime: RuntimeValue,
    enabled: bool = true,
};

test "comptime auto-wires required fields when init is absent" {
    const AutoWiredContainer = struct {
        settings: Settings,
        renderer: AutoWiredRenderer,
    };

    const container = try zdi.init(testing.allocator, AutoWiredContainer, .{
        .externals = .{RuntimeValue{ .seed = 99 }},
    });
    defer zdi.deinit(testing.allocator, container);

    try testing.expect(container.renderer.settings == &container.settings);
    try testing.expectEqual(@as(u64, 99), container.renderer.runtime.seed);
    try testing.expect(container.renderer.enabled);
}

const DefaultBeatsExternal = struct {
    value: u8 = 7,
};

test "field defaults take precedence over matching externals" {
    const DefaultPrecedenceContainer = struct {
        service: DefaultBeatsExternal,
    };

    const container = try zdi.init(testing.allocator, DefaultPrecedenceContainer, .{
        .externals = .{@as(u8, 42)},
    });
    defer zdi.deinit(testing.allocator, container);

    try testing.expectEqual(@as(u8, 7), container.service.value);
}
