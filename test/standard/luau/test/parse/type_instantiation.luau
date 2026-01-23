local function f<T, U>() end

local f1 = f<<number, string>>
local f2 = f<<number>>
local res = f<<number, string>>()
--[[ @result {
    line_offsets = {0, 29, 30, 61, 84},
    lines = 5,
    eof = {
        position = vector.create(33, 4),
        tag = "eof",
        text = "",
        leading_trivia = {},
        trailing_trivia = {},
    },
    root = {
        span_start = vector.create(0, 0),
        span_stop = vector.create(33, 4),
        statements = {
            {
                body = {
                    generic_packs = {},
                    open_generics = {
                        trailing_trivia = {},
                        text = "<",
                        leading_trivia = {},
                        position = vector.create(16, 0),
                    },
                    generics = {
                        {
                            node = {
                                name = {
                                    trailing_trivia = {},
                                    text = "T",
                                    leading_trivia = {},
                                    position = vector.create(17, 0),
                                },
                                span_start = vector.create(17, 0),
                                span_stop = vector.create(18, 0),
                                tag = "generic",
                            },
                            separator = {
                                trailing_trivia = {},
                                text = ",",
                                leading_trivia = {},
                                position = vector.create(18, 0),
                            },
                        },
                        {
                            node = {
                                name = {
                                    trailing_trivia = {},
                                    text = "U",
                                    leading_trivia = {
                                        {
                                            span_start = vector.create(19, 0),
                                            text = " ",
                                            span_stop = vector.create(20, 0),
                                            tag = "whitespace",
                                        },
                                    },
                                    position = vector.create(20, 0),
                                },
                                span_start = vector.create(20, 0),
                                span_stop = vector.create(21, 0),
                                tag = "generic",
                            },
                        },
                    },
                    parameters = {},
                    close_generics = {
                        trailing_trivia = {},
                        text = ">",
                        leading_trivia = {},
                        position = vector.create(21, 0),
                    },
                    open_parens = {
                        trailing_trivia = {},
                        text = "(",
                        leading_trivia = {},
                        position = vector.create(22, 0),
                    },
                    body = {
                        span_start = vector.create(24, 0),
                        span_stop = vector.create(25, 0),
                        statements = {},
                        tag = "block",
                    },
                    end_keyword = {
                        trailing_trivia = {},
                        text = "end",
                        leading_trivia = {
                            {
                                span_start = vector.create(24, 0),
                                text = " ",
                                span_stop = vector.create(25, 0),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(25, 0),
                    },
                    close_parens = {
                        trailing_trivia = {},
                        text = ")",
                        leading_trivia = {},
                        position = vector.create(23, 0),
                    },
                },
                name = {
                    name = {
                        trailing_trivia = {},
                        text = "f",
                        leading_trivia = {
                            {
                                span_start = vector.create(14, 0),
                                text = " ",
                                span_stop = vector.create(15, 0),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(15, 0),
                    },
                },
                attributes = {},
                function_keyword = {
                    trailing_trivia = {},
                    text = "function",
                    leading_trivia = {
                        {
                            span_start = vector.create(5, 0),
                            text = " ",
                            span_stop = vector.create(6, 0),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(6, 0),
                },
                span_start = vector.create(0, 0),
                span_stop = vector.create(28, 0),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {},
                    position = vector.create(0, 0),
                },
                tag = "localfunction",
            },
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "f1",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 2),
                                        text = " ",
                                        span_stop = vector.create(6, 2),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(6, 2),
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            expression = {
                                token = {
                                    trailing_trivia = {},
                                    text = "f",
                                    leading_trivia = {
                                        {
                                            span_start = vector.create(10, 2),
                                            text = " ",
                                            span_stop = vector.create(11, 2),
                                            tag = "whitespace",
                                        },
                                    },
                                    position = vector.create(11, 2),
                                },
                                local_node = {
                                    name = {
                                        trailing_trivia = {},
                                        text = "f",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(14, 0),
                                                text = " ",
                                                span_stop = vector.create(15, 0),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(15, 0),
                                    },
                                },
                                span_start = vector.create(11, 2),
                                span_stop = vector.create(12, 2),
                                upvalue = false,
                                tag = "local",
                            },
                            span_start = vector.create(11, 2),
                            span_stop = vector.create(30, 2),
                            type_arguments = {
                                {
                                    node = {
                                        span_start = vector.create(14, 2),
                                        name = {
                                            trailing_trivia = {},
                                            text = "number",
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(12, 2),
                                                    text = "<<",
                                                    span_stop = vector.create(14, 2),
                                                    tag = "whitespace",
                                                },
                                            },
                                            position = vector.create(14, 2),
                                        },
                                        span_stop = vector.create(20, 2),
                                        tag = "reference",
                                    },
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(20, 2),
                                    },
                                },
                                {
                                    node = {
                                        span_start = vector.create(22, 2),
                                        name = {
                                            trailing_trivia = {},
                                            text = "string",
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(21, 2),
                                                    text = " ",
                                                    span_stop = vector.create(22, 2),
                                                    tag = "whitespace",
                                                },
                                            },
                                            position = vector.create(22, 2),
                                        },
                                        span_stop = vector.create(28, 2),
                                        tag = "reference",
                                    },
                                },
                            },
                            tag = "instantiate",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(8, 2),
                            text = " ",
                            span_stop = vector.create(9, 2),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(9, 2),
                },
                span_start = vector.create(0, 2),
                span_stop = vector.create(30, 2),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {
                        {
                            span_start = vector.create(28, 0),
                            text = "\n",
                            span_stop = vector.create(0, 1),
                            tag = "whitespace",
                        },
                        {
                            span_start = vector.create(0, 1),
                            text = "\n",
                            span_stop = vector.create(0, 2),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 2),
                },
                tag = "local",
            },
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "f2",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 3),
                                        text = " ",
                                        span_stop = vector.create(6, 3),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(6, 3),
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            expression = {
                                token = {
                                    trailing_trivia = {},
                                    text = "f",
                                    leading_trivia = {
                                        {
                                            span_start = vector.create(10, 3),
                                            text = " ",
                                            span_stop = vector.create(11, 3),
                                            tag = "whitespace",
                                        },
                                    },
                                    position = vector.create(11, 3),
                                },
                                local_node = {
                                    name = {
                                        trailing_trivia = {},
                                        text = "f",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(14, 0),
                                                text = " ",
                                                span_stop = vector.create(15, 0),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(15, 0),
                                    },
                                },
                                span_start = vector.create(11, 3),
                                span_stop = vector.create(12, 3),
                                upvalue = false,
                                tag = "local",
                            },
                            span_start = vector.create(11, 3),
                            span_stop = vector.create(22, 3),
                            type_arguments = {
                                {
                                    node = {
                                        span_start = vector.create(14, 3),
                                        name = {
                                            trailing_trivia = {},
                                            text = "number",
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(12, 3),
                                                    text = "<<",
                                                    span_stop = vector.create(14, 3),
                                                    tag = "whitespace",
                                                },
                                            },
                                            position = vector.create(14, 3),
                                        },
                                        span_stop = vector.create(20, 3),
                                        tag = "reference",
                                    },
                                },
                            },
                            tag = "instantiate",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(8, 3),
                            text = " ",
                            span_stop = vector.create(9, 3),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(9, 3),
                },
                span_start = vector.create(0, 3),
                span_stop = vector.create(22, 3),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {
                        {
                            span_start = vector.create(28, 2),
                            text = ">>\n",
                            span_stop = vector.create(0, 3),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 3),
                },
                tag = "local",
            },
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "res",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 4),
                                        text = " ",
                                        span_stop = vector.create(6, 4),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(6, 4),
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            self = false,
                            arg_span_stop = vector.create(33, 4),
                            span_start = vector.create(12, 4),
                            func = {
                                expression = {
                                    token = {
                                        trailing_trivia = {},
                                        text = "f",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(11, 4),
                                                text = " ",
                                                span_stop = vector.create(12, 4),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(12, 4),
                                    },
                                    local_node = {
                                        name = {
                                            trailing_trivia = {},
                                            text = "f",
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(14, 0),
                                                    text = " ",
                                                    span_stop = vector.create(15, 0),
                                                    tag = "whitespace",
                                                },
                                            },
                                            position = vector.create(15, 0),
                                        },
                                    },
                                    span_start = vector.create(12, 4),
                                    span_stop = vector.create(13, 4),
                                    upvalue = false,
                                    tag = "local",
                                },
                                span_start = vector.create(12, 4),
                                span_stop = vector.create(31, 4),
                                type_arguments = {
                                    {
                                        node = {
                                            span_start = vector.create(15, 4),
                                            name = {
                                                trailing_trivia = {},
                                                text = "number",
                                                leading_trivia = {
                                                    {
                                                        span_start = vector.create(13, 4),
                                                        text = "<<",
                                                        span_stop = vector.create(15, 4),
                                                        tag = "whitespace",
                                                    },
                                                },
                                                position = vector.create(15, 4),
                                            },
                                            span_stop = vector.create(21, 4),
                                            tag = "reference",
                                        },
                                        separator = {
                                            trailing_trivia = {},
                                            text = ",",
                                            leading_trivia = {},
                                            position = vector.create(21, 4),
                                        },
                                    },
                                    {
                                        node = {
                                            span_start = vector.create(23, 4),
                                            name = {
                                                trailing_trivia = {},
                                                text = "string",
                                                leading_trivia = {
                                                    {
                                                        span_start = vector.create(22, 4),
                                                        text = " ",
                                                        span_stop = vector.create(23, 4),
                                                        tag = "whitespace",
                                                    },
                                                },
                                                position = vector.create(23, 4),
                                            },
                                            span_stop = vector.create(29, 4),
                                            tag = "reference",
                                        },
                                    },
                                },
                                tag = "instantiate",
                            },
                            arguments = {},
                            close_parens = {
                                trailing_trivia = {},
                                text = ")",
                                leading_trivia = {},
                                position = vector.create(32, 4),
                            },
                            arg_span_start = vector.create(32, 4),
                            span_stop = vector.create(33, 4),
                            open_parens = {
                                trailing_trivia = {},
                                text = "(",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(29, 4),
                                        text = ">>",
                                        span_stop = vector.create(31, 4),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(31, 4),
                            },
                            tag = "call",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(9, 4),
                            text = " ",
                            span_stop = vector.create(10, 4),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(10, 4),
                },
                span_start = vector.create(0, 4),
                span_stop = vector.create(33, 4),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {
                        {
                            span_start = vector.create(20, 3),
                            text = ">>\n",
                            span_stop = vector.create(0, 4),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 4),
                },
                tag = "local",
            },
        },
        tag = "block",
    },
    hotcomments = {},
}, {
    LuauExplicitTypeInstantiationSyntax = true
}]]