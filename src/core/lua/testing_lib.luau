--!strict
local io = zune.io;
local task = zune.task;

local GLOBAL = getfenv();

local DECLARE_SAFEENV = GLOBAL.declare_safeEnv :: () -> ();
local SCHEDULER_DROPTASKS = GLOBAL.scheduler_droptasks :: () -> ();
local STEPCHECK_REFERENCES = GLOBAL.stepcheck_references :: (scope: string) -> ();

DECLARE_SAFEENV();

type TestInfo = {
    Name: string?,
    Timeout: number?,
};

type FileContext = {
    name: string,
    source: string,
};

type StackTraceInfo = {
    file: FileContext,
    name: string,
    line: number,
    address: string,
};

local testing = {};

testing.running = true;

-- INTERNAL USE
testing._failed = 0;
testing._count = 0;
testing._start = nil::number?;

local DEFER_QUEUE = {}::{()->()};
local SCOPE_STACK = {}::{string};
local TEST_STACK = {}::{string};

local useColor = (zune.process.env["NO_COLOR"] == nil or zune.process.env["NO_COLOR"] == "0");

local RESET = if (useColor) then "\27[0m" else "";

local DIM = if (useColor) then "\27[2m" else "";
local BOLD = if (useColor) then "\27[1m" else "";
local UNDERLINE = if (useColor) then "\27[4m" else "";

local WHITE = if (useColor) then "\27[37m" else "";
local RED = if (useColor) then "\27[31m" else "";
local BLUE = if (useColor) then "\27[34m" else "";
local GREEN = if (useColor) then "\27[32m" else "";
local YELLOW = if (useColor) then "\27[33m" else "";

function paddedNumber(line: number, longest: number, padding: string): string
    return `{line}{string.rep(padding, longest - #tostring(line))}`
end

function printPreviewLine(
    source_lines: {string},
    line: number,
    longest: number,
    dim: boolean
)
    if (source_lines[line] == nil) then
        return
    end
    local style = if (dim) then DIM else BOLD;
    local color = if (dim) then WHITE else BLUE;
    print(` {style}{color}{paddedNumber(line, longest, " ")} | {source_lines[line]}{RESET}`);
end

local function nonEmptyString(v : any?) : boolean
    return type(v) == "string" and #v > 1;
end

local function writeStackTrace(file: FileContext, name: string, line: number, address: string): StackTraceInfo
    return {
        file = file,
        name = name,
        line = line,
        address = address,
    };
end

local function secondstoMs(seconds : number) : number
    return (seconds * 1000) // 1;
end

local function runTest(fn: () -> (), info: TestInfo)
    testing._count += 1;
    if (not testing._start) then
        testing._start = os.clock();
    end

    local ok, err;
    local stacktrace = {};
    local timeLength = os.clock();
    local thread: thread? = coroutine.running();
    local timout = info.Timeout or -1;

    local delayedThread = if (timout >= 0) then task.delay(timout, function()
        local main = thread;
        if (not main) then
            return;
        end
        timeLength = os.clock() - timeLength;
        thread = nil;
        err = `Timeout in {timout} seconds`;
        task.spawn(main); -- resume
    end) else nil;

    task.defer(function()
        ok = xpcall(fn, function(e)
            local main = thread;
            if (not main) then
                return;
            end
            timeLength = os.clock() - timeLength;
            if (delayedThread) then
                task.cancel(delayedThread);
            end
            thread = nil;
            local lastN = debug.info(1, "n");
            for i = 1, 30 do
                local f, n, l, s = debug.info(i + 1, "fnls");
                if (not f) then
                    break;
                end
                local ln = lastN;
                if (#stacktrace > 0 or nonEmptyString(n)) then
                    lastN = n;
                end
                if (l < 0) then
                    continue;
                end
                local context = getfenv(f);
                local file = context._FILE;
                if (type(file) ~= "table") then
                    continue;
                end
                local copy = table.clone(file);
                copy.name = s;
                table.insert(
                    stacktrace,
                    writeStackTrace(copy, ln::string, l, tostring(f))
                );
            end
            err = e;
            task.spawn(main); -- resume
        end)
        local main = thread;
        if (not main) then
            return;
        end
        if (ok) then
            timeLength = os.clock() - timeLength;
            if (delayedThread) then
                task.cancel(delayedThread);
            end
            thread = nil;
            task.spawn(main); -- resume
        end
    end)
    coroutine.yield();
    timeLength = secondstoMs(timeLength);

    local scopePadded = if (#SCOPE_STACK > 0) then " " else '';
    local scope = `{DIM}{scopePadded}{table.concat(SCOPE_STACK, "/")}{RESET}`;
    scope ..= ` ({BOLD}{info.Name}{RESET})`;

    for i = #DEFER_QUEUE, 1, -1 do
        local v = DEFER_QUEUE[i];
        local success, result: any = pcall(v);
        if (not success) then
            print(`{YELLOW}Deferred function failed:{RESET}\n    {RED}{result}{RESET}`);
        end
    end
    table.clear(DEFER_QUEUE);

    if (task.count() > 0 and ok) then
        local rest = os.clock() + (timout - timeLength);
        while true do
            if (timout >= 0) then
                if (os.clock() > rest) then
                    break;
                end
            end
            if (task.count() > 0) then
                task.wait()
            else
                break;
            end
        end
    end

    STEPCHECK_REFERENCES(` -- {scope}`);

    local test_root = #TEST_STACK == 1;
    local type = if (ok) then "PASS" else "FAIL";
    local color = if (ok) then GREEN else RED;
    local leaked = test_root and task.count() > 0;

    if (ok) then
        if (leaked) then
            color = YELLOW;
            type = "WARN";
        end
    end

    print(`{color}{BOLD}{type}{RESET}{scope} {DIM}[{timeLength}ms]{RESET}`);

    if (ok) then
        if (leaked) then
            print(` {DIM}|{RESET}{YELLOW} Test Running Tasks Timedout (Possible Leak){RESET}`);
            print(` {DIM}|    This message is just a warning, but should be noted, that the test has active tasks{RESET}`);
            print(` {DIM}|    in the scheduler for more than {timout} seconds.{RESET}`);
            print(` {DIM}|{RESET}`);
            local s, d, w, t = task.count("sdwt");
            local show = {};
            if (s > 0) then
                print(` {DIM}|    "Sleeping" - (zune luau),{RESET}`);
                print(` {DIM}|      Active luau task, usually means there is a running task created by luau or zune.{RESET}`);
                print(` {DIM}|      Caused when a sleeping task is still in queue.{RESET}`);
                table.insert(show, `Sleeping Tasks: {YELLOW}{s}{RESET}`);
            end
            if (d > 0) then
                print(` {DIM}|    "Deferred" - (zune luau),{RESET}`);
                print(` {DIM}|      Active luau task, usually means there is a running task created by luau or zune.{RESET}`);
                print(` {DIM}|      Caused when a deferred task is still in queue.{RESET}`);
                table.insert(show, `Deferred Tasks: {YELLOW}{d}{RESET}`);
            end
            if (w > 0) then
                print(` {DIM}|    "Awaiting" - (zune backend),{RESET}`);
                print(` {DIM}|      Active zune awaiting task, usually means there is a running task created by the zune backend.{RESET}`);
                print(` {DIM}|      Caused by a the zune backend waiting for a response from luau{RESET}`);
                table.insert(show, `Awaiting Tasks: {YELLOW}{w}{RESET}`);
            end
            if (t > 0) then
                print(` {DIM}|    "Internal" - (zune backend){RESET}`);
                print(` {DIM}|      Active zune core task, usually means there is a running task created by the zune backend.{RESET}`);
                print(` {DIM}|      Caused by undisposed backend tasks.{RESET}`);
                table.insert(show, `Internal Tasks: {YELLOW}{t}{RESET}`);
            end
            print(` {DIM}|`);
            print(` {DIM}|    If this is a bug, please report it!{RESET}`);
            print(` {DIM}|{RESET}    {BLUE}All tasks has been dropped{RESET}`);
            for _, v in show do
                print(` {DIM}|{RESET}  {v}`);
            end
        end
    else
        testing._failed += 1;
        print(`{RED}error{RESET}: {err}{RESET}`);

        for stack, v in stacktrace do
            local contents = v.file.source;
            local lineNumber = v.line;
            local lines = contents:split("\n");
            local possible_lines = {}
            for i = -1, 1 do
                table.insert(possible_lines, #tostring(lineNumber + i))
            end
            local bigLineLen = math.max(unpack(possible_lines))
    
            local line = lines[v.line];
            local safeLine = line:gsub("\t", "    ");
            local indent : number = #(string.match(safeLine, "^(%s*)") or "");
            local column = #(string.match(line, "^(%s*)") or "");
            local nameHasValue = nonEmptyString(v.name);
            if (nameHasValue and v.name) then
                local start = safeLine:find(v.name, 1, true);
                if (start) then
                    local subColumn = line:find(v.name, 1, true);
                    if (subColumn) then
                        column = subColumn;
                        indent = (start - 1) or indent;
                    end
                end
            end

            print(`{BOLD}{UNDERLINE}{v.file.name}:{v.line}:{column}:{RESET} {DIM}{v.address:sub(11)}{nameHasValue and ` called {v.name}` or ""}{RESET}`);
            printPreviewLine(lines, v.line - 1, bigLineLen, true);
            printPreviewLine(lines, v.line, bigLineLen, false);
            printPreviewLine(lines, v.line + 1, bigLineLen, true);
        end
    end

    if (leaked) then
        SCHEDULER_DROPTASKS();
    end

    DECLARE_SAFEENV();
end

function testing.describe(
    name: string,
    fn: (...any) -> ...any
): ()
    local line = debug.info(2, "l");
    table.insert(SCOPE_STACK, name);
    local ok, err = pcall(fn::any);
    table.remove(SCOPE_STACK);
    if (not ok) then
        testing._failed += 1;
        print(`{YELLOW}{line}: describe(\"{name}\", ...):{RESET}`);
        print(`   {RED}{err}{RESET}`);
    end
end

function testing.test(
    name: string,
    fn: (...any) -> ...any,
    timeout: number?
): ()
    table.insert(TEST_STACK, name);
    runTest(fn, {
        Name = name,
        Timeout = timeout,
    });
    table.remove(TEST_STACK);
end

function testing.defer(fn: () -> ())
    table.insert(DEFER_QUEUE, fn);
end

--// Conditionals

local function assertExpect(flipped : boolean, value : boolean, fmt : string, ... : any)
    if (flipped) then
        value = not value;
    end
    if (not value) then
        error(string.format(fmt, ...), 4);
    end
end


local Conditional = {};
Conditional.__index = Conditional;

function Conditional.new(name : string, func : (value : any) -> (boolean, string?), any: any?)
    return setmetatable({
        test = func,
        name = name,
        value = any,
    }, Conditional);
end

function Conditional.is(a)
    return type(a) == "table" and getmetatable(a) == Conditional;
end

type Conditional = typeof(Conditional.new("", function(_) return true, "" end));

function Conditional.__call(self : Conditional, ...)
    return self.test(...);
end

function Conditional.__tostring(self : Conditional)
    return self.name;
end

type ConditionState = {
    received : any,
    flipped : boolean,
    shared : {[string] : any},
};

local function flipTag(flipped : boolean)
    return if (flipped) then "not " else ""
end

local READABLE_CONTROL = {
    ['\n'] = "\\n";
    ['\r'] = "\\r";
    ['\t'] = "\\t";
    ['\v'] = "\\v";
    ['\f'] = "\\f";
    ['\b'] = "\\b";
    ['\a'] = "\\a";
    ['\\'] = "\\\\";
    ['"'] = "\\\"";
    ['%'] = string.format("\\x%02X", 37);
};

local function readable(value : any)
    local t = type(value);
    if (t == "string") then
        local safeValue = value:gsub(".", function(char : string)
            local b = char:byte();
            if (b < 32 or b > 126) then
                if (READABLE_CONTROL[char]) then
                    return READABLE_CONTROL[char];
                else
                    return string.format("\\x%02X", b);
                end
            elseif (char == "\\") then
                return "\\\\";
            elseif (READABLE_CONTROL[char]) then
                return READABLE_CONTROL[char];
            end
            return char;
        end)
        return `{GREEN}"{safeValue}"{RESET}`;
    elseif (t ~= "table") then
        return io.format(value);
    else
        return tostring(value);
    end
end

local conditionals = {
    toBe = function(self : ConditionState, expected : any)
        if (Conditional.is(expected)) then
            local cond, a, s = expected(self.received);
            if (s) then
                assertExpect(self.flipped, cond, s, flipTag(self.flipped));
            else
                assertExpect(self.flipped, cond, "Expected %s to %sbe %s", a or readable(self.received), flipTag(self.flipped), readable(expected));
            end
        else 
            assertExpect(self.flipped, self.received == expected, "Expected %s to %sbe %s", readable(self.received), flipTag(self.flipped), readable(expected));
        end
    end,
    toBeDefined = function(self : ConditionState)
        assertExpect(self.flipped, self.received ~= nil, "Expected %s to %sbe defined", readable(self.received), flipTag(self.flipped));
    end,
    toBeCloseTo = function(self : ConditionState, expected, precision: number)
        assertExpect(self.flipped, 
            expected == math.huge and self.received == math.huge
            or expected == -math.huge and self.received == -math.huge
            or math.abs(self.received - expected) < (10 ^ -precision)/2
        , "Expected %s to be close to %s", readable(self.received), expected);
    end,
    toBeGreaterThan = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received > expected, "Expected %s to %sbe greater than %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeGreaterThanOrEqual = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received >= expected, "Expected %s to %sbe greater than or equal to %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeLessThan = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received < expected, "Expected %s to %sbe less than %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeLessThanOrEqual = function(self : ConditionState, expected)
        assertExpect(self.flipped, self.received <= expected, "Expected %s to %sbe less than or equal to %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeNil = function(self : ConditionState)
        assertExpect(self.flipped, self.received == nil, "Expected %s to %sbe Nil", readable(self.received), flipTag(self.flipped));
    end,
    toBeNan = function(self : ConditionState)
        assertExpect(self.flipped, self.received ~= self.received and type(self.received) == "number", "Expected %s to %sbe NaN", readable(self.received), flipTag(self.flipped));
    end,
    toHaveLength = function(self : ConditionState, expected)
        assertExpect(self.flipped, #self.received == expected, "Expected %s to %shave length %s", readable(self.received), flipTag(self.flipped), readable(expected));
    end,
    toBeFalsy = function(self : ConditionState)
        assertExpect(self.flipped, not self.received, "Expected %s to %sbe falsy", readable(self.received), flipTag(self.flipped));
    end,
    toBeTruthy = function(self : ConditionState)
        assertExpect(self.flipped, self.received, "Expected %s to %sbe truthy", readable(self.received), flipTag(self.flipped));
    end,
    toThrow = function(self : ConditionState, expected : string?)
        assertExpect(false, type(self.received) == "function", "Expected %s to %sbe a function", readable(self.received), flipTag(self.flipped));
        local success, err = pcall(self.received);
        if (expected ~= nil) then
            assertExpect(false, type(err) == "string", "Expected error to be a string (got %s)", readable(err));
            assertExpect(false, not success, "Expected %s to %sthrow an error", readable(self.received), flipTag(self.flipped));
            local stripped = err:match(`^.+:%d+: (.+)$`);
            if (stripped) then
                assertExpect(self.flipped, stripped == expected, "Got error %s expected to %sthrow %s", readable(stripped), flipTag(self.flipped), readable(expected));
            else
                assertExpect(self.flipped, err == expected, "Got error %s expected to %sthrow %s", readable(err), flipTag(self.flipped), readable(expected));
            end
        else
            assertExpect(self.flipped, not success, "Expected %s to %sthrow an error", readable(self.received), flipTag(self.flipped));
        end
    end,
};

conditionals.toEqual = conditionals.toBe;

type ScanResult = {string};

local function deepScan(a : any, b : any, state : {[any] : any}, key: string?) : ScanResult
    if (a == b) then
        return {};
    end
    if (Conditional.is(a)) then
        if (a.name ~= "@similar") then
            local result, _, reason = a(b);
            if (not result) then
                return {`{key or ''}{if (reason) then string.format(reason, "") else "failed condition"}`};
            end
            return {}
        else
            a = a.value;
        end
    end
    if (type(a) ~= type(b)) then
        return {`{key or ''}{DIM}(type: {RESET}{YELLOW}{type(b)}{RESET}{DIM}) ~= (type: {RESET}{YELLOW}{type(a)}{RESET}{DIM}){RESET}`};
    end
    if (type(a) == "table") then
        if (state[a] == b) then
            return {};
        end
        state[a] = b;
        local chunk = {};
        local keys_hit = {};
        for key, value in a do
            local result = deepScan(value, b[key], state, `{DIM}[{RESET}{GREEN}{readable(key)}{DIM}]: {RESET}`);
            if (#result > 0) then
                keys_hit[key] = true;
            end
            for _, difference in result do
                table.insert(chunk, `    {difference}`);
            end
        end
        for key, value in b do
            local result = deepScan(a[key], value, state, `{DIM}[{RESET}{GREEN}{readable(key)}{DIM}]: {RESET}`);
            if (keys_hit[key]) then
                continue;
            end
            for _, difference in result do
                table.insert(chunk, `    {difference}`);
            end
        end
        if (#chunk > 0) then
            table.insert(chunk, 1, `{key or ''}{DIM}\{{RESET}`);
            table.insert(chunk, `{DIM}\}{RESET}`);
            return chunk;
        end
        return {};
    end
    return {`{key or ''}{DIM}(value: {RESET}{readable(b)}{DIM}) ~= (expected: {RESET}{readable(a)}{DIM}){RESET}`};
end

local expect = setmetatable({
    nothing = Conditional.new("nothing", function(value)
        return value == nil;
    end),
    any = function(typename : string)
        if (type(typename) ~= "string") then
            error(`expect.any expected string, got {type(typename)}`, 2);
        end
        return Conditional.new(typename, function(value)
            local t = type(value);
            return t == typename, t, `value is supposed to %sbe of type {typename}, got {t}`;
        end)
    end,
    type = function(typename : string)
        if (type(typename) ~= "string") then
            error(`expect.type expected string, got {type(typename)}`, 2);
        end
        return Conditional.new(typename, function(value)
            local t = type(value);
            return t == typename, t, `value is supposed to %sbe of type {typename}, got {t}`;
        end)
    end,
    similar = function(t : {[any]: any})
        if (type(t) ~= "table") then
            error(`expect.type expected string, got {type(t)}`, 2);
        end
        return Conditional.new("@similar", function(value)
            local result = deepScan(t, value, {});
            return #result == 0, nil, `value is supposed to %sbe similar to value, got:\n{table.concat(result, "\n")}`;
            -- return result, nil, `value is supposed to %sbe similar to specified table\n\n<table>{reason}`;
        end, t)
    end
}, {
    __call = function(self: any, value: any)
        local obj = {
            never = {},
        };

        local sharedState = {};
        local normalState = {
            received = value,
            flipped = false,
            shared = sharedState,
        };
        local neverState = {
            received = value,
            flipped = true,
            shared = sharedState,
        };
        for key, func in conditionals::{[string] : (...any) -> ()} do
            obj[key] = function(...)
                func(normalState, ...);
            end
            obj.never[key] = function(...)
                func(neverState, ...);
            end
        end

        return obj;
    end
});

testing.expect = expect;

testing.expected = function(a : any)
    if (not a) then
        error(string.format("Truthy value expected"), 2);
    end
end

testing.expectEqual = function(a : any, b : any)
    if (a ~= b) then
        error(string.format("Expected %s to be equal to %s", readable(a), readable(b)), 2);
    end
end

return testing;
