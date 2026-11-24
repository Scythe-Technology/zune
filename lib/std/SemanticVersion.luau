--!strict
--!optimize 2

local mem = zune.mem
local ascii = zune.ascii

local SemanticVersion = {}

export type Version = {
    major: number,
    minor: number,
    patch: number,
    prerelease: { string },
    build: { string },
}

type PartKind = "number" | "pre" | "build"

local function identByte(byte: number): boolean
    return ascii.isAlphanumeric(byte) or byte == 45 -- '-'
end

local function readPart(text: string, at: number, limit: number, kind: PartKind): number?
    if at > limit then
        return nil
    end
    local first = string.byte(text, at) :: number
    if kind == "number" then
        if not ascii.isDigit(first) then
            return nil
        end
    elseif not identByte(first) then
        return nil
    end
    local pos = at + 1
    local digits = ascii.isDigit(first)
    while pos <= limit do
        local byte = string.byte(text, pos) :: number
        if kind == "number" then
            if not ascii.isDigit(byte) then
                break
            end
        else
            if not identByte(byte) then
                break
            end
            if not ascii.isDigit(byte) then
                digits = false
            end
        end
        pos += 1
    end
    if kind ~= "build" and digits and first == 48 and pos > at + 1 then -- '0'
        return nil
    end
    return pos
end

local function readDotParts(text: string, at: number, limit: number, kind: PartKind): { string }?
    if at > limit then
        return nil
    end
    local parts: { string } = {}
    local cursor = at
    while true do
        local pos = readPart(text, cursor, limit, kind)
        if not pos then
            return nil
        end
        table.insert(parts, string.sub(text, cursor, pos - 1))
        if pos > limit then
            return parts
        end
        if string.byte(text, pos) ~= 46 then -- '.'
            return nil
        end
        cursor = pos + 1
    end
end

function SemanticVersion.parse(text: string): Version?
    local len = #text
    if len == 0 then
        return nil
    end
    local plus = mem.findScalar(text, 43) -- '+'
    local core_end = len
    local build: { string } = {}
    if plus then
        local parts = readDotParts(text, plus + 2, len, "build")
        if not parts then
            return nil
        end
        build = parts
        core_end = plus
    end
    local dash = mem.findScalar(text, 45) -- '-'
    local prerelease: { string } = {}
    local number_end = core_end
    if dash and dash <= core_end then
        local parts = readDotParts(text, dash + 2, core_end, "pre")
        if not parts then
            return nil
        end
        prerelease = parts
        number_end = dash
    end
    local numbers = readDotParts(text, 1, number_end, "number")
    if not numbers or #numbers ~= 3 then
        return nil
    end
    local major = tonumber(numbers[1])
    local minor = tonumber(numbers[2])
    local patch = tonumber(numbers[3])
    if not major or not minor or not patch then
        return nil
    end
    return {
        major = major,
        minor = minor,
        patch = patch,
        prerelease = prerelease,
        build = build,
    }
end

local function sign(left: number, right: number): number
    return if left < right then -1 elseif left > right then 1 else 0
end

local function numericIdent(text: string): boolean
    if #text == 0 then
        return false
    end
    for i = 1, #text do
        if not ascii.isDigit(string.byte(text, i) :: number) then
            return false
        end
    end
    return true
end

local function compareIdent(left: string, right: string): number
    local left_num = numericIdent(left)
    local right_num = numericIdent(right)
    if left_num and right_num then
        return if #left ~= #right
            then sign(#left, #right)
            elseif left == right then 0
            else if left < right then -1 else 1
    end
    if left_num then
        return -1
    end
    if right_num then
        return 1
    end
    if left == right then
        return 0
    end
    return if left < right then -1 else 1
end

function SemanticVersion.compare(left: Version, right: Version): number
    local major = sign(left.major, right.major)
    if major ~= 0 then
        return major
    end
    local minor = sign(left.minor, right.minor)
    if minor ~= 0 then
        return minor
    end
    local patch = sign(left.patch, right.patch)
    if patch ~= 0 then
        return patch
    end
    local left_pre = #left.prerelease > 0
    local right_pre = #right.prerelease > 0
    if left_pre ~= right_pre then
        return if left_pre then -1 else 1
    end
    local count = math.min(#left.prerelease, #right.prerelease)
    for i = 1, count do
        local order = compareIdent(left.prerelease[i], right.prerelease[i])
        if order ~= 0 then
            return order
        end
    end
    return sign(#left.prerelease, #right.prerelease)
end

return SemanticVersion
