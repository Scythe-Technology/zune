--!strict
--!optimize 2

local mem = zune.mem

export type SpecFn = (...any) -> (boolean, string?)

export type ObjectName =
    | "BufferArray"
    | "CPointer"
    | "CType"
    | "CryptoHasher"
    | "CryptoTls"
    | "CryptoTlsCertBundle"
    | "CryptoTlsCertKeyPair"
    | "Datetime"
    | "DeflateStream"
    | "Dir"
    | "DynamicLibrary"
    | "File"
    | "FileWatcher"
    | "GpioLine"
    | "HTTPServer"
    | "HTTPWebSocket"
    | "InflateStream"
    | "ProcessChild"
    | "Random"
    | "Regex"
    | "Socket"
    | "Thread"
    | "ThreadHardMutex"
    | "ThreadLane"
    | "ThreadMutex"
    | "ThreadValue"

type StructShape = {
    keys: { any },
    values: { SpecFn },
    key_patterns: { SpecFn },
    value_patterns: { SpecFn },
    strict: boolean,
}

type ArrayShape = {
    item: SpecFn,
    strict: boolean,
}

type TableShape = {
    struct: StructShape?,
    array: ArrayShape?,
}

type NumberShape = {
    domain: string,
    finite: boolean,
    min: number?,
    max: number?,
    bucket: string?,
}

type PartsShape = {
    list: { SpecFn },
    strict: boolean?,
}

type InnerShape = {
    check: SpecFn,
}

type Shape = {
    table: TableShape?,
    number: NumberShape?,
    parts: PartsShape?,
    inner: InnerShape?,
}

type Meta = {
    kind: string,
    name: string,
    shape: Shape?,
}

type Apply = (check: SpecFn, meta: Meta) -> SpecFn

local IDENTITY: { [string]: boolean } = {
    table = true,
    userdata = true,
    ["function"] = true,
    thread = true,
    buffer = true,
}

local PRINTABLE: { [string]: boolean } = {
    string = true,
    number = true,
    boolean = true,
}

local spec = {}

local META_REGISTRY: { [any]: Meta } = {}

local function register(check: SpecFn, meta: Meta): SpecFn
    META_REGISTRY[check] = meta
    return check
end

local function labelOf(check: SpecFn): string
    local meta = META_REGISTRY[check]
    if meta then
        return meta.name
    end
    return "value"
end

local TEXT_LIMIT = 32

local function describe(value: any): string
    local kind = type(value)
    if kind == "string" then
        local text = value :: string
        if mem.findScalar(text, 10) or mem.findScalar(text, 13) then -- '\n', '\r'
            text = (string.gsub(text, "[\r\n]+", " "))
        end
        if #text > TEXT_LIMIT then
            text = `{string.sub(text, 1, TEXT_LIMIT)}...`
        end
        return `"{text}"`
    end
    if kind == "number" then
        local number = value :: number
        if number ~= number then
            return "nan"
        end
        if number == math.huge then
            return "infinity"
        end
        if number == -math.huge then
            return "-infinity"
        end
        return tostring(number)
    end
    if kind == "boolean" then
        return if value then "true" else "false"
    end
    if kind == "nil" then
        return "nil"
    end
    if kind == "userdata" then
        return typeof(value)
    end
    if kind == "vector" then
        return tostring(value)
    end
    return kind
end

local function miss(name: string, value: any): (boolean, string)
    return false, `expected {name}, got {describe(value)}`
end

local function missArgs(name: string, ...: any): (boolean, string)
    if select("#", ...) == 1 then
        return false, `expected {name}, got {describe(...)}`
    end
    return false, `expected {name}`
end

function spec.string(value: any): (boolean, string?)
    if type(value) == "string" then
        return true, nil
    end
    return miss("string", value)
end

function spec.number(value: any): (boolean, string?)
    if type(value) == "number" then
        return true, nil
    end
    return miss("number", value)
end

function spec.boolean(value: any): (boolean, string?)
    if type(value) == "boolean" then
        return true, nil
    end
    return miss("boolean", value)
end

function spec.table(value: any): (boolean, string?)
    if type(value) == "table" then
        return true, nil
    end
    return miss("table", value)
end

function spec.fn(value: any): (boolean, string?)
    if type(value) == "function" then
        return true, nil
    end
    return miss("function", value)
end

function spec.thread(value: any): (boolean, string?)
    if type(value) == "thread" then
        return true, nil
    end
    return miss("thread", value)
end

function spec.userdata(value: any): (boolean, string?)
    if type(value) == "userdata" then
        return true, nil
    end
    return miss("userdata", value)
end

function spec.buffer(value: any): (boolean, string?)
    if type(value) == "buffer" then
        return true, nil
    end
    return miss("buffer", value)
end

function spec.vector(value: any): (boolean, string?)
    if type(value) == "vector" then
        return true, nil
    end
    return miss("vector", value)
end

function spec.none(value: any): (boolean, string?)
    if value == nil then
        return true, nil
    end
    return miss("nil", value)
end

function spec.void(...: any): (boolean, string?)
    if select("#", ...) == 0 then
        return true, nil
    end
    return missArgs("nothing", ...)
end

function spec.finite(value: any): (boolean, string?)
    if spec.number(value) and math.isfinite(value :: number) then
        return true, nil
    end
    return miss("finite number", value)
end

function spec.nan(value: any): (boolean, string?)
    if spec.number(value) and value ~= value then
        return true, nil
    end
    return miss("nan", value)
end

function spec.infinite(value: any): (boolean, string?)
    if spec.number(value) then
        local number = value :: number
        if number == math.huge or number == -math.huge then
            return true, nil
        end
    end
    return miss("infinity", value)
end

function spec.integer(value: any): (boolean, string?)
    if not spec.number(value) then
        return miss("integer", value)
    end
    local _, frac = math.modf(value :: number)
    if frac == 0 then
        return true, nil
    end
    return miss("integer", value)
end

local function finiteInteger(value: any): (boolean, string?)
    if spec.finite(value) and spec.integer(value) then
        return true, nil
    end
    return miss("finite integer", value)
end

local function nonfiniteValue(value: any): (boolean, string?)
    if spec.number(value) and not math.isfinite(value :: number) then
        return true, nil
    end
    return miss("nan or infinity", value)
end

register(spec.string, { kind = "type", name = "string" })
register(spec.number, {
    kind = "number",
    name = "number",
    shape = { number = { domain = "number", finite = false } },
})
register(spec.boolean, { kind = "type", name = "boolean" })
register(spec.table, { kind = "type", name = "table" })
register(spec.fn, { kind = "type", name = "function" })
register(spec.thread, { kind = "type", name = "thread" })
register(spec.userdata, { kind = "type", name = "userdata" })
register(spec.buffer, { kind = "type", name = "buffer" })
register(spec.vector, { kind = "type", name = "vector" })
register(spec.none, { kind = "none", name = "nil" })
register(spec.void, { kind = "void", name = "nothing" })
register(spec.finite, {
    kind = "finite",
    name = "finite number",
    shape = { number = { domain = "number", finite = true } },
})
register(spec.nan, { kind = "nan", name = "nan" })
register(spec.infinite, { kind = "infinite", name = "infinity" })
register(spec.integer, {
    kind = "integer",
    name = "integer",
    shape = { number = { domain = "integer", finite = false } },
})
local finite_integer = register(finiteInteger, {
    kind = "integer",
    name = "finite integer",
    shape = { number = { domain = "integer", finite = true } },
})
local nonfinite_check = register(nonfiniteValue, { kind = "nonfinite", name = "nan or infinity" })

local function place(key: any): string
    if spec.string(key) then
        return key :: string
    end
    return describe(key)
end

local function at(key: any, check: SpecFn, value: any): (boolean, string?)
    local ok, reason = check(value)
    if ok then
        return true, nil
    end
    return false, `{place(key)}: {reason or `expected {labelOf(check)}`}`
end

local function boundName(domain: string, min: number?, max: number?, finite: boolean): string
    local head = if finite then `finite {domain}` else domain
    if min and max then
        return `{head} from {min} to {max}`
    end
    if min then
        return `{head} >= {min}`
    end
    if max then
        return `{head} <= {max}`
    end
    if finite and domain == "integer" then
        return "finite integer"
    end
    if finite then
        return "finite number"
    end
    return domain
end

local function boundKind(min: number?, max: number?, domain: string, finite: boolean): string
    if min and max then
        return "range"
    end
    if min then
        return "min"
    end
    if max then
        return "max"
    end
    if domain == "integer" then
        return "integer"
    end
    if finite then
        return "finite"
    end
    return "number"
end

local function makeBound(domain: string, min: number?, max: number?, finite: boolean): SpecFn
    if not min and not max then
        if domain == "number" then
            return if finite then spec.finite else spec.number
        end
        return if finite then finite_integer else spec.integer
    end
    local lo, hi = min or 0, max or 0
    local has_min, has_max = min ~= nil, max ~= nil
    local expect_integer = domain == "integer"
    local name = boundName(domain, min, max, finite)
    local check = function(value: any): (boolean, string?)
        -- slow path
        if not spec.number(value) then
            return miss(name, value)
        end
        local number = value :: number
        if finite and not spec.finite(number) then
            return miss(name, value)
        end
        if has_min and not (number >= lo) then
            return miss(name, value)
        end
        if has_max and not (number <= hi) then
            return miss(name, value)
        end
        if expect_integer and not spec.integer(number) then
            return miss(name, value)
        end
        return true, nil
    end
    local kind = boundKind(min, max, domain, finite)
    return register(check, {
        kind = kind,
        name = name,
        shape = {
            number = {
                domain = domain,
                finite = finite,
                min = min,
                max = max,
                bucket = if kind == "min" or kind == "max" then `{domain}:{kind}` else nil,
            },
        },
    })
end

local function finiteBound(value: any, what: string, level: number): number
    if not spec.finite(value) then
        error(`{what} must be a finite number`, level)
    end
    return value :: number
end

local function wholeBound(value: any, what: string): number
    local number = finiteBound(value, what, 4)
    if not spec.integer(number) then
        error(`{what} must be an integer`, 3)
    end
    return number
end

function spec.minInteger(min: number): SpecFn
    return makeBound("integer", wholeBound(min, "min"), nil, false)
end

function spec.maxInteger(max: number): SpecFn
    return makeBound("integer", nil, wholeBound(max, "max"), false)
end

function spec.minNumber(min: number): SpecFn
    return makeBound("number", finiteBound(min, "min", 3), nil, false)
end

function spec.maxNumber(max: number): SpecFn
    return makeBound("number", nil, finiteBound(max, "max", 3), false)
end

local function makeLength(min: number?, max: number?): SpecFn
    local lo, hi = min or 0, max or 0
    local has_min, has_max = min ~= nil, max ~= nil
    local name = if min then `length >= {min}` else `length <= {max or 0}`
    local check = function(value: any): (boolean, string?)
        local count: number
        if spec.string(value) then
            count = #(value :: string)
        elseif spec.table(value) then
            count = #(value :: { any })
        elseif spec.buffer(value) then
            count = buffer.len(value :: buffer)
        else
            return miss(name, value)
        end
        if has_min and count < lo or has_max and count > hi then
            return false, `expected {name}, got length {count}`
        end
        return true, nil
    end
    return register(check, {
        kind = "length",
        name = name,
    })
end

local nonNegative = spec.minInteger(0)

function spec.minLength(min: number): SpecFn
    local bound = wholeBound(min, "min")
    if not nonNegative(bound) then
        error("min must be at least 0", 2)
    end
    return makeLength(bound, nil)
end

function spec.maxLength(max: number): SpecFn
    local bound = wholeBound(max, "max")
    if not nonNegative(bound) then
        error("max must be at least 0", 2)
    end
    return makeLength(nil, bound)
end

local function makeStruct(shape: { [any]: SpecFn }?, exact: boolean): SpecFn
    local keys: { any }, values: { SpecFn } = {}, {}
    local key_patterns: { SpecFn }, value_patterns: { SpecFn } = {}, {}
    if shape then
        for key, check in shape do
            if not spec.fn(check) then
                error("struct field must be a spec", 2)
            end
            if spec.fn(key) then
                table.insert(key_patterns, key :: SpecFn)
                table.insert(value_patterns, check)
            else
                table.insert(keys, key)
                table.insert(values, check)
            end
        end
    end
    local count, pattern_count = #keys, #key_patterns
    local built: SpecFn
    if exact and pattern_count == 0 then
        local allowed: { [any]: boolean } = {}
        for i = 1, count do
            allowed[keys[i]] = true
        end
        built = function(value: any): (boolean, string?)
            -- slow path
            if not spec.table(value) then
                return miss("struct", value)
            end
            for i = 1, count do
                local ok, reason = at(keys[i], values[i], value[keys[i]])
                if not ok then
                    return ok, reason
                end
            end
            for key in value do
                if not allowed[key] then
                    return false, `unexpected {place(key)}`
                end
            end
            return true, nil
        end
    elseif exact then
        local allowed: { [any]: boolean } = {}
        for i = 1, count do
            allowed[keys[i]] = true
        end
        built = function(value: any): (boolean, string?)
            -- slow path
            if not spec.table(value) then
                return miss("struct", value)
            end
            for i = 1, count do
                local ok, reason = at(keys[i], values[i], value[keys[i]])
                if not ok then
                    return ok, reason
                end
            end
            for key, item in value do
                if not allowed[key] then
                    local matched = false
                    for i = 1, pattern_count do
                        if key_patterns[i](key) then
                            matched = true
                            local ok, reason = at(key, value_patterns[i], item)
                            if not ok then
                                return ok, reason
                            end
                            break
                        end
                    end
                    if not matched then
                        return false, `unexpected {place(key)}`
                    end
                end
            end
            return true, nil
        end
    elseif pattern_count == 0 then
        built = function(value: any): (boolean, string?)
            -- slow path
            if not spec.table(value) then
                return miss("struct", value)
            end
            for i = 1, count do
                local ok, reason = at(keys[i], values[i], value[keys[i]])
                if not ok then
                    return ok, reason
                end
            end
            return true, nil
        end
    else
        local named: { [any]: boolean } = {}
        for i = 1, count do
            named[keys[i]] = true
        end
        built = function(value: any): (boolean, string?)
            -- slow path
            if not spec.table(value) then
                return miss("struct", value)
            end
            for i = 1, count do
                local ok, reason = at(keys[i], values[i], value[keys[i]])
                if not ok then
                    return ok, reason
                end
            end
            for key, item in value do
                if not named[key] then
                    for i = 1, pattern_count do
                        if key_patterns[i](key) then
                            local ok, reason = at(key, value_patterns[i], item)
                            if not ok then
                                return ok, reason
                            end
                            break
                        end
                    end
                end
            end
            return true, nil
        end
    end
    return register(built, {
        kind = "struct",
        name = "struct",
        shape = {
            table = {
                struct = {
                    keys = keys,
                    values = values,
                    key_patterns = key_patterns,
                    value_patterns = value_patterns,
                    strict = exact,
                },
            },
        },
    })
end

function spec.struct(shape: { [any]: SpecFn }?): SpecFn
    if shape ~= nil and not spec.table(shape) then
        error("struct expects a table", 2)
    end
    return makeStruct(shape, false)
end

local function makeArray(item: SpecFn, exact: boolean): SpecFn
    if not spec.fn(item) then
        error("array expects a spec", 2)
    end
    local meta = META_REGISTRY[item]
    local item_name = if meta then meta.name else "value"
    local name = `array of {item_name}`
    local built: SpecFn
    if exact then
        built = function(value: any): (boolean, string?)
            -- slow path
            if not spec.table(value) then
                return miss(name, value)
            end
            local count = #value
            local seen = 0
            for key, entry in value do
                seen += 1
                if not spec.integer(key) or key < 1 or key > count then
                    return false, `unexpected {place(key)}`
                end
                local ok, reason = at(key, item, entry)
                if not ok then
                    return ok, reason
                end
            end
            if seen ~= count then
                return false, `expected {count} items`
            end
            return true, nil
        end
    else
        built = function(value: any): (boolean, string?)
            -- slow path
            if not spec.table(value) then
                return miss(name, value)
            end
            for i = 1, #value do
                local ok, reason = at(i, item, value[i])
                if not ok then
                    return ok, reason
                end
            end
            return true, nil
        end
    end
    return register(built, {
        kind = "array",
        name = name,
        shape = {
            table = {
                array = {
                    item = item,
                    strict = exact,
                },
            },
        },
    })
end

function spec.array(item: SpecFn): SpecFn
    return makeArray(item, false)
end

register(spec.struct, { kind = "struct_builder", name = "struct" })
register(spec.array, { kind = "array_builder", name = "array" })

function spec.optional(check: SpecFn): SpecFn
    if not spec.fn(check) then
        error("optional expects a spec", 2)
    end
    local out = function(value: any): (boolean, string?)
        if spec.none(value) then
            return true, nil
        end
        return check(value)
    end
    return register(out, {
        kind = "optional",
        name = `optional {labelOf(check)}`,
        shape = { inner = { check = check } },
    })
end

local BOUND_DOMAINS = { "integer", "number" }

local function numberShape(meta: Meta?): NumberShape?
    local shape = if meta then meta.shape else nil
    return if shape then shape.number else nil
end

local function widestMin(parts: { SpecFn }): (number, boolean)
    local number = numberShape(META_REGISTRY[parts[1]])
    local bound, finite = if number and number.min then number.min else 0, number ~= nil and number.finite
    for i = 2, #parts do
        local part = numberShape(META_REGISTRY[parts[i]])
        local next_min = if part and part.min then part.min else 0
        if next_min < bound then
            bound = next_min
        end
        if part and part.finite then
            finite = true
        end
    end
    return bound, finite
end

local function widestMax(parts: { SpecFn }): (number, boolean)
    local number = numberShape(META_REGISTRY[parts[1]])
    local bound, finite = if number and number.max then number.max else 0, number ~= nil and number.finite
    for i = 2, #parts do
        local part = numberShape(META_REGISTRY[parts[i]])
        local next_max = if part and part.max then part.max else 0
        if next_max > bound then
            bound = next_max
        end
        if part and part.finite then
            finite = true
        end
    end
    return bound, finite
end

function spec.union(...: SpecFn): SpecFn
    local count = select("#", ...)
    if count == 0 then
        return register(function(value: any): (boolean, string?)
            -- slow path
            return miss("nothing", value)
        end, {
            kind = "union",
            name = "nothing",
            shape = { parts = { list = {}, strict = true } },
        })
    end
    if count == 1 then
        return (select(1, ...))
    end
    local parts = { ... }
    local groups: { [string]: { SpecFn } } = {
        ["integer:min"] = {},
        ["integer:max"] = {},
        ["number:min"] = {},
        ["number:max"] = {},
    }
    local rest: { SpecFn } = {}
    for i = 1, count do
        local part = parts[i]
        if not spec.fn(part) then
            error("union expects specs", 2)
        end
        local number = numberShape(META_REGISTRY[part])
        local bucket = if number then number.bucket else nil
        local group = if bucket then groups[bucket] else nil
        if group then
            table.insert(group, part)
        else
            table.insert(rest, part)
        end
    end
    local function keep(held: { SpecFn })
        for i = 1, #held do
            table.insert(rest, held[i])
        end
    end
    for i = 1, #BOUND_DOMAINS do
        local domain = BOUND_DOMAINS[i]
        local mins = groups[`{domain}:min`]
        local maxs = groups[`{domain}:max`]
        if #mins > 0 and #maxs > 0 then
            local lo, min_finite = widestMin(mins)
            local hi, max_finite = widestMax(maxs)
            if lo <= hi then
                table.insert(rest, makeBound(domain, lo, hi, min_finite or max_finite))
            else
                keep(mins)
                keep(maxs)
            end
        else
            keep(mins)
            keep(maxs)
        end
    end
    if #rest == 1 then
        return rest[1]
    end
    local names = table.create(#rest) :: { string }
    for i = 1, #rest do
        names[i] = labelOf(rest[i])
    end
    local n = #rest
    local name = table.concat(names, " or ")
    local built: SpecFn
    if n == 2 then
        local first, second = rest[1], rest[2]
        built = function(value: any): (boolean, string?)
            -- fast path
            if first(value) or second(value) then
                return true, nil
            end
            return miss(name, value)
        end
    elseif n == 3 then
        local first, second, third = rest[1], rest[2], rest[3]
        built = function(value: any): (boolean, string?)
            -- fast path
            if first(value) or second(value) or third(value) then
                return true, nil
            end
            return miss(name, value)
        end
    else
        built = function(value: any): (boolean, string?)
            -- slow path
            for i = 1, n do
                if rest[i](value) then
                    return true, nil
                end
            end
            return miss(name, value)
        end
    end
    return register(built, {
        kind = "union",
        name = name,
        shape = { parts = { list = rest } },
    })
end

function spec.intersection(...: SpecFn): SpecFn
    local count = select("#", ...)
    if count == 0 then
        error("intersection expects specs", 2)
    end
    if count == 1 then
        return (select(1, ...))
    end
    local parts = { ... }
    for i = 1, count do
        if not spec.fn(parts[i]) then
            error("intersection expects specs", 2)
        end
    end
    local names = table.create(count) :: { string }
    for i = 1, count do
        names[i] = labelOf(parts[i])
    end
    local first, second = parts[1], parts[2]
    local built: SpecFn
    if count == 2 then
        built = function(...: any): (boolean, string?)
            local ok, reason = first(...)
            if not ok then
                return false, reason
            end
            return second(...)
        end
    elseif count == 3 then
        local third = parts[3]
        built = function(...: any): (boolean, string?)
            local ok, reason = first(...)
            if not ok then
                return false, reason
            end
            ok, reason = second(...)
            if not ok then
                return false, reason
            end
            return third(...)
        end
    else
        built = function(...: any): (boolean, string?)
            -- slow path
            for i = 1, count do
                local ok, reason = parts[i](...)
                if not ok then
                    return false, reason
                end
            end
            return true, nil
        end
    end
    return register(built, {
        kind = "intersection",
        name = table.concat(names, " and "),
        shape = { parts = { list = parts } },
    })
end

local function strictStruct(check: SpecFn, meta: Meta): SpecFn
    local table_shape = if meta.shape then meta.shape.table else nil
    local struct_shape = if table_shape then table_shape.struct else nil
    if not struct_shape or struct_shape.strict then
        return check
    end
    local shape: { [any]: SpecFn } = {}
    local keys, values = struct_shape.keys, struct_shape.values
    for i = 1, #keys do
        shape[keys[i]] = values[i]
    end
    local key_patterns, value_patterns = struct_shape.key_patterns, struct_shape.value_patterns
    for i = 1, #key_patterns do
        shape[key_patterns[i]] = value_patterns[i]
    end
    return makeStruct(shape, true)
end

local function strictArray(check: SpecFn, meta: Meta): SpecFn
    local table_shape = if meta.shape then meta.shape.table else nil
    local array_shape = if table_shape then table_shape.array else nil
    if not array_shape or array_shape.strict then
        return check
    end
    return makeArray(array_shape.item, true)
end

local function strictOptional(_: SpecFn, meta: Meta): SpecFn
    local inner = if meta.shape then meta.shape.inner else nil
    return spec.optional(spec.strict(if inner then inner.check else spec.none))
end

local function strictCombined(kind: string, combine: (...SpecFn) -> SpecFn): Apply
    return function(check: SpecFn, meta: Meta): SpecFn
        local parts_shape = if meta.shape then meta.shape.parts else nil
        if not parts_shape or parts_shape.strict then
            return check
        end
        local list = parts_shape.list
        local next_parts = table.create(#list) :: { SpecFn }
        for i = 1, #list do
            next_parts[i] = spec.strict(list[i])
        end
        local out = combine(table.unpack(next_parts))
        local out_meta = META_REGISTRY[out]
        local out_parts = if out_meta and out_meta.shape then out_meta.shape.parts else nil
        if out_meta and out_meta.kind == kind and out_parts then
            out_parts.strict = true
        end
        return out
    end
end

local function strictBound(check: SpecFn, meta: Meta): SpecFn
    local number = numberShape(meta)
    if not number or number.finite then
        return check
    end
    return makeBound(number.domain, number.min, number.max, true)
end

local function strictArrayBuilder(_: SpecFn, _: Meta): SpecFn
    return function(item: SpecFn): SpecFn
        return makeArray(item, true)
    end :: any
end

local function strictStructBuilder(_: SpecFn, _: Meta): SpecFn
    return function(shape: { [any]: SpecFn }?): SpecFn
        if shape ~= nil and not spec.table(shape) then
            error("struct expects a table", 2)
        end
        return makeStruct(shape, true)
    end :: any
end

local function strictLabel(_: SpecFn, meta: Meta): SpecFn
    local inner = if meta.shape then meta.shape.inner else nil
    return spec.label(meta.name, spec.strict(if inner then inner.check else spec.none))
end

local strict_of: { [string]: Apply } = {
    struct = strictStruct,
    array = strictArray,
    optional = strictOptional,
    union = strictCombined("union", spec.union),
    intersection = strictCombined("intersection", spec.intersection),
    number = strictBound,
    integer = strictBound,
    min = strictBound,
    max = strictBound,
    range = strictBound,
    array_builder = strictArrayBuilder,
    struct_builder = strictStructBuilder,
    label = strictLabel,
}

function spec.strict(check: SpecFn): SpecFn
    if not spec.fn(check) then
        error("strict expects a spec", 2)
    end
    local meta = META_REGISTRY[check]
    if not meta then
        error("strict expects a spec", 2)
    end
    local rule = strict_of[meta.kind]
    if rule then
        return rule(check, meta)
    end
    return check
end

local function genericNot(check: SpecFn): SpecFn
    local name = `not {labelOf(check)}`
    local out = function(...: any): (boolean, string?)
        if check(...) then
            return missArgs(name, ...)
        end
        return true, nil
    end
    return register(out, {
        kind = "negate",
        name = name,
        shape = { inner = { check = check } },
    })
end

local negate_of: { [string]: Apply } = {
    finite = function(_: SpecFn, _: Meta): SpecFn
        return nonfinite_check
    end,
    nonfinite = function(_: SpecFn, _: Meta): SpecFn
        return spec.finite
    end,
    negate = function(_: SpecFn, meta: Meta): SpecFn
        local inner = if meta.shape then meta.shape.inner else nil
        return if inner then inner.check else spec.none
    end,
    label = function(_: SpecFn, meta: Meta): SpecFn
        local inner = if meta.shape then meta.shape.inner else nil
        return spec.label(meta.name, spec.negate(if inner then inner.check else spec.none))
    end,
}

function spec.negate(check: SpecFn): SpecFn
    if not spec.fn(check) then
        error("negate expects a spec", 2)
    end
    local meta = META_REGISTRY[check]
    if meta then
        local rule = negate_of[meta.kind]
        if rule then
            return rule(check, meta)
        end
    end
    return genericNot(check)
end

function spec.vararg(...: SpecFn): SpecFn
    local count = select("#", ...)
    if count == 0 then
        return spec.void
    end
    local parts = { ... }
    for i = 1, count do
        if not spec.fn(parts[i]) then
            error("vararg expects specs", 2)
        end
    end
    local names = table.create(count) :: { string }
    for i = 1, count do
        names[i] = labelOf(parts[i])
    end
    local name = table.concat(names, ", ")
    local function argAt(i: number, part: SpecFn, value: any): (boolean, string?)
        local ok, reason = part(value)
        if ok then
            return true, nil
        end
        local why = reason or `expected {labelOf(part)}`
        if count == 1 then
            return false, why
        end
        return false, `{i}: {why}`
    end
    local first, second, third = parts[1], parts[2], parts[3]
    local built: SpecFn
    if count == 1 then
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= 1 then
                return missArgs(name, ...)
            end
            return argAt(1, first, (select(1, ...)))
        end
    elseif count == 2 then
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= 2 then
                return missArgs(name, ...)
            end
            local ok, reason = argAt(1, first, (select(1, ...)))
            if not ok then
                return ok, reason
            end
            return argAt(2, second, (select(2, ...)))
        end
    elseif count == 3 then
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= 3 then
                return missArgs(name, ...)
            end
            local ok, reason = argAt(1, first, (select(1, ...)))
            if not ok then
                return ok, reason
            end
            ok, reason = argAt(2, second, (select(2, ...)))
            if not ok then
                return ok, reason
            end
            return argAt(3, third, (select(3, ...)))
        end
    else
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= count then
                return missArgs(name, ...)
            end
            for i = 1, count do
                local ok, reason = argAt(i, parts[i], (select(i, ...)))
                if not ok then
                    return ok, reason
                end
            end
            return true, nil
        end
    end
    return register(built, {
        kind = "vararg",
        name = name,
        shape = { parts = { list = parts } },
    })
end

function spec.literal(expect: any): SpecFn
    local kind = type(expect)
    local name = "literal"
    if PRINTABLE[kind] then
        name = `literal {tostring(expect)}`
    elseif kind == "nil" then
        name = "nil"
    end
    local built: SpecFn
    if IDENTITY[kind] then
        built = function(value: any): (boolean, string?)
            -- fast path
            if rawequal(value, expect) then
                return true, nil
            end
            return miss(name, value)
        end
    else
        built = function(value: any): (boolean, string?)
            -- fast path
            if value == expect then
                return true, nil
            end
            return miss(name, value)
        end
    end
    return register(built, { kind = "literal", name = name })
end

function spec.oneOf(...: any): SpecFn
    local count = select("#", ...)
    if count == 0 then
        error("oneOf expects a value", 2)
    end
    if count == 1 then
        return spec.literal((select(1, ...)))
    end
    local values = { ... }
    local identity = table.create(count) :: { boolean }
    local names = table.create(count) :: { string }
    local use_eq, use_id, named = true, true, true
    for i = 1, count do
        local value = values[i]
        local kind = type(value)
        local by_id = IDENTITY[kind] == true

        identity[i] = by_id

        if by_id then
            use_eq, named = false, false
        else
            use_id = false
            if PRINTABLE[kind] then
                names[i] = tostring(value)
            elseif kind == "nil" then
                names[i] = "nil"
            else
                named = false
            end
        end
    end
    local name = "one of"
    if named then
        name = `one of {table.concat(names, ", ")}`
    end
    local built: SpecFn
    if use_eq then
        built = function(value: any): (boolean, string?)
            -- slow path
            for i = 1, count do
                if value == values[i] then
                    return true, nil
                end
            end
            return miss(name, value)
        end
    elseif use_id then
        built = function(value: any): (boolean, string?)
            -- slow path
            for i = 1, count do
                if rawequal(value, values[i]) then
                    return true, nil
                end
            end
            return miss(name, value)
        end
    else
        built = function(value: any): (boolean, string?)
            -- slow path
            for i = 1, count do
                if identity[i] then
                    if rawequal(value, values[i]) then
                        return true, nil
                    end
                elseif value == values[i] then
                    return true, nil
                end
            end
            return miss(name, value)
        end
    end
    return register(built, { kind = "oneOf", name = name })
end

function spec.assert(check: SpecFn): (...any) -> ()
    if not spec.fn(check) then
        error("assert expects a spec", 2)
    end
    local name = labelOf(check)
    return function(...: any): ()
        local ok, reason = check(...)
        if ok then
            return
        end
        if spec.string(reason) then
            error(reason :: string, 2)
        end
        if select("#", ...) == 1 then
            error(`expected {name}, got {describe(...)}`, 2)
        end
        error(`expected {name}`, 2)
    end
end

local text = spec.intersection(spec.string, spec.minLength(1))

local function makeParams(parts: { SpecFn }, name: string): SpecFn
    local count = #parts
    local first, second, third = parts[1], parts[2], parts[3]
    local built: SpecFn
    if count == 1 then
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= 1 then
                return missArgs(name, ...)
            end
            return first((select(1, ...)))
        end
    elseif count == 2 then
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= 2 then
                return missArgs(name, ...)
            end
            local ok, reason = first((select(1, ...)))
            if not ok then
                return ok, reason
            end
            return second((select(2, ...)))
        end
    elseif count == 3 then
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= 3 then
                return missArgs(name, ...)
            end
            local ok, reason = first((select(1, ...)))
            if not ok then
                return ok, reason
            end
            ok, reason = second((select(2, ...)))
            if not ok then
                return ok, reason
            end
            return third((select(3, ...)))
        end
    else
        built = function(...: any): (boolean, string?)
            -- slow path
            if select("#", ...) ~= count then
                return missArgs(name, ...)
            end
            for i = 1, count do
                local ok, reason = parts[i]((select(i, ...)))
                if not ok then
                    return ok, reason
                end
            end
            return true, nil
        end
    end
    return register(built, {
        kind = "params",
        name = name,
        shape = { parts = { list = parts } },
    })
end

function spec.reason(check: SpecFn, message: string): SpecFn
    if not spec.fn(check) then
        error("reason expects a spec", 2)
    end
    if not text(message) then
        error("reason is required", 2)
    end
    local built = function(value: any): (boolean, string?)
        if check(value) then
            return true, nil
        end
        return false, message
    end
    return register(built, {
        kind = "reason",
        name = message,
        shape = { inner = { check = check } },
    })
end

function spec.label(label: string, check: SpecFn): SpecFn
    if not text(label) then
        error("label is required", 2)
    end
    if not spec.fn(check) then
        error("label expects a spec", 2)
    end
    local built = function(value: any): (boolean, string?)
        local ok, reason = check(value)
        if ok then
            return true, nil
        end
        local why = reason or `expected {labelOf(check)}`
        return false, `{label}: {why}`
    end
    return register(built, {
        kind = "label",
        name = label,
        shape = { inner = { check = check } },
    })
end

local function isLabel(check: SpecFn): boolean
    local meta = META_REGISTRY[check]
    return meta ~= nil and meta.kind == "label"
end

function spec.params(...: SpecFn): SpecFn
    local count = select("#", ...)
    if count == 0 then
        error("params expects labels", 2)
    end
    local parts = { ... }
    local names = table.create(count) :: { string }
    for i = 1, count do
        local check = parts[i]
        if not isLabel(check) then
            error("params expects labels", 2)
        end
        names[i] = labelOf(check)
    end
    return makeParams(parts, table.concat(names, ", "))
end

strict_of.params = strictCombined("params", function(...: SpecFn): SpecFn
    return spec.params(...)
end)

strict_of.reason = function(_: SpecFn, meta: Meta): SpecFn
    local inner = if meta.shape then meta.shape.inner else nil
    return spec.reason(spec.strict(if inner then inner.check else spec.none), meta.name)
end

negate_of.reason = function(_: SpecFn, meta: Meta): SpecFn
    local inner = if meta.shape then meta.shape.inner else nil
    return spec.negate(if inner then inner.check else spec.none)
end

function spec.object(name: ObjectName): SpecFn
    if not text(name) then
        error("object name is required", 2)
    end
    return register(function(value: any): (boolean, string?)
        if spec.userdata(value) and typeof(value) == name then
            return true, nil
        end
        return miss(name, value)
    end, { kind = "object", name = name })
end

function spec.match(pattern: string): SpecFn
    if not text(pattern) then
        error("pattern is required", 2)
    end
    return register(function(value: any): (boolean, string?)
        -- slow path
        if spec.string(value) and string.match(value :: string, pattern) ~= nil then
            return true, nil
        end
        return miss("string match", value)
    end, { kind = "match", name = "string match" })
end

return spec
