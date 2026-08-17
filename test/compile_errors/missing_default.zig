const std = @import("std");
const zdi = @import("zdi");

test {
    _ = try zdi.init(std.testing.allocator, struct { value: u8 }, .{});
}
