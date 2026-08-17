const std = @import("std");
const zdi = @import("zdi");

const Missing = struct {};
const Consumer = struct {
    missing: *Missing,
};

test {
    _ = try zdi.init(std.testing.allocator, struct { consumer: Consumer }, .{});
}
