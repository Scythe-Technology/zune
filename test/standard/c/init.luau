--!strict
local c = zune.c;
local mem = zune.mem;
local testing = zune.testing;
local platform = zune.platform;

local test = testing.test;
local expect = testing.expect;
local describe = testing.describe;

local function warn(message: string)
    print("\27[33m" .. message .. "\27[0m");
end

if (not c) then
    warn("Skipping 'FFI' tests (Not Supported)");
    return;
end

expect(c).toBe(
    expect.similar({
        dlopen = expect.type("function"),
        struct = expect.type("function"),
        closure = expect.type("function"),
        fn = expect.type("function"),
        ptr = expect.type("function"),
        ptrFromAddress = expect.type("function"),
        getLuaState = expect.type("function"),
        alloc = expect.type("function"),
        create = expect.type("function"),
        free = expect.type("function"),
        dupe = expect.type("function"),
        tagName = expect.type("function"),
        prefix = expect.type("string"),
        suffix = expect.type("string"),
        null = expect.type("userdata"),
        types = expect.similar({
            void = expect.type("userdata"),
            i8 = expect.type("userdata"),
            u8 = expect.type("userdata"),
            i16 = expect.type("userdata"),
            u16 = expect.type("userdata"),
            i32 = expect.type("userdata"),
            u32 = expect.type("userdata"),
            i64 = expect.type("userdata"),
            u64 = expect.type("userdata"),
            float = expect.type("userdata"),
            double = expect.type("userdata"),
            pointer = expect.type("userdata"),
            vector2_32 = expect.type("userdata"),
            vector3_32 = expect.type("userdata"),
        }),
        compile = expect.type("function"),
    })
)

if (platform.os == "windows") then
    expect(c.prefix).toBe("");
    expect(c.suffix).toBe("dll");
elseif (platform.os == "linux") then
    expect(c.prefix).toBe("lib");
    expect(c.suffix).toBe("so");
elseif (platform.os == "macos") then
    expect(c.prefix).toBe("lib");
    expect(c.suffix).toBe("dylib");
elseif (platform.os == "freebsd") then
    expect(c.prefix).toBe("lib");
    expect(c.suffix).toBe("so");
else
    error("Unsupported OS: " .. platform.os);
end

local static_suffix = c.suffix;

local function testBufferOfValue(size: number, writer: (b: buffer, o: number, v: number) -> (), value: number): buffer
    local buf = buffer.create(size);
    writer(buf, 0, value);
    return buf;
end

describe("C", function()
    describe("dlopen", function()
        test("Sample Library (No Decls)", function()
            local lib = c.dlopen(`./zig-out/lib/{c.prefix}sample.{static_suffix}`, {});
            expect(lib).toBe(expect.type("userdata"));
        end);
        test("Fail", function()
            expect(function()
                c.dlopen(`./zig-out/lib/{c.prefix}invalid.{static_suffix}`, {});
            end).toThrow("FileNotFound");
        end);
    end)

    describe("Contextual", function()
        test("Span From Pointer", function()
            local src = c.dupe(buffer.fromstring("terminated string\0")):release();

            local ptr = c.ptr(src):release();
            local unknown = ptr:readptr():release();

            local buf = unknown:span(0);

            expect(buffer.len(buf)).toBe(mem.len(src));
            expect(buffer.tostring(buf)).toBe("terminated string\0");
        end)

        test("Read Pointer", function()
            local src = buffer.create(c.types.i32:size());
            buffer.writei32(src, 0, 42);

            local block = c.dupe(src);
            block:release();

            local dest = buffer.create(c.types.i32:size());
            mem.copy(dest, 0, block, 0, c.types.i32:size());

            expect(buffer.readi32(dest, 0)).toBe(42);
        end)

        test("Write Into Pointer", function()
            local src = buffer.create(c.types.i32:size());
            buffer.writei32(src, 0, 42);

            local ptr = c.alloc(c.types.i32:size());
            ptr:release();

            mem.copy(ptr, 0, src, 0, c.types.i32:size());

            expect(ptr:readi32()).toBe(42);
        end)

        test("Read Casting From Pointer", function()
            local src = buffer.create(c.types.i32:size());
            buffer.writei32(src, 0, 42);

            local ptr = c.dupe(src);
            ptr:release();

            expect(ptr:readi32()).toBe(42);
        end)

        test("__eql Pointer", function()
            local src = buffer.create(c.types.i32:size());
            buffer.writei32(src, 0, 42);

            local mem = c.dupe(src);
            mem:release();
            local ptr = c.ptr(mem):release():readptr();
            local ptr2 = c.ptr(mem):release():readptr();

            expect(ptr == ptr2).toBe(true);

            expect(mem:readi32()).toBe(42);

            local null_ptr = c.ptrFromAddress(buffer.create(c.types.pointer:size()));

            expect(null_ptr == c.null).toBe(true);
            expect(null_ptr == ptr).toBe(false);
        end)

        test("Size Of", function()
            expect(c.types.i32:size()).toBe(4);
        end)

        test("Align Of", function()
            expect(c.types.i32:alignment()).toBe(4);
        end)

        test("Alloc", function()
            local block = c.alloc(24);
            expect(block).toBe(expect.type("userdata"));
            expect(mem.len(block)).toBe(24);
            c.free(block);
        end)

        test("Create", function()
            local block = c.create(c.types.i32);
            expect(block).toBe(expect.type("userdata"));
            expect(mem.len(block)).toBe(4);
            expect(block:size()).toBe(c.types.i32:size());
            expect(block:alignment()).toBe(c.types.i32:alignment());
            c.free(block);
        end)

        test("Alloc GC", function()
            local block = c.alloc(24):release();
            expect(block).toBe(expect.type("userdata"));
            expect(mem.len(block)).toBe(24);
        end)

        test("Alloc Zero", function()
            local mem = c.alloc(24):release();
            for i = 0, 23 do
                expect(mem:readu8(i)).toBe(0);
            end
            expect(function()
                mem:readu8(24);
            end).toThrow("access out of bounds");
        end)

        test("Alloc Offset", function()
            local block = c.alloc(24):release();
            for i = 1, 23 do
                local ptr = block:offset(i);
                expect(ptr == block).toBe(false);
                expect(mem.len(ptr)).toBe(24 - i);
                expect(ptr:readu8()).toBe(0);
            end
        end)

        test("Static Offset", function()
            local address = buffer.create(c.types.pointer:size());
            local base = c.ptrFromAddress(address);
            
            expect(base == c.ptrFromAddress(address)).toBe(true);
            expect(base == c.null).toBe(true);

            for i = 1, 3 do
                local ptr = base:offset(i);
                buffer.writeu8(address, 0, i);
                local located_ptr = c.ptrFromAddress(address);
                expect(ptr == base).toBe(false);
                expect(ptr == located_ptr).toBe(true);
                expect(function()
                    mem.len(ptr)
                end).toThrow("unknown size");
            end
        end);

        describe("Generative C Calls", function()
            test("Lua<i32 add(i32 i32)>", function()
                local add_defintion = {
                    returns = c.types.i32,
                    args = {c.types.i32, c.types.i32},
                };
                local c_add_func = c.closure(add_defintion, function(a: number, b: number)
                    return a + b;
                end):release();

                local addfn = c.fn(add_defintion, c_add_func);

                expect(addfn(1, 2)).toBe(3);
                expect(addfn(2, 3)).toBe(5);
                expect(addfn(-4, 4)).toBe(0);
                
                expect(c.fn(add_defintion, c_add_func)(1, 2)).toBe(3);
                expect(c.fn(add_defintion, c_add_func)(2, 3)).toBe(5);
                expect(c.fn(add_defintion, c_add_func)(-4, 4)).toBe(0);

                do
                    local a = testBufferOfValue(c.types.i32:size(), buffer.writei32, 1);
                    local b = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2);
                    expect(addfn(a, b)).toBe(3);
                    expect(c.fn(add_defintion, c_add_func)(a, b)).toBe(3);
                end
                
                do
                    local a = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2);
                    local b = testBufferOfValue(c.types.i32:size(), buffer.writei32, 3);
                    expect(addfn(a, b)).toBe(5);
                    expect(c.fn(add_defintion, c_add_func)(a, b)).toBe(5);
                end
                
                do
                    local a = testBufferOfValue(c.types.i32:size(), buffer.writei32, -4);
                    local b = testBufferOfValue(c.types.i32:size(), buffer.writei32, 4);
                    expect(addfn(a, b)).toBe(0);
                    expect(c.fn(add_defintion, c_add_func)(a, b)).toBe(0);
                end
                
                c.free(c_add_func); -- free reference to closure in backend (not necessary in real world case).
            end)

            test("Lua<f64 add(f64 f64)>", function()
                local add_defintion = {
                    returns = c.types.double,
                    args = {c.types.double, c.types.double},
                };
                local c_add_func = c.closure(add_defintion, function(a: number, b: number)
                    return a + b;
                end):release();

                local addfn = c.fn(add_defintion, c_add_func);

                expect(addfn(1.123, 2)).toBe(3.123);
                expect(addfn(2.25, 3.25)).toBe(5.5);
                expect(addfn(-4.25, 4.25)).toBe(0);

                expect(c.fn(add_defintion, c_add_func)(1.123, 2)).toBe(3.123);
                expect(c.fn(add_defintion, c_add_func)(2.25, 3.25)).toBe(5.5);
                expect(c.fn(add_defintion, c_add_func)(-4.25, 4.25)).toBe(0);
                
                do
                    local a = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.123);
                    local b = testBufferOfValue(c.types.double:size(), buffer.writef64, 2);
                    expect(addfn(a, b)).toBe(3.123);
                    expect(c.fn(add_defintion, c_add_func)(a, b)).toBe(3.123);
                end

                do
                    local a = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.25);
                    local b = testBufferOfValue(c.types.double:size(), buffer.writef64, 3.25);
                    expect(addfn(a, b)).toBe(5.5);
                    expect(c.fn(add_defintion, c_add_func)(a, b)).toBe(5.5);
                end

                do
                    local a = testBufferOfValue(c.types.double:size(), buffer.writef64, -4.25);
                    local b = testBufferOfValue(c.types.double:size(), buffer.writef64, 4.25);
                    expect(addfn(a, b)).toBe(0);
                    expect(c.fn(add_defintion, c_add_func)(a, b)).toBe(0);
                end

                c.free(c_add_func); -- free reference to closure in backend (not necessary in real world case).
            end)
        end)
    end)

    describe("struct", function()
        test("Vec Struct", function()
            local Vec2_struct = c.struct({
                { x = c.types.float },
                { y = c.types.float },
            });
            expect(Vec2_struct:size()).toBe(c.types.vector2_32:size());
            expect(Vec2_struct:alignment()).toBe(c.types.vector2_32:alignment());
            expect(Vec2_struct:offset("x")).toBe(c.types.vector2_32:offset(0));
            expect(Vec2_struct:offset("y")).toBe(c.types.vector2_32:offset(1));

            local Vec3_struct = c.struct({
                { x = c.types.float },
                { y = c.types.float },
                { z = c.types.float },
            });
            expect(Vec3_struct:size()).toBe(c.types.vector3_32:size());
            expect(Vec3_struct:alignment()).toBe(c.types.vector3_32:alignment());
            expect(Vec3_struct:offset("x")).toBe(c.types.vector3_32:offset(0));
            expect(Vec3_struct:offset("y")).toBe(c.types.vector3_32:offset(1));
            expect(Vec3_struct:offset("z")).toBe(c.types.vector3_32:offset(2));

            expect(function()
                c.types.vector3_32:offset(3)
            end).toThrow("index out of bounds");

            do
                local buf = Vec2_struct:new {
                    x = 1.0,
                    y = 2.0,
                };
                local vec = vector.create(1.0, 2.0);

                expect(buffer.len(buf)).toBe(Vec2_struct:size());
    
                expect(buffer.readf32(buf, Vec2_struct:offset("x"))).toBe(vec.x);
                expect(buffer.readf32(buf, Vec2_struct:offset("y"))).toBe(vec.y);
            end

            do
                local buf = Vec3_struct:new {
                    x = 1.0,
                    y = 2.0,
                    z = 3.0,
                };
                local vec = vector.create(1.0, 2.0, 3.0);

                expect(buffer.len(buf)).toBe(Vec3_struct:size());
    
                expect(buffer.readf32(buf, Vec3_struct:offset("x"))).toBe(vec.x);
                expect(buffer.readf32(buf, Vec3_struct:offset("y"))).toBe(vec.y);
                expect(buffer.readf32(buf, Vec3_struct:offset("z"))).toBe(vec.z);
            end
        end)

        test("Array", function()
            local i32_Array_4 = c.types.i32:array(4);
            expect(i32_Array_4:size()).toBe(c.types.i32:size() * 4);
            expect(i32_Array_4:alignment()).toBe(c.types.i32:alignment());
            expect(i32_Array_4:offset(0)).toBe(0);
            expect(i32_Array_4:offset(1)).toBe(c.types.i32:size());
            expect(i32_Array_4:offset(2)).toBe(c.types.i32:size() * 2);
            expect(i32_Array_4:offset(3)).toBe(c.types.i32:size() * 3);
            expect(function()
                i32_Array_4:offset(4)
            end).toThrow("index out of bounds");

            do
                local buf = i32_Array_4:new {1, 2, 3, 4};
                expect(buffer.len(buf)).toBe(i32_Array_4:size());
                expect(buffer.readi32(buf, i32_Array_4:offset(0))).toBe(1);
                expect(buffer.readi32(buf, i32_Array_4:offset(1))).toBe(2);
                expect(buffer.readi32(buf, i32_Array_4:offset(2))).toBe(3);
                expect(buffer.readi32(buf, i32_Array_4:offset(3))).toBe(4);
            end
            
            local Foo_struct = c.struct({
                { x = c.types.i32 },
                { y = c.types.i32 },
            });

            local Foo_struct_Array = Foo_struct:array(4);
            expect(Foo_struct_Array:size()).toBe(Foo_struct:size() * 4);
            expect(Foo_struct_Array:alignment()).toBe(Foo_struct:alignment());
            expect(Foo_struct_Array:offset(0)).toBe(0);
            expect(Foo_struct_Array:offset(1)).toBe(Foo_struct:size());
            expect(Foo_struct_Array:offset(2)).toBe(Foo_struct:size() * 2);
            expect(Foo_struct_Array:offset(3)).toBe(Foo_struct:size() * 3);

            local Foo_struct2_Array = c.struct({
                { x = c.types.i32 },
                { buf = i32_Array_4 },
            });

            expect(Foo_struct2_Array:size()).toBe(c.types.i32:size() + i32_Array_4:size());
            expect(Foo_struct2_Array:alignment()).toBe(i32_Array_4:alignment());
        end)

        test("Foo Structure", function()
            local Foo_struct = c.struct({
                { x = c.types.i32 },
                { y = c.types.i32 },
            });

            expect(Foo_struct:size()).toBe(8);
            expect(Foo_struct:alignment()).toBe(4);
            expect(Foo_struct:offset("x")).toBe(0);
            expect(Foo_struct:offset("y")).toBe(4);

            do
                local buf = Foo_struct:new {
                    x = 1,
                    y = 2,
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(1);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(2);
            end

            do
                local buf = Foo_struct:new {
                    x = 2_147_483_647,
                    y = -2_147_483_648,
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(2_147_483_647);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(-2_147_483_648);
            end

            do
                local buf = Foo_struct:new {
                    x = testBufferOfValue(c.types.i32:size(), buffer.writei32, 1),
                    y = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(1);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(2);
            end

            do
                local buf = Foo_struct:new {
                    x = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2_147_483_647),
                    y = testBufferOfValue(c.types.i32:size(), buffer.writei32, -2_147_483_648),
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(2_147_483_647);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(-2_147_483_648);
            end
        end)

        test("Float Structure", function()
            local Float_struct = c.struct({
                { x = c.types.float },
                -- [...] padded by 4 bytes
                { y = c.types.double },
            });

            expect(Float_struct:size()).toBe(16);
            expect(Float_struct:alignment()).toBe(8);
            expect(Float_struct:offset("x")).toBe(0);
            expect(Float_struct:offset("y")).toBe(8);

            do
                local buf = Float_struct:new {
                    x = 3.4028234663852886e38,
                    y = 1.7976931348623158e308,
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(1.7976931348623158e308);
            end

            do
                local buf = Float_struct:new {
                    x = -3.4028234663852886e38,
                    y = -1.7976931348623158e308,
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(-3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(-1.7976931348623158e308);
            end

            do
                local buf = Float_struct:new {
                    x = testBufferOfValue(c.types.float:size(), buffer.writef32, 3.4028234663852886e38),
                    y = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.7976931348623158e308),
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(1.7976931348623158e308);
            end

            do
                local buf = Float_struct:new {
                    x = testBufferOfValue(c.types.float:size(), buffer.writef32, -3.4028234663852886e38),
                    y = testBufferOfValue(c.types.double:size(), buffer.writef64, -1.7976931348623158e308),
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(-3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(-1.7976931348623158e308);
            end
        end)

        test("Deep Structure", function()
            local a_struct = c.struct({
                { x = c.types.i32 },
                { y = c.types.i32 },
            });
            local b_struct = c.struct({
                { tag = c.types.i32 },
                { data = a_struct },
            });

            local buf = b_struct:new {
                tag = 1,
                data = a_struct:new {
                    x = 1,
                    y = 2,
                },
            }
            
            expect(buffer.len(buf)).toBe(b_struct:size());
            expect(buffer.readi32(buf, b_struct:offset("tag"))).toBe(1);
            expect(buffer.readi32(buf, b_struct:offset("data") + a_struct:offset("x"))).toBe(1);
            expect(buffer.readi32(buf, b_struct:offset("data") + a_struct:offset("y"))).toBe(2);
        end)

        test("Invalid Structure", function()
            expect(function()
                c.struct({
                    { x = c.types.i32 },
                    { y = c.types.i32 },
                    { [3] = c.types.i32 } :: any,
                });
            end).toThrow("struct field name must be a string (got number)");
            expect(function()
                c.struct({
                    { x = c.types.i32 },
                    { y = c.types.i32 },
                    { z = c.types.i32, b = c.types.i32 },
                });
            end).toThrow("struct field contains more than one field type");
        end)
    end)

    describe("Sample Library", function()
        local foo_struct = c.struct({
            { x = c.types.i32 },
            { y = c.types.i32 },
        });

        local foo2_struct = c.struct({
            { x = c.types.double },
            { y = c.types.double },
        });

        local foo3_struct = c.struct({
            { x = c.types.double },
        });

        local foo2e_struct = c.struct({
            { second = foo2_struct },
        });

        local foo2ec_struct = c.struct({
            { first = foo2e_struct },
        });

        local vec2_32_struct = c.struct({
            { x = c.types.float },
            { y = c.types.float },
        });

        local vec3_32_struct = c.struct({
            { x = c.types.float },
            { y = c.types.float },
            { z = c.types.float },
        });

        local vec2e_32_struct = c.struct({
            { second = c.types.vector2_32 },
        });

        local vec3e_32_struct = c.struct({
            { second = c.types.vector3_32 },
        });

        local small_field_struct = c.struct({
            { first = c.types.u32 },
            { second = c.types.pointer },
        });

        local blank_defintion = {
            returns = c.types.void,
            args = {},
        };
        local add_defintion = {
            returns = c.types.i32,
            args = {c.types.i32, c.types.i32},
        };
        local add_float_defintion = {
            returns = c.types.double,
            args = {c.types.double, c.types.double},
        };
        local add_ptr_defintion: FFIFunctionDefintion = {
            returns = c.types.void,
            args = {c.types.pointer, c.types.i32},
        };
        local add_ptr_ptr_defintion: FFIFunctionDefintion = {
            returns = c.types.void,
            args = {c.types.pointer, c.types.i32},
        };
        local fire_callback_defintion = {
            returns = c.types.u8,
            args = {c.types.pointer},
        };
        local double_call_defintion = {
            returns = c.types.u8,
            args = {c.types.pointer},
        };
        local check_string_defintion = {
            returns = c.types.u8,
            args = {c.types.pointer},
        };
        local check_struct_defintion = {
            returns = c.types.u8,
            args = {foo_struct},
        };
        local check_struct2_defintion = {
            returns = c.types.u8,
            args = {foo2_struct},
        };
        local check_struct2ec_defintion = {
            returns = c.types.u8,
            args = {foo2ec_struct},
        };
        local check_struct3_defintion = {
            returns = c.types.u8,
            args = {foo3_struct},
        };
        local check_vec2_32_defintion = {
            returns = c.types.u8,
            args = {c.types.vector2_32},
        };
        local check_vec2e_32_defintion = {
            returns = c.types.u8,
            args = {vec2e_32_struct},
        };
        local check_vec3_32_defintion = {
            returns = c.types.u8,
            args = {c.types.vector3_32},
        };
        local check_vec3e_32_defintion = {
            returns = c.types.u8,
            args = {vec3e_32_struct},
        };
        local new_vec2_32_defintion = {
            returns = c.types.vector2_32,
            args = {c.types.float, c.types.float},
        };
        local new_vec3_32_defintion = {
            returns = c.types.vector3_32,
            args = {c.types.float, c.types.float, c.types.float},
        };
        local small_field_defintion = {
            returns = small_field_struct,
            args = {},
        };
        local check_nullptr_defintion = {
            returns = c.types.u8,
            args = {c.types.pointer},
        };
        local new_i32_defintion = {
            returns = c.types.pointer,
            args = {},
        };
        local free_i32_defintion = {
            returns = c.types.void,
            args = {c.types.pointer},
        };
        local lib = c.dlopen(`./zig-out/lib/{c.prefix}sample.{static_suffix}`, {
            blank = blank_defintion,
            add = add_defintion,
            add_float = add_float_defintion,
            add_ptr = add_ptr_defintion,
            add_ptr_ptr = add_ptr_ptr_defintion,
            fire_callback = fire_callback_defintion,
            double_call = double_call_defintion,

            check_string = check_string_defintion,
            check_struct = check_struct_defintion,
            check_struct2 = check_struct2_defintion,
            check_struct3 = check_struct3_defintion,
            check_vec2_32 = check_vec2_32_defintion,
            check_vec3_32 = check_vec3_32_defintion,
            check_nullptr = check_nullptr_defintion,

            new_vec2_32 = new_vec2_32_defintion,
            new_vec3_32 = new_vec3_32_defintion,

            get_small_field = small_field_defintion,

            new_i32 = new_i32_defintion,
            free_i32 = free_i32_defintion,
        });
        expect(lib).toBe(expect.type("userdata"));

        test("Symbol<void blank()>", function()
            lib.blank();
        end)

        test("Symbol<?>", function()
            expect(lib:getSymbol("add")).toBe(expect.type("userdata"));
            expect(lib:getSymbol("add")).toBe(lib:getSymbol("add"));
            expect(lib:getSymbol("someUnkownSymbol")).toBeNil();
        end)

        describe("Symbol<i32 add(i32 i32)>", function()
            local a = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2);
            local b = testBufferOfValue(c.types.i32:size(), buffer.writei32, 4);
            test("Library Fn", function()
                expect(lib.add(1, 2)).toBe(3);
                expect(lib.add(a, b)).toBe(6);
            end)
            test("Dynamic Fn", function()
                local add = c.fn(add_defintion, lib:getSymbol("add") or error("Symbol 'add' not found"));
                expect(add(1, 2)).toBe(3);
                expect(add(a, b)).toBe(6);
            end)
        end)

        describe("Symbol<f64 add_float(f64 f64)>", function()
            local a = testBufferOfValue(c.types.double:size(), buffer.writef64, 2);
            local b = testBufferOfValue(c.types.double:size(), buffer.writef64, 4);
            test("Library Fn", function()
                expect(lib.add_float(1, 2)).toBe(3);
                expect(lib.add_float(a, b)).toBe(6);
            end)
            test("Dynamic Fn", function()
                local add_float = c.fn(add_float_defintion, lib:getSymbol("add_float") or error("Symbol 'add_float' not found"));
                expect(add_float(1, 2)).toBe(3);
                expect(add_float(a, b)).toBe(6);
            end)
        end)

        describe("Symbol<void add_ptr(*i32, i32)>", function()
            test("Library Fn", function()
                local out = c.alloc(c.types.i32:size()):release();

                lib.add_ptr(out, 1);
                
                expect(out:readi32()).toBe(1);

                lib.add_ptr(out, 6);

                expect(out:readi32()).toBe(7);

                lib.add_ptr(out, testBufferOfValue(c.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
            test("Dynamic Fn", function()
                local add_ptr = c.fn(add_ptr_defintion, lib:getSymbol("add_ptr") or error("Symbol 'add_ptr' not found"));
                local out = c.alloc(c.types.i32:size()):release();

                add_ptr(out, 1);
                
                expect(out:readi32()).toBe(1);

                add_ptr(out, 6);

                expect(out:readi32()).toBe(7);

                add_ptr(out, testBufferOfValue(c.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
        end)
        describe("Symbol<void add_ptr_ptr(**i32, i32)>", function()
            test("Library Fn", function()
                local out = c.alloc(c.types.i32:size());
                out:release();

                local ptr = c.ptr(out):release();

                lib.add_ptr_ptr(ptr, 1);
                
                expect(out:readi32()).toBe(1);

                lib.add_ptr_ptr(ptr, 6);

                expect(out:readi32()).toBe(7);

                lib.add_ptr_ptr(ptr, testBufferOfValue(c.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
            test("Dynamic Fn", function()
                local add_ptr_ptr = c.fn(add_ptr_ptr_defintion, lib:getSymbol("add_ptr_ptr") or error("Symbol 'add_ptr_ptr' not found"));
                local out = c.alloc(c.types.i32:size());
                out:release();

                local ptr = c.ptr(out):release();

                add_ptr_ptr(ptr, 1);
                
                expect(out:readi32()).toBe(1);

                add_ptr_ptr(ptr, 6);

                expect(out:readi32()).toBe(7);

                add_ptr_ptr(ptr, testBufferOfValue(c.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
        end)

        describe("Symbol<void fire_callback(*void)>", function()
            test("Library Fn", function()
                local counter = 0;
                local c_func = c.closure({
                    returns = c.types.i8,
                    args = {c.types.i32},
                }, function(a)
                    if (a ~= 123) then
                        return 0;
                    end
                    counter += 1;
                    return if (counter == 1) then -1 else 1;
                end):release();

                expect(lib.fire_callback(c_func)).toBe(1);
                expect(lib.fire_callback(c_func)).toBe(0);

                c.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end)
            test("Dynamic Fn", function()
                local counter = 0;
                local c_func = c.closure({
                    returns = c.types.i8,
                    args = {c.types.i32},
                }, function(a)
                    if (a ~= 123) then
                        return 0;
                    end
                    counter += 1;
                    return if (counter == 1) then -1 else 1;
                end):release();

                local fire_callback = c.fn(fire_callback_defintion, lib:getSymbol("fire_callback") or error("Symbol 'fire_callback' not found"));

                expect(fire_callback(c_func)).toBe(1);
                expect(fire_callback(c_func)).toBe(0);

                c.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end);
        end)

        describe("Symbol<char double_call(*void)>", function()
            test("Library Fn", function()
                local counter = 0;
                local c_func = c.closure({
                    returns = c.types.u8,
                    args = {c.types.pointer},
                }, function(callback)
                    counter += 1;
                    local num = c.fn({
                        returns = c.types.i32,
                        args = {c.types.i32},
                    }, callback)(counter);
                    return num == 2556;
                end):release();
                c_func:release();

                expect(lib.double_call(c_func)).toBe(1);
                expect(lib.double_call(c_func)).toBe(0);

                c.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end)
            test("Dynamic Fn", function()
                local counter = 0;
                local c_func = c.closure({
                    returns = c.types.u8,
                    args = {c.types.pointer},
                }, function(callback)
                    counter += 1;
                    local num = c.fn({
                        returns = c.types.i32,
                        args = {c.types.i32},
                    }, callback)(counter);
                    return num == 2556;
                end):release();

                local double_call = c.fn(double_call_defintion, lib:getSymbol("double_call") or error("Symbol 'double_call' not found"));

                expect(double_call(c_func)).toBe(1);
                expect(double_call(c_func)).toBe(0);

                c.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end)
        end)

        describe("Symbol<void check_string(const char*)>", function()
            test("Library Fn", function()
                expect(lib.check_string("hello")).toBe(1);
                expect(lib.check_string("Hello")).toBe(0);

                do
                    local buf = c.dupe(buffer.fromstring("hello\0")):release();
                    expect(lib.check_string(buf)).toBe(1);
                end
                do
                    local buf_2 = c.dupe(buffer.fromstring("Hello\0")):release();
                    expect(lib.check_string(buf_2)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_string = c.fn(check_string_defintion, lib:getSymbol("check_string") or error("Symbol 'check_string' not found"));

                expect(check_string("hello")).toBe(1);
                expect(check_string("Hello")).toBe(0);

                do
                    local buf = c.dupe(buffer.fromstring("hello\0")):release();
                    expect(check_string(buf)).toBe(1);
                end
                do
                    local buf_2 = c.dupe(buffer.fromstring("Hello\0")):release();
                    expect(check_string(buf_2)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_struct(Foo)>", function()
            test("Library Fn", function()
                do
                    local buf = foo_struct:new {
                        x = 1,
                        y = 2,
                    };
    
                    expect(lib.check_struct(buf)).toBe(1);
                end
    
                do
                    local buf = foo_struct:new {
                        x = 2,
                        y = 2,
                    };
        
                    expect(lib.check_struct(buf)).toBe(0);
                end
    
                do
                    local buf = foo_struct:new {
                        x = testBufferOfValue(c.types.i32:size(), buffer.writei32, 1),
                        y = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                    };
    
                    expect(lib.check_struct(buf)).toBe(1);
                end
    
                do
                    local buf = foo_struct:new {
                        x = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                        y = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                    };
        
                    expect(lib.check_struct(buf)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_struct = c.fn(check_struct_defintion, lib:getSymbol("check_struct") or error("Symbol 'check_struct' not found"));

                do
                    local buf = foo_struct:new {
                        x = 1,
                        y = 2,
                    };
    
                    expect(check_struct(buf)).toBe(1);
                end
    
                do
                    local buf = foo_struct:new {
                        x = 2,
                        y = 2,
                    };
        
                    expect(check_struct(buf)).toBe(0);
                end
    
                do
                    local buf = foo_struct:new {
                        x = testBufferOfValue(c.types.i32:size(), buffer.writei32, 1),
                        y = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                    };
    
                    expect(check_struct(buf)).toBe(1);
                end
    
                do
                    local buf = foo_struct:new {
                        x = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                        y = testBufferOfValue(c.types.i32:size(), buffer.writei32, 2),
                    };
        
                    expect(check_struct(buf)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_struct2(Foo2)>", function()
            test("Library Fn", function()
                do
                    local buf = foo2_struct:new {
                        x = 1.1,
                        y = 2.2,
                    };

                    expect(lib.check_struct2(buf)).toBe(1);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = 2.2,
                        y = 2.2,
                    };
        
                    expect(lib.check_struct2(buf)).toBe(0);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.1),
                        y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
    
                    expect(lib.check_struct2(buf)).toBe(1);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                        y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(lib.check_struct2(buf)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_struct2 = c.fn(check_struct2_defintion, lib:getSymbol("check_struct2") or error("Symbol 'check_struct2' not found"));

                do
                    local buf = foo2_struct:new {
                        x = 1.1,
                        y = 2.2,
                    };
    
                    expect(check_struct2(buf)).toBe(1);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = 2.2,
                        y = 2.2,
                    };
        
                    expect(check_struct2(buf)).toBe(0);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.1),
                        y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
    
                    expect(check_struct2(buf)).toBe(1);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                        y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(check_struct2(buf)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_struct2ec(Foo2ec)>", function()
            test("Dynamic Fn", function()
                local check_struct2ec = c.fn(check_struct2ec_defintion, lib:getSymbol("check_struct2") or error("Symbol 'check_struct2ec' not found"));

                do
                    local buf = foo2ec_struct:new {
                        first = foo2e_struct:new {
                            second = foo2_struct:new {
                                x = 1.1,
                                y = 2.2,
                            },
                        }
                    };
    
                    expect(check_struct2ec(buf)).toBe(1);
                end
    
                do
                    local buf = foo2ec_struct:new {
                        first = foo2e_struct:new {
                            second = foo2_struct:new {
                                x = 2.2,
                                y = 2.2,
                            },
                        }
                    };
        
                    expect(check_struct2ec(buf)).toBe(0);
                end
    
                do
                    local buf = foo2ec_struct:new {
                        first = foo2e_struct:new {
                            second = foo2_struct:new {
                                x = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.1),
                                y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                            },
                        }
                    };
    
                    expect(check_struct2ec(buf)).toBe(1);
                end
    
                do
                    local buf = foo2ec_struct:new {
                        first = foo2e_struct:new {
                            second = foo2_struct:new {
                                x = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                                y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                            },
                        }
                    };
        
                    expect(check_struct2ec(buf)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_struct3(Foo3)>", function()
            test("Library Fn", function()
                do
                    local buf = foo3_struct:new {
                        x = 1.1,
                    };
    
                    expect(lib.check_struct3(buf)).toBe(1);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = 2.2,
                    };
        
                    expect(lib.check_struct3(buf)).toBe(0);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.1),
                        y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
    
                    expect(lib.check_struct3(buf)).toBe(1);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                        y = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(lib.check_struct3(buf)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_struct3 = c.fn(check_struct3_defintion, lib:getSymbol("check_struct3") or error("Symbol 'check_struct3' not found"));

                do
                    local buf = foo3_struct:new {
                        x = 1.1,
                    };
    
                    expect(check_struct3(buf)).toBe(1);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = 2.2,
                    };
        
                    expect(check_struct3(buf)).toBe(0);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 1.1),
                    };
    
                    expect(check_struct3(buf)).toBe(1);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = testBufferOfValue(c.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(check_struct3(buf)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_vec2_32(Vec2_32)>", function()
            test("Library Fn", function()
                do
                    local buf = vec2_32_struct:new {
                        x = 1.23,
                        y = 2.34,
                    };
                    local vec = vector.create(1.23, 2.34);
    
                    expect(lib.check_vec2_32(buf)).toBe(1);
                    expect(lib.check_vec2_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec2_32_struct:new {
                        x = 2.34,
                        y = 2.34,
                    };
                    local vec = vector.create(2.34, 2.34);
        
                    expect(lib.check_vec2_32(buf)).toBe(0);
                    expect(lib.check_vec2_32(vec)).toBe(0);
                end
    
                do
                    local buf = vec2_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 1.23),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                    };
                    local vec = buffer.create(c.types.vector2_32:size());
                    buffer.writef32(vec, 0, 1.23);
                    buffer.writef32(vec, 4, 2.34);
    
                    expect(lib.check_vec2_32(buf)).toBe(1);
                    expect(lib.check_vec2_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec2_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 1.23),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.33),
                    };
                    local vec = buffer.create(c.types.vector2_32:size());
                    buffer.writef32(vec, 0, 2.34);
                    buffer.writef32(vec, 4, 2.34);
        
                    expect(lib.check_vec2_32(buf)).toBe(0);
                    expect(lib.check_vec2_32(vec)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_vec2_32 = c.fn(check_vec2_32_defintion, lib:getSymbol("check_vec2_32") or error("Symbol 'check_vec2_32' not found"));

                do
                    local buf = vec2_32_struct:new {
                        x = 1.23,
                        y = 2.34,
                    };
                    local vec = vector.create(1.23, 2.34);
    
                    expect(check_vec2_32(buf)).toBe(1);
                    expect(check_vec2_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec2_32_struct:new {
                        x = 2.2,
                        y = 2.34,
                    };
                    local vec = vector.create(2.34, 2.34);
        
                    expect(check_vec2_32(buf)).toBe(0);
                    expect(check_vec2_32(vec)).toBe(0);
                end
    
                do
                    local buf = vec2_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 1.23),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                    };
                    local vec = buffer.create(c.types.vector2_32:size());
                    buffer.writef32(vec, 0, 1.23);
                    buffer.writef32(vec, 4, 2.34);
    
                    expect(check_vec2_32(buf)).toBe(1);
                    expect(check_vec2_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec2_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                    };
                    local vec = buffer.create(c.types.vector2_32:size());
                    buffer.writef32(vec, 0, 2.34);
                    buffer.writef32(vec, 4, 2.34);
        
                    expect(check_vec2_32(buf)).toBe(0);
                    expect(check_vec2_32(vec)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_vec2e_32(Vec2_32)>", function()
            test("Fn", function()
                local check_vec2e_32 = c.fn(check_vec2e_32_defintion, lib:getSymbol("check_vec2_32") or error("Symbol 'check_vec2_32' not found"));

                do
                    local buf = vec2e_32_struct:new {
                        second = vec2_32_struct:new {
                            x = 1.23,
                            y = 2.34,
                        }
                    };
                    local buf2 = vec2_32_struct:new {
                        x = 1.23,
                        y = 2.34,
                    };
                    local buf_vec = vec2e_32_struct:new {
                        second = vector.create(1.23, 2.34),
                    };

                    expect(function()
                        vec2e_32_struct:new {
                            second = 1.23,
                        };
                    end).toThrow("invalid type for field 'second' (expected vector/buffer, got number)");

                    expect(check_vec2e_32(buf)).toBe(1);
                    expect(check_vec2e_32(buf2)).toBe(1);
                    expect(check_vec2e_32(buf_vec)).toBe(1);
                end
                do
                    local buf = vec2e_32_struct:new {
                        second = vec2_32_struct:new {
                            x = 2.34,
                            y = 2.34,
                        }
                    };
                    local buf2 = vec2_32_struct:new {
                        x = 2.34,
                        y = 2.34,
                    };
                    local buf_vec = vec2e_32_struct:new {
                        second = vector.create(2.34, 2.34),
                    };

                    expect(check_vec2e_32(buf)).toBe(0);
                    expect(check_vec2e_32(buf2)).toBe(0);
                    expect(check_vec2e_32(buf_vec)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_vec3_32(Vec3_32)>", function()
            test("Library Fn", function()
                do
                    local buf = vec3_32_struct:new {
                        x = 1.23,
                        y = 2.34,
                        z = 3.45,
                    };
                    local vec = vector.create(1.23, 2.34, 3.45);
    
                    expect(lib.check_vec3_32(buf)).toBe(1);
                    expect(lib.check_vec3_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec3_32_struct:new {
                        x = 2.34,
                        y = 2.34,
                        z = 3.45
                    };
                    local vec = vector.create(2.34, 2.34, 3.45);
        
                    expect(lib.check_vec3_32(buf)).toBe(0);
                    expect(lib.check_vec3_32(vec)).toBe(0);
                end
    
                do
                    local buf = vec3_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 1.23),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                        z = testBufferOfValue(c.types.float:size(), buffer.writef32, 3.45)
                    };
                    local vec = buffer.create(c.types.vector3_32:size());
                    buffer.writef32(vec, 0, 1.23);
                    buffer.writef32(vec, 4, 2.34);
                    buffer.writef32(vec, 8, 3.45);
    
                    expect(lib.check_vec3_32(buf)).toBe(1);
                    expect(lib.check_vec3_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec3_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 1.23),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.33),
                        z = testBufferOfValue(c.types.float:size(), buffer.writef32, 3.45)
                    };
                    local vec = buffer.create(c.types.vector3_32:size());
                    buffer.writef32(vec, 0, 2.34);
                    buffer.writef32(vec, 4, 2.34);
                    buffer.writef32(vec, 8, 3.45);
        
                    expect(lib.check_vec3_32(buf)).toBe(0);
                    expect(lib.check_vec3_32(vec)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_vec3_32 = c.fn(check_vec3_32_defintion, lib:getSymbol("check_vec3_32") or error("Symbol 'check_vec3_32' not found"));

                do
                    local buf = vec3_32_struct:new {
                        x = 1.23,
                        y = 2.34,
                        z = 3.45,
                    };
                    local vec = vector.create(1.23, 2.34, 3.45);
    
                    expect(check_vec3_32(buf)).toBe(1);
                    expect(check_vec3_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec3_32_struct:new {
                        x = 2.2,
                        y = 2.34,
                        z = 3.45
                    };
                    local vec = vector.create(2.34, 2.34, 3.45);
        
                    expect(check_vec3_32(buf)).toBe(0);
                    expect(check_vec3_32(vec)).toBe(0);
                end
    
                do
                    local buf = vec3_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 1.23),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                        z = testBufferOfValue(c.types.float:size(), buffer.writef32, 3.45)
                    };
                    local vec = buffer.create(c.types.vector3_32:size());
                    buffer.writef32(vec, 0, 1.23);
                    buffer.writef32(vec, 4, 2.34);
                    buffer.writef32(vec, 8, 3.45);
    
                    expect(check_vec3_32(buf)).toBe(1);
                    expect(check_vec3_32(vec)).toBe(1);
                end
    
                do
                    local buf = vec3_32_struct:new {
                        x = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                        y = testBufferOfValue(c.types.float:size(), buffer.writef32, 2.34),
                        z = testBufferOfValue(c.types.float:size(), buffer.writef32, 3.45)
                    };
                    local vec = buffer.create(c.types.vector3_32:size());
                    buffer.writef32(vec, 0, 2.34);
                    buffer.writef32(vec, 4, 2.34);
                    buffer.writef32(vec, 8, 3.45);
        
                    expect(check_vec3_32(buf)).toBe(0);
                    expect(check_vec3_32(vec)).toBe(0);
                end
            end)
        end)
        
        describe("Symbol<small_field get_small_field()>", function()
            test("Library Fn", function()
                local buf = lib.get_small_field();

                expect(buffer.readu32(buf, 0)).toBe(67);
                local ptr = c.ptrFromAddress(zune.mem.slice(buf, 4, 8));
                expect(ptr == c.null).toBe(true);
            end)
            test("Dynamic Fn", function()
                local get_small_field = c.fn(small_field_defintion, lib:getSymbol("get_small_field") or error("Symbol 'check_vec3_32' not found"));

                local buf = get_small_field();

                expect(buffer.readu32(buf, 0)).toBe(67);
                local ptr = c.ptrFromAddress(zune.mem.slice(buf, 4, 8));
                expect(ptr == c.null).toBe(true);
            end)
        end)

        describe("Symbol<void check_vec3e_32(Vec3_32)>", function()
            test("Fn", function()
                local check_vec3e_32 = c.fn(check_vec3e_32_defintion, lib:getSymbol("check_vec3_32") or error("Symbol 'check_vec3_32' not found"));
    
                do
                    local buf = vec3e_32_struct:new {
                        second = vec3_32_struct:new {
                            x = 1.23,
                            y = 2.34,
                            z = 3.45,
                        }
                    };
                    local buf2 = vec3_32_struct:new {
                        x = 1.23,
                        y = 2.34,
                        z = 3.45,
                    };
                    local buf_vec = vec3e_32_struct:new {
                        second = vector.create(1.23, 2.34, 3.45),
                    };
    
                    expect(check_vec3e_32(buf)).toBe(1);
                    expect(check_vec3e_32(buf2)).toBe(1);
                    expect(check_vec3e_32(buf_vec)).toBe(1);
                end
                do
                    local buf = vec3e_32_struct:new {
                        second = vec3_32_struct:new {
                            x = 2.34,
                            y = 2.34,
                            z = 3.45
                        }
                    };
                    local buf2 = vec3_32_struct:new {
                        x = 2.34,
                        y = 2.34,
                        z = 3.45
                    };
                    local buf_vec = vec3e_32_struct:new {
                        second = vector.create(2.34, 2.34, 3.45),
                    };
    
                    expect(check_vec3e_32(buf)).toBe(0);
                    expect(check_vec3e_32(buf2)).toBe(0);
                    expect(check_vec3e_32(buf_vec)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_nullptr(*void)>", function()
            test("Library Fn", function()
                expect(lib.check_nullptr(nil)).toBe(1);
            
                local null_ptr = c.ptrFromAddress(buffer.create(c.types.pointer:size()));
                expect(lib.check_nullptr(null_ptr)).toBe(1);

                local dummy_value = c.dupe(buffer.create(0));
                dummy_value:release();
                local ptr = c.ptr(dummy_value):release();
                expect(lib.check_nullptr(ptr)).toBe(0);
                expect(lib.check_nullptr("")).toBe(0);
            end)
            test("Dynamic Fn", function()
                local check_nullptr = c.fn(check_nullptr_defintion, lib:getSymbol("check_nullptr") or error("Symbol 'check_nullptr' not found"));

                expect(check_nullptr(nil)).toBe(1);
            
                local null_ptr = c.ptrFromAddress(buffer.create(c.types.pointer:size()));
                expect(check_nullptr(null_ptr)).toBe(1);

                local dummy_value = c.dupe(buffer.create(0));
                dummy_value:release();
                local ptr = c.ptr(dummy_value):release();
                expect(check_nullptr(ptr)).toBe(0);
                expect(check_nullptr("")).toBe(0);
            end)
        end)

        describe("Symbol<void new_vec2_32(f32, f32)>", function()
            test("Library Fn", function()
                do
                    local vec = lib.new_vec2_32(1.0, 2.0);
                    expect(vec).toBe(expect.type("vector"));
    
                    expect(vec.x).toBe(1.0);
                    expect(vec.y).toBe(2.0);
                    expect(vec.z).toBe(0.0);
                end
            end)
            test("Dynamic Fn", function()
                local new_vec2_32 = c.fn(new_vec2_32_defintion, lib:getSymbol("new_vec2_32") or error("Symbol 'new_vec2_32' not found"));

                do
                    local vec = new_vec2_32(1.0, 2.0);
                    expect(vec).toBe(expect.type("vector"));
    
                    expect(vec.x).toBe(1.0);
                    expect(vec.y).toBe(2.0);
                    expect(vec.z).toBe(0.0);
                end
            end)
        end)

        describe("Symbol<void new_vec3_32(f32, f32, f32)>", function()
            test("Library Fn", function()
                do
                    local vec = lib.new_vec3_32(1.0, 2.0, 3.0);
                    expect(vec).toBe(expect.type("vector"));
    
                    expect(vec.x).toBe(1.0);
                    expect(vec.y).toBe(2.0);
                    expect(vec.z).toBe(3.0);
                end
            end)
            test("Dynamic Fn", function()
                local new_vec3_32 = c.fn(new_vec3_32_defintion, lib:getSymbol("new_vec3_32") or error("Symbol 'new_vec3_32' not found"));

                do
                    local vec = new_vec3_32(1.0, 2.0, 3.0);
                    expect(vec).toBe(expect.type("vector"));
    
                    expect(vec.x).toBe(1.0);
                    expect(vec.y).toBe(2.0);
                    expect(vec.z).toBe(3.0);
                end
            end)
        end)

        describe("External Memory Management", function()
            describe("Library", function()
                local ptr = nil;
                test("Symbol<*i32 new_i32()>", function()
                    ptr = lib.new_i32();

                    ptr:size(c.types.i32:size());
                    expect(ptr).toBe(expect.type("userdata"));

                    expect(ptr:readi32()).toBe(123);

                    local src = buffer.create(c.types.i32:size());
                    buffer.writei32(src, 0, 42);
                    mem.copy(ptr, 0, src, 0, c.types.i32:size());

                    expect(ptr:readi32()).toBe(42);

                    ptr:writei32(0, 24);

                    expect(ptr:readi32()).toBe(24);
                end)

                test("Symbol<void free_i32(*i32)>", function()
                    assert(ptr, "Pointer is nil");
                    lib.free_i32(ptr);
                end)
            end)
            describe("Dynamic", function()
                local ptr = nil;
                test("Symbol<*i32 new_i32()>", function()
                    ptr = c.fn(new_i32_defintion, lib:getSymbol("new_i32") or error("Symbol 'new_i32' not found"))();
                    ptr:size(c.types.i32:size());
                    expect(ptr).toBe(expect.type("userdata"));

                    expect(ptr:readi32()).toBe(123);

                    local src = buffer.create(c.types.i32:size());
                    buffer.writei32(src, 0, 42);
                    mem.copy(ptr, 0, src, 0, c.types.i32:size());

                    expect(ptr:readi32()).toBe(42);

                    ptr:writei32(0, 24);

                    expect(ptr:readi32()).toBe(24);
                end)

                test("Symbol<void free_i32(*i32)>", function()
                    assert(ptr, "Pointer is nil");
                    c.fn(free_i32_defintion, lib:getSymbol("free_i32") or error("Symbol 'free_i32' not found"))(ptr);
                end)
            end)
        end)

        describe("Internal Memory Management", function()
            test("Block", function()
                local block = c.alloc(24);
                expect(block).toBe(expect.type("userdata"));

                expect(mem.len(block)).toBe(24);

                expect(function()
                    mem.copy(block, 24, buffer.create(1), 0, 1);
                end).toThrow("access out of bounds");

                c.free(block);
            end)

            local block_address = buffer.create(c.types.pointer:size());
            test("Leaky Block, Unknown Transform", function()
                local block = c.alloc(24);
                expect(block).toBe(expect.type("userdata"));

                expect(mem.len(block)).toBe(24);

                expect(function()
                    mem.copy(buffer.create(1), 0, block, 24, 1);
                end).toThrow("access out of bounds");

                expect(function()
                    block:read(24, buffer.create(1), 0, 1);
                end).toThrow("access out of bounds");

                local temp = buffer.create(24);
                buffer.writei32(temp, 0, -42);
                buffer.writei32(temp, 4, 100);
                buffer.writei32(temp, 8, 0);
                buffer.writei32(temp, 12, -10);
                mem.copy(block, 0, temp, 0, 24);

                mem.copy(block_address, 0, c.ptr(block):release(), 0, c.types.pointer:size());

                block:drop();
            end)

            test("Leaky Unknown Block, Free", function()
                local block = c.ptrFromAddress(block_address);
                expect(block == c.null).toBe(false);
                expect(mem.len(block)).toBe(24);

                local out = buffer.create(24);
                mem.copy(out, 0, block, 0, 24);

                expect(buffer.readi32(out, 0)).toBe(-42);
                expect(buffer.readi32(out, 4)).toBe(100);
                expect(buffer.readi32(out, 8)).toBe(0);
                expect(buffer.readi32(out, 12)).toBe(-10);

                expect(function()
                    mem.copy(buffer.create(1), 0, block, 24, 1);
                end).toThrow("access out of bounds");
                expect(function()
                    block:read(24, buffer.create(1), 0, 1);
                end).toThrow("access out of bounds");

                c.free(block);
            end)
        end)

        describe("Tagged Pointers", function()
            local any_ptr = c.types.pointer;
            local ctxA_ptr = c.types.pointer:newTag("ContextA");
            local ctxB_ptr = c.types.pointer:newTag("ContextB");

            expect(c.tagName(any_ptr:tag())).toBe(nil);
            expect(c.tagName(ctxA_ptr:tag())).toBe("ContextA");
            expect(c.tagName(ctxB_ptr:tag())).toBe("ContextB");

            expect(any_ptr:tag()).toBe(0);
            expect(ctxA_ptr:tag()).toBe(1);
            expect(ctxB_ptr:tag()).toBe(2);

            local any_check = c.fn({
                returns = c.types.u8,
                args = {any_ptr},
            }, lib:getSymbol("check_nullptr") or error("Symbol 'check_nullptr' not found"));

            local ctxA_check = c.fn({
                returns = c.types.u8,
                args = {ctxA_ptr},
            }, lib:getSymbol("check_nullptr") or error("Symbol 'check_nullptr' not found"));

            local ctxB_check = c.fn({
                returns = c.types.u8,
                args = {ctxB_ptr},
            }, lib:getSymbol("check_nullptr") or error("Symbol 'check_nullptr' not found"));

            test("Null Pointer", function()
                expect(any_check(nil)).toBe(1);
                expect(ctxA_check(nil)).toBe(1);
                expect(ctxB_check(nil)).toBe(1);
            end)

            test("Pointer tagged", function()
                for i = 1, 10 do
                    expect(c.dupe(buffer.create(0)):release():tag(i):tag()).toBe(i);
                end
            end)

            test("Anonymous Tag", function()
                for id = 20_000, 20_010 do
                    expect(c.tagName(id)).toBe(nil);
                end
            end)

            test("No Conflict", function()
                expect(any_check(c.dupe(buffer.create(0)):release())).toBe(0);
                expect(ctxA_check(c.dupe(buffer.create(0)):release():tag(1))).toBe(0);
                expect(ctxB_check(c.dupe(buffer.create(0)):release():tag(2))).toBe(0);
            end)

            test("Conflict", function()
                expect(function()
                    any_check(c.dupe(buffer.create(0)):release():tag(1));
                end).toThrow("tag mismatch");
                expect(function()
                    any_check(c.dupe(buffer.create(0)):release():tag(2));
                end).toThrow("tag mismatch");
                expect(function()
                    ctxA_check(c.dupe(buffer.create(0)):release():tag(2));
                end).toThrow("tag mismatch");
                expect(function()
                    ctxB_check(c.dupe(buffer.create(0)):release():tag(1));
                end).toThrow("tag mismatch");
                expect(function()
                    ctxA_check(c.dupe(buffer.create(0)):release());
                end).toThrow("tag mismatch");
                expect(function()
                    ctxB_check(c.dupe(buffer.create(0)):release());
                end).toThrow("tag mismatch");
            end)
        end)
    end)

    test("Lua State", function()
        local L = c.getLuaState();
        local L2 = c.getLuaState();
        local GL = c.getLuaState(true);

        expect(L == L2).toBe(true);
        expect(L == GL).toBe(false);
    end)

    describe("C", function()
        describe("Compile", function()
            test("Basic", function()
                local compiled = c.compile([[
                    int hello() {
                        return 50;
                    }
                    int add(int a) {
                        return a + 5;
                    }
                    double add_double(double a) {
                        return a + 2.5;
                    }
                ]]);

                local start = if (platform.cpu.arch == "aarch64" or platform.cpu.arch == "riscv64") then 3 else 0;
                expect(compiled:listSymbols()[start + 1]:find("hello$") ~= nil).toBeTruthy();
                expect(compiled:listSymbols()[start + 2]:find("add$") ~= nil).toBeTruthy();
                expect(compiled:listSymbols()[start + 3]:find("add_double$") ~= nil).toBeTruthy();

                local hellofn = c.fn({ returns = c.types.i32, args = {} }, compiled:getSymbol("hello") or error("Symbol 'hello' not found"));
                local addfn = c.fn({ returns = c.types.i32, args = {c.types.i32} }, compiled:getSymbol("add") or error("Symbol 'add' not found"));
                local add_doublefn = c.fn({ returns = c.types.double, args = {c.types.double} }, compiled:getSymbol("add_double") or error("Symbol 'add_double' not found"));

                expect(hellofn()).toBe(50);
                expect(addfn(25)).toBe(30);
                expect(add_doublefn(62.5)).toBe(65);
            end)
            test("Complex", function()
                local compiled = c.compile((if (platform.os == "windows") then "__declspec(dllimport) " else "extern") .. " void blank();\n\nvoid blank2() { blank(); }", {
                    files = {`./zig-out/lib/{c.prefix}sample.{static_suffix}`},
                });

                local blank2fn = c.fn({ returns = c.types.void, args = {} }, compiled:getSymbol("blank2") or error("Symbol 'blank2' not found"));

                blank2fn();
            end)
            test("Error", function()
                expect(function()
                    c.compile([[
                        double add_double(
                    ]]);
                end).toThrow("error: identifier expected");
                expect(function()
                    c.compile([[
                        double add_double(double a) {
                            return a + 2.5;
                        }
                    ]], { files = {`unknown_nothing`} });
                end).toThrow("tcc: error: file 'unknown_nothing' not found");
            end)
        end)
    end)
end)
