const std = @import("std");

export fn blank() void {
    // This function is intentionally left blank.
}

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn add_float(a: f64, b: f64) f64 {
    return a + b;
}

export fn add_ptr(a_ptr: *i32, b: i32) void {
    a_ptr.* += b;
}

export fn add_ptr_ptr(a_ptr_ptr: **i32, b: i32) void {
    a_ptr_ptr.*.* += b;
}

export fn fire_callback(callback: *const fn (i32) callconv(.c) i8) bool {
    return callback(123) == -1;
}

fn the_callback(a: i32) callconv(.c) i32 {
    return a + 2555;
}

export fn double_call(callback: *const fn (*const fn (i32) callconv(.c) i32) callconv(.c) i8) bool {
    return callback(the_callback) == 1;
}

export fn check_string(string: [*c]const u8) bool {
    return std.mem.eql(u8, std.mem.span(string), "hello");
}

export fn check_nullptr(ptr: [*c]u8) bool {
    return ptr == null;
}

const Foo = extern struct {
    x: i32,
    y: i32,
};

export fn check_struct(foo: Foo) bool {
    return foo.x == 1 and foo.y == 2;
}

const Foo2 = extern struct {
    x: f64,
    y: f64,
};

export fn check_struct2(foo: Foo2) bool {
    return foo.x == 1.1 and foo.y == 2.2;
}

const Foo3 = extern struct {
    x: f64,
};

export fn check_struct3(foo: Foo3) bool {
    return foo.x == 1.1;
}

const Vec2_32 = extern struct {
    x: f32,
    y: f32,
};

export fn check_vec2_32(foo: Vec2_32) bool {
    return foo.x == 1.23 and foo.y == 2.34;
}

const Vec3_32 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

export fn check_vec3_32(foo: Vec3_32) bool {
    return foo.x == 1.23 and foo.y == 2.34 and foo.z == 3.45;
}

export fn new_vec2_32(x: f32, y: f32) Vec2_32 {
    return .{
        .x = x,
        .y = y,
    };
}

export fn new_vec3_32(x: f32, y: f32, z: f32) Vec3_32 {
    return .{
        .x = x,
        .y = y,
        .z = z,
    };
}

export fn new_i32() *i32 {
    const ptr = std.heap.page_allocator.create(i32) catch @panic("allocation failed");
    ptr.* = 123;
    return ptr;
}
export fn free_i32(ptr: *i32) void {
    std.heap.page_allocator.destroy(ptr);
}

test add {
    const result = add(1, 2);
    try std.testing.expect(result == 3);
}
