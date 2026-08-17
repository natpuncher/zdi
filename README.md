# zdi

Small compile-time dependency injection container for Zig.

Container fields are initialized in declaration order. An `init` declaration
receives pointers to earlier fields by type and may receive
`std.mem.Allocator`. Initializers may return either `T` or `!T`.

```zig
const std = @import("std");
const zdi = @import("zdi");

const Renderer = struct {};

const UI = struct {
    renderer: *Renderer,

    pub fn init(renderer: *Renderer) UI {
        return .{ .renderer = renderer };
    }
};

const Container = struct {
    renderer: Renderer,
    ui: UI,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const container = try zdi.init(allocator, Container);
    defer zdi.deinit(allocator, container);
}
```

Types without `init` are initialized with `T{}`. If a type declares `deinit`,
zdi it during cleanup. Cleanup uses reverse declaration order and also
runs for fields initialized before a later initializer returns an error.

Dependencies must appear before their consumers and field types must be unique
within the resolvable prefix. Missing and ambiguous dependencies produce
compile-time errors.
