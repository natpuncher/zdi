# zdi

Small compile-time dependency injection registry for Zig. Register one or more
container structs and zdi derives a global initialization order from their
dependencies at compile time. Types may provide `init` or let zdi assemble
their fields automatically.

## Example

```zig
const std = @import("std");
const zdi = @import("zdi");

// Runtime values created outside the container.
const RuntimeConfig = struct {
    application_name: []const u8,
    volume: u8,
};

// Custom fallible initialization and owned memory.
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

// No init: zdi injects logger and preserves cache_limit.
const Assets = struct {
    logger: *Logger,
    cache_limit: usize = 128,
};

// Custom initialization combining a component and an external value.
const Audio = struct {
    assets: *Assets,
    volume: u8,

    pub fn init(assets: *Assets, config: RuntimeConfig) Audio {
        return .{
            .assets = assets,
            .volume = config.volume,
        };
    }

    pub fn deinit(_: *Audio) void {
        std.debug.print("audio stopped\n", .{});
    }
};

// No init: both dependency injection and a field default are automatic.
const Game = struct {
    audio: *Audio,
    running: bool = true,
};

// UI lives in a separate container but shares the same dependency graph.
const InventoryWindow = struct {
    game: *Game,
};

// Declaration order is arbitrary; zdi derives Logger -> Assets -> Audio -> Game.
const Container = struct {
    game: Game,
    audio: Audio,
    logger: Logger,
    assets: Assets,
};

const UiContainer = struct {
    inventory: InventoryWindow,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const runtime = RuntimeConfig{
        .application_name = "example",
        .volume = 80,
    };

    const containers = try zdi.init(allocator, .{ Container, UiContainer }, .{
        .externals = .{runtime},
    });

    // Reverse-order component cleanup, then registry destruction with the
    // allocator captured by init.
    defer zdi.deinit(containers);

    const container = containers.get(Container);
    const ui = containers.get(UiContainer);

    std.debug.assert(container.assets.logger == &container.logger);
    std.debug.assert(container.assets.cache_limit == 128);
    std.debug.assert(container.audio.assets == &container.assets);
    std.debug.assert(container.audio.volume == 80);
    std.debug.assert(container.game.audio == &container.audio);
    std.debug.assert(ui.inventory.game == &container.game);
    std.debug.assert(container.game.running);
}
```

If a later initializer fails, zdi cleans up already initialized components in
reverse dependency order.

## Compile-time contract

- `init` accepts a tuple containing one or more unique container struct types.
- `get(ContainerType)` returns the registered container by type.
- Config accepts optional `externals` and `observer` fields.
- Externals are resolved by exact type before container dependencies.
- Container dependencies use single-item pointers and resolve across every
  registered container.
- A component `init` returns its own type or an error union containing it.
- Without `init`, required fields are injected and defaults are preserved.
- Container, component, and external types are unique in their respective
  registries.
- Invalid, missing, ambiguous, and cyclic dependencies produce compile errors.
