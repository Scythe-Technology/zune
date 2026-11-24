--!strict
--!optimize 2

local io = require("@zune/io")
local text = require("@zune/text")
local tui = require("@zune/tui")
local spec = require("@zune/spec")

local ansi = require("@zune/ansi").sequences

local package = require("@zune/package")

local pkg_tui = {}

local SIZE_W = 10
local SPEED_W = 12
local ETA_W = 6
local PERCENT_W = 4
local BAR_MIN = 5

type Row = {
    name: string,
    got: number,
    total: number?,
    started: number,
    done: number?,
    known: number?,
}

local function etaText(got: number, total: number?, speed: number): string
    if not total or total <= 0 or speed <= 0 then
        return "--"
    end
    return text.time(math.max(total - got, 0) / speed)
end

local function percentText(got: number, total: number?): string
    if not total or total <= 0 then
        return "--"
    end
    return `{math.clamp(math.floor(got / total * 100 + 0.5), 0, 100)}%`
end

local function labelFor(row: Row): string
    if row.done ~= nil and row.known ~= nil then
        return `{row.done}/{row.known}`
    end
    return row.name
end

local function barText(got: number, total: number?, width: number): string
    local inner = width - 2
    if inner < 1 then
        inner = 1
    end
    if not total or total <= 0 then
        return `[{string.rep(" ", inner)}]`
    end
    local fraction = got / total
    if fraction >= 1 then
        return `[{string.rep("-", inner)}]`
    end
    local head = math.clamp(math.floor(fraction * inner), 0, inner - 1)
    return `[{string.rep("-", head)}>{string.rep(" ", inner - head - 1)}]`
end

local function termColumns(): number
    local ok, width = pcall(io.terminal.getSize)
    if ok and spec.number(width) and (width :: number) >= 40 then
        return width :: number
    end
    return 80
end

function pkg_tui.reporter(): package.Reporter
    local tty = io.terminal.isTty()
    local rows: { Row } = {}
    local by_name: { [string]: Row } = {}
    local drawn = 0
    local name_width = 0
    local last_paint = 0
    local writer = io.createWriter(io.stdout)

    local function lineFor(row: Row, now: number): string
        local shown = if row.total and row.total > 0 then row.total else row.got
        local elapsed = (now - row.started) / 1000
        local speed = if elapsed >= 0.2 and row.got > 0 then row.got / elapsed else 0
        local speed_text = if speed > 0 then `{text.bytes(speed)}/s` else "--"
        local columns = termColumns()
        local budget = math.max(columns - 40, BAR_MIN + 1)
        local label_width = math.clamp(name_width, 1, budget - BAR_MIN)
        local bar_width = math.clamp(budget - label_width, BAR_MIN, 40)
        local label = text.pad(text.fit(labelFor(row), label_width), label_width)
        local main = row.done ~= nil and row.known ~= nil
        local bar = barText(row.got, row.total, bar_width)
        local line =
            `  {label}  {text.pad(text.bytes(shown), SIZE_W, "right")} {text.pad(speed_text, SPEED_W, "right")} {text.pad(
                etaText(row.got, row.total, speed),
                ETA_W,
                "right"
            )} {bar} {text.pad(percentText(row.got, row.total), PERCENT_W, "right")}`
        if main then
            return line
        end
        return ansi.paint(ansi.dim, line)
    end

    local dirty = false
    local frame: thread? = nil
    local log_lines: { string } = {}

    local function flush()
        local pending = frame
        frame = nil
        if pending then
            pcall(zune.task.cancel, pending)
        end
        dirty = false
        if not tty then
            for _, text in log_lines do
                print(text)
            end
            table.clear(log_lines)
            return
        end
        local now = zune.time.timestampMillis()
        last_paint = now
        local parts: { string } = {}
        if drawn > 0 then
            table.insert(parts, ansi.cursorMove("up", drawn))
            table.insert(parts, "\r")
        end
        for _, text in log_lines do
            table.insert(parts, `{ansi.erase("entire_line")}\r{text}\n`)
        end
        local logged = #log_lines
        table.clear(log_lines)
        for _, row in rows do
            table.insert(parts, `{ansi.erase("entire_line")}\r{lineFor(row, now)}\n`)
        end
        local count = #rows
        local extra = drawn - logged - count
        if extra > 0 then
            for i = 1, extra do
                table.insert(parts, `{ansi.erase("entire_line")}\r`)
                if i < extra then
                    table.insert(parts, "\n")
                end
            end
            if extra > 1 then
                table.insert(parts, ansi.cursorMove("up", extra - 1))
            end
        end
        drawn = count
        if #parts > 0 then
            writer:writeAll(table.concat(parts))
        end
    end

    local function schedule(soon: boolean)
        if not tty then
            return
        end
        dirty = true
        if frame then
            return
        end
        local function run()
            frame = nil
            if dirty then
                flush()
            end
        end
        local wait = 0.08 - (zune.time.timestampMillis() - last_paint) / 1000
        if soon or wait <= 0 then
            frame = zune.task.defer(run)
        else
            frame = zune.task.delay(wait, run)
        end
    end

    local reporter = {} :: package.Reporter

    function reporter.message(_self: package.Reporter, text: string, name: string?)
        local retired: Row? = nil
        if name then
            retired = by_name[name]
            for index, row in rows do
                if row.name == name then
                    table.remove(rows, index)
                    by_name[name] = nil
                    break
                end
            end
        end
        if text == "" and retired and retired.done == nil and retired.known == nil then
            text = lineFor(retired, zune.time.timestampMillis())
        end
        if text ~= "" or not name then
            table.insert(log_lines, text)
        end
        flush()
    end

    function reporter.confirm(self: package.Reporter, prompt: string, msg: string?): boolean
        if msg then
            self:message(msg)
        end
        table.clear(rows)
        table.clear(by_name)
        name_width = 0
        flush()
        return tui.ask(prompt, { "Y", "n" }) == "Y"
    end

    function reporter.progress(
        _self: package.Reporter,
        name: string,
        got: number,
        total: number?,
        done: number?,
        known: number?
    )
        local row = by_name[name]
        local created = false
        local counts_changed = false
        if not row then
            created = true
            row = {
                name = name,
                got = got,
                total = total,
                started = zune.time.timestampMillis(),
                done = done,
                known = known,
            }
            by_name[name] = row
            local at = #rows + 1
            if row.done == nil and row.known == nil then
                for index, live in rows do
                    if live.done ~= nil and live.known ~= nil then
                        at = index
                        break
                    end
                end
            end
            table.insert(rows, at, row)
        else
            row.got = got
            if total then
                row.total = total
            end
            if done ~= nil and row.done ~= done then
                row.done = done
                counts_changed = true
            end
            if known ~= nil and row.known ~= known then
                row.known = known
                counts_changed = true
            end
        end
        local label = labelFor(row)
        if #label > name_width then
            name_width = #label
        end
        schedule(created or counts_changed)
    end

    return reporter
end

return pkg_tui
