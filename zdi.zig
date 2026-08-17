const std = @import("std");

pub fn Registry(comptime container_types: anytype) type {
    const types = validatedContainerTypes(container_types);
    const Containers = std.meta.Tuple(&types);

    return struct {
        const Self = @This();

        pub const zdi_container_types = container_types;

        allocator: std.mem.Allocator,
        containers: Containers,

        pub fn get(self: *Self, comptime container_type: type) *container_type {
            inline for (container_types, 0..) |registered_type, container_index| {
                if (registered_type == container_type) return &self.containers[container_index];
            }
            @compileError(
                "zdi container type '" ++ @typeName(container_type) ++ "' is not registered",
            );
        }
    };
}

pub fn init(
    allocator: std.mem.Allocator,
    comptime container_types: anytype,
    config: anytype,
) !*Registry(container_types) {
    const component_count = comptime componentCount(container_types);
    @setEvalBranchQuota(component_count * component_count * component_count * 2);

    validateConfig(config);
    validateComponents(container_types);

    const RegistryType = Registry(container_types);
    const init_order = comptime initializationOrder(container_types);

    const registry = try allocator.create(RegistryType);
    registry.allocator = allocator;
    errdefer allocator.destroy(registry);

    var initialized_count: usize = 0;
    errdefer internalDeinit(registry, container_types, init_order, initialized_count);

    inline for (init_order, 0..) |component_index, init_index| {
        try initializeComponent(registry, container_types, component_index, config);
        initialized_count = init_index + 1;
    }

    comptime std.debug.assert(component_count == init_order.len);
    return registry;
}

pub fn deinit(registry: anytype) void {
    const RegistryType = @TypeOf(registry.*);
    const container_types = RegistryType.zdi_container_types;
    const component_count = comptime componentCount(container_types);
    @setEvalBranchQuota(component_count * component_count * component_count * 2);

    const init_order = comptime initializationOrder(container_types);
    const allocator = registry.allocator;
    internalDeinit(registry, container_types, init_order, init_order.len);
    allocator.destroy(registry);
}

fn initializeComponent(
    registry: anytype,
    comptime container_types: anytype,
    comptime target_index: usize,
    config: anytype,
) !void {
    comptime var component_index: usize = 0;
    inline for (container_types, 0..) |container_type, container_index| {
        const fields = @typeInfo(container_type).@"struct".fields;
        inline for (fields) |field| {
            if (component_index == target_index) {
                if (field.type == std.mem.Allocator) {
                    @compileError(
                        "zdi container field '" ++ field.name ++
                            "' must not store std.mem.Allocator; request it as an init parameter",
                    );
                }

                const container = &registry.containers[container_index];
                if (comptime hasDecl(field.type, "init")) {
                    validateInit(field.type, componentPath(container_type, field.name));
                    const args = createArgs(
                        initArgsType(field.type),
                        registry,
                        container_types,
                        componentPath(container_type, field.name),
                        config,
                    );
                    const value = @call(.auto, @field(field.type, "init"), args);
                    switch (@typeInfo(@TypeOf(value))) {
                        .error_union => @field(container, field.name) = try value,
                        else => @field(container, field.name) = value,
                    }
                } else {
                    @field(container, field.name) = createInstance(
                        field,
                        registry,
                        container_types,
                        componentPath(container_type, field.name),
                        config,
                    );
                }
                observeInit(config, container, field.name);
                return;
            }
            component_index += 1;
        }
    }
    unreachable;
}

fn createInstance(
    comptime container_field: anytype,
    registry: anytype,
    comptime container_types: anytype,
    comptime consumer_name: []const u8,
    config: anytype,
) container_field.type {
    const component_type = container_field.type;

    if (container_field.default_value_ptr) |default_value_ptr| {
        return readDefault(component_type, default_value_ptr);
    }
    if (component_type == void) return {};
    if (@typeInfo(component_type) != .@"struct") {
        @compileError(
            "zdi field '" ++ consumer_name ++ "' of type '" ++
                @typeName(component_type) ++ "' has no init and no default value",
        );
    }

    var result: component_type = undefined;
    inline for (@typeInfo(component_type).@"struct".fields) |field| {
        if (field.default_value_ptr) |default_value_ptr| {
            @field(result, field.name) = readDefault(field.type, default_value_ptr);
        } else {
            const field_name = std.fmt.comptimePrint("{s}.{s}", .{ consumer_name, field.name });
            @field(result, field.name) = resolve(
                registry,
                field.type,
                container_types,
                field_name,
                config,
            );
        }
    }
    return result;
}

fn readDefault(comptime value_type: type, default_value_ptr: *const anyopaque) value_type {
    const default_value: *const value_type = @ptrCast(@alignCast(default_value_ptr));
    return default_value.*;
}

fn initArgsType(comptime field_type: type) type {
    return std.meta.ArgsTuple(@TypeOf(@field(field_type, "init")));
}

fn createArgs(
    comptime args_type: type,
    registry: anytype,
    comptime container_types: anytype,
    comptime consumer_name: []const u8,
    config: anytype,
) args_type {
    var result: args_type = undefined;
    const args_info = @typeInfo(args_type);

    switch (args_info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                @field(result, field.name) = resolve(
                    registry,
                    field.type,
                    container_types,
                    consumer_name,
                    config,
                );
            }
        },
        else => {},
    }

    return result;
}

fn resolve(
    registry: anytype,
    comptime dependency_type: type,
    comptime container_types: anytype,
    comptime consumer_name: []const u8,
    config: anytype,
) dependency_type {
    if (dependency_type == std.mem.Allocator) return registry.allocator;

    if (comptime @hasField(@TypeOf(config), "externals")) {
        const externals = config.externals;
        const external_fields = @typeInfo(@TypeOf(externals)).@"struct".fields;
        comptime var external_match: ?usize = null;

        inline for (external_fields, 0..) |field, field_index| {
            if (field.type == dependency_type) {
                if (external_match != null) {
                    @compileError(
                        "zdi external dependency '" ++ @typeName(dependency_type) ++
                            "' for field '" ++ consumer_name ++ "' is ambiguous",
                    );
                }
                external_match = field_index;
            }
        }
        if (external_match) |field_index| {
            return @field(externals, external_fields[field_index].name);
        }
    }

    const dependency_info = @typeInfo(dependency_type);
    if (dependency_info == .pointer) {
        if (dependency_info.pointer.size != .one) {
            @compileError(
                "zdi dependency '" ++ @typeName(dependency_type) ++
                    "' for field '" ++ consumer_name ++
                    "' must be a single-item pointer or external value",
            );
        }
        const pointee_type = dependency_info.pointer.child;
        if (comptime componentDependencyIndex(container_types, dependency_type) != null) {
            return componentPointer(registry, container_types, pointee_type);
        }
    }

    @compileError(
        "zdi can't resolve dependency '" ++ @typeName(dependency_type) ++
            "' for field '" ++ consumer_name ++ "'",
    );
}

fn componentPointer(
    registry: anytype,
    comptime container_types: anytype,
    comptime component_type: type,
) *component_type {
    inline for (container_types, 0..) |container_type, container_index| {
        inline for (@typeInfo(container_type).@"struct".fields) |field| {
            if (field.type == component_type) {
                return &@field(registry.containers[container_index], field.name);
            }
        }
    }
    unreachable;
}

fn initializationOrder(comptime container_types: anytype) [componentCount(container_types)]usize {
    const count = componentCount(container_types);
    var order: [count]usize = undefined;
    var initialized: [count]bool = .{false} ** count;

    for (0..count) |init_index| {
        var selected: ?usize = null;
        for (0..count) |component_index| {
            if (!initialized[component_index] and
                dependenciesReady(container_types, component_index, initialized))
            {
                selected = component_index;
                break;
            }
        }

        const component_index = selected orelse dependencyCycle(container_types, initialized);
        order[init_index] = component_index;
        initialized[component_index] = true;
    }
    return order;
}

fn dependenciesReady(
    comptime container_types: anytype,
    comptime target_index: usize,
    initialized: anytype,
) bool {
    comptime var component_index: usize = 0;
    inline for (container_types) |container_type| {
        inline for (@typeInfo(container_type).@"struct".fields) |component| {
            if (component_index == target_index) {
                if (component.default_value_ptr != null or component.type == void) return true;

                if (hasDecl(component.type, "init")) {
                    validateInit(component.type, componentPath(container_type, component.name));
                    const function = @typeInfo(@TypeOf(@field(component.type, "init"))).@"fn";
                    for (function.params) |parameter| {
                        const dependency_type = parameter.type orelse return false;
                        if (componentDependencyIndex(container_types, dependency_type)) |dependency_index| {
                            if (!initialized[dependency_index]) return false;
                        }
                    }
                    return true;
                }

                const component_info = @typeInfo(component.type);
                if (component_info != .@"struct") return true;
                for (component_info.@"struct".fields) |field| {
                    if (field.default_value_ptr != null) continue;
                    if (componentDependencyIndex(container_types, field.type)) |dependency_index| {
                        if (!initialized[dependency_index]) return false;
                    }
                }
                return true;
            }
            component_index += 1;
        }
    }
    unreachable;
}

fn componentDependencyIndex(comptime container_types: anytype, comptime dependency_type: type) ?usize {
    if (dependency_type == std.mem.Allocator) return null;
    const dependency_info = @typeInfo(dependency_type);
    if (dependency_info != .pointer or dependency_info.pointer.size != .one) return null;

    comptime var component_index: usize = 0;
    inline for (container_types) |container_type| {
        inline for (@typeInfo(container_type).@"struct".fields) |field| {
            if (field.type == dependency_info.pointer.child) return component_index;
            component_index += 1;
        }
    }
    return null;
}

fn dependencyCycle(comptime container_types: anytype, initialized: anytype) noreturn {
    comptime var message: []const u8 = "zdi dependency cycle between fields";
    comptime var component_index: usize = 0;
    inline for (container_types) |container_type| {
        inline for (@typeInfo(container_type).@"struct".fields) |field| {
            if (!initialized[component_index]) {
                message = message ++ " '" ++ componentPath(container_type, field.name) ++ "'";
            }
            component_index += 1;
        }
    }
    @compileError(message);
}

fn observeInit(config: anytype, container: anytype, comptime field_name: []const u8) void {
    if (comptime @hasField(@TypeOf(config), "observer")) {
        const observer = config.observer;
        @call(.auto, observer.callback, .{ observer.context, container, field_name });
    }
}

fn internalDeinit(
    registry: anytype,
    comptime container_types: anytype,
    comptime init_order: anytype,
    initialized_count: usize,
) void {
    inline for (init_order, 0..) |_, reverse_offset| {
        const init_index = init_order.len - 1 - reverse_offset;
        if (initialized_count > init_index) {
            deinitComponent(registry, container_types, init_order[init_index]);
        }
    }
}

fn deinitComponent(registry: anytype, comptime container_types: anytype, comptime target_index: usize) void {
    comptime var component_index: usize = 0;
    inline for (container_types, 0..) |container_type, container_index| {
        inline for (@typeInfo(container_type).@"struct".fields) |field| {
            if (component_index == target_index) {
                if (comptime hasDecl(field.type, "deinit")) {
                    const component = &@field(registry.containers[container_index], field.name);
                    @call(.auto, @field(field.type, "deinit"), .{component});
                }
                return;
            }
            component_index += 1;
        }
    }
    unreachable;
}

fn validatedContainerTypes(comptime container_types: anytype) [container_types.len]type {
    const info = @typeInfo(@TypeOf(container_types));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("zdi containers must be a tuple of struct types");
    }
    if (container_types.len == 0) {
        @compileError("zdi requires at least one container type");
    }

    var result: [container_types.len]type = undefined;
    inline for (container_types, 0..) |container_type, container_index| {
        if (@TypeOf(container_type) != type or @typeInfo(container_type) != .@"struct") {
            @compileError("zdi containers must be a tuple of struct types");
        }
        inline for (container_types, 0..) |other_type, other_index| {
            if (other_index > container_index and container_type == other_type) {
                @compileError("zdi container type '" ++ @typeName(container_type) ++ "' is duplicated");
            }
        }
        result[container_index] = container_type;
    }
    return result;
}

fn componentCount(comptime container_types: anytype) usize {
    var count = 0;
    inline for (container_types) |container_type| {
        count += @typeInfo(container_type).@"struct".fields.len;
    }
    return count;
}

fn componentPath(comptime container_type: type, comptime field_name: []const u8) []const u8 {
    return @typeName(container_type) ++ "." ++ field_name;
}

fn validateConfig(config: anytype) void {
    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct") @compileError("zdi config must be a struct");

    inline for (config_info.@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "externals") and
            !std.mem.eql(u8, field.name, "observer"))
        {
            @compileError("zdi config field '" ++ field.name ++ "' is not supported");
        }
    }
    if (comptime @hasField(@TypeOf(config), "externals")) validateExternals(@TypeOf(config.externals));
}

fn validateExternals(comptime externals_type: type) void {
    const externals_info = @typeInfo(externals_type);
    if (externals_info != .@"struct") {
        @compileError("zdi config externals must be a tuple or struct");
    }

    const fields = externals_info.@"struct".fields;
    inline for (fields, 0..) |field, field_index| {
        inline for (fields, 0..) |other, other_index| {
            if (other_index > field_index and field.type == other.type) {
                @compileError("zdi external type '" ++ @typeName(field.type) ++ "' is duplicated");
            }
        }
    }
}

fn validateComponents(comptime container_types: anytype) void {
    _ = validatedContainerTypes(container_types);
    inline for (container_types) |container_type| {
        inline for (@typeInfo(container_type).@"struct".fields) |field| {
            if (comptime hasDecl(field.type, "deinit")) validateDeinit(field.type);
        }
    }

    comptime var left_index: usize = 0;
    inline for (container_types) |container_type| {
        inline for (@typeInfo(container_type).@"struct".fields) |field| {
            comptime var right_index: usize = 0;
            inline for (container_types) |other_container_type| {
                inline for (@typeInfo(other_container_type).@"struct".fields) |other_field| {
                    if (right_index > left_index and field.type == other_field.type) {
                        @compileError(
                            "zdi component type '" ++ @typeName(field.type) ++ "' is duplicated",
                        );
                    }
                    right_index += 1;
                }
            }
            left_index += 1;
        }
    }
}

fn validateInit(comptime field_type: type, comptime field_name: []const u8) void {
    const function = @typeInfo(@TypeOf(@field(field_type, "init"))).@"fn";
    if (function.is_generic or function.is_var_args) {
        @compileError("zdi init for field '" ++ field_name ++ "' cannot be generic or variadic");
    }
    const return_type = function.return_type orelse @compileError(
        "zdi init for field '" ++ field_name ++ "' must declare a return type",
    );
    const payload_type = switch (@typeInfo(return_type)) {
        .error_union => |error_union| error_union.payload,
        else => return_type,
    };
    if (payload_type != field_type) {
        @compileError(
            "zdi init for field '" ++ field_name ++ "' must return '" ++
                @typeName(field_type) ++ "' or an error union containing it, found '" ++
                @typeName(return_type) ++ "'",
        );
    }
}

fn validateDeinit(comptime field_type: type) void {
    const function_info = @typeInfo(@TypeOf(@field(field_type, "deinit")));
    const expected_message = "zdi deinit for type '" ++ @typeName(field_type) ++
        "' must have signature 'fn (*" ++ @typeName(field_type) ++ ") void'";
    if (function_info != .@"fn") @compileError(expected_message);

    const function = function_info.@"fn";
    if (function.is_generic or function.is_var_args or function.params.len != 1 or
        function.params[0].type != *field_type or function.return_type != void)
    {
        @compileError(expected_message);
    }
}

fn hasDecl(comptime value_type: type, comptime name: []const u8) bool {
    return switch (@typeInfo(value_type)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(value_type, name),
        else => false,
    };
}
