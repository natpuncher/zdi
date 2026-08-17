const std = @import("std");
const zdi = @import("zdi");

const Service = struct {
    pub fn deinit() void {}
};

test {
    const container = try zdi.init(std.testing.allocator, struct { service: Service }, .{});
    zdi.deinit(std.testing.allocator, container);
}
