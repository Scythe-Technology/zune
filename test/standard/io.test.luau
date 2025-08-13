--!strict
local io = zune.io;
local task = zune.task;
local testing = zune.testing;

local test = testing.test;
local expect = testing.expect;
local describe = testing.describe;

describe("IO", function()
    describe("BufferSink", function()
        test("Generic", function()
            local sink = io.createBufferSink();
            expect(sink).toBe(expect.type("userdata"));

            local a = "test default";
            sink:write(a);
            expect(sink.len).toBe(#a);
            expect(buffer.tostring(sink:flush())).toBe(a);
            expect(sink.len).toBe(0);

            local b = "test buffer";
            sink:write(b);
            expect(sink.len).toBe(#b);
            expect(buffer.tostring(sink:flush(true))).toBe(b);
            expect(sink.len).toBe(0);

            local c = "test string";
            sink:write(c);
            expect(sink.len).toBe(#c);
            expect(sink:flush(false)).toBe(c);
            expect(sink.len).toBe(0);

            local chunk = buffer.create(1024);
            local data = "test chunk";
            buffer.writestring(chunk, 0, data);
            sink:write(chunk);
            expect(sink.len).toBe(1024);
            local flushed_chunk = sink:flush();
            local rem = 1024 - #data;
            expect(buffer.readstring(flushed_chunk, #data, rem)).toBe(string.rep("\0", rem));
            expect(buffer.readstring(flushed_chunk, 0, 10)).toBe("test chunk");
            expect(sink.len).toBe(0);

            expect(function()
                sink:close()
            end).never.toThrow();
        end)
        test("WritableStream", function()
            local sink = io.createBufferSink();
            expect(sink).toBe(expect.type("userdata"));

            local stream = sink:writer();
            expect(stream).toBe(sink:writer());
            expect(stream).toBe(sink:writer());

            stream:writeu8(123);
            expect(sink.len).toBe(1);
            expect(buffer.readu8(sink:flush(), 0)).toBe(123);
            expect(sink.len).toBe(0);

            stream:writeu8(257);
            expect(sink.len).toBe(1);
            expect(buffer.readu8(sink:flush(), 0)).toBe(1);
            expect(sink.len).toBe(0);

            stream:writeu16(12345);
            expect(sink.len).toBe(2);
            expect(buffer.readu16(sink:flush(), 0)).toBe(12345);
            expect(sink.len).toBe(0);

            stream:writeu16(70000);
            expect(sink.len).toBe(2);
            expect(buffer.readu16(sink:flush(), 0)).toBe(4464);
            expect(sink.len).toBe(0);

            stream:writeu32(123456789);
            expect(sink.len).toBe(4);
            expect(buffer.readu32(sink:flush(), 0)).toBe(123456789);

            stream:writef32(123.456);
            expect(sink.len).toBe(4);
            expect(
                buffer.readf32(sink:flush(), 0) * 1000
                // 1
                / 1000
            ).toBe(123.456);
            expect(sink.len).toBe(0);

            stream:writef64(12345.12345);
            expect(sink.len).toBe(8);
            expect(buffer.readf64(sink:flush(), 0)).toBe(12345.12345);
            expect(sink.len).toBe(0);

            expect(function()
                sink:close()
            end).never.toThrow();
        end)
        test("Limited Small", function()
            local sink = io.createBufferSink({
                limit = 1024,
            });
            expect(sink).toBe(expect.type("userdata"));
    
            local large = string.rep("a", 1024);
            sink:write(large);
            expect(sink.len).toBe(#large);
            expect(buffer.tostring(sink:flush())).toBe(large);
            expect(sink.len).toBe(0);

            expect(function()
                sink:write(large .. "a");
            end).toThrow("BufferSink limit exceeded");
    
            expect(function()
                sink:close()
            end).never.toThrow();
        end)
    end)

    describe("FixedBufferStream", function()
        test("Generic Usage", function()
            local buf = buffer.fromstring("test default");
            local stream = io.createFixedBufferStream(buf);
            expect(stream).toBe(expect.type("userdata"));

            local a = "test default";
            stream:write(a);
            expect(buffer.tostring(buf)).toBe(a);
            expect(stream:pos()).toBe(#a);

            stream:seekTo(0);
            expect(stream:pos()).toBe(0);

            local b = "test buffer";
            stream:write(b);
            expect(buffer.tostring(buf)).toBe(b .. (a:sub(#b + 1)));
            expect(stream:pos()).toBe(#b);

            stream:seekTo(0);
            expect(stream:pos()).toBe(0);

            local c = "test string";
            stream:write(c);
            expect(buffer.tostring(buf)).toBe(c .. (a:sub(#c + 1)));
            expect(stream:pos()).toBe(#c);

            stream:seekTo(0);
            expect(stream:pos()).toBe(0);

            local all = stream:read()
            expect(all).never.toBeNil();
            assert(all)
            expect(buffer.tostring(all)).toBe(c .. (a:sub(#c + 1)));

            stream:seekTo(0);
            expect(stream:pos()).toBe(0);

            buffer.writestring(buf, 0, "test default");
            stream:write(buf);

            local ok, err = pcall(stream.read, stream)
            expect(ok).toBeTruthy();
            expect(buffer.tostring(err)).toBe("");

            stream:seekTo(0);
            expect(stream:pos()).toBe(0)

            expect(stream:canRead()).toBeTruthy()
            expect(stream:canRead(4)).toBeTruthy()
            expect(stream:canRead(#a)).toBeTruthy()
            expect(stream:canRead(#a + 1)).toBeFalsy()

            expect(stream:read(#a, false)).toBe(a)
            
            stream:seekTo(0)
            expect(stream:pos()).toBe(0)

            stream:seekBy(1)
            expect(stream:pos()).toBe(1)
            stream:seekBy(-1)
            expect(stream:pos()).toBe(0)
            stream:seekBy(-1)
            expect(stream:pos()).toBe(0)
            stream:seekBy(10000)
            expect(stream:pos()).toBe(12)

            stream:seekTo(0)
            expect(stream:pos()).toBe(0)

            local string_ok, string_err = pcall(stream.read, stream, 0, false)
            expect(string_ok).toBeTruthy()
            expect(string_err).toBe("")

            local partial = stream:read(4)
            expect(partial).never.toBeNil()
            assert(partial)
            expect(buffer.tostring(partial)).toBe("test")
        end)
        test("Generic Reader", function()
            local buf = buffer.fromstring("test default");
            local stream = io.createFixedBufferStream(buf);
            expect(stream).toBe(expect.type("userdata"));
            expect(stream:pos()).toBe(0);
            expect(stream:size()).toBe(buffer.len(buf));

            local reader = stream:reader();
            expect(reader).toBe(expect.type("userdata"));
            expect(reader).toBe(stream:reader());
            expect(reader).toBe(stream:reader());

            expect(reader:readu8()).toBe(116); -- 't'
            expect(reader:readu8()).toBe(101); -- 'e'
            expect(reader:readu8()).toBe(115); -- 's'
            expect(reader:readu8()).toBe(116); -- 't'

            expect(stream:pos()).toBe(4);

            expect(reader:read(nil, false)).toBe(" default");
            expect(stream:pos()).toBe(12);

            local ok, err = pcall(reader.readu8, reader)
            expect(ok).toBeFalsy();
            expect(err).toBe("EOF");
            expect(stream:size()).toBe(buffer.len(buf));
        end)
        test("Generic Writer", function()
            local buf = buffer.fromstring("____ _______");
            local stream = io.createFixedBufferStream(buf);
            expect(stream).toBe(expect.type("userdata"));
            expect(stream:pos()).toBe(0);
            expect(stream:size()).toBe(buffer.len(buf));

            local writer = stream:writer();
            expect(writer).toBe(expect.type("userdata"));
            expect(writer).toBe(stream:writer());
            expect(writer).toBe(stream:writer());

            writer:writeu8(116); -- 't'
            writer:writeu8(101); -- 'e'
            writer:writeu8(115); -- 's'
            writer:writeu8(116); -- 't'
            expect(buffer.tostring(buf)).toBe("test _______");

            expect(stream:pos()).toBe(4);

            writer:write(" default");
            expect(buffer.tostring(buf)).toBe("test default");
            expect(stream:size()).toBe(buffer.len(buf));
        end)
        test("Complex Reader", function()
            local complex: {any} = setmetatable({}, {__mode = "v"}) :: any;

            local buf = buffer.fromstring("test complex");
            local stream = io.createFixedBufferStream(buf);
            expect(stream).toBe(expect.type("userdata"));
            expect(stream:pos()).toBe(0);
            local address = "";
            do
                local reader: IoReadable = stream:reader();
                expect(reader:readu8()).toBe(116); -- 't'
                expect(reader:readu8()).toBe(101); -- 'e'
                task.wait();
                expect(reader:readu8()).toBe(115); -- 's'
                expect(reader:readu8()).toBe(116); -- 't'
                address = tostring(reader);
                complex[1] = reader;
                reader = nil :: any; -- remove reference
                repeat
                    task.wait();
                until complex[1] == nil;
            end
            local reader = stream:reader();
            -- this should have created a new reader
            -- old reader should be garbage collected
            expect(address).never.toBe(tostring(reader));
            expect(reader).toBe(expect.type("userdata"));

            expect(reader:readu8()).toBe(32); -- ' '
            expect(reader:readu8()).toBe(99); -- 'c'

            complex[1] = stream;
            stream = nil :: any; -- remove reference
            for i = 1, 16 do
                task.wait(); -- tick gc
            end

            -- stream should not be garbage collected
            -- reader exists, so stream should be alive

            expect(reader:read(nil, false)).toBe("omplex");

            local ok, err = pcall(reader.readu8, reader)
            expect(ok).toBeFalsy();
            expect(err).toBe("EOF");
            local string_ok, string_err = pcall(reader.read, reader, 0, false)
            expect(string_ok).toBeTruthy()
            expect(string_err).toBe("");

            reader = nil :: any; -- remove reference

            repeat
                task.wait();
            until complex[1] == nil;
        end)
    end)

    test("Format", function()
        local useColor = (zune.process.env["NO_COLOR"] == nil or zune.process.env["NO_COLOR"] == "0");
        expect(io.format("test")).toBe("test");
        expect(io.format(123)).toBe(if (useColor) then "\x1B[96m123\x1B[0m" else "123");
        local res : string = io.format({[" "] = 1});
        local start : number = (res:find(">")) or error("Bad format");
        start += 1;
        expect(res:sub(start)).toBe(
            if (useColor) then " {\x1B[0m\n    \x1B[2m[\x1B[0;32m\" \"\x1B[0;2m]\x1B[0m\x1B[2m = \x1B[0m\x1B[96m1\x1B[0m\x1B[2m,\x1B[0m \n\x1B[2m}\x1B[0m"
            else " {\n    [\" \"] = 1, \n}"
        );
        expect(((res:sub(1,start)):find(if (useColor) then "\x1B%[2m<table: 0x.+>" else "<table: 0x.+>"))).never.toBeNil();
    end)
end)
