const std = @import("std");
const zdi = @import("zdi");

const Service = struct {
    pub fn init(_: anytype) Service {
        return .{};
    }
};

test {
    _ = try zdi.init(std.testing.allocator, struct { service: Service }, .{});
}
