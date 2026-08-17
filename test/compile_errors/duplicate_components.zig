const std = @import("std");
const zdi = @import("zdi");

const Service = struct {};

test {
    _ = try zdi.init(std.testing.allocator, struct {
        first: Service,
        second: Service,
    }, .{});
}
