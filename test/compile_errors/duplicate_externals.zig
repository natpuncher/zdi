const std = @import("std");
const zdi = @import("zdi");

test {
    _ = try zdi.init(std.testing.allocator, struct {}, .{
        .externals = .{ @as(u8, 1), @as(u8, 2) },
    });
}
