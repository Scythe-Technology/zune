@native
function foo() end

@deprecated
function bar2() end

@[deprecated({reason = "reason"})]
function bar() end
@native
@[
    deprecated{reason = "reason 2"}
]
function abc() end
--[[ @result {
    line_offsets = {0, 8, 27, 28, 40, 60, 61, 96, 115, 123, 126, 162, 164},
    lines = 13,
    eof = {
        position = vector.create(18, 12),
        tag = "eof",
        text = "",
        leading_trivia = {},
        trailing_trivia = {},
    },
    root = {
        span_start = vector.create(0, 0),
        span_stop = vector.create(18, 12),
        statements = {
            {
                body = {
                    open_parens = {
                        trailing_trivia = {},
                        text = "(",
                        leading_trivia = {},
                        position = vector.create(12, 1),
                    },
                    parameters = {},
                    body = {
                        span_start = vector.create(14, 1),
                        span_stop = vector.create(15, 1),
                        statements = {},
                        tag = "block",
                    },
                    end_keyword = {
                        trailing_trivia = {},
                        text = "end",
                        leading_trivia = {
                            {
                                span_start = vector.create(14, 1),
                                text = " ",
                                span_stop = vector.create(15, 1),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(15, 1),
                    },
                    close_parens = {
                        trailing_trivia = {},
                        text = ")",
                        leading_trivia = {},
                        position = vector.create(13, 1),
                    },
                },
                attributes = {
                    {
                        type = {
                            trailing_trivia = {},
                            text = "@native",
                            leading_trivia = {},
                            position = vector.create(0, 0),
                        },
                        args = {},
                        span_start = vector.create(0, 0),
                        span_stop = vector.create(7, 0),
                        tag = "attribute",
                    },
                },
                name = {
                    span_start = vector.create(9, 1),
                    span_stop = vector.create(12, 1),
                    name = {
                        trailing_trivia = {},
                        text = "foo",
                        leading_trivia = {
                            {
                                span_start = vector.create(8, 1),
                                text = " ",
                                span_stop = vector.create(9, 1),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(9, 1),
                    },
                    tag = "global",
                },
                span_start = vector.create(0, 0),
                span_stop = vector.create(18, 1),
                function_keyword = {
                    trailing_trivia = {},
                    text = "function",
                    leading_trivia = {
                        {
                            span_start = vector.create(7, 0),
                            text = "\n",
                            span_stop = vector.create(0, 1),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 1),
                },
                tag = "function",
            },
            {
                body = {
                    open_parens = {
                        trailing_trivia = {},
                        text = "(",
                        leading_trivia = {},
                        position = vector.create(13, 4),
                    },
                    parameters = {},
                    body = {
                        span_start = vector.create(15, 4),
                        span_stop = vector.create(16, 4),
                        statements = {},
                        tag = "block",
                    },
                    end_keyword = {
                        trailing_trivia = {},
                        text = "end",
                        leading_trivia = {
                            {
                                span_start = vector.create(15, 4),
                                text = " ",
                                span_stop = vector.create(16, 4),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(16, 4),
                    },
                    close_parens = {
                        trailing_trivia = {},
                        text = ")",
                        leading_trivia = {},
                        position = vector.create(14, 4),
                    },
                },
                attributes = {
                    {
                        type = {
                            trailing_trivia = {},
                            text = "@deprecated",
                            leading_trivia = {
                                {
                                    span_start = vector.create(18, 1),
                                    text = "\n",
                                    span_stop = vector.create(0, 2),
                                    tag = "whitespace",
                                },
                                {
                                    span_start = vector.create(0, 2),
                                    text = "\n",
                                    span_stop = vector.create(0, 3),
                                    tag = "whitespace",
                                },
                            },
                            position = vector.create(0, 3),
                        },
                        args = {},
                        span_start = vector.create(0, 3),
                        span_stop = vector.create(11, 3),
                        tag = "attribute",
                    },
                },
                name = {
                    span_start = vector.create(9, 4),
                    span_stop = vector.create(13, 4),
                    name = {
                        trailing_trivia = {},
                        text = "bar2",
                        leading_trivia = {
                            {
                                span_start = vector.create(8, 4),
                                text = " ",
                                span_stop = vector.create(9, 4),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(9, 4),
                    },
                    tag = "global",
                },
                span_start = vector.create(0, 3),
                span_stop = vector.create(19, 4),
                function_keyword = {
                    trailing_trivia = {},
                    text = "function",
                    leading_trivia = {
                        {
                            span_start = vector.create(11, 3),
                            text = "\n",
                            span_stop = vector.create(0, 4),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 4),
                },
                tag = "function",
            },
            {
                body = {
                    open_parens = {
                        trailing_trivia = {},
                        text = "(",
                        leading_trivia = {},
                        position = vector.create(12, 7),
                    },
                    parameters = {},
                    body = {
                        span_start = vector.create(14, 7),
                        span_stop = vector.create(15, 7),
                        statements = {},
                        tag = "block",
                    },
                    end_keyword = {
                        trailing_trivia = {},
                        text = "end",
                        leading_trivia = {
                            {
                                span_start = vector.create(14, 7),
                                text = " ",
                                span_stop = vector.create(15, 7),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(15, 7),
                    },
                    close_parens = {
                        trailing_trivia = {},
                        text = ")",
                        leading_trivia = {},
                        position = vector.create(13, 7),
                    },
                },
                attributes = {
                    {
                        attr_close = {
                            trailing_trivia = {},
                            text = "]",
                            leading_trivia = {},
                            position = vector.create(32, 6),
                        },
                        attr_open = {
                            trailing_trivia = {},
                            text = "@[",
                            leading_trivia = {
                                {
                                    span_start = vector.create(19, 4),
                                    text = "\n",
                                    span_stop = vector.create(0, 5),
                                    tag = "whitespace",
                                },
                                {
                                    span_start = vector.create(0, 5),
                                    text = "\n",
                                    span_stop = vector.create(0, 6),
                                    tag = "whitespace",
                                },
                            },
                            position = vector.create(0, 6),
                        },
                        args = {
                            {
                                open_brace = {
                                    trailing_trivia = {},
                                    text = "{",
                                    leading_trivia = {
                                        {
                                            span_start = vector.create(12, 6),
                                            text = "(",
                                            span_stop = vector.create(13, 6),
                                            tag = "whitespace",
                                        },
                                    },
                                    position = vector.create(13, 6),
                                },
                                close_brace = {
                                    trailing_trivia = {},
                                    text = "}",
                                    leading_trivia = {},
                                    position = vector.create(31, 6),
                                },
                                span_start = vector.create(13, 6),
                                span_stop = vector.create(32, 6),
                                entries = {
                                    {
                                        key = {
                                            trailing_trivia = {},
                                            text = "reason",
                                            leading_trivia = {},
                                            position = vector.create(14, 6),
                                        },
                                        equals = {
                                            trailing_trivia = {},
                                            text = "=",
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(20, 6),
                                                    text = " ",
                                                    span_stop = vector.create(21, 6),
                                                    tag = "whitespace",
                                                },
                                            },
                                            position = vector.create(21, 6),
                                        },
                                        value = {
                                            block_depth = 0,
                                            span_start = vector.create(23, 6),
                                            text = "reason",
                                            trailing_trivia = {},
                                            position = vector.create(23, 6),
                                            quote_style = "double",
                                            span_stop = vector.create(31, 6),
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(22, 6),
                                                    text = " ",
                                                    span_stop = vector.create(23, 6),
                                                    tag = "whitespace",
                                                },
                                            },
                                            tag = "string",
                                        },
                                        kind = "record",
                                    },
                                },
                                tag = "table",
                            },
                        },
                        span_start = vector.create(2, 6),
                        span_stop = vector.create(33, 6),
                        type = {
                            trailing_trivia = {},
                            text = "deprecated",
                            leading_trivia = {},
                            position = vector.create(2, 6),
                        },
                        tag = "attribute",
                    },
                },
                name = {
                    span_start = vector.create(9, 7),
                    span_stop = vector.create(12, 7),
                    name = {
                        trailing_trivia = {},
                        text = "bar",
                        leading_trivia = {
                            {
                                span_start = vector.create(8, 7),
                                text = " ",
                                span_stop = vector.create(9, 7),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(9, 7),
                    },
                    tag = "global",
                },
                span_start = vector.create(2, 6),
                span_stop = vector.create(18, 7),
                function_keyword = {
                    trailing_trivia = {},
                    text = "function",
                    leading_trivia = {
                        {
                            span_start = vector.create(33, 6),
                            text = "]\n",
                            span_stop = vector.create(0, 7),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 7),
                },
                tag = "function",
            },
            {
                body = {
                    open_parens = {
                        trailing_trivia = {},
                        text = "(",
                        leading_trivia = {},
                        position = vector.create(12, 12),
                    },
                    parameters = {},
                    body = {
                        span_start = vector.create(14, 12),
                        span_stop = vector.create(15, 12),
                        statements = {},
                        tag = "block",
                    },
                    end_keyword = {
                        trailing_trivia = {},
                        text = "end",
                        leading_trivia = {
                            {
                                span_start = vector.create(14, 12),
                                text = " ",
                                span_stop = vector.create(15, 12),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(15, 12),
                    },
                    close_parens = {
                        trailing_trivia = {},
                        text = ")",
                        leading_trivia = {},
                        position = vector.create(13, 12),
                    },
                },
                attributes = {
                    {
                        type = {
                            trailing_trivia = {},
                            text = "@native",
                            leading_trivia = {
                                {
                                    span_start = vector.create(18, 7),
                                    text = "\n",
                                    span_stop = vector.create(0, 8),
                                    tag = "whitespace",
                                },
                            },
                            position = vector.create(0, 8),
                        },
                        args = {},
                        span_start = vector.create(0, 8),
                        span_stop = vector.create(7, 8),
                        tag = "attribute",
                    },
                    {
                        attr_close = {
                            trailing_trivia = {},
                            text = "]",
                            leading_trivia = {
                                {
                                    span_start = vector.create(35, 10),
                                    text = "\n",
                                    span_stop = vector.create(0, 11),
                                    tag = "whitespace",
                                },
                            },
                            position = vector.create(0, 11),
                        },
                        attr_open = {
                            trailing_trivia = {},
                            text = "@[",
                            leading_trivia = {
                                {
                                    span_start = vector.create(7, 8),
                                    text = "\n",
                                    span_stop = vector.create(0, 9),
                                    tag = "whitespace",
                                },
                            },
                            position = vector.create(0, 9),
                        },
                        args = {
                            {
                                open_brace = {
                                    trailing_trivia = {},
                                    text = "{",
                                    leading_trivia = {},
                                    position = vector.create(14, 10),
                                },
                                close_brace = {
                                    trailing_trivia = {},
                                    text = "}",
                                    leading_trivia = {},
                                    position = vector.create(34, 10),
                                },
                                span_start = vector.create(14, 10),
                                span_stop = vector.create(35, 10),
                                entries = {
                                    {
                                        key = {
                                            trailing_trivia = {},
                                            text = "reason",
                                            leading_trivia = {},
                                            position = vector.create(15, 10),
                                        },
                                        equals = {
                                            trailing_trivia = {},
                                            text = "=",
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(21, 10),
                                                    text = " ",
                                                    span_stop = vector.create(22, 10),
                                                    tag = "whitespace",
                                                },
                                            },
                                            position = vector.create(22, 10),
                                        },
                                        value = {
                                            block_depth = 0,
                                            span_start = vector.create(24, 10),
                                            text = "reason 2",
                                            trailing_trivia = {},
                                            position = vector.create(24, 10),
                                            quote_style = "double",
                                            span_stop = vector.create(34, 10),
                                            leading_trivia = {
                                                {
                                                    span_start = vector.create(23, 10),
                                                    text = " ",
                                                    span_stop = vector.create(24, 10),
                                                    tag = "whitespace",
                                                },
                                            },
                                            tag = "string",
                                        },
                                        kind = "record",
                                    },
                                },
                                tag = "table",
                            },
                        },
                        span_start = vector.create(4, 10),
                        span_stop = vector.create(35, 10),
                        type = {
                            trailing_trivia = {},
                            text = "deprecated",
                            leading_trivia = {
                                {
                                    span_start = vector.create(2, 9),
                                    text = "\n",
                                    span_stop = vector.create(0, 10),
                                    tag = "whitespace",
                                },
                                {
                                    span_start = vector.create(0, 10),
                                    text = "    ",
                                    span_stop = vector.create(4, 10),
                                    tag = "whitespace",
                                },
                            },
                            position = vector.create(4, 10),
                        },
                        tag = "attribute",
                    },
                },
                name = {
                    span_start = vector.create(9, 12),
                    span_stop = vector.create(12, 12),
                    name = {
                        trailing_trivia = {},
                        text = "abc",
                        leading_trivia = {
                            {
                                span_start = vector.create(8, 12),
                                text = " ",
                                span_stop = vector.create(9, 12),
                                tag = "whitespace",
                            },
                        },
                        position = vector.create(9, 12),
                    },
                    tag = "global",
                },
                span_start = vector.create(0, 8),
                span_stop = vector.create(18, 12),
                function_keyword = {
                    trailing_trivia = {},
                    text = "function",
                    leading_trivia = {
                        {
                            span_start = vector.create(1, 11),
                            text = "\n",
                            span_stop = vector.create(0, 12),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 12),
                },
                tag = "function",
            },
        },
        tag = "block",
    },
    hotcomments = {},
}, {
}]]