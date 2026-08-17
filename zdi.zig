const std = @import("std");

pub fn init(allocator: std.mem.Allocator, comptime container_type: type) *container_type {
    @setEvalBranchQuota(1_000);

    var container = allocator.create(container_type) catch unreachable;

    const container_info = @typeInfo(container_type).@"struct";
    inline for (container_info.fields) |field| {
        if (field.type != std.mem.Allocator) {
            if (@hasDecl(field.type, "init")) {
                const args = createArgs(initArgsType(field.type), container, allocator);
                @field(container, field.name) = @call(.auto, @field(field.type, "init"), args);
            } else {
                @field(container, field.name) = field.type{};
            }
        }
    }
    return container;
}

fn initArgsType(field_type: type) type {
    return std.meta.ArgsTuple(@TypeOf(@field(field_type, "init")));
}

fn createArgs(args_type: type, container_instance: anytype, allocator: std.mem.Allocator) args_type {
    const args_info = @typeInfo(args_type);
    var result: args_type = undefined;
    switch (args_info) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                @field(result, field.name) = resolve(container_instance, field.type, allocator);
            }
        },
        else => {},
    }
    return result;
}

fn resolve(container_instance: anytype, comptime field_type: type, allocator: std.mem.Allocator) field_type {
    const field_type_info = @typeInfo(field_type);
    switch (field_type_info) {
        .pointer => {
            const container_info = @typeInfo(@TypeOf(container_instance.*)).@"struct";
            inline for (container_info.fields) |field| {
                if (field.type == field_type_info.pointer.child) {
                    return &@field(container_instance, field.name);
                }
            }
        },
        .@"struct" => |_| {
            if (field_type == std.mem.Allocator) {
                return allocator;
            }
        },
        else => {},
    }

    @compileError("can't find in container " ++ @typeName(field_type));
}

pub fn deinit(container: anytype) void {
    const container_info = @typeInfo(@TypeOf(container.*)).@"struct";
    inline for (container_info.fields) |field| {
        if (@hasDecl(field.type, "deinit")) {
            @call(.auto, @field(field.type, "deinit"), .{&@field(container, field.name)});
        }
    }
}
