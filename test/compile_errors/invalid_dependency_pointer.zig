const std = @import("std");
const zdi = @import("zdi");

const Item = struct {};
const Consumer = struct {
    pub fn init(_: []Item) Consumer {
        return .{};
    }
};

test {
    _ = try zdi.init(std.testing.allocator, .{struct {
        item: Item,
        consumer: Consumer,
    }}, .{});
}
