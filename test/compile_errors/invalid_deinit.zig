const std = @import("std");
const zdi = @import("zdi");

const Service = struct {
    pub fn deinit() void {}
};

test {
    const registry = try zdi.init(std.testing.allocator, .{struct { service: Service }}, .{});
    zdi.deinit(registry);
}
