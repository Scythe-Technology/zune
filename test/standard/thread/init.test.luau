--!strict
local luau = zune.luau;
local thread = zune.thread;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function noYield(fn: () -> ())
    local coro = coroutine.create(fn);
    local ok, err = coroutine.resume(coro);
    if (not ok) then
        error(err, 2);
    end
    if (coroutine.status(coro) == "suspended") then
        error("Operation yielded", 2);
    end
end

local function expectYield(fn: () -> ())
    local this_thread = coroutine.running();
    local yielded = false;
    local coro = coroutine.create(function()
        fn();
        if (not yielded) then
            return;
        end
        coroutine.resume(this_thread);
    end);
    local ok, err = coroutine.resume(coro);
    if (not ok) then
        error(err, 2);
    end
    if (coroutine.status(coro) ~= "suspended") then
        error(`Operation did not yield, status: {coroutine.status(coro)}`, 2);
    end
    yielded = true;
    coroutine.yield();
end

describe("thread", function()
    test("Nothing", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
        ]]);
        local _ = thread.fromBytecode(bytecode, { chunk_name = "test" });
        -- since it hasn't started, GC would clean
        -- up the thread automatically
    end)

    test("No Start + Join", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
        ]]);
        local t = thread.fromBytecode(bytecode, { chunk_name = "test" });
        -- Joining a thread that has not been started
        -- should do nothing
        noYield(function()
            -- join should never yield in this case
            t:join();
        end)
    end)

    test("Start + No Join", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
        ]]);
        local t = thread.fromBytecode(bytecode, { chunk_name = "test" });
        noYield(function()
            -- start should never yield in any case
            t:start();
        end)
        -- GC would join the thread automatically,
        -- only if the thread is not running.
        -- Otherwise the engine will join the thread.
    end)
    
    test("Generic Bytecode", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
            zune.task.wait(0.25);
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        });
        noYield(function()
            t:start();
        end)
        expectYield(function()
            -- joining a running thread should yield
            t:join();
        end)
    end)

    test("Generic Bytecode Busy Join", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
            zune.task.wait(0.25);
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        });
        noYield(function()
            t:start();
        end)
        expect(t:status()).toBe("running");
        while (t:status() ~= "dead") do
            zune.task.wait();
        end
        noYield(function()
            t:join();
        end)
    end)

    test("Generic Bytecode Context", function()
        local bytecode = luau.compile([[
            zune.thread.send(debug.info(1, "sl"));
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        });
        t:start();
        t:join();
        noYield(function()
            -- receive should not yield.
            -- Thread has sent data before it ended
            -- join has gave it enough time to send data entirely.
            local src, n = t:receive();
            expect(src).toBe(`[string "test"]`);
            expect(n).toBe(1);
        end)
    end)

    test("Async Message Receiver", function()
        local bytecode = luau.compile([[
            zune.task.wait(0.25);
            zune.thread.send(debug.info(1, "sl"));
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test 2",
        });
        t:start();
        expectYield(function()
            -- receive should yield.
            -- Called receive before thread could send data.
            -- This should resume the moment thread sends data.
            local src, n = t:receive();
            expect(src).toBe(`[string "test 2"]`);
            expect(n).toBe(2);
        end)
        t:join();
    end)

    test("Message Sender", function()
        local bytecode = luau.compile([[
            local msg = zune.thread.receive();
            print("Received message:", msg);
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        });
        t:start();
        noYield(function()
            -- send should never yield.
            t:send("from main");
        end)
        t:join();
    end)

     test("Basic Error", function()
        -- should not stop any of the code below
        local bytecode = luau.compile([[
            error("Some error");
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        });
        t:start();
        t:join();
    end)

    test("Echo Thread", function()
        local bytecode = luau.compile([[
            local thread = zune.thread;

            while true do
                local a, b = thread.receive();
                if (a == nil) then
                    break;
                end
                print("Received:", a, b);
                thread.send(a, b);
            end
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "echo",
        });
        noYield(function()
            -- should be possible to send data
            -- without starting the thread
            t:send(1, 2);
        end)
        t:start();
        expect({t:receive()}).toBe(expect.similar({1, 2}));
        t:send(3, 4);
        expect({t:receive()}).toBe(expect.similar({3, 4}));
        t:send();
        t:join();
    end)

    test("Echo Thread Values", function()
        local bytecode = luau.compile([[
            local thread = zune.thread;

            while true do
                local msgs = {thread.receive()};
                if (#msgs == 0) then
                    break;
                end
                thread.send(unpack(msgs));
            end
        ]]);
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "echo values",
        });

        local function sendExpect(...)
            local args = {...};
            noYield(function()
                t:send(unpack(args));
            end)
            expect({t:receive()}).toBe(expect.similar(args));
        end
        t:start();
        sendExpect(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        sendExpect("a", "b", "c", "d", "e");
        sendExpect(true, nil, false);
        sendExpect(1.23, 4.56, 7.89);
        sendExpect(vector.create(1, 2, 3), vector.create(4, 5, 6));
        sendExpect({"a", "b", "c"}, {1, 2, 3}, {vector.create(1, 2, 3), vector.create(4, 5, 6)});
        sendExpect({a = 1, b = 2, c = 3}, {[4] = "d", [5] = "e", [6] = "f"});
        sendExpect({a = {b = {c = {d = {f = {"g"}}}}}}, {[4] = {[5] = {[6] = {[7] = {[8] = {9}}}}}});
        t:send({[{a = {b = {c = {d = {f = {"g"}}}}}}] = {a = {b = {c = {d = {f = {2}}}}}}});
        do
            local complex_table = t:receive();
            for k, v in complex_table do
                expect(k).toBe(expect.similar({a = {b = {c = {d = {f = {"g"}}}}}}));
                expect(v).toBe(expect.similar({a = {b = {c = {d = {f = {2}}}}}}));
                break;
            end
        end
        local a, b = buffer.fromstring("Hello, World!"), buffer.fromstring(_VERSION);
        t:send(a, b);
        local a2, b2 = t:receive();
        expect(buffer.tostring(a2)).toBe(buffer.tostring(a));
        expect(buffer.tostring(b2)).toBe(buffer.tostring(b));
        expect(function()
            local cycle = {};
            cycle.self = cycle;
            t:send(cycle);
        end).toThrow("CyclicReference");
        expect(function()
            local cycle = {};
            cycle[cycle] = 0;
            t:send(cycle);
        end).toThrow("CyclicReference");
        expect(function()
            t:send(function() end);
        end).toThrow("Unsupported lua type for sending (got function)");
        expect(function()
            t:send(newproxy());
        end).toThrow("Unsupported lua type for sending (got userdata)");
        t:send();
        t:join();
    end)

    test("Test", function()
        local t1 = thread.fromModule("@self/module");
        t1:send(1, 2);
        t1:start();
    end)

    test("Generic Module", function()
        local t1 = thread.fromModule("@self/module");
        t1:send(1, 2);
        t1:start();
    end)

    test("Invalid Module", function()
        local ok, res = pcall(thread.fromModule, "@self/unknown");
        expect(ok).toBeFalsy();
        assert(type(res) == "string");
        expect(res:match("%w+ %w+ %w+:")).toBe("module not found:");
    end)

    test("Cpu Count", function()
        expect(thread.getCpuCount()).toBeGreaterThan(0);
    end)

    test("isThread", function()
        expect(thread.isThread).toBeFalsy();
    end)
end)
