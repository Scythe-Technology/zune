--!strict
local ffi = zune.ffi;
local mem = zune.mem;
local testing = zune.testing;
local platform = zune.platform;

local test = testing.test;
local expect = testing.expect;
local describe = testing.describe;

local function warn(message: string)
    print("\27[33m" .. message .. "\27[0m");
end

if (not ffi) then
    warn("Skipping 'FFI' tests (Not Supported)");
    return;
end

expect(ffi).toBe(
    expect.similar({
        dlopen = expect.type("function"),
        struct = expect.type("function"),
        closure = expect.type("function"),
        fn = expect.type("function"),
        ptr = expect.type("function"),
        ptrFromAddress = expect.type("function"),
        getLuaState = expect.type("function"),
        alloc = expect.type("function"),
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
        }),
        c = expect.similar({
            compile = expect.type("function"),
        }),
    })
)

if (platform.os == "windows") then
    expect(ffi.prefix).toBe("");
    expect(ffi.suffix).toBe("dll");
elseif (platform.os == "linux") then
    expect(ffi.prefix).toBe("lib");
    expect(ffi.suffix).toBe("so");
elseif (platform.os == "macos") then
    expect(ffi.prefix).toBe("lib");
    expect(ffi.suffix).toBe("dylib");
elseif (platform.os == "freebsd") then
    expect(ffi.prefix).toBe("lib");
    expect(ffi.suffix).toBe("so");
else
    error("Unsupported OS: " .. platform.os);
end

local static_suffix = ffi.suffix;

local function testBufferOfValue(size: number, writer: (b: buffer, o: number, v: number) -> (), value: number): buffer
    local buf = buffer.create(size);
    writer(buf, 0, value);
    return buf;
end

describe("FFI", function()
    describe("dlopen", function()
        test("Sample Library (No Decls)", function()
            local lib = ffi.dlopen(`./zig-out/lib/{ffi.prefix}sample.{static_suffix}`, {});
            expect(lib).toBe(expect.type("userdata"));
        end);
        test("Fail", function()
            expect(function()
                ffi.dlopen(`./zig-out/lib/{ffi.prefix}invalid.{static_suffix}`, {});
            end).toThrow("FileNotFound");
        end);
    end)

    describe("Contextual", function()
        test("Span From Pointer", function()
            local src = ffi.dupe(buffer.fromstring("terminated string\0")):release();

            local ptr = ffi.ptr(src):release();
            local unknown = ptr:readptr():release();

            local buf = unknown:span(0);

            expect(buffer.len(buf)).toBe(mem.len(src));
            expect(buffer.tostring(buf)).toBe("terminated string\0");
        end)

        test("Read Pointer", function()
            local src = buffer.create(ffi.types.i32:size());
            buffer.writei32(src, 0, 42);

            local block = ffi.dupe(src);
            block:release();

            local dest = buffer.create(ffi.types.i32:size());
            mem.copy(dest, 0, block, 0, ffi.types.i32:size());

            expect(buffer.readi32(dest, 0)).toBe(42);
        end)

        test("Write Into Pointer", function()
            local src = buffer.create(ffi.types.i32:size());
            buffer.writei32(src, 0, 42);

            local ptr = ffi.alloc(ffi.types.i32:size());
            ptr:release();

            mem.copy(ptr, 0, src, 0, ffi.types.i32:size());

            expect(ptr:readi32()).toBe(42);
        end)

        test("Read Casting From Pointer", function()
            local src = buffer.create(ffi.types.i32:size());
            buffer.writei32(src, 0, 42);

            local ptr = ffi.dupe(src);
            ptr:release();

            expect(ptr:readi32()).toBe(42);
        end)

        test("__eql Pointer", function()
            local src = buffer.create(ffi.types.i32:size());
            buffer.writei32(src, 0, 42);

            local mem = ffi.dupe(src);
            mem:release();
            local ptr = ffi.ptr(mem):release():readptr();
            local ptr2 = ffi.ptr(mem):release():readptr();

            expect(ptr == ptr2).toBe(true);

            expect(mem:readi32()).toBe(42);

            local null_ptr = ffi.ptrFromAddress(buffer.create(ffi.types.pointer:size()));

            expect(null_ptr == ffi.null).toBe(true);
            expect(null_ptr == ptr).toBe(false);
        end)

        test("Size Of", function()
            expect(ffi.types.i32:size()).toBe(4);
        end)

        test("Align Of", function()
            expect(ffi.types.i32:alignment()).toBe(4);
        end)

        test("Alloc", function()
            local block = ffi.alloc(24);
            expect(block).toBe(expect.type("userdata"));
            expect(mem.len(block)).toBe(24);
            ffi.free(block);
        end)

        test("Alloc GC", function()
            local block = ffi.alloc(24):release();
            expect(block).toBe(expect.type("userdata"));
            expect(mem.len(block)).toBe(24);
        end)

        test("Alloc Zero", function()
            local mem = ffi.alloc(24):release();
            for i = 0, 23 do
                expect(mem:readu8(i)).toBe(0);
            end
            expect(function()
                mem:readu8(24);
            end).toThrow("access out of bounds");
        end)

        test("Alloc Offset", function()
            local block = ffi.alloc(24):release();
            for i = 1, 23 do
                local ptr = block:offset(i);
                expect(ptr == block).toBe(false);
                expect(mem.len(ptr)).toBe(24 - i);
                expect(ptr:readu8()).toBe(0);
            end
        end)

        test("Static Offset", function()
            local address = buffer.create(ffi.types.pointer:size());
            local base = ffi.ptrFromAddress(address);
            
            expect(base == ffi.ptrFromAddress(address)).toBe(true);
            expect(base == ffi.null).toBe(true);

            for i = 1, 3 do
                local ptr = base:offset(i);
                buffer.writeu8(address, 0, i);
                local located_ptr = ffi.ptrFromAddress(address);
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
                    returns = ffi.types.i32,
                    args = {ffi.types.i32, ffi.types.i32},
                };
                local c_add_func = ffi.closure(add_defintion, function(a, b)
                    return a + b;
                end):release();

                local addfn = ffi.fn(add_defintion, c_add_func);

                expect(addfn(1, 2)).toBe(3);
                expect(addfn(2, 3)).toBe(5);
                expect(addfn(-4, 4)).toBe(0);
                
                expect(ffi.fn(add_defintion, c_add_func)(1, 2)).toBe(3);
                expect(ffi.fn(add_defintion, c_add_func)(2, 3)).toBe(5);
                expect(ffi.fn(add_defintion, c_add_func)(-4, 4)).toBe(0);

                do
                    local a = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 1);
                    local b = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2);
                    expect(addfn(a, b)).toBe(3);
                    expect(ffi.fn(add_defintion, c_add_func)(a, b)).toBe(3);
                end
                
                do
                    local a = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2);
                    local b = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 3);
                    expect(addfn(a, b)).toBe(5);
                    expect(ffi.fn(add_defintion, c_add_func)(a, b)).toBe(5);
                end
                
                do
                    local a = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, -4);
                    local b = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 4);
                    expect(addfn(a, b)).toBe(0);
                    expect(ffi.fn(add_defintion, c_add_func)(a, b)).toBe(0);
                end
                
                ffi.free(c_add_func); -- free reference to closure in backend (not necessary in real world case).
            end)

            test("Lua<f64 add(f64 f64)>", function()
                local add_defintion = {
                    returns = ffi.types.double,
                    args = {ffi.types.double, ffi.types.double},
                };
                local c_add_func = ffi.closure(add_defintion, function(a, b)
                    return a + b;
                end):release();

                local addfn = ffi.fn(add_defintion, c_add_func);

                expect(addfn(1.123, 2)).toBe(3.123);
                expect(addfn(2.25, 3.25)).toBe(5.5);
                expect(addfn(-4.25, 4.25)).toBe(0);

                expect(ffi.fn(add_defintion, c_add_func)(1.123, 2)).toBe(3.123);
                expect(ffi.fn(add_defintion, c_add_func)(2.25, 3.25)).toBe(5.5);
                expect(ffi.fn(add_defintion, c_add_func)(-4.25, 4.25)).toBe(0);
                
                do
                    local a = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.123);
                    local b = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2);
                    expect(addfn(a, b)).toBe(3.123);
                    expect(ffi.fn(add_defintion, c_add_func)(a, b)).toBe(3.123);
                end

                do
                    local a = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.25);
                    local b = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 3.25);
                    expect(addfn(a, b)).toBe(5.5);
                    expect(ffi.fn(add_defintion, c_add_func)(a, b)).toBe(5.5);
                end

                do
                    local a = testBufferOfValue(ffi.types.double:size(), buffer.writef64, -4.25);
                    local b = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 4.25);
                    expect(addfn(a, b)).toBe(0);
                    expect(ffi.fn(add_defintion, c_add_func)(a, b)).toBe(0);
                end

                ffi.free(c_add_func); -- free reference to closure in backend (not necessary in real world case).
            end)
        end)
    end)

    describe("struct", function()
        test("Foo Structure", function()
            local Foo_struct = ffi.struct({
                { x = ffi.types.i32 },
                { y = ffi.types.i32 },
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
                    x = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 1),
                    y = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(1);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(2);
            end

            do
                local buf = Foo_struct:new {
                    x = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2_147_483_647),
                    y = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, -2_147_483_648),
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(2_147_483_647);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(-2_147_483_648);
            end
        end)

        test("Float Structure", function()
            local Float_struct = ffi.struct({
                { x = ffi.types.float },
                -- [...] padded by 4 bytes
                { y = ffi.types.double },
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
                    x = testBufferOfValue(ffi.types.float:size(), buffer.writef32, 3.4028234663852886e38),
                    y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.7976931348623158e308),
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(1.7976931348623158e308);
            end

            do
                local buf = Float_struct:new {
                    x = testBufferOfValue(ffi.types.float:size(), buffer.writef32, -3.4028234663852886e38),
                    y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, -1.7976931348623158e308),
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(-3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(-1.7976931348623158e308);
            end
        end)

        test("Deep Structure", function()
            local a_struct = ffi.struct({
                { x = ffi.types.i32 },
                { y = ffi.types.i32 },
            });
            local b_struct = ffi.struct({
                { tag = ffi.types.i32 },
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
                ffi.struct({
                    { x = ffi.types.i32 },
                    { y = ffi.types.i32 },
                    { [3] = ffi.types.i32 } :: any,
                });
            end).toThrow("struct field name must be a string (got number)");
            expect(function()
                ffi.struct({
                    { x = ffi.types.i32 },
                    { y = ffi.types.i32 },
                    { z = ffi.types.i32, b = ffi.types.i32 },
                });
            end).toThrow("struct field contains more than one field type");
        end)
    end)

    describe("Sample Library", function()
        local foo_struct = ffi.struct({
            { x = ffi.types.i32 },
            { y = ffi.types.i32 },
        });

        local foo2_struct = ffi.struct({
            { x = ffi.types.double },
            { y = ffi.types.double },
        });

        local foo3_struct = ffi.struct({
            { x = ffi.types.double },
        });

        local foo2e_struct = ffi.struct({
            { second = foo2_struct },
        });

        local foo2ec_struct = ffi.struct({
            { first = foo2e_struct },
        });

        local blank_defintion = {
            returns = ffi.types.void,
            args = {},
        };
        local add_defintion = {
            returns = ffi.types.i32,
            args = {ffi.types.i32, ffi.types.i32},
        };
        local add_float_defintion = {
            returns = ffi.types.double,
            args = {ffi.types.double, ffi.types.double},
        };
        local add_ptr_defintion: FFIFunctionDef = {
            returns = ffi.types.void,
            args = {ffi.types.pointer, ffi.types.i32},
        };
        local add_ptr_ptr_defintion: FFIFunctionDef = {
            returns = ffi.types.void,
            args = {ffi.types.pointer, ffi.types.i32},
        };
        local fire_callback_defintion = {
            returns = ffi.types.u8,
            args = {ffi.types.pointer},
        };
        local double_call_defintion = {
            returns = ffi.types.u8,
            args = {ffi.types.pointer},
        };
        local check_string_defintion = {
            returns = ffi.types.u8,
            args = {ffi.types.pointer},
        };
        local check_struct_defintion = {
            returns = ffi.types.u8,
            args = {foo_struct},
        };
        local check_struct2_defintion = {
            returns = ffi.types.u8,
            args = {foo2_struct},
        };
        local check_struct2ec_defintion = {
            returns = ffi.types.u8,
            args = {foo2ec_struct},
        };
        local check_struct3_defintion = {
            returns = ffi.types.u8,
            args = {foo3_struct},
        };
        local check_nullptr_defintion = {
            returns = ffi.types.u8,
            args = {ffi.types.pointer},
        };
        local new_i32_defintion = {
            returns = ffi.types.pointer,
            args = {},
        };
        local free_i32_defintion = {
            returns = ffi.types.void,
            args = {ffi.types.pointer},
        };
        local lib = ffi.dlopen(`./zig-out/lib/{ffi.prefix}sample.{static_suffix}`, {
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
            check_nullptr = check_nullptr_defintion,

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
            local a = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2);
            local b = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 4);
            test("Library Fn", function()
                expect(lib.add(1, 2)).toBe(3);
                expect(lib.add(a, b)).toBe(6);
            end)
            test("Dynamic Fn", function()
                local add = ffi.fn(add_defintion, lib:getSymbol("add"));
                expect(add(1, 2)).toBe(3);
                expect(add(a, b)).toBe(6);
            end)
        end)

        describe("Symbol<f64 add_float(f64 f64)>", function()
            local a = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2);
            local b = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 4);
            test("Library Fn", function()
                expect(lib.add_float(1, 2)).toBe(3);
                expect(lib.add_float(a, b)).toBe(6);
            end)
            test("Dynamic Fn", function()
                local add_float = ffi.fn(add_float_defintion, lib:getSymbol("add_float"));
                expect(add_float(1, 2)).toBe(3);
                expect(add_float(a, b)).toBe(6);
            end)
        end)

        describe("Symbol<void add_ptr(*i32, i32)>", function()
            test("Library Fn", function()
                local out = ffi.alloc(ffi.types.i32:size()):release();

                lib.add_ptr(out, 1);
                
                expect(out:readi32()).toBe(1);

                lib.add_ptr(out, 6);

                expect(out:readi32()).toBe(7);

                lib.add_ptr(out, testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
            test("Dynamic Fn", function()
                local add_ptr = ffi.fn(add_ptr_defintion, lib:getSymbol("add_ptr"));
                local out = ffi.alloc(ffi.types.i32:size()):release();

                add_ptr(out, 1);
                
                expect(out:readi32()).toBe(1);

                add_ptr(out, 6);

                expect(out:readi32()).toBe(7);

                add_ptr(out, testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
        end)
        describe("Symbol<void add_ptr_ptr(**i32, i32)>", function()
            test("Library Fn", function()
                local out = ffi.alloc(ffi.types.i32:size());
                out:release();

                local ptr = ffi.ptr(out):release();

                lib.add_ptr_ptr(ptr, 1);
                
                expect(out:readi32()).toBe(1);

                lib.add_ptr_ptr(ptr, 6);

                expect(out:readi32()).toBe(7);

                lib.add_ptr_ptr(ptr, testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
            test("Dynamic Fn", function()
                local add_ptr_ptr = ffi.fn(add_ptr_ptr_defintion, lib:getSymbol("add_ptr_ptr"));
                local out = ffi.alloc(ffi.types.i32:size());
                out:release();

                local ptr = ffi.ptr(out):release();

                add_ptr_ptr(ptr, 1);
                
                expect(out:readi32()).toBe(1);

                add_ptr_ptr(ptr, 6);

                expect(out:readi32()).toBe(7);

                add_ptr_ptr(ptr, testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 6));

                expect(out:readi32()).toBe(13);
            end)
        end)

        describe("Symbol<void fire_callback(*void)>", function()
            test("Library Fn", function()
                local counter = 0;
                local c_func = ffi.closure({
                    returns = ffi.types.i8,
                    args = {ffi.types.i32},
                }, function(a)
                    if (a ~= 123) then
                        return 0;
                    end
                    counter += 1;
                    return if (counter == 1) then -1 else 1;
                end):release();

                expect(lib.fire_callback(c_func)).toBe(1);
                expect(lib.fire_callback(c_func)).toBe(0);

                ffi.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end)
            test("Dynamic Fn", function()
                local counter = 0;
                local c_func = ffi.closure({
                    returns = ffi.types.i8,
                    args = {ffi.types.i32},
                }, function(a)
                    if (a ~= 123) then
                        return 0;
                    end
                    counter += 1;
                    return if (counter == 1) then -1 else 1;
                end):release();

                local fire_callback = ffi.fn(fire_callback_defintion, lib:getSymbol("fire_callback"));

                expect(fire_callback(c_func)).toBe(1);
                expect(fire_callback(c_func)).toBe(0);

                ffi.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end);
        end)

        describe("Symbol<char double_call(*void)>", function()
            test("Library Fn", function()
                local counter = 0;
                local c_func = ffi.closure({
                    returns = ffi.types.u8,
                    args = {ffi.types.pointer},
                }, function(callback)
                    counter += 1;
                    local num = ffi.fn({
                        returns = ffi.types.i32,
                        args = {ffi.types.i32},
                    }, callback)(counter);
                    return num == 2556;
                end):release();
                c_func:release();

                expect(lib.double_call(c_func)).toBe(1);
                expect(lib.double_call(c_func)).toBe(0);

                ffi.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end)
            test("Dynamic Fn", function()
                local counter = 0;
                local c_func = ffi.closure({
                    returns = ffi.types.u8,
                    args = {ffi.types.pointer},
                }, function(callback)
                    counter += 1;
                    local num = ffi.fn({
                        returns = ffi.types.i32,
                        args = {ffi.types.i32},
                    }, callback)(counter);
                    return num == 2556;
                end):release();

                local double_call = ffi.fn(double_call_defintion, lib:getSymbol("double_call"));

                expect(double_call(c_func)).toBe(1);
                expect(double_call(c_func)).toBe(0);

                ffi.free(c_func); -- free reference to closure in backend (not necessary in real world case).
            end)
        end)

        describe("Symbol<void check_string(const char*)>", function()
            test("Library Fn", function()
                expect(lib.check_string("hello")).toBe(1);
                expect(lib.check_string("Hello")).toBe(0);

                do
                    local buf = ffi.dupe(buffer.fromstring("hello\0")):release();
                    expect(lib.check_string(buf)).toBe(1);
                end
                do
                    local buf_2 = ffi.dupe(buffer.fromstring("Hello\0")):release();
                    expect(lib.check_string(buf_2)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_string = ffi.fn(check_string_defintion, lib:getSymbol("check_string"));

                expect(check_string("hello")).toBe(1);
                expect(check_string("Hello")).toBe(0);

                do
                    local buf = ffi.dupe(buffer.fromstring("hello\0")):release();
                    expect(check_string(buf)).toBe(1);
                end
                do
                    local buf_2 = ffi.dupe(buffer.fromstring("Hello\0")):release();
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
                        x = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 1),
                        y = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
                    };
    
                    expect(lib.check_struct(buf)).toBe(1);
                end
    
                do
                    local buf = foo_struct:new {
                        x = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
                        y = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
                    };
        
                    expect(lib.check_struct(buf)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_struct = ffi.fn(check_struct_defintion, lib:getSymbol("check_struct"));

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
                        x = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 1),
                        y = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
                    };
    
                    expect(check_struct(buf)).toBe(1);
                end
    
                do
                    local buf = foo_struct:new {
                        x = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
                        y = testBufferOfValue(ffi.types.i32:size(), buffer.writei32, 2),
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
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.1),
                        y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
    
                    expect(lib.check_struct2(buf)).toBe(1);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                        y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(lib.check_struct2(buf)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_struct2 = ffi.fn(check_struct2_defintion, lib:getSymbol("check_struct2"));

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
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.1),
                        y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
    
                    expect(check_struct2(buf)).toBe(1);
                end
    
                do
                    local buf = foo2_struct:new {
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                        y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(check_struct2(buf)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_struct2ec(Foo2ec)>", function()
            test("Dynamic Fn", function()
                local check_struct2ec = ffi.fn(check_struct2ec_defintion, lib:getSymbol("check_struct2"));

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
                                x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.1),
                                y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                            },
                        }
                    };
    
                    expect(check_struct2ec(buf)).toBe(1);
                end
    
                do
                    local buf = foo2ec_struct:new {
                        first = foo2e_struct:new {
                            second = foo2_struct:new {
                                x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                                y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
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
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.1),
                        y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
    
                    expect(lib.check_struct3(buf)).toBe(1);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                        y = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(lib.check_struct3(buf)).toBe(0);
                end
            end)
            test("Dynamic Fn", function()
                local check_struct3 = ffi.fn(check_struct3_defintion, lib:getSymbol("check_struct3"));

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
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 1.1),
                    };
    
                    expect(check_struct3(buf)).toBe(1);
                end
    
                do
                    local buf = foo3_struct:new {
                        x = testBufferOfValue(ffi.types.double:size(), buffer.writef64, 2.2),
                    };
        
                    expect(check_struct3(buf)).toBe(0);
                end
            end)
        end)

        describe("Symbol<void check_nullptr(*void)>", function()
            test("Library Fn", function()
                expect(lib.check_nullptr(nil)).toBe(1);
            
                local null_ptr = ffi.ptrFromAddress(buffer.create(ffi.types.pointer:size()));
                expect(lib.check_nullptr(null_ptr)).toBe(1);

                local dummy_value = ffi.dupe(buffer.create(0));
                dummy_value:release();
                local ptr = ffi.ptr(dummy_value):release();
                expect(lib.check_nullptr(ptr)).toBe(0);
                expect(lib.check_nullptr("")).toBe(0);
            end)
            test("Dynamic Fn", function()
                local check_nullptr = ffi.fn(check_nullptr_defintion, lib:getSymbol("check_nullptr"));

                expect(check_nullptr(nil)).toBe(1);
            
                local null_ptr = ffi.ptrFromAddress(buffer.create(ffi.types.pointer:size()));
                expect(check_nullptr(null_ptr)).toBe(1);

                local dummy_value = ffi.dupe(buffer.create(0));
                dummy_value:release();
                local ptr = ffi.ptr(dummy_value):release();
                expect(check_nullptr(ptr)).toBe(0);
                expect(check_nullptr("")).toBe(0);
            end)
        end)

        describe("External Memory Management", function()
            describe("Library", function()
                local ptr = nil;
                test("Symbol<*i32 new_i32()>", function()
                    ptr = lib.new_i32();

                    ptr:size(ffi.types.i32:size());
                    expect(ptr).toBe(expect.type("userdata"));

                    expect(ptr:readi32()).toBe(123);

                    local src = buffer.create(ffi.types.i32:size());
                    buffer.writei32(src, 0, 42);
                    mem.copy(ptr, 0, src, 0, ffi.types.i32:size());

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
                    ptr = ffi.fn(new_i32_defintion, lib:getSymbol("new_i32"))();
                    ptr:size(ffi.types.i32:size());
                    expect(ptr).toBe(expect.type("userdata"));

                    expect(ptr:readi32()).toBe(123);

                    local src = buffer.create(ffi.types.i32:size());
                    buffer.writei32(src, 0, 42);
                    mem.copy(ptr, 0, src, 0, ffi.types.i32:size());

                    expect(ptr:readi32()).toBe(42);

                    ptr:writei32(0, 24);

                    expect(ptr:readi32()).toBe(24);
                end)

                test("Symbol<void free_i32(*i32)>", function()
                    assert(ptr, "Pointer is nil");
                    ffi.fn(free_i32_defintion, lib:getSymbol("free_i32"))(ptr);
                end)
            end)
        end)

        describe("Internal Memory Management", function()
            test("Block", function()
                local block = ffi.alloc(24);
                expect(block).toBe(expect.type("userdata"));

                expect(mem.len(block)).toBe(24);

                expect(function()
                    mem.copy(block, 24, buffer.create(1), 0, 1);
                end).toThrow("access out of bounds");

                ffi.free(block);
            end)

            local block_address = buffer.create(ffi.types.pointer:size());
            test("Leaky Block, Unknown Transform", function()
                local block = ffi.alloc(24);
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

                mem.copy(block_address, 0, ffi.ptr(block):release(), 0, ffi.types.pointer:size());

                block:drop();
            end)

            test("Leaky Unknown Block, Free", function()
                local block = ffi.ptrFromAddress(block_address);
                expect(block == ffi.null).toBe(false);
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

                ffi.free(block);
            end)
        end)

        describe("Tagged Pointers", function()
            local any_ptr = ffi.types.pointer;
            local ctxA_ptr = ffi.types.pointer:newTag("ContextA");
            local ctxB_ptr = ffi.types.pointer:newTag("ContextB");

            expect(ffi.tagName(any_ptr:tag())).toBe(nil);
            expect(ffi.tagName(ctxA_ptr:tag())).toBe("ContextA");
            expect(ffi.tagName(ctxB_ptr:tag())).toBe("ContextB");

            expect(any_ptr:tag()).toBe(0);
            expect(ctxA_ptr:tag()).toBe(1);
            expect(ctxB_ptr:tag()).toBe(2);

            local any_check = ffi.fn({
                returns = ffi.types.u8,
                args = {any_ptr},
            }, lib:getSymbol("check_nullptr"));

            local ctxA_check = ffi.fn({
                returns = ffi.types.u8,
                args = {ctxA_ptr},
            }, lib:getSymbol("check_nullptr"));

            local ctxB_check = ffi.fn({
                returns = ffi.types.u8,
                args = {ctxB_ptr},
            }, lib:getSymbol("check_nullptr"));

            test("Null Pointer", function()
                expect(any_check(nil)).toBe(1);
                expect(ctxA_check(nil)).toBe(1);
                expect(ctxB_check(nil)).toBe(1);
            end)

            test("Pointer tagged", function()
                for i = 1, 10 do
                    expect(ffi.dupe(buffer.create(0)):release():tag(i):tag()).toBe(i);
                end
            end)

            test("Anonymous Tag", function()
                for id = 20_000, 20_010 do
                    expect(ffi.tagName(id)).toBe(nil);
                end
            end)

            test("No Conflict", function()
                expect(any_check(ffi.dupe(buffer.create(0)):release())).toBe(0);
                expect(ctxA_check(ffi.dupe(buffer.create(0)):release():tag(1))).toBe(0);
                expect(ctxB_check(ffi.dupe(buffer.create(0)):release():tag(2))).toBe(0);
            end)

            test("Conflict", function()
                expect(function()
                    any_check(ffi.dupe(buffer.create(0)):release():tag(1));
                end).toThrow("tag mismatch");
                expect(function()
                    any_check(ffi.dupe(buffer.create(0)):release():tag(2));
                end).toThrow("tag mismatch");
                expect(function()
                    ctxA_check(ffi.dupe(buffer.create(0)):release():tag(2));
                end).toThrow("tag mismatch");
                expect(function()
                    ctxB_check(ffi.dupe(buffer.create(0)):release():tag(1));
                end).toThrow("tag mismatch");
                expect(function()
                    ctxA_check(ffi.dupe(buffer.create(0)):release());
                end).toThrow("tag mismatch");
                expect(function()
                    ctxB_check(ffi.dupe(buffer.create(0)):release());
                end).toThrow("tag mismatch");
            end)
        end)
    end)

    test("Lua State", function()
        local L = ffi.getLuaState();
        local L2 = ffi.getLuaState();
        local GL = ffi.getLuaState(true);

        expect(L == L2).toBe(true);
        expect(L == GL).toBe(false);
    end)

    describe("C", function()
        describe("Compile", function()
            test("Basic", function()
                local compiled = ffi.c.compile([[
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

                expect(compiled:listSymbols()[1]:find("hello$") ~= nil).toBeTruthy();
                expect(compiled:listSymbols()[2]:find("add$") ~= nil).toBeTruthy();
                expect(compiled:listSymbols()[3]:find("add_double$") ~= nil).toBeTruthy();

                local hellofn = ffi.fn({ returns = ffi.types.i32, args = {} }, compiled:getSymbol("hello"));
                local addfn = ffi.fn({ returns = ffi.types.i32, args = {ffi.types.i32} }, compiled:getSymbol("add"));
                local add_doublefn = ffi.fn({ returns = ffi.types.double, args = {ffi.types.double} }, compiled:getSymbol("add_double"));

                expect(hellofn()).toBe(50);
                expect(addfn(25)).toBe(30);
                expect(add_doublefn(62.5)).toBe(65);
            end)
            test("Complex", function()
                local compiled = ffi.c.compile((if (platform.os == "windows") then "__declspec(dllimport) " else "extern") .. " void blank();\n\nvoid blank2() { blank(); }", {
                    files = {`./zig-out/lib/{ffi.prefix}sample.{static_suffix}`},
                });

                local blank2fn = ffi.fn({ returns = ffi.types.void, args = {} }, compiled:getSymbol("blank2"));

                blank2fn();
            end)
            test("Error", function()
                expect(function()
                    ffi.c.compile([[
                        double add_double(
                    ]]);
                end).toThrow("error: identifier expected");
                expect(function()
                    ffi.c.compile([[
                        double add_double(double a) {
                            return a + 2.5;
                        }
                    ]], { files = {`unknown_nothing`} });
                end).toThrow("tcc: error: file 'unknown_nothing' not found");
            end)
        end)
    end)
end)
