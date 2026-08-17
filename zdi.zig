const std = @import("std");

pub fn init(allocator: std.mem.Allocator, comptime container_type: type) !*container_type {
    @setEvalBranchQuota(10_000);

    const container = try allocator.create(container_type);
    errdefer allocator.destroy(container);

    var initialized_count: usize = 0;
    errdefer deinitInitialized(container, initialized_count);

    const fields = @typeInfo(container_type).@"struct".fields;
    inline for (fields, 0..) |field, field_index| {
        if (field.type == std.mem.Allocator) {
            @compileError(
                "zdi container field '" ++ field.name ++
                    "' must not store std.mem.Allocator; request it as an init parameter",
            );
        }

        if (comptime hasDecl(field.type, "init")) {
            const args = createArgs(
                initArgsType(field.type),
                container,
                allocator,
                fields,
                field_index,
                field.name,
            );
            const value = @call(.auto, @field(field.type, "init"), args);
            switch (@typeInfo(@TypeOf(value))) {
                .error_union => @field(container, field.name) = try value,
                else => @field(container, field.name) = value,
            }
        } else {
            @field(container, field.name) = field.type{};
        }

        initialized_count = field_index + 1;
    }

    return container;
}

fn initArgsType(comptime field_type: type) type {
    return std.meta.ArgsTuple(@TypeOf(@field(field_type, "init")));
}

fn createArgs(
    comptime args_type: type,
    container: anytype,
    allocator: std.mem.Allocator,
    comptime container_fields: anytype,
    comptime consumer_index: usize,
    comptime consumer_name: []const u8,
) args_type {
    var result: args_type = undefined;
    const args_info = @typeInfo(args_type);

    switch (args_info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                @field(result, field.name) = resolve(
                    container,
                    field.type,
                    allocator,
                    container_fields,
                    consumer_index,
                    consumer_name,
                );
            }
        },
        else => {},
    }

    return result;
}

fn resolve(
    container: anytype,
    comptime dependency_type: type,
    allocator: std.mem.Allocator,
    comptime container_fields: anytype,
    comptime consumer_index: usize,
    comptime consumer_name: []const u8,
) dependency_type {
    if (dependency_type == std.mem.Allocator) {
        return allocator;
    }

    const dependency_info = @typeInfo(dependency_type);
    if (dependency_info == .pointer) {
        const pointee_type = dependency_info.pointer.child;
        comptime var match_index: ?usize = null;

        inline for (container_fields[0..consumer_index], 0..) |field, field_index| {
            if (field.type == pointee_type) {
                if (match_index != null) {
                    @compileError(
                        "zdi dependency '" ++ @typeName(dependency_type) ++
                            "' for field '" ++ consumer_name ++
                            "' is ambiguous",
                    );
                }
                match_index = field_index;
            }
        }

        if (match_index) |field_index| {
            return &@field(container, container_fields[field_index].name);
        }
    }

    @compileError(
        "zdi can't resolve dependency '" ++ @typeName(dependency_type) ++
            "' for field '" ++ consumer_name ++
            "'; dependencies must appear earlier in the container",
    );
}

fn deinitInitialized(container: anytype, initialized_count: usize) void {
    const fields = @typeInfo(@TypeOf(container.*)).@"struct".fields;

    inline for (fields, 0..) |_, reverse_offset| {
        const field_index = fields.len - 1 - reverse_offset;
        const field = fields[field_index];

        if (initialized_count > field_index and comptime hasDecl(field.type, "deinit")) {
            @call(.auto, @field(field.type, "deinit"), .{&@field(container, field.name)});
        }
    }
}

pub fn deinit(allocator: std.mem.Allocator, container: anytype) void {
    const fields = @typeInfo(@TypeOf(container.*)).@"struct".fields;
    deinitInitialized(container, fields.len);
    allocator.destroy(container);
}

fn hasDecl(comptime value_type: type, comptime name: []const u8) bool {
    return switch (@typeInfo(value_type)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(value_type, name),
        else => false,
    };
}
