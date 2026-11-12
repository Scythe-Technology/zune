--!strict
--!native
--!optimize 2

local io = zune.io
local task = zune.task

local ansi = require("./ansi").auto()

local tui = {}

local function moveLeft(amount: number?)
    return `\x1b[{amount or ""}D`
end
local function moveRight(amount: number?)
    return `\x1b[{amount or ""}C`
end
local function moveUp(amount: number?)
    return `\x1b[{amount or ""}A`
end
local function moveDown(amount: number?)
    return `\x1b[{amount or ""}B`
end
local function moveToColumn(position: number)
    return `\x1b[{position}G`
end
local CLEAR_FROM_CURSOR = "\x1b[0J"

type PromptFn =
    & ((kind: "text"?, message: string) -> string)
    & ((kind: "confirm", message: string) -> boolean)
    & ((kind: "select", message: string, options: { string }) -> number)
    & ((kind: "multiselect", message: string, options: { string }) -> { number })

local function prompt(
    kind: ("text" | "confirm" | "select" | "multiselect")?,
    message: string,
    options: { string }
): string | boolean | number | { number }
    kind = kind or "text"
    if not io.terminal.isTty() then
        error("Not a terminal")
    end

    local is_raw = io.terminal.getCurrentMode() == "raw"
    if not is_raw then
        if not io.terminal.enableRawMode() then
            error("Failed to enable raw mode")
        end
    end

    io.stderr:write(`{ansi.paint(ansi.yellow, "?")} {ansi.paint(ansi.bold, message)}`)

    local input = ""
    local order = 0
    local selection = {}
    if kind == "select" or kind == "multiselect" then
        assert(options, "Options are required for select and multiselect")
        assert(#options > 0, "Options cannot be empty")
        for i = 1, #options do
            assert(type(options[i]) == "string", "Option must be strings")
            selection[i] = false
        end
        for i = 1, #options do
            local option = options[i]
            if kind == "select" then
                io.stderr:write(
                    `\n {if i == 1 then ansi.paint(ansi.green, ">") else " "} {ansi.paint(ansi.bold, option)}`
                )
            elseif kind == "multiselect" then
                io.stderr:write(
                    `\n {if i == 1 then ansi.paint(ansi.green, "[ ]") else ansi.paint(ansi.dim, "[ ]")} {ansi.paint(
                        ansi.bold,
                        option
                    )}`
                )
            end
        end
        io.stderr:write(moveUp(#options - 1))
        io.stderr:write(moveToColumn(0))
        order = 1
    elseif kind == "confirm" then
        io.stderr:write(` {ansi.paint(ansi.dim, "(y/n)")} › `)
    elseif kind == "text" then
        io.stderr:write(" › ")
    end

    local function renderSelection(id: number, hovered: boolean)
        if kind == "select" then
            io.stderr:write(`{moveToColumn(0)}\x1b[2K`)
            io.stderr:write(
                ` {if hovered then ansi.paint(ansi.green, ">") else " "} {ansi.paint(ansi.bold, options[id])}`
            )
        else
            io.stderr:write(`{moveToColumn(0)}\x1b[2K`)
            local selected = selection[id]
            if hovered then
                io.stderr:write(
                    ` {ansi.paint(ansi.green, "[")}{if selected then ansi.paint(ansi.green, "x") else " "}{ansi.paint(
                        ansi.green,
                        "]"
                    )} {ansi.paint(ansi.bold, options[id])}`
                )
            else
                io.stderr:write(
                    ` {ansi.paint(ansi.dim, "[")}{if selected then ansi.paint(ansi.green, "x") else " "}{ansi.paint(
                        ansi.dim,
                        "]"
                    )} {ansi.paint(ansi.bold, options[id])}`
                )
            end
        end
    end

    local input_buf = buffer.create(3)
    while true do
        task.wait()
        local amt = io.stdin:read(input_buf, 0, 3)
        if amt == 0 then
            continue
        end

        local bytes = {}
        for i = 1, amt do
            bytes[i] = buffer.readu8(input_buf, i - 1)
        end
        if bytes[1] == 0x1B then
            if bytes[2] ~= 91 then
                continue
            end
            if bytes[3] == 65 then -- up
                if kind == "select" or kind == "multiselect" then
                    local last_order = order
                    local direction = ""
                    if order == 1 then
                        order = #options
                        if last_order == order then
                            continue
                        end
                        direction = moveDown(#options - 1)
                    else
                        order -= 1
                        direction = moveUp()
                    end
                    renderSelection(last_order, false)
                    io.stderr:write(direction)
                    renderSelection(order, true)
                    io.stderr:write(moveToColumn(0))
                end
            elseif bytes[3] == 66 then -- down
                if kind == "select" or kind == "multiselect" then
                    local last_order = order
                    local direction = ""
                    if order == #options then
                        order = 1
                        if last_order == order then
                            continue
                        end
                        direction = moveUp(#options - 1)
                    else
                        order += 1
                        direction = moveDown()
                    end
                    renderSelection(last_order, false)
                    io.stderr:write(direction)
                    renderSelection(order, true)
                    io.stderr:write(moveToColumn(0))
                end
            elseif bytes[3] == 67 then -- right
                if kind == "text" then
                    if order >= #input then
                        continue
                    end
                    order += 1
                    io.stderr:write(moveRight())
                end
            elseif bytes[3] == 68 then -- left
                if kind == "text" then
                    if order == 0 then
                        continue
                    end
                    order -= 1
                    io.stderr:write(moveLeft())
                end
            else
                continue
            end
        elseif bytes[1] == 0x03 or bytes[1] == 0x04 then -- interrupt
            error("Interrupted")
        elseif bytes[1] == 0x0A then -- enter
            break
        elseif bytes[1] == 0x7F then -- backspace
            if kind == "text" then
                if #input == 0 then
                    continue
                end
                io.stderr:write(moveLeft())
                input = input:sub(1, order - 1) .. input:sub(order + 1)
                order -= 1
                io.stderr:write(CLEAR_FROM_CURSOR)
                if order ~= #input then
                    local rest = input:sub(order + 1)
                    io.stderr:write(rest)
                    io.stderr:write(moveLeft(#rest))
                end
            end
        elseif bytes[1] == 0x09 then -- tab
            if kind == "multiselect" then
                if selection[order] then
                    selection[order] = false
                    renderSelection(order, true)
                    io.stderr:write(moveToColumn(0))
                else
                    selection[order] = true
                    renderSelection(order, true)
                    io.stderr:write(moveToColumn(0))
                end
            end
        elseif bytes[1] >= 0x20 and bytes[1] <= 0x7E then -- printable
            if kind == "text" then
                input ..= buffer.readstring(input_buf, 0, amt)
                order += 1
                io.stderr:write(input_buf, 0, amt)
            elseif kind == "confirm" then
                if bytes[1] == 121 or bytes[1] == 89 then
                    input = "yes"
                elseif bytes[1] == 110 or bytes[1] == 78 then
                    input = "no"
                else
                    continue
                end
                io.stderr:write(input)
                break
            elseif kind == "multiselect" then
                if bytes[1] == 65 or bytes[1] == 97 then
                    if selection[1] then
                        for i = 1, #selection do
                            selection[i] = false
                        end
                    else
                        for i = 1, #selection do
                            selection[i] = true
                        end
                    end
                    for i = 1, order - 1 do
                        io.stderr:write(moveUp())
                    end
                    for i = 1, #selection do
                        if i ~= 1 then
                            io.stderr:write("\n")
                        end
                        renderSelection(i, i == order)
                    end
                    for i = 1, #selection - order do
                        io.stderr:write(moveUp())
                    end
                    io.stderr:write(moveToColumn(0))
                end
            end
        end
    end

    if not is_raw then
        io.terminal.restoreMode()
    end

    if kind == "multiselect" or kind == "select" then
        local len = #options
        local down = len - order
        if down > 0 then
            io.stderr:write(moveDown(down))
        end
        for _ = 1, len do
            io.stderr:write(`{moveToColumn(0)}\x1b[2K`)
            io.stderr:write(moveUp())
        end
        if kind == "select" then
            io.stderr:write(
                `\x1b[2K{ansi.paint(ansi.green, "✔")} {ansi.paint(ansi.bold, message)} · {ansi.paint(
                    "green",
                    options[order]
                )}`
            )
        else
            local selected_items = {}
            for i = 1, len do
                if selection[i] then
                    table.insert(selected_items, options[i])
                end
            end
            if #selected_items == 0 then
                io.stderr:write(
                    `{ansi.paint(ansi.green, "✔")} {ansi.paint(ansi.bold, message)} · {ansi.paint(ansi.dim, "empty")}`
                )
            else
                io.stderr:write(`{ansi.paint(ansi.green, "✔")} {ansi.paint(ansi.bold, message)} · `)
                for i = 1, #selected_items do
                    if i ~= 1 then
                        io.stderr:write(", ")
                    end
                    local obj = selected_items[i]
                    io.stderr:write(`{ansi.paint(ansi.green, obj)}`)
                end
            end
        end
    else
        io.stderr:write(`{moveToColumn(0)}\x1b[2K`)
        io.stderr:write(
            `{ansi.paint(ansi.green, "✔")} {ansi.paint(ansi.bold, message)} · {ansi.paint(ansi.green, input)}`
        )
    end

    io.stderr:write("\n")
    if kind == "text" then
        return input
    elseif kind == "confirm" then
        return input:lower() == "y" or input:lower() == "yes"
    elseif kind == "select" then
        return order
    elseif kind == "multiselect" then
        local selected_items = {}
        for i = 1, #selection do
            if selection[i] then
                table.insert(selected_items, i)
            end
        end
        return selected_items
    end
    error("unreachable")
end

tui.prompt = (prompt :: any) :: PromptFn

return tui
