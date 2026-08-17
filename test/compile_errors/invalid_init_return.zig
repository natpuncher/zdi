const std = @import("std");
const zdi = @import("zdi");

const Service = struct {
    pub fn init() u8 {
        return 1;
    }
};

test {
    _ = try zdi.init(std.testing.allocator, .{struct { service: Service }}, .{});
}
