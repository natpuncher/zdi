# zdi

Small compile-time dependency injection registry for Zig. Describe components
as fields of one or more container structs; zdi wires them together in
dependency order, rejects invalid graphs at compile time, and cleans them up
automatically.

![logo](res/logo.png)

## Features

- Dependency resolution by exact type, independent of declaration order.
- Automatic struct assembly with preserved field defaults.
- Custom fallible `init` and reverse-order `deinit`.
- Runtime values supplied as external dependencies.
- One dependency graph shared by multiple containers.
- Optional initialization observer.
- Compile errors for missing, ambiguous, cyclic, or invalid dependencies.

## Installation

Execute in your project repository root:

```
zig fetch --save git+https://github.com/natpuncher/zdi
```

Then add the dependency and import in `build.zig`:

```zig
const zdi = b.dependency("zdi", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zdi", zdi.module("zdi"));
```

## Quick start

```zig
const std = @import("std");
const zdi = @import("zdi");

const Settings = struct {
    title: []const u8 = "Example",
};

const Renderer = struct {
    settings: *Settings,
};

const App = struct {
    renderer: *Renderer,
    running: bool = true,

    pub fn init(renderer: *Renderer) App {
        return .{ .renderer = renderer };
    }
};

// Declaration order does not matter.
const Container = struct {
    app: App,
    renderer: Renderer,
    settings: Settings,
};

pub fn main() !void {
    const registry = try zdi.init(std.heap.page_allocator, .{Container}, .{});
    defer zdi.deinit(registry);

    const container = registry.get(Container);
    std.debug.assert(container.renderer.settings == &container.settings);
    std.debug.assert(container.app.renderer == &container.renderer);
    std.debug.assert(container.app.running);
}
```

Types without `init` are assembled from injectable fields and field defaults.
Single-item pointers such as `*Settings` identify container dependencies.

## Usage

### Custom initialization and external values

Use `init` when a component needs custom construction. Parameters may combine
container dependencies, `std.mem.Allocator`, and values passed through
`externals`.

```zig
const RuntimeConfig = struct {
    application_name: []const u8,
};

const Logger = struct {
    allocator: std.mem.Allocator,
    prefix: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        config: RuntimeConfig,
    ) !Logger {
        return .{
            .allocator = allocator,
            .prefix = try allocator.dupe(u8, config.application_name),
        };
    }

    pub fn deinit(logger: *Logger) void {
        logger.allocator.free(logger.prefix);
    }
};

const Container = struct {
    logger: Logger,
};

const registry = try zdi.init(allocator, .{Container}, .{
    .externals = .{RuntimeConfig{ .application_name = "example" }},
});
defer zdi.deinit(registry);
```

If initialization fails, zdi deinitializes every completed component in reverse
dependency order. Normal `deinit` uses the same order and destroys the registry
with the allocator captured by `init`.

### Multiple containers

Containers remain separate for access, but their components share one global
dependency graph.

```zig
const Renderer = struct {};

const InventoryWindow = struct {
    renderer: *Renderer,
};

const SettingsWindow = struct {
    renderer: *Renderer,
};

const Game = struct {
    inventory: *InventoryWindow,
    settings: *SettingsWindow,
};

const GameContainer = struct {
    game: Game,
    renderer: Renderer,
};

const UiContainer = struct {
    inventory: InventoryWindow,
    settings: SettingsWindow,
};

const registry = try zdi.init(allocator, .{ GameContainer, UiContainer }, .{});
defer zdi.deinit(registry);

const game = registry.get(GameContainer);
const ui = registry.get(UiContainer);
std.debug.assert(ui.inventory.renderer == &game.renderer);
std.debug.assert(ui.settings.renderer == &game.renderer);
std.debug.assert(game.game.inventory == &ui.inventory);
std.debug.assert(game.game.settings == &ui.settings);
```

### Observe initialization

An observer runs after each component is initialized successfully. Its callback
receives the configured context, the owning container, and the field name.

```zig
const InitProfiler = struct {
    timer: std.time.Timer,
    initialized_count: usize = 0,

    fn observe(
        profiler: *InitProfiler,
        container: anytype,
        comptime field_name: []const u8,
    ) void {
        const component = @field(container, field_name);

        std.debug.print(
            "{s}: {s} initialized after {d} ns\n",
            .{
                field_name,
                @typeName(@TypeOf(component)),
                profiler.timer.read(),
            },
        );
        profiler.initialized_count += 1;
    }
};

var profiler = InitProfiler{ .timer = try std.time.Timer.start() };
const registry = try zdi.init(allocator, .{Container}, .{
    .observer = .{
        .context = &profiler,
        .callback = InitProfiler.observe,
    },
});
defer zdi.deinit(registry);

std.debug.assert(profiler.initialized_count == 3);
```

## How it works

At compile time, zdi combines fields from every registered container into one
dependency graph. Container declaration order and field declaration order do
not affect initialization order.

For each parameter of a component's `init`, zdi resolves:

- `std.mem.Allocator` from the allocator passed to `zdi.init`;
- an exact external type from `config.externals`;
- a single-item pointer such as `*Renderer` from any registered container.

Components without `init` are assembled the same way from their fields, while
fields with defaults keep their default values.

At runtime, components initialize in dependency order. If initialization fails,
zdi deinitializes completed components in reverse order. `zdi.deinit` follows
the same reverse order and then destroys the registry.

Missing, ambiguous, cyclic, and invalid dependencies stop compilation with a
descriptive error.
