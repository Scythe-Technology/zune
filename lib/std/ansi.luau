--!strict
--!optimize 2

local function color256Fn(set: number): (code: number) -> string
    return function(code: number): string
        if code < 0 or code > 255 then
            error("Code must be between 0 to 255", 2)
        end
        return string.format(`\x1b[{set};5;%dm`, code)
    end
end

local function trueColorFn(set: number): (r: number, g: number, b: number) -> string
    return function(r: number, g: number, b: number): string
        if r < 0 or r > 255 then
            error("R must be between 0 to 255", 2)
        end
        if g < 0 or g > 255 then
            error("G must be between 0 to 255", 2)
        end
        if b < 0 or b > 255 then
            error("B must be between 0 to 255", 2)
        end
        return string.format(`\x1b[{set};2;%d;%d;%dm`, r, g, b)
    end
end

local CURSOR_MOVE_TEMPLATES = {
    home = "\x1b[H",
    goto = "\x1b[%d;%dH",
    up = "\x1b[%dA",
    down = "\x1b[%dB",
    right = "\x1b[%dC",
    left = "\x1b[%dD",
    nextline = "\x1b[%dE",
    prevline = "\x1b[%dF",
    gotocol = "\x1b[%dG",
}

local function cursorMove(action: string, ...): string
    local template = CURSOR_MOVE_TEMPLATES[action] or error("unknown action", 2)
    return string.format(template :: string, ...)
end

local ERASE_TEMPLATES = {
    end_of = "\x1b[0J",
    start_of = "\x1b[1J",
    entire = "\x1b[2J",
    saved_lines = "\x1b[3J",
    end_of_line = "\x1b[0K",
    start_of_line = "\x1b[1K",
    entire_line = "\x1b[2K",
}

local function erase(
    erase: "end_of" | "start_of" | "entire" | "saved_lines" | "end_of_line" | "start_of_line" | "entire_line"
): string
    return ERASE_TEMPLATES[erase] or error("unknown erase kind", 2)
end

type CursorMoveFn =
    & ((action: "home") -> string)
    & ((action: "goto", line: number, column: number) -> string)
    & ((action: "up" | "down" | "right" | "left", amount: number) -> string)
    & ((action: "nextline", lines_down: number) -> string)
    & ((action: "prevline", lines_up: number) -> string)
    & ((action: "gotocol", column: number) -> string)

local function empty()
    return ""
end

local function painter(reset: string): (sequence: string, text: string) -> string
    return function(sequence: string, text: string)
        return `{sequence}{text}{reset}`
    end
end

local blank_sequences = {
    black = "",
    red = "",
    green = "",
    yellow = "",
    blue = "",
    magenta = "",
    cyan = "",
    white = "",
    bright_black = "",
    bright_red = "",
    bright_green = "",
    bright_yellow = "",
    bright_blue = "",
    bright_magenta = "",
    bright_cyan = "",
    bright_white = "",
    color256 = (empty :: any) :: typeof(color256Fn(38)),
    trueColor = (empty :: any) :: typeof(trueColorFn(38)),

    bg = {
        black = "",
        red = "",
        green = "",
        yellow = "",
        blue = "",
        magenta = "",
        cyan = "",
        white = "",
        bright_black = "",
        bright_red = "",
        bright_green = "",
        bright_yellow = "",
        bright_blue = "",
        bright_magenta = "",
        bright_cyan = "",
        bright_white = "",
        color256 = (empty :: any) :: typeof(color256Fn(48)),
        trueColor = (empty :: any) :: typeof(trueColorFn(48)),
    },

    dim = "",
    bold = "",
    italic = "",
    underline = "",
    blink = "",
    inverse = "",
    hidden = "",
    strikethrough = "",

    reset = "",
    reset_bold = "",
    reset_dim = "",
    reset_italic = "",
    reset_underline = "",
    reset_blink = "",
    reset_inverse = "",
    reset_hidden = "",
    reset_strikethrough = "",
    reset_color = "",
    reset_bgcolor = "",

    alternate_screen_buffer = "",
    normal_screen_buffer = "",

    hide_cursor = "",
    show_cursor = "",

    cursorMove = (empty :: any) :: CursorMoveFn,

    erase = (empty :: any) :: typeof(erase),

    paint = painter(""),
}

local sequences = {
    black = "\x1b[30m",
    red = "\x1b[31m",
    green = "\x1b[32m",
    yellow = "\x1b[33m",
    blue = "\x1b[34m",
    magenta = "\x1b[35m",
    cyan = "\x1b[36m",
    white = "\x1b[37m",
    bright_black = "\x1b[90m",
    bright_red = "\x1b[91m",
    bright_green = "\x1b[92m",
    bright_yellow = "\x1b[93m",
    bright_blue = "\x1b[94m",
    bright_magenta = "\x1b[95m",
    bright_cyan = "\x1b[96m",
    bright_white = "\x1b[97m",
    color256 = color256Fn(38),
    trueColor = trueColorFn(38),

    bg = {
        black = "\x1b[40m",
        red = "\x1b[41m",
        green = "\x1b[42m",
        yellow = "\x1b[43m",
        blue = "\x1b[44m",
        magenta = "\x1b[45m",
        cyan = "\x1b[46m",
        white = "\x1b[47m",
        bright_black = "\x1b[100m",
        bright_red = "\x1b[101m",
        bright_green = "\x1b[102m",
        bright_yellow = "\x1b[103m",
        bright_blue = "\x1b[104m",
        bright_magenta = "\x1b[105m",
        bright_cyan = "\x1b[106m",
        bright_white = "\x1b[107m",
        color256 = color256Fn(48),
        trueColor = trueColorFn(48),
    },

    dim = "\x1b[2m",
    bold = "\x1b[1m",
    italic = "\x1b[3m",
    underline = "\x1b[4m",
    blink = "\x1b[5m",
    inverse = "\x1b[7m",
    hidden = "\x1b[8m",
    strikethrough = "\x1b[9m",

    reset = "\x1b[0m",
    reset_bold = "\x1b[22m",
    reset_dim = "\x1b[22m",
    reset_italic = "\x1b[23m",
    reset_underline = "\x1b[24m",
    reset_blink = "\x1b[25m",
    reset_inverse = "\x1b[27m",
    reset_hidden = "\x1b[28m",
    reset_strikethrough = "\x1b[29m",
    reset_color = "\x1b[39m",
    reset_bgcolor = "\x1b[49m",

    alternate_screen_buffer = "\x1b[?1049h",
    normal_screen_buffer = "\x1b[?1049l",

    hide_cursor = "\x1b[?25l",
    show_cursor = "\x1b[?25h",

    cursorMove = (cursorMove :: any) :: CursorMoveFn,

    erase = erase,

    paint = painter("\x1b[0m"),
}

return {
    sequences = sequences,
    blank_sequences = blank_sequences,
    auto = function()
        if zune.fmt.useColors() then
            return sequences
        else
            return blank_sequences
        end
    end,
}
