--!strict
local fmt = zune.fmt
local task = zune.task
local mem = zune.mem

local io = require("./io")
local ansi = require("./ansi").auto()

local testing_env = getfenv()

type TestInfo = {
    name: string?,
    timeout: number?,
}

type FileContext = {
    name: string,
}

type StackTraceInfo = {
    file: FileContext,
    name: string,
    line: number,
    address: string,
}

local clock_now = os.clock

local testing = {}

testing.started = false

local DEFER_QUEUE = {} :: { () -> () }
local SCOPE_STACK = {} :: { string }
local TEST_STACK = {} :: { string }

local function secondsToMs(seconds: number): number
    return (seconds * 1000) // 1
end

local function stripSourceFromError(src: string?, line: number?, err: string): string
    if src and line then
        local test = `{src}:{line}: `
        if mem.startsWith(err, test) then
            return err:sub(#test + 1)
        end
    end
    return err
end

local function findTargetTrace()
    local level, count = nil, 0
    local src: string? = nil
    local line: number? = nil
    for i = 1, 30 do
        local f, l, s = debug.info(i + 1, "fls")
        if not f then
            break
        end
        if l < 0 then
            continue
        end
        if not level then
            if getfenv(f) ~= testing_env then
                level = i
                src = s
                line = l
            end
        else
            if getfenv(f) == testing_env then
                break
            end
            count += 1
        end
    end
    if not level then
        level = 1
    end
    return level :: number, src, line, math.max(count, 1)
end

local function runTest(fn: () -> (), info: TestInfo)
    zune.testing.start()

    testing.started = true

    zune.testing.addCount(1)

    local scope = if #SCOPE_STACK > 0 then `{ansi.dim}{table.concat(SCOPE_STACK, "/")}{ansi.reset} ` else ""
    scope ..= `({ansi.bold}{info.name}{ansi.reset})`

    local time_length = clock_now()
    local thread: thread? = coroutine.running()
    local timout = info.timeout or -1
    local skipped = false

    local function cleanupAsync()
        for i = #DEFER_QUEUE, 1, -1 do
            local v = DEFER_QUEUE[i]
            xpcall(v, function(e)
                local level, src, line, count = findTargetTrace()
                print(
                    `{ansi.yellow}{ansi.bold}DEFER ERROR{ansi.reset} {scope} {ansi.dim}[{secondsToMs(
                        clock_now() - time_length
                    )}ms]{ansi.reset} {e}`
                )
                print(
                    `{ansi.red}error{ansi.reset}: {stripSourceFromError(
                        src,
                        line,
                        if typeof(e) == "string" then e else tostring(e)
                    )}{ansi.reset}`
                )
                print(zune.debug.dumpStacktrace(level, count))
            end)
        end
        table.clear(DEFER_QUEUE)
        local f = 0
        if task.count() > 0 then
            local rest = clock_now() + (timout - time_length)
            while true do
                if timout >= 0 then
                    if clock_now() > rest then
                        break
                    end
                end
                if task.count() > 0 then
                    if f == 300 then
                        local s, d, w, t = task.count("sdwt")
                        print(
                            `{ansi.yellow}{ansi.bold}~ {ansi.reset}{ansi.dim}[{ansi.reset}{scope}{ansi.dim}]{ansi.reset} {ansi.yellow}<waiting for tasks... {s} + {d} + {w} + {t}>{ansi.reset}`
                        )
                    end
                    f += 1
                    task.wait()
                else
                    break
                end
            end
        end

        zune.testing.stepCheckReferences(` -- {scope}`)
    end

    local delayed_thread: thread?
    local testing_thread = task.defer(function()
        xpcall(fn, function(e)
            if typeof(e) == "string" then
                if e == "SkipTest" then
                    skipped = true
                    return
                end
            end
            local main = thread
            if not main then
                return
            end
            thread = nil
            time_length = clock_now() - time_length
            if delayed_thread then
                task.cancel(delayed_thread)
            end
            zune.testing.addFailed(1)
            local levels, src, line, count = findTargetTrace()
            print(`{ansi.red}{ansi.bold}FAIL{ansi.reset} {scope} {ansi.dim}[{secondsToMs(time_length)}ms]{ansi.reset}`)
            print(
                `{ansi.red}error{ansi.reset}: {stripSourceFromError(
                    src,
                    line,
                    if typeof(e) == "string" then e else tostring(e)
                )}{ansi.reset}`
            )
            print(zune.debug.dumpStacktrace(levels, count))
            task.spawn(main) -- resume
        end)
        local main = thread
        if not main then
            return
        end
        time_length = clock_now() - time_length
        if delayed_thread then
            task.cancel(delayed_thread)
        end
        thread = nil
        if skipped then
            zune.testing.addSkipped(1)
            print(
                `{ansi.yellow}{ansi.bold}SKIP{ansi.reset} {scope} {ansi.dim}[{secondsToMs(time_length)}ms]{ansi.reset}`
            )
        else
            print(
                `{ansi.green}{ansi.bold}PASS{ansi.reset} {scope} {ansi.dim}[{secondsToMs(time_length)}ms]{ansi.reset}`
            )
        end
        task.spawn(main) -- resume
    end)

    delayed_thread = if (timout >= 0)
        then task.delay(timout, function()
            local main = thread
            if not main then
                return
            end
            time_length = clock_now() - time_length
            thread = nil
            task.cancel(testing_thread)
            print(
                `{ansi.yellow}{ansi.bold}TIMEOUT{ansi.reset} {scope} {ansi.dim}[{secondsToMs(time_length)}ms]{ansi.reset}`
            )
            task.spawn(main) -- resume
        end)
        else nil

    coroutine.yield()

    cleanupAsync()
end

function testing.describe(name: string, fn: (...any) -> ...any): ()
    local thread: thread? = coroutine.running()
    task.spawn(function()
        table.insert(SCOPE_STACK, name)
        local ok = xpcall(fn, function(e)
            local level, src, line, count = findTargetTrace()
            print(
                `{ansi.yellow}{ansi.bold}DESCRIBE ERROR{ansi.reset} describe(\"{name}\", ...): {stripSourceFromError(
                    src,
                    line,
                    if typeof(e) == "string" then e else tostring(e)
                )}`
            )
            print(zune.debug.dumpStacktrace(level, count))
        end)
        table.remove(SCOPE_STACK)
        if not ok then
            zune.testing.addFailed(1)
        end
        if thread and coroutine.status(thread) == "suspended" then
            task.spawn(thread)
        end
        thread = nil
    end)
    if thread then
        coroutine.yield()
    end
end

function testing.test(name: string, fn: () -> (), timeout: number?): ()
    table.insert(TEST_STACK, name)
    runTest(fn, {
        name = name,
        timeout = timeout,
    })
    table.remove(TEST_STACK)
end

function testing.defer(fn: () -> ())
    table.insert(DEFER_QUEUE, fn)
end

--// Conditionals

local function assertExpect(flipped: boolean, value: boolean, fmt: string, ...: any)
    if flipped then
        value = not value
    end
    if not value then
        error(string.format(fmt :: any, ...), 4)
    end
end

local Conditional = {}
Conditional.__index = Conditional

function Conditional.new(name: string, func: (value: any) -> (boolean, string?, string?), any: any?)
    return setmetatable({
        test = func,
        name = name,
        value = any,
    }, Conditional)
end

function Conditional.is(a)
    return type(a) == "table" and getmetatable(a) == Conditional
end

type Conditional = typeof(Conditional.new("", function(_)
    return true, "", ""
end))

function Conditional.__call(self: Conditional, ...)
    return self.test(... :: any)
end

function Conditional.__tostring(self: Conditional)
    return self.name
end

type ConditionState = {
    received: any,
    flipped: boolean,
    shared: { [string]: any },
}

local function flipTag(flipped: boolean)
    return if flipped then "not " else ""
end

local READABLE_CONTROL = {
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
    ["\f"] = "\\f",
    ["\b"] = "\\b",
    ["\a"] = "\\a",
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["%"] = string.format("\\x%02X", 37),
}

local function readable(value: any)
    local t = type(value)
    if t == "string" then
        local safe_value = value:gsub(".", function(char: string)
            local b = char:byte()
            if b < 32 or b > 126 then
                if READABLE_CONTROL[char] then
                    return READABLE_CONTROL[char]
                else
                    return string.format("\\x%02X", b)
                end
            elseif char == "\\" then
                return "\\\\"
            elseif READABLE_CONTROL[char] then
                return READABLE_CONTROL[char]
            end
            return char
        end)
        return `{ansi.green}"{safe_value}"{ansi.reset}`
    elseif t ~= "table" then
        return fmt.format(value)
    else
        return tostring(value)
    end
end

local conditionals = {
    toBe = function(self: ConditionState, expected: any)
        if Conditional.is(expected) then
            local cond, a, s = expected(self.received)
            if s then
                assertExpect(self.flipped, cond, s :: string, flipTag(self.flipped))
            else
                assertExpect(
                    self.flipped,
                    cond,
                    "expected %s to %sbe %s",
                    a or readable(self.received),
                    flipTag(self.flipped),
                    readable(expected)
                )
            end
        else
            assertExpect(
                self.flipped,
                self.received == expected,
                "expected %s to %sbe %s",
                readable(self.received),
                flipTag(self.flipped),
                readable(expected)
            )
        end
    end,
    toBeDefined = function(self: ConditionState)
        assertExpect(
            self.flipped,
            self.received ~= nil,
            "expected %s to %sbe defined",
            readable(self.received),
            flipTag(self.flipped)
        )
    end,
    toBeCloseTo = function(self: ConditionState, expected, precision: number)
        assertExpect(
            self.flipped,
            expected == math.huge and self.received == math.huge
                or expected == -math.huge and self.received == -math.huge
                or math.abs(self.received - expected) < (10 ^ -precision) / 2,
            "expected %s to be close to %s",
            readable(self.received),
            expected
        )
    end,
    toBeGreaterThan = function(self: ConditionState, expected)
        assertExpect(
            self.flipped,
            self.received > expected,
            "expected %s to %sbe greater than %s",
            readable(self.received),
            flipTag(self.flipped),
            readable(expected)
        )
    end,
    toBeGreaterThanOrEqual = function(self: ConditionState, expected)
        assertExpect(
            self.flipped,
            self.received >= expected,
            "expected %s to %sbe greater than or equal to %s",
            readable(self.received),
            flipTag(self.flipped),
            readable(expected)
        )
    end,
    toBeLessThan = function(self: ConditionState, expected)
        assertExpect(
            self.flipped,
            self.received < expected,
            "expected %s to %sbe less than %s",
            readable(self.received),
            flipTag(self.flipped),
            readable(expected)
        )
    end,
    toBeLessThanOrEqual = function(self: ConditionState, expected)
        assertExpect(
            self.flipped,
            self.received <= expected,
            "expected %s to %sbe less than or equal to %s",
            readable(self.received),
            flipTag(self.flipped),
            readable(expected)
        )
    end,
    toBeNil = function(self: ConditionState)
        assertExpect(
            self.flipped,
            self.received == nil,
            "expected %s to %sbe Nil",
            readable(self.received),
            flipTag(self.flipped)
        )
    end,
    toBeNan = function(self: ConditionState)
        assertExpect(
            self.flipped,
            self.received ~= self.received and type(self.received) == "number",
            "expected %s to %sbe NaN",
            readable(self.received),
            flipTag(self.flipped)
        )
    end,
    toHaveLength = function(self: ConditionState, expected)
        assertExpect(
            self.flipped,
            #self.received == expected,
            "expected %s to %shave length %s",
            readable(self.received),
            flipTag(self.flipped),
            readable(expected)
        )
    end,
    toBeFalsy = function(self: ConditionState)
        assertExpect(
            self.flipped,
            not self.received,
            "expected %s to %sbe falsy",
            readable(self.received),
            flipTag(self.flipped)
        )
    end,
    toBeTruthy = function(self: ConditionState)
        assertExpect(
            self.flipped,
            self.received,
            "expected %s to %sbe truthy",
            readable(self.received),
            flipTag(self.flipped)
        )
    end,
    toThrow = function(self: ConditionState, expected: string?)
        assertExpect(
            false,
            type(self.received) == "function",
            "expected %s to %sbe a function",
            readable(self.received),
            flipTag(self.flipped)
        )
        local ok, err = pcall(self.received)
        if expected ~= nil then
            assertExpect(false, type(err) == "string", "expected error to be a string (got %s)", readable(err))
            assertExpect(
                false,
                not ok,
                "expected %s to %sthrow an error",
                readable(self.received),
                flipTag(self.flipped)
            )
            local stripped = err:match(`^.+:%d+: (.+)$`)
            if stripped then
                assertExpect(
                    self.flipped,
                    stripped == expected,
                    "got error %s expected to %sthrow %s",
                    readable(stripped),
                    flipTag(self.flipped),
                    readable(expected)
                )
            else
                assertExpect(
                    self.flipped,
                    err == expected,
                    "got error %s expected to %sthrow %s",
                    readable(err),
                    flipTag(self.flipped),
                    readable(expected)
                )
            end
        else
            assertExpect(
                self.flipped,
                not ok,
                "expected %s to %sthrow an error",
                readable(self.received),
                flipTag(self.flipped)
            )
        end
    end,
}

conditionals.toEqual = conditionals.toBe

type ScanResult = { string }

local function deepScan(a: any, b: any, state: { [any]: any }, key: string?): ScanResult
    if a == b then
        return {}
    end
    if Conditional.is(a) then
        if a.name ~= "@similar" then
            local result, _, reason: string = (a :: any)(b)
            if not result then
                return { `{key or ""}{if reason then string.format(reason :: any, "") else "failed condition"}` }
            end
            return {}
        else
            a = a.value
        end
    end
    if type(a) ~= type(b) then
        return {
            `{key or ""}{ansi.dim}(type: {ansi.reset}{ansi.yellow}{type(b)}{ansi.reset}{ansi.dim}) ~= (type: {ansi.reset}{ansi.yellow}{type(
                a
            )}{ansi.reset}{ansi.dim}){ansi.reset}`,
        }
    end
    if type(a) == "table" then
        if state[a] == b then
            return {}
        end
        state[a] = b
        local chunk = {}
        local keys_hit = {}
        for key, value in a do
            local result = deepScan(
                value,
                b[key],
                state,
                `{ansi.dim}[{ansi.reset}{ansi.green}{readable(key)}{ansi.dim}]: {ansi.reset}`
            )
            if #result > 0 then
                keys_hit[key] = true
            end
            for _, difference in result do
                table.insert(chunk, `    {difference}`)
            end
        end
        for key, value in b do
            local result = deepScan(
                (a :: any)[key],
                value,
                state,
                `{ansi.dim}[{ansi.reset}{ansi.green}{readable(key)}{ansi.dim}]: {ansi.reset}`
            )
            if keys_hit[key] then
                continue
            end
            for _, difference in result do
                table.insert(chunk, `    {difference}`)
            end
        end
        if #chunk > 0 then
            table.insert(chunk, 1, `{key or ""}{ansi.dim}\{{ansi.reset}`)
            table.insert(chunk, `{ansi.dim}\}{ansi.reset}`)
            return chunk
        end
        return {}
    end
    return {
        `{key or ""}{ansi.dim}(value: {ansi.reset}{readable(b)}{ansi.dim}) ~= (expected: {ansi.reset}{readable(a)}{ansi.dim}){ansi.reset}`,
    }
end

local expect = setmetatable({
    nothing = Conditional.new("nothing", function(value)
        return value == nil, nil, nil
    end),
    any = function(typename: string)
        if type(typename) ~= "string" then
            error(`expect.any expected string, got {type(typename)}`, 2)
        end
        return Conditional.new(typename, function(value)
            local t = type(value)
            return t == typename, t, `value is supposed to %sbe of type {typename}, got {t}`
        end)
    end,
    type = function(typename: string)
        if type(typename) ~= "string" then
            error(`expect.type expected string, got {type(typename)}`, 2)
        end
        return Conditional.new(typename, function(value)
            local t = type(value)
            return t == typename, t, `value is supposed to %sbe of type {typename}, got {t}`
        end)
    end,
    similar = function(t: { [any]: any })
        if type(t) ~= "table" then
            error(`expect.type expected string, got {type(t)}`, 2)
        end
        return Conditional.new("@similar", function(value)
            local result = deepScan(t, value, {})
            return #result == 0, nil, `value is supposed to %sbe similar to value, got:\n{table.concat(result, "\n")}`
        end, t)
    end,
}, {
    __call = function(self: any, value: any)
        local obj = {
            never = {},
        }

        local shared_state = {}
        local normal_state = {
            received = value,
            flipped = false,
            shared = shared_state,
        }
        local never_state = {
            received = value,
            flipped = true,
            shared = shared_state,
        }
        for key, func in conditionals :: { [string]: (...any) -> () } do
            obj[key] = function(...)
                func(normal_state, ...)
            end
            obj.never[key] = function(...)
                func(never_state, ...)
            end
        end

        return obj
    end,
})

testing.expect = expect

testing.expected = function(a: any)
    if not a then
        error(string.format("Truthy value expected"), 2)
    end
end

testing.expectEqual = function(a: any, b: any)
    if a ~= b then
        error(string.format("expected %s to be equal to %s", readable(a), readable(b)), 2)
    end
end

testing.complete = function()
    testing.started = false
    return zune.testing.consumeResults()
end

zune.testing.onComplete(function(result)
    local writer = io.createWriter(zune.io.stderr)

    writer:writeAll(`\n {ansi.bold}Tests{ansi.reset}: `)
    if result.failed > 0 then
        writer:writeAll(`{ansi.red}{result.failed} failed{ansi.reset}, `)
    end
    if result.skipped > 0 then
        writer:writeAll(`{ansi.yellow}{result.skipped} skipped{ansi.reset}, `)
    end
    writer:writeAll(`{result.total} total\n`)
    writer:writeAll(` {ansi.bold}Time{ansi.reset}: {math.ceil((result.finish - result.start) * 1000) // 1000} s\n`)

    return true -- let zune handle the rest (exit code)
end)

return testing
