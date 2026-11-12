--!strict

assert(zune, "zune is not defined")

local success, err = pcall(function()
    zune.fs = {} :: any
end)
assert(not success, "zune should be readonly")
assert((err :: string):find("readonly"), "zune should be readonly")

local task = zune.task
local luau = zune.luau
local process = zune.process

local io = require("./lib/std/io")
local fs = require("./lib/std/fs")

local cwd = io.cwd()

local filter = process.args[2] or ""

local failed = false
local count = 0

local PARALLEL = process.env.PARALLEL_TEST == "1"
local TUI = process.env.TUI == "1"
local TEMP_PATH = ".zig-cache/tmp/ZUNE"

local USE_COLORS = zune.fmt.useColors()

local RESET = if USE_COLORS then "\27[0m" else ""

local DIM = if USE_COLORS then "\27[2m" else ""
local BOLD = if USE_COLORS then "\27[1m" else ""

local RED = if USE_COLORS then "\27[31m" else ""
local GREEN = if USE_COLORS then "\27[32m" else ""

local parallel_tests: { Worker } = {}
local main_thread = coroutine.running()
local should_resume = false

type Worker = {
    file: string,
    done: boolean,
    ready: boolean,
    failed: boolean,
    output: BufferArray?,
}

local function countRunningParallel(ready: boolean?)
    local count = 0
    for _, worker in parallel_tests do
        if not worker.done and (ready == nil or worker.ready == ready) then
            count += 1
        end
    end
    return count
end

local function runTest(path: string, args: { string }?)
    if #filter > 0 and not path:find(`/{filter}`, nil, true) then
        return
    end
    local RUN_TEMP_PATH = `{TEMP_PATH}_{count}`
    count += 1
    if fs.statFile(cwd, RUN_TEMP_PATH).kind == "directory" then
        fs.deleteDir(RUN_TEMP_PATH, true)
    end
    cwd:createDir(RUN_TEMP_PATH)

    local env = {
        HOME = process.env.HOME,
        USERPROFILE = process.env.USERPROFILE,
        NO_COLOR = process.env.NO_COLOR,
        TEMP_PATH = RUN_TEMP_PATH,
        PATH = process.env.PATH,
        SystemRoot = process.env.SystemRoot, -- windows
    }

    if PARALLEL then
        local child = process.create(process.getExePath(), { "run", path, unpack(args or {}) }, {
            stderr = "pipe",
            stdout = "pipe",
            env = env,
        })
        local worker: Worker = {
            file = path,
            done = false,
            ready = false,
            failed = false,
            output = nil,
        }
        table.insert(parallel_tests, worker)
        task.spawn(function()
            do
                local output = io.createBufferArray()
                local waiting_buffer = { true, true }
                local thread = coroutine.running()
                local should_resume = false
                task.spawn(function()
                    local chunk = buffer.create(1024)
                    local stdout = child.stdout
                    assert(stdout)
                    while true do
                        local amt = stdout:read(chunk)
                        if amt == 0 then
                            break
                        end
                        output:write(chunk, 0, amt)
                    end
                    if waiting_buffer[1] then
                        waiting_buffer[1] = false
                        if should_resume and not waiting_buffer[2] then
                            should_resume = false
                            task.spawn(thread)
                        end
                    end
                end)
                task.spawn(function()
                    local chunk = buffer.create(1024)
                    local stderr = child.stderr
                    assert(stderr)
                    while true do
                        local amt = stderr:read(chunk)
                        if amt == 0 then
                            break
                        end
                        output:write(chunk, 0, amt)
                    end
                    if waiting_buffer[2] then
                        waiting_buffer[2] = false
                        if should_resume and not waiting_buffer[2] then
                            should_resume = false
                            task.spawn(thread)
                        end
                    end
                end)
                local res = child:wait()
                worker.done = true
                if not res.ok then
                    failed = true
                    worker.failed = true
                end
                if waiting_buffer[1] or waiting_buffer[2] then
                    should_resume = true
                    coroutine.yield()
                end
                worker.ready = true
                worker.output = output
            end
            if countRunningParallel() == 0 and should_resume then
                task.spawn(main_thread)
            end
        end)
    else
        local res = process.run(process.getExePath(), { "run", path, unpack(args or {}) }, {
            stderr = "inherit",
            stdout = "inherit",
            env = env,
        })
        if not res.ok then
            failed = true
        end
    end
end

runTest("./test/lib/std/init.luau")

runTest("./test/engine/require.test.luau")

runTest("./test/standard/c/init.luau")
runTest("./test/standard/crypto/init.luau")
runTest("./test/standard/luau/init.test.luau")
runTest("./test/standard/net/init.luau")
runTest("./test/standard/require/init.luau")
runTest("./test/standard/serde/init.luau")
runTest("./test/standard/thread/init.luau")

runTest("./test/standard/ascii.test.luau")
runTest("./test/standard/debug.test.luau")
runTest("./test/standard/fs.test.luau")
runTest("./test/standard/fmt.test.luau")
runTest("./test/standard/gpio.test.luau")
runTest("./test/standard/io.test.luau")
runTest("./test/standard/mem.test.luau")
runTest("./test/standard/platform.test.luau")
runTest("./test/standard/process.test.luau", { "Test", "someValue" })
runTest("./test/standard/random.test.luau")
runTest("./test/standard/regex.test.luau")
runTest("./test/standard/task.test.luau")
runTest("./test/standard/testing.test.luau")
runTest("./test/standard/time.test.luau")

if PARALLEL then
    local running_tui = false
    if TUI then
        task.spawn(function()
            if not io.terminal.isTty() then
                error("not a terminal")
            end

            if not io.terminal.enableRawMode() then
                error("failed to enable raw mode")
            end

            running_tui = true

            local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
            local spinner_index = 1

            local lines = 0
            process.onSignal("INT", function()
                io.stdout:write(`\x1b[?25h`)
                process.exit(0)
            end)
            io.stdout:write(`\x1b[?25l`)
            while running_tui or lines > 0 do
                if lines > 0 then
                    io.stdout:write(`\x1b[{lines}A`)
                    if not running_tui then
                        break
                    end
                end
                lines = 0
                for _, worker in parallel_tests do
                    if not worker.done and not worker.ready then
                        io.stderr:write(`\x1b[1K{spinner[spinner_index]} {BOLD}{worker.file or ""}{RESET}\n`)
                    else
                        if worker.failed then
                            io.stderr:write(`\x1b[1K{RED}✗{RESET} {DIM}{worker.file or ""}{RESET}\n`)
                        else
                            io.stderr:write(`\x1b[1K{GREEN}✓{RESET} {DIM}{worker.file or ""}{RESET}\n`)
                        end
                    end
                    lines += 1
                end

                spinner_index %= #spinner
                spinner_index += 1
                task.wait(1 / 24)
            end

            io.stdout:write(`\x1b[?25h`)
            task.spawn(main_thread)
        end)
    end

    if countRunningParallel() > 0 then
        should_resume = true
        coroutine.yield()
    end

    if running_tui then
        running_tui = false
        coroutine.yield()
    end

    local stderr_writer = io.createWriter(io.stderr)
    for _, worker in parallel_tests do
        assert(worker.output, "unreachable")
        if worker.failed then
            local reader = io.createReader(worker.output, { positional = true })
            reader:pipe(stderr_writer)
        end
    end
    if failed then
        io.stderr:write(`\x1b[1K\n`)
    end
    for _, worker in parallel_tests do
        if worker.failed then
            io.stderr:write(`\x1b[1K{RED}✗{RESET} {DIM}{worker.file or ""}{RESET}\n`)
        else
            io.stderr:write(`\x1b[1K{GREEN}✓{RESET} {DIM}{worker.file or ""}{RESET}\n`)
        end
    end
end

if failed then
    process.exit(1)
end
