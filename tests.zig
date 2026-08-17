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

test "initializes dependencies before consumers" {
    resetLifecycleLog();

    const registry = try zdi.init(testing.allocator, .{Container}, .{});
    defer zdi.deinit(registry);
    const container = registry.get(Container);

    try testing.expectEqual(@as(u8, 7), container.settings.volume);
    try testing.expect(container.renderer.settings == &container.settings);
    try testing.expect(container.ui.renderer == &container.renderer);
    try testing.expect(container.ui.allocator.ptr == testing.allocator.ptr);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, lifecycle_log[0..lifecycle_log_len]);
}

test "deinitializes fields in reverse dependency order" {
    resetLifecycleLog();

    const registry = try zdi.init(testing.allocator, .{Container}, .{});
    zdi.deinit(registry);

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

    const registry = try zdi.init(testing.allocator, .{FallibleContainer}, .{});
    defer zdi.deinit(registry);
    const container = registry.get(FallibleContainer);

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
    try testing.expectError(error.InitializationFailed, zdi.init(testing.allocator, .{FailingContainer}, .{}));
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
        zdi.init(failing_allocator.allocator(), .{NonZeroContainer}, .{}),
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

    const registry = try zdi.init(testing.allocator, .{ReadOnlyContainer}, .{});
    defer zdi.deinit(registry);
    const container = registry.get(ReadOnlyContainer);

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

    const registry = try zdi.init(testing.allocator, .{DefaultContainer}, .{});
    defer zdi.deinit(registry);
    const container = registry.get(DefaultContainer);

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

    const registry = try zdi.init(testing.allocator, .{ExternalContainer}, .{
        .externals = .{RuntimeValue{ .seed = 1234 }},
    });
    defer zdi.deinit(registry);
    const container = registry.get(ExternalContainer);

    try testing.expectEqual(@as(u64, 1234), container.consumer.seed);
}

var observed_fields: [4][]const u8 = undefined;
var observed_field_count: usize = 0;

const ObservedContainer = struct {
    settings: Settings,
    renderer: Renderer,
    ui: UI,
};

fn observeInit(count: *usize, _: anytype, comptime field_name: []const u8) void {
    observed_fields[count.*] = field_name;
    count.* += 1;
}

test "calls observer after each successfully initialized field" {
    observed_field_count = 0;
    resetLifecycleLog();

    const registry = try zdi.init(testing.allocator, .{ObservedContainer}, .{
        .observer = .{
            .context = &observed_field_count,
            .callback = observeInit,
        },
    });
    defer zdi.deinit(registry);

    try testing.expectEqual(@as(usize, 3), observed_field_count);
    try testing.expectEqualStrings("settings", observed_fields[0]);
    try testing.expectEqualStrings("renderer", observed_fields[1]);
    try testing.expectEqualStrings("ui", observed_fields[2]);
}

test "does not observe a field whose initializer fails" {
    const ObservedFailingContainer = struct {
        initialized: RollbackService,
        failing: FailingService,
    };

    observed_field_count = 0;
    rollback_deinit_count = 0;

    try testing.expectError(
        error.InitializationFailed,
        zdi.init(testing.allocator, .{ObservedFailingContainer}, .{
            .observer = .{
                .context = &observed_field_count,
                .callback = observeInit,
            },
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

    const registry = try zdi.init(testing.allocator, .{AutoWiredContainer}, .{
        .externals = .{RuntimeValue{ .seed = 99 }},
    });
    defer zdi.deinit(registry);
    const container = registry.get(AutoWiredContainer);

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

    const registry = try zdi.init(testing.allocator, .{DefaultPrecedenceContainer}, .{
        .externals = .{@as(u8, 42)},
    });
    defer zdi.deinit(registry);
    const container = registry.get(DefaultPrecedenceContainer);

    try testing.expectEqual(@as(u8, 7), container.service.value);
}

const ReorderedContainer = struct {
    ui: UI,
    renderer: Renderer,
    settings: Settings,
};

test "derives initialization and cleanup order from dependencies" {
    resetLifecycleLog();
    observed_field_count = 0;

    const registry = try zdi.init(testing.allocator, .{ReorderedContainer}, .{
        .observer = .{
            .context = &observed_field_count,
            .callback = observeInit,
        },
    });
    const container = registry.get(ReorderedContainer);

    try testing.expect(container.renderer.settings == &container.settings);
    try testing.expect(container.ui.renderer == &container.renderer);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, lifecycle_log[0..lifecycle_log_len]);
    try testing.expectEqualStrings("settings", observed_fields[0]);
    try testing.expectEqualStrings("renderer", observed_fields[1]);
    try testing.expectEqualStrings("ui", observed_fields[2]);

    zdi.deinit(registry);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, lifecycle_log[0..lifecycle_log_len]);
}
