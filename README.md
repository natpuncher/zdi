# zdi

Small compile-time dependency injection container for Zig. Container fields are
initialized in declaration order. Types may provide `init` or let zdi assemble
their fields at compile time.

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

// Dependencies appear before consumers.
const Container = struct {
    logger: Logger,
    assets: Assets,
    audio: Audio,
    game: Game,

    // Called after every successfully initialized container field.
    pub fn observeInit(
        _: *Container,
        comptime field_name: []const u8,
    ) void {
        std.debug.print("initialized: {s}\n", .{field_name});
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const runtime = RuntimeConfig{
        .application_name = "example",
        .volume = 80,
    };

    const container = try zdi.init(allocator, Container, .{
        .externals = .{runtime},
        .observer = Container.observeInit,
    });

    // Reverse-order component cleanup, then container destruction.
    defer zdi.deinit(allocator, container);

    std.debug.assert(container.assets.logger == &container.logger);
    std.debug.assert(container.assets.cache_limit == 128);
    std.debug.assert(container.audio.assets == &container.assets);
    std.debug.assert(container.audio.volume == 80);
    std.debug.assert(container.game.audio == &container.audio);
    std.debug.assert(container.game.running);
}
```

If a later initializer fails, zdi cleans up already initialized components in
reverse declaration order.

## Compile-time contract

- Config accepts optional `externals` and `observer` fields.
- Externals are resolved by exact type before container dependencies.
- Container dependencies use single-item pointers and refer to earlier fields.
- A component `init` returns its own type or an error union containing it.
- Without `init`, required fields are injected and defaults are preserved.
- Component types and external types are unique.
- Invalid, missing, late, and ambiguous dependencies produce compile errors.
