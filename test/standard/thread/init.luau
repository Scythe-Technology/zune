--!strict
local luau = zune.luau
local thread = zune.thread

local testing = require("@zune/testing")

local describe = testing.describe
local expect = testing.expect
local test = testing.test

local function noYield(fn: () -> ())
    local coro = coroutine.create(fn)
    local ok, err = coroutine.resume(coro)
    if not ok then
        error(err, 2)
    end
    if coroutine.status(coro) == "suspended" then
        error("Operation yielded", 2)
    end
end

local function expectYield(fn: () -> ())
    local this_thread = coroutine.running()
    local yielded = false
    local coro = coroutine.create(function()
        fn()
        if not yielded then
            return
        end
        coroutine.resume(this_thread)
    end)
    local ok, err = coroutine.resume(coro)
    if not ok then
        error(err, 2)
    end
    if coroutine.status(coro) ~= "suspended" then
        error(`Operation did not yield, status: {coroutine.status(coro)}`, 2)
    end
    yielded = true
    coroutine.yield()
end

describe("thread", function()
    test("nothing", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
        ]])
        local _ = thread.fromBytecode(bytecode, { chunk_name = "test" })
        -- since it hasn't started, GC would clean
        -- up the thread automatically
    end)

    test("no start + join", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
        ]])
        local t = thread.fromBytecode(bytecode, { chunk_name = "test" })
        -- Joining a thread that has not been started
        -- should do nothing
        noYield(function()
            -- join should never yield in this case
            t:join()
        end)
    end)

    test("start + no join", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
        ]])
        local t = thread.fromBytecode(bytecode, { chunk_name = "test" })
        noYield(function()
            -- start should never yield in any case
            t:start()
        end)
        -- GC would join the thread automatically,
        -- only if the thread is not running.
        -- Otherwise the engine will join the thread.
    end)

    test("generic bytecode", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
            zune.task.wait(0.25);
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        })
        noYield(function()
            t:start()
        end)
        expectYield(function()
            -- joining a running thread should yield
            t:join()
        end)
    end)

    test("generic bytecode busy join", function()
        local bytecode = luau.compile([[
            print("Hello from thread!");
            zune.task.wait(0.25);
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        })
        noYield(function()
            t:start()
        end)
        expect(t:status()).toBe("running")
        while t:status() ~= "dead" do
            zune.task.wait()
        end
        noYield(function()
            t:join()
        end)
    end)

    test("generic bytecode context", function()
        local bytecode = luau.compile([[
            zune.thread.send(debug.info(1, "sl"));
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        })
        t:start()
        t:join()
        noYield(function()
            -- receive should not yield.
            -- Thread has sent data before it ended
            -- join has gave it enough time to send data entirely.
            local src, n = t:receive()
            expect(src).toBe(`[string "test"]`)
            expect(n).toBe(1)
        end)
    end)

    test("async message receiver", function()
        local bytecode = luau.compile([[
            zune.task.wait(0.25);
            zune.thread.send(debug.info(1, "sl"));
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test 2",
        })
        t:start()
        expectYield(function()
            -- receive should yield.
            -- Called receive before thread could send data.
            -- This should resume the moment thread sends data.
            local src, n = t:receive()
            expect(src).toBe(`[string "test 2"]`)
            expect(n).toBe(2)
        end)
        t:join()
    end)

    test("message sender", function()
        local bytecode = luau.compile([[
            local msg = zune.thread.receive();
            print("Received message:", msg);
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        })
        t:start()
        noYield(function()
            -- send should never yield.
            t:send("from main")
        end)
        t:join()
    end)

    test("basic error", function()
        -- should not stop any of the code below
        local bytecode = luau.compile([[
            error("Some error");
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "test",
        })
        t:start()
        t:join()
    end)

    test("echo thread", function()
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
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "echo",
        })
        noYield(function()
            -- should be possible to send data
            -- without starting the thread
            t:send(1, 2)
        end)
        t:start()
        expect({ t:receive() }).toBe(expect.similar({ 1, 2 }))
        t:send(3, 4)
        expect({ t:receive() }).toBe(expect.similar({ 3, 4 }))
        t:send()
        t:join()
    end)

    test("echo thread values", function()
        local bytecode = luau.compile([[
            local thread = zune.thread;

            while true do
                local msgs = {thread.receive()};
                if (#msgs == 0) then
                    break;
                end
                thread.send(unpack(msgs));
            end
        ]])
        local t = thread.fromBytecode(bytecode, {
            chunk_name = "echo values",
        })

        local function sendExpect(...)
            local args = { ... }
            noYield(function()
                t:send(unpack(args))
            end)
            expect({ t:receive() }).toBe(expect.similar(args))
        end
        t:start()
        sendExpect(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
        sendExpect("a", "b", "c", "d", "e")
        sendExpect(true, nil, false)
        sendExpect(1.23, 4.56, 7.89)
        sendExpect(vector.create(1, 2, 3), vector.create(4, 5, 6))
        sendExpect({ "a", "b", "c" }, { 1, 2, 3 }, { vector.create(1, 2, 3), vector.create(4, 5, 6) })
        sendExpect({ a = 1, b = 2, c = 3 }, { [4] = "d", [5] = "e", [6] = "f" })
        sendExpect(
            { a = { b = { c = { d = { f = { "g" } } } } } },
            { [4] = { [5] = { [6] = { [7] = { [8] = { 9 } } } } } }
        )
        t:send({ [{ a = { b = { c = { d = { f = { "g" } } } } } }] = { a = { b = { c = { d = { f = { 2 } } } } } } })
        do
            local complex_table = t:receive()
            for k, v in complex_table do
                expect(k).toBe(expect.similar({ a = { b = { c = { d = { f = { "g" } } } } } }))
                expect(v).toBe(expect.similar({ a = { b = { c = { d = { f = { 2 } } } } } }))
                break
            end
        end
        local a, b = buffer.fromstring("Hello, World!"), buffer.fromstring(_VERSION)
        t:send(a, b)
        local a2, b2 = t:receive()
        expect(buffer.tostring(a2)).toBe(buffer.tostring(a))
        expect(buffer.tostring(b2)).toBe(buffer.tostring(b))
        expect(function()
            local cycle = {}
            cycle.self = cycle
            t:send(cycle)
        end).toThrow("CyclicReference")
        expect(function()
            local cycle = {}
            cycle[cycle] = 0
            t:send(cycle)
        end).toThrow("CyclicReference")
        expect(function()
            t:send(function() end)
        end).toThrow("unsupported lua type for sending (got function)")
        expect(function()
            t:send(newproxy())
        end).toThrow("unsupported lua type for sending (got userdata)")
        t:send()
        t:join()
    end)

    test("test", function()
        local t1 = thread.fromModule("@self/module")
        t1:send(1, 2)
        t1:start()
    end)

    test("generic module", function()
        local t1 = thread.fromModule("@self/module")
        t1:send(1, 2)
        t1:start()
    end)

    test("invalid module", function()
        local ok, res = pcall(thread.fromModule, "@self/unknown")
        expect(ok).toBeFalsy()
        assert(type(res) == "string")
        expect(res:match("%w+ %w+ %w+:")).toBe("module not found:")
    end)

    test("cpu count", function()
        expect(thread.getCpuCount()).toBeGreaterThan(0)
    end)

    test("mutex same thread", function()
        local task = zune.task
        local a = thread.createMutex("same-thread")
        local b = thread.createMutex("same-thread")
        expect((a :: any) == (b :: any)).toBeTruthy()

        local other = thread.createMutex("same-thread-other")
        expect((a :: any) == (other :: any)).toBeFalsy()

        other:lock()

        local ran = false
        task.defer(function()
            ran = true
        end)
        a:lock()
        expect(ran).toBeFalsy()
        task.wait()
        expect(ran).toBeTruthy()

        expect(function()
            a:unlock()
            a:unlock()
        end).toThrow("not locked")

        a:lock()
        local order: { string } = {}
        task.spawn(function()
            a:lock()
            table.insert(order, "a")
            a:unlock()
        end)
        task.spawn(function()
            a:lock()
            table.insert(order, "b")
            a:unlock()
        end)
        expect(#order).toBe(0)
        a:unlock()

        task.wait()
        task.wait()

        expect(order[1]).toBe("a")
        expect(order[2]).toBe("b")

        a:lock()

        local ok, err = pcall(function()
            luau.sync(function()
                a:lock()
            end)
        end)
        expect(ok).toBeFalsy()
        assert(type(err) == "string")
        expect((err :: string):match("yield") ~= nil).toBeTruthy()

        a:unlock()
        other:unlock()
    end)

    local function runShared(create: string, name: string, progressed: boolean)
        local task = zune.task
        local bytecode = luau.compile(string.format(
            [[
            local thread = zune.thread
            local task = zune.task
            local mode = thread.receive()
            local mutex = thread.%s("%s")
            if mode == "hold" then
                mutex:lock()
                thread.send("held")
                thread.receive()
                mutex:unlock()
                thread.send("done")
            else
                thread.send("approaching")
                local moved = false
                task.defer(function()
                    moved = true
                end)
                mutex:lock()
                thread.send(if moved then "progressed" else "stalled")
                thread.send(zune.time.date.now().timestamp_millis)
                mutex:unlock()
            end
        ]],
            create,
            name
        ))
        local holder = thread.fromBytecode(bytecode, { chunk_name = name .. "-holder" })
        local waiter: Thread? = nil
        local function cleanup()
            if holder:status() == "running" then
                holder:send("release")
            end
            holder:join()
            if waiter ~= nil then
                waiter:join()
            end
        end
        local ok, err = pcall(function()
            holder:start()
            holder:send("hold")
            expect(holder:receive()).toBe("held")

            waiter = thread.fromBytecode(bytecode, { chunk_name = name .. "-waiter" })
            waiter:start()
            waiter:send("wait")

            expect(waiter:receive()).toBe("approaching")

            task.wait(0.2)

            local released_at = zune.time.date.now().timestamp_millis

            holder:send("release")

            expect(waiter:receive()).toBe(if progressed then "progressed" else "stalled")

            local acquired_at = waiter:receive() :: number
            expect(holder:receive()).toBe("done")
            expect(acquired_at).toBeGreaterThanOrEqual(released_at)
        end)
        cleanup()
        if not ok then
            error(tostring(err), 0)
        end
    end

    test("mutex shared lock", function()
        runShared("createMutex", "mutex-shared", true)
    end)

    test("HardMutex same thread", function()
        local a = thread.createHardMutex("hard-same-thread")
        local b = thread.createHardMutex("hard-same-thread")
        expect((a :: any) == (b :: any)).toBeTruthy()
        local other = thread.createHardMutex("hard-same-thread-other")
        expect((a :: any) == (other :: any)).toBeFalsy()

        other:lock()
        a:lock()
        expect(function()
            a:lock()
        end).toThrow("already locked")
        expect(function()
            a:unlock()
            a:unlock()
        end).toThrow("not locked")
        other:unlock()
        a:lock()
        a:unlock()
    end)

    test("HardMutex shared lock", function()
        runShared("createHardMutex", "hard-shared", false)
    end)

    test("lane same state", function()
        local a = thread.createLane("lane-same")
        local b = thread.createLane("lane-same")
        expect((a :: any) == (b :: any)).toBeTruthy()
        local other = thread.createLane("lane-same-other")
        expect((a :: any) == (other :: any)).toBeFalsy()

        a:send(1, "x")
        noYield(function()
            local n, s = a:receive()
            expect(n).toBe(1)
            expect(s).toBe("x")
        end)
        a:send()
        noYield(function()
            a:receive()
        end)

        expect(function()
            a:send(function() end)
        end).toThrow("unsupported lua type for sending (got function)")

        local ok, err = pcall(function()
            luau.sync(function()
                a:receive()
            end)
        end)
        expect(ok).toBeFalsy()
        assert(type(err) == "string")
        expect((err :: string):match("yield") ~= nil).toBeTruthy()
    end)

    test("lane waiters", function()
        local task = zune.task
        local lane = thread.createLane("lane-waiters")
        local order: { string } = {}
        task.spawn(function()
            table.insert(order, (lane:receive()))
        end)
        task.spawn(function()
            table.insert(order, (lane:receive()))
        end)
        expect(#order).toBe(0)
        lane:send("a")
        task.wait()
        lane:send("b")
        task.wait()
        expect(order[1]).toBe("a")
        expect(order[2]).toBe("b")
    end)

    test("lane shared", function()
        local bytecode = luau.compile([[
            local lane = zune.thread.createLane("lane-shared")
            lane:send("ready")
            local msg = lane:receive()
            lane:send(msg, "worker")
        ]])
        local lane = thread.createLane("lane-shared")

        local worker = thread.fromBytecode(bytecode, { chunk_name = "lane-shared" })
        worker:start()

        expect(lane:receive()).toBe("ready")

        lane:send("ping")

        local msg, from = lane:receive()
        expect(msg).toBe("ping")
        expect(from).toBe("worker")

        worker:join()
    end)

    test("value same state", function()
        local task = zune.task
        local a = thread.createValue("value-same")
        local b = thread.createValue("value-same")
        expect((a :: any) == (b :: any)).toBeTruthy()

        local other = thread.createValue("value-same-other")
        expect((a :: any) == (other :: any)).toBeFalsy()

        local ran = false
        task.defer(function()
            ran = true
        end)

        expect(a:get()).toBeNil()
        expect(ran).toBeFalsy()

        a:set("x")

        expect(ran).toBeTruthy()
        expect(a:get()).toBe("x")
        expect(other:get()).toBeNil()

        local prev: any = nil
        a:update(function(current: any)
            prev = current
            return 3
        end)

        expect(prev).toBe("x")
        expect(a:get()).toBe(3)

        a:update(function(current: any)
            expect(current).toBe(3)
            return nil
        end)

        expect(a:get()).toBeNil()

        a:set(8)
        a:set()

        expect(a:get()).toBeNil()

        a:set({ n = 1 })

        local copy = a:get() :: { n: number }
        expect(copy.n).toBe(1)

        copy.n = 9

        expect((a:get() :: { n: number }).n).toBe(1)

        a:set(0)

        local order: { number } = {}
        task.spawn(function()
            a:update(function(current: any)
                table.insert(order, current :: number)
                return 5
            end)
        end)
        task.spawn(function()
            a:set(7)
        end)
        -- should be last
        a:update(function(current: any)
            table.insert(order, current :: number)
            return (current :: number) + 1
        end)
        expect(order[1]).toBe(0)
        expect(order[2]).toBe(7)
        expect(a:get()).toBe(8)

        expect(function()
            a:set(function() end)
        end).toThrow("unsupported lua type (got function)")
        expect(a:get()).toBe(8)

        local ok, err = pcall(function()
            luau.sync(function()
                a:set(9)
            end)
        end)
        expect(ok).toBeFalsy()
        assert(type(err) == "string")
        expect((err :: string):match("yield") ~= nil).toBeTruthy()
        local ok_update, err_update = pcall(function()
            luau.sync(function()
                a:update(function(current: any)
                    return current
                end)
            end)
        end)
        expect(ok_update).toBeFalsy()
        assert(type(err_update) == "string")
        expect((err_update :: string):match("yield") ~= nil).toBeTruthy()
        expect(a:get()).toBe(8)
    end)

    test("value update error", function()
        local a = thread.createValue("value-error")

        a:set(4)

        local ok, err = pcall(function()
            a:update(function(current: any)
                expect(current).toBe(4)
                error("nope")
            end)
        end)
        expect(ok).toBeFalsy()
        assert(type(err) == "string")
        expect((err :: string):match("nope") ~= nil).toBeTruthy()
        expect(a:get()).toBe(4)

        local ok_type, err_type = pcall(function()
            a:update(function(current: any)
                expect(current).toBe(4)
                return function() end
            end)
        end)
        expect(ok_type).toBeFalsy()
        assert(type(err_type) == "string")
        expect((err_type :: string):match("unsupported lua type") ~= nil).toBeTruthy()
        expect(a:get()).toBe(4)
    end)

    test("value shared", function()
        local bytecode = luau.compile([[
            local value = zune.thread.createValue("value-shared")
            value:set("from-worker")
            zune.thread.send("set")
            local msg = zune.thread.receive()
            value:update(function(current)
                return current .. ":" .. msg
            end)
            zune.thread.send(value:get())
        ]])
        local value = thread.createValue("value-shared")
        local worker = thread.fromBytecode(bytecode, { chunk_name = "value-shared" })

        worker:start()

        expect(worker:receive()).toBe("set")
        expect(value:get()).toBe("from-worker")

        value:set("replaced")
        worker:send("ping")

        expect(worker:receive()).toBe("replaced:ping")
        expect(value:get()).toBe("replaced:ping")

        worker:join()
    end)

    test("isThread", function()
        expect(thread.isThread).toBeFalsy()
    end)
end)
