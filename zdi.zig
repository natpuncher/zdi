const std = @import("std");

pub fn init(
    allocator: std.mem.Allocator,
    comptime container_type: type,
    config: anytype,
) !*container_type {
    @setEvalBranchQuota(10_000);
    validateContainerType(container_type);
    validateConfig(container_type, config);

    const fields = @typeInfo(container_type).@"struct".fields;
    validateContainerFields(fields);
    const init_order = comptime initializationOrder(container_type);

    const container = try allocator.create(container_type);
    errdefer allocator.destroy(container);

    var initialized_count: usize = 0;
    errdefer internalDeinit(container, init_order, initialized_count);

    inline for (init_order, 0..) |field_index, init_index| {
        const field = fields[field_index];
        if (field.type == std.mem.Allocator) {
            @compileError(
                "zdi container field '" ++ field.name ++
                    "' must not store std.mem.Allocator; request it as an init parameter",
            );
        }

        if (comptime hasDecl(field.type, "init")) {
            validateInit(field.type, field.name);
            const args = createArgs(
                initArgsType(field.type),
                container,
                allocator,
                fields,
                field.name,
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
                container,
                allocator,
                fields,
                config,
            );
        }

        initialized_count = init_index + 1;
        observeInit(config, container, field.name);
    }

    return container;
}

pub fn deinit(allocator: std.mem.Allocator, container: anytype) void {
    const container_type = @TypeOf(container.*);
    const init_order = comptime initializationOrder(container_type);
    internalDeinit(container, init_order, init_order.len);
    allocator.destroy(container);
}

fn createInstance(
    comptime container_field: anytype,
    container: anytype,
    allocator: std.mem.Allocator,
    comptime container_fields: anytype,
    config: anytype,
) container_field.type {
    const component_type = container_field.type;

    if (container_field.default_value_ptr) |default_value_ptr| {
        return readDefault(component_type, default_value_ptr);
    }
    if (component_type == void) return {};
    if (@typeInfo(component_type) != .@"struct") {
        @compileError(
            "zdi field '" ++ container_field.name ++ "' of type '" ++
                @typeName(component_type) ++ "' has no init and no default value",
        );
    }

    var result: component_type = undefined;
    inline for (@typeInfo(component_type).@"struct".fields) |field| {
        if (field.default_value_ptr) |default_value_ptr| {
            @field(result, field.name) = readDefault(field.type, default_value_ptr);
        } else {
            const consumer_name = std.fmt.comptimePrint(
                "{s}.{s}",
                .{ container_field.name, field.name },
            );
            @field(result, field.name) = resolve(
                container,
                field.type,
                allocator,
                container_fields,
                consumer_name,
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
    container: anytype,
    allocator: std.mem.Allocator,
    comptime container_fields: anytype,
    comptime consumer_name: []const u8,
    config: anytype,
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
    container: anytype,
    comptime dependency_type: type,
    allocator: std.mem.Allocator,
    comptime container_fields: anytype,
    comptime consumer_name: []const u8,
    config: anytype,
) dependency_type {
    if (dependency_type == std.mem.Allocator) {
        return allocator;
    }

    if (comptime @hasField(@TypeOf(config), "externals")) {
        const externals = config.externals;
        const external_fields = @typeInfo(@TypeOf(externals)).@"struct".fields;
        comptime var external_match: ?usize = null;

        inline for (external_fields, 0..) |field, field_index| {
            if (field.type == dependency_type) {
                if (external_match != null) {
                    @compileError(
                        "zdi external dependency '" ++ @typeName(dependency_type) ++
                            "' for field '" ++ consumer_name ++
                            "' is ambiguous",
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
        comptime var match_index: ?usize = null;

        inline for (container_fields, 0..) |field, field_index| {
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
            "' for field '" ++ consumer_name ++ "'",
    );
}

fn initializationOrder(
    comptime container_type: type,
) [@typeInfo(container_type).@"struct".fields.len]usize {
    const fields = @typeInfo(container_type).@"struct".fields;
    var order: [fields.len]usize = undefined;
    var initialized: [fields.len]bool = .{false} ** fields.len;

    for (0..fields.len) |init_index| {
        var selected: ?usize = null;
        for (fields, 0..) |field, field_index| {
            if (!initialized[field_index] and dependenciesReady(field, fields, initialized)) {
                selected = field_index;
                break;
            }
        }

        const field_index = selected orelse dependencyCycle(fields, initialized);
        order[init_index] = field_index;
        initialized[field_index] = true;
    }

    return order;
}

fn dependenciesReady(comptime component: anytype, comptime fields: anytype, initialized: anytype) bool {
    if (component.default_value_ptr != null or component.type == void) return true;

    if (hasDecl(component.type, "init")) {
        validateInit(component.type, component.name);
        const function = @typeInfo(@TypeOf(@field(component.type, "init"))).@"fn";
        for (function.params) |parameter| {
            const dependency_type = parameter.type orelse return false;
            if (containerDependencyIndex(fields, dependency_type)) |dependency_index| {
                if (!initialized[dependency_index]) return false;
            }
        }
        return true;
    }

    const component_info = @typeInfo(component.type);
    if (component_info != .@"struct") return true;
    for (component_info.@"struct".fields) |field| {
        if (field.default_value_ptr != null) continue;
        if (containerDependencyIndex(fields, field.type)) |dependency_index| {
            if (!initialized[dependency_index]) return false;
        }
    }
    return true;
}

fn containerDependencyIndex(comptime fields: anytype, comptime dependency_type: type) ?usize {
    if (dependency_type == std.mem.Allocator) return null;

    const dependency_info = @typeInfo(dependency_type);
    if (dependency_info != .pointer or dependency_info.pointer.size != .one) return null;

    for (fields, 0..) |field, field_index| {
        if (field.type == dependency_info.pointer.child) return field_index;
    }
    return null;
}

fn dependencyCycle(comptime fields: anytype, initialized: anytype) noreturn {
    comptime var message: []const u8 = "zdi dependency cycle between fields";
    comptime var first = true;
    for (fields, 0..) |field, field_index| {
        if (!initialized[field_index]) {
            message = message ++ if (first) " '" else ", '";
            message = message ++ field.name ++ "'";
            first = false;
        }
    }
    @compileError(message);
}

fn observeInit(config: anytype, container: anytype, comptime field_name: []const u8) void {
    if (comptime @hasField(@TypeOf(config), "observer")) {
        @call(.auto, config.observer, .{ container, field_name });
    }
}

fn internalDeinit(container: anytype, comptime init_order: anytype, initialized_count: usize) void {
    const fields = @typeInfo(@TypeOf(container.*)).@"struct".fields;

    inline for (init_order, 0..) |_, reverse_offset| {
        const init_index = init_order.len - 1 - reverse_offset;
        const field_index = init_order[init_index];
        const field = fields[field_index];

        if (initialized_count > init_index and comptime hasDecl(field.type, "deinit")) {
            @call(.auto, @field(field.type, "deinit"), .{&@field(container, field.name)});
        }
    }
}

fn validateContainerType(comptime container_type: type) void {
    if (@typeInfo(container_type) != .@"struct") {
        @compileError(
            "zdi container type must be a struct, found '" ++
                @typeName(container_type) ++ "'",
        );
    }
}

fn validateConfig(comptime container_type: type, config: anytype) void {
    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct") {
        @compileError("zdi config must be a struct");
    }

    inline for (config_info.@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "externals") and
            !std.mem.eql(u8, field.name, "observer"))
        {
            @compileError("zdi config field '" ++ field.name ++ "' is not supported");
        }
    }

    if (comptime @hasField(@TypeOf(config), "externals")) {
        validateExternals(@TypeOf(config.externals));
    }
    if (comptime @hasField(@TypeOf(config), "observer")) {
        validateObserver(container_type, @TypeOf(config.observer));
    }
}

fn validateExternals(comptime externals_type: type) void {
    const externals_info = @typeInfo(externals_type);
    if (externals_info != .@"struct") {
        @compileError("zdi config externals must be a tuple or struct");
    }

    const fields = externals_info.@"struct".fields;
    inline for (fields, 0..) |field, field_index| {
        inline for (fields[field_index + 1 ..]) |other| {
            if (field.type == other.type) {
                @compileError(
                    "zdi external type '" ++ @typeName(field.type) ++ "' is duplicated",
                );
            }
        }
    }
}

fn validateObserver(comptime container_type: type, comptime observer_type: type) void {
    const observer_info = @typeInfo(observer_type);
    const expected_message = "zdi observer must be a function with signature 'fn (*" ++
        @typeName(container_type) ++ ", []const u8) void'";

    if (observer_info != .@"fn") {
        @compileError(expected_message);
    }

    const function = observer_info.@"fn";
    if (function.is_var_args or
        function.params.len != 2 or
        function.params[0].type != *container_type or
        function.params[1].type != []const u8 or
        function.return_type != void)
    {
        @compileError(expected_message);
    }
}

fn validateContainerFields(comptime fields: anytype) void {
    inline for (fields, 0..) |field, field_index| {
        if (comptime hasDecl(field.type, "deinit")) {
            validateDeinit(field.type);
        }

        if (comptime !canHaveDecls(field.type)) continue;
        inline for (fields[field_index + 1 ..]) |other| {
            if (field.type == other.type) {
                @compileError(
                    "zdi component type '" ++ @typeName(field.type) ++ "' is duplicated",
                );
            }
        }
    }
}

fn validateInit(comptime field_type: type, comptime field_name: []const u8) void {
    const function = @typeInfo(@TypeOf(@field(field_type, "init"))).@"fn";
    if (function.is_generic or function.is_var_args) {
        @compileError(
            "zdi init for field '" ++ field_name ++ "' cannot be generic or variadic",
        );
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

    if (function_info != .@"fn") {
        @compileError(expected_message);
    }

    const function = function_info.@"fn";
    if (function.is_generic or
        function.is_var_args or
        function.params.len != 1 or
        function.params[0].type != *field_type or
        function.return_type != void)
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

fn canHaveDecls(comptime value_type: type) bool {
    return switch (@typeInfo(value_type)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}
