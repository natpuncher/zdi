const std = @import("std");
const zdi = @import("zdi");

const First = struct {
    second: *Second,
};

const Second = struct {
    first: *First,
};

test {
    _ = try zdi.init(std.testing.allocator, struct {
        first: First,
        second: Second,
    }, .{});
}
