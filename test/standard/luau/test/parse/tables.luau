local list = {
    [1] = "a",
    [2] = "b",
    [3] = "c",
}

local dict = {
    key1 = "value1",
    key2 = "value2",
    key3 = "value3",
}

local mixed = {
    [1] = "first",
    second = 2,
    [3] = "third",
    fourth = 4,
}

local general = {
    [{}] = "empty_table_key",
    [function() end] = "function_key",
    [vector.create(1,2,3)] = "vector_key",
}

--[[ @result {
    lines = 24,
    line_offsets = {0, 15, 30, 45, 60, 62, 63, 78, 99, 120, 141, 143, 144, 160, 179, 195, 214, 230, 232, 233, 251, 281, 320, 363, 365},
    lines = 24,
    eof = {
        position = vector.create(0, 24),
        tag = "eof",
        text = "",
        leading_trivia = {
            {
                span_start = vector.create(1, 23),
                text = "\n",
                span_stop = vector.create(0, 24),
                tag = "whitespace",
            },
        },
        trailing_trivia = {},
    },
    root = {
        span_start = vector.create(0, 0),
        span_stop = vector.create(0, 24),
        statements = {
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "list",
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
                        },
                    },
                },
                values = {
                    {
                        node = {
                            open_brace = {
                                trailing_trivia = {},
                                text = "{",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(12, 0),
                                        text = " ",
                                        span_stop = vector.create(13, 0),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(13, 0),
                            },
                            close_brace = {
                                trailing_trivia = {},
                                text = "}",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(14, 3),
                                        text = "\n",
                                        span_stop = vector.create(0, 4),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(0, 4),
                            },
                            span_start = vector.create(13, 0),
                            span_stop = vector.create(1, 4),
                            entries = {
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(6, 1),
                                    },
                                    key = {
                                        value = 1,
                                        span_stop = vector.create(6, 1),
                                        tag = "number",
                                        position = vector.create(5, 1),
                                        span_start = vector.create(5, 1),
                                        text = "1",
                                        leading_trivia = {},
                                        trailing_trivia = {},
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(7, 1),
                                                text = " ",
                                                span_stop = vector.create(8, 1),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(8, 1),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(10, 1),
                                        text = "a",
                                        trailing_trivia = {},
                                        position = vector.create(10, 1),
                                        quote_style = "double",
                                        span_stop = vector.create(13, 1),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(9, 1),
                                                text = " ",
                                                span_stop = vector.create(10, 1),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(13, 1),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(14, 0),
                                                text = "\n",
                                                span_stop = vector.create(0, 1),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 1),
                                                text = "    ",
                                                span_stop = vector.create(4, 1),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 1),
                                    },
                                },
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(6, 2),
                                    },
                                    key = {
                                        value = 2,
                                        span_stop = vector.create(6, 2),
                                        tag = "number",
                                        position = vector.create(5, 2),
                                        span_start = vector.create(5, 2),
                                        text = "2",
                                        leading_trivia = {},
                                        trailing_trivia = {},
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(7, 2),
                                                text = " ",
                                                span_stop = vector.create(8, 2),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(8, 2),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(10, 2),
                                        text = "b",
                                        trailing_trivia = {},
                                        position = vector.create(10, 2),
                                        quote_style = "double",
                                        span_stop = vector.create(13, 2),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(9, 2),
                                                text = " ",
                                                span_stop = vector.create(10, 2),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(13, 2),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(14, 1),
                                                text = "\n",
                                                span_stop = vector.create(0, 2),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 2),
                                                text = "    ",
                                                span_stop = vector.create(4, 2),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 2),
                                    },
                                },
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(6, 3),
                                    },
                                    key = {
                                        value = 3,
                                        span_stop = vector.create(6, 3),
                                        tag = "number",
                                        position = vector.create(5, 3),
                                        span_start = vector.create(5, 3),
                                        text = "3",
                                        leading_trivia = {},
                                        trailing_trivia = {},
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(7, 3),
                                                text = " ",
                                                span_stop = vector.create(8, 3),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(8, 3),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(10, 3),
                                        text = "c",
                                        trailing_trivia = {},
                                        position = vector.create(10, 3),
                                        quote_style = "double",
                                        span_stop = vector.create(13, 3),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(9, 3),
                                                text = " ",
                                                span_stop = vector.create(10, 3),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(13, 3),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(14, 2),
                                                text = "\n",
                                                span_stop = vector.create(0, 3),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 3),
                                                text = "    ",
                                                span_stop = vector.create(4, 3),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 3),
                                    },
                                },
                            },
                            tag = "table",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(10, 0),
                            text = " ",
                            span_stop = vector.create(11, 0),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(11, 0),
                },
                span_start = vector.create(0, 0),
                span_stop = vector.create(1, 4),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {},
                    position = vector.create(0, 0),
                },
                tag = "local",
            },
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "dict",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 6),
                                        text = " ",
                                        span_stop = vector.create(6, 6),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(6, 6),
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            open_brace = {
                                trailing_trivia = {},
                                text = "{",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(12, 6),
                                        text = " ",
                                        span_stop = vector.create(13, 6),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(13, 6),
                            },
                            close_brace = {
                                trailing_trivia = {},
                                text = "}",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(20, 9),
                                        text = "\n",
                                        span_stop = vector.create(0, 10),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(0, 10),
                            },
                            span_start = vector.create(13, 6),
                            span_stop = vector.create(1, 10),
                            entries = {
                                {
                                    key = {
                                        trailing_trivia = {},
                                        text = "key1",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(14, 6),
                                                text = "\n",
                                                span_stop = vector.create(0, 7),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 7),
                                                text = "    ",
                                                span_stop = vector.create(4, 7),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 7),
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
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
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(11, 7),
                                        text = "value1",
                                        trailing_trivia = {},
                                        position = vector.create(11, 7),
                                        quote_style = "double",
                                        span_stop = vector.create(19, 7),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(10, 7),
                                                text = " ",
                                                span_stop = vector.create(11, 7),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "record",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(19, 7),
                                    },
                                },
                                {
                                    key = {
                                        trailing_trivia = {},
                                        text = "key2",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(20, 7),
                                                text = "\n",
                                                span_stop = vector.create(0, 8),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 8),
                                                text = "    ",
                                                span_stop = vector.create(4, 8),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 8),
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(8, 8),
                                                text = " ",
                                                span_stop = vector.create(9, 8),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(9, 8),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(11, 8),
                                        text = "value2",
                                        trailing_trivia = {},
                                        position = vector.create(11, 8),
                                        quote_style = "double",
                                        span_stop = vector.create(19, 8),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(10, 8),
                                                text = " ",
                                                span_stop = vector.create(11, 8),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "record",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(19, 8),
                                    },
                                },
                                {
                                    key = {
                                        trailing_trivia = {},
                                        text = "key3",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(20, 8),
                                                text = "\n",
                                                span_stop = vector.create(0, 9),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 9),
                                                text = "    ",
                                                span_stop = vector.create(4, 9),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 9),
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(8, 9),
                                                text = " ",
                                                span_stop = vector.create(9, 9),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(9, 9),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(11, 9),
                                        text = "value3",
                                        trailing_trivia = {},
                                        position = vector.create(11, 9),
                                        quote_style = "double",
                                        span_stop = vector.create(19, 9),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(10, 9),
                                                text = " ",
                                                span_stop = vector.create(11, 9),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "record",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(19, 9),
                                    },
                                },
                            },
                            tag = "table",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(10, 6),
                            text = " ",
                            span_stop = vector.create(11, 6),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(11, 6),
                },
                span_start = vector.create(0, 6),
                span_stop = vector.create(1, 10),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {
                        {
                            span_start = vector.create(1, 4),
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
                tag = "local",
            },
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "mixed",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 12),
                                        text = " ",
                                        span_stop = vector.create(6, 12),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(6, 12),
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            open_brace = {
                                trailing_trivia = {},
                                text = "{",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(13, 12),
                                        text = " ",
                                        span_stop = vector.create(14, 12),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(14, 12),
                            },
                            close_brace = {
                                trailing_trivia = {},
                                text = "}",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(15, 16),
                                        text = "\n",
                                        span_stop = vector.create(0, 17),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(0, 17),
                            },
                            span_start = vector.create(14, 12),
                            span_stop = vector.create(1, 17),
                            entries = {
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(6, 13),
                                    },
                                    key = {
                                        value = 1,
                                        span_stop = vector.create(6, 13),
                                        tag = "number",
                                        position = vector.create(5, 13),
                                        span_start = vector.create(5, 13),
                                        text = "1",
                                        leading_trivia = {},
                                        trailing_trivia = {},
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(7, 13),
                                                text = " ",
                                                span_stop = vector.create(8, 13),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(8, 13),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(10, 13),
                                        text = "first",
                                        trailing_trivia = {},
                                        position = vector.create(10, 13),
                                        quote_style = "double",
                                        span_stop = vector.create(17, 13),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(9, 13),
                                                text = " ",
                                                span_stop = vector.create(10, 13),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(17, 13),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(15, 12),
                                                text = "\n",
                                                span_stop = vector.create(0, 13),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 13),
                                                text = "    ",
                                                span_stop = vector.create(4, 13),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 13),
                                    },
                                },
                                {
                                    key = {
                                        trailing_trivia = {},
                                        text = "second",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(18, 13),
                                                text = "\n",
                                                span_stop = vector.create(0, 14),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 14),
                                                text = "    ",
                                                span_stop = vector.create(4, 14),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 14),
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(10, 14),
                                                text = " ",
                                                span_stop = vector.create(11, 14),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(11, 14),
                                    },
                                    value = {
                                        value = 2,
                                        span_stop = vector.create(14, 14),
                                        tag = "number",
                                        position = vector.create(13, 14),
                                        span_start = vector.create(13, 14),
                                        text = "2",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(12, 14),
                                                text = " ",
                                                span_stop = vector.create(13, 14),
                                                tag = "whitespace",
                                            },
                                        },
                                        trailing_trivia = {},
                                    },
                                    kind = "record",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(14, 14),
                                    },
                                },
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(6, 15),
                                    },
                                    key = {
                                        value = 3,
                                        span_stop = vector.create(6, 15),
                                        tag = "number",
                                        position = vector.create(5, 15),
                                        span_start = vector.create(5, 15),
                                        text = "3",
                                        leading_trivia = {},
                                        trailing_trivia = {},
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(7, 15),
                                                text = " ",
                                                span_stop = vector.create(8, 15),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(8, 15),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(10, 15),
                                        text = "third",
                                        trailing_trivia = {},
                                        position = vector.create(10, 15),
                                        quote_style = "double",
                                        span_stop = vector.create(17, 15),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(9, 15),
                                                text = " ",
                                                span_stop = vector.create(10, 15),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(17, 15),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(15, 14),
                                                text = "\n",
                                                span_stop = vector.create(0, 15),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 15),
                                                text = "    ",
                                                span_stop = vector.create(4, 15),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 15),
                                    },
                                },
                                {
                                    key = {
                                        trailing_trivia = {},
                                        text = "fourth",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(18, 15),
                                                text = "\n",
                                                span_stop = vector.create(0, 16),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 16),
                                                text = "    ",
                                                span_stop = vector.create(4, 16),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 16),
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(10, 16),
                                                text = " ",
                                                span_stop = vector.create(11, 16),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(11, 16),
                                    },
                                    value = {
                                        value = 4,
                                        span_stop = vector.create(14, 16),
                                        tag = "number",
                                        position = vector.create(13, 16),
                                        span_start = vector.create(13, 16),
                                        text = "4",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(12, 16),
                                                text = " ",
                                                span_stop = vector.create(13, 16),
                                                tag = "whitespace",
                                            },
                                        },
                                        trailing_trivia = {},
                                    },
                                    kind = "record",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(14, 16),
                                    },
                                },
                            },
                            tag = "table",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(11, 12),
                            text = " ",
                            span_stop = vector.create(12, 12),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(12, 12),
                },
                span_start = vector.create(0, 12),
                span_stop = vector.create(1, 17),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {
                        {
                            span_start = vector.create(1, 10),
                            text = "\n",
                            span_stop = vector.create(0, 11),
                            tag = "whitespace",
                        },
                        {
                            span_start = vector.create(0, 11),
                            text = "\n",
                            span_stop = vector.create(0, 12),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 12),
                },
                tag = "local",
            },
            {
                variables = {
                    {
                        node = {
                            name = {
                                trailing_trivia = {},
                                text = "general",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 19),
                                        text = " ",
                                        span_stop = vector.create(6, 19),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(6, 19),
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            open_brace = {
                                trailing_trivia = {},
                                text = "{",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(15, 19),
                                        text = " ",
                                        span_stop = vector.create(16, 19),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(16, 19),
                            },
                            close_brace = {
                                trailing_trivia = {},
                                text = "}",
                                leading_trivia = {
                                    {
                                        span_start = vector.create(42, 22),
                                        text = "\n",
                                        span_stop = vector.create(0, 23),
                                        tag = "whitespace",
                                    },
                                },
                                position = vector.create(0, 23),
                            },
                            span_start = vector.create(16, 19),
                            span_stop = vector.create(1, 23),
                            entries = {
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(7, 20),
                                    },
                                    key = {
                                        open_brace = {
                                            trailing_trivia = {},
                                            text = "{",
                                            leading_trivia = {},
                                            position = vector.create(5, 20),
                                        },
                                        close_brace = {
                                            trailing_trivia = {},
                                            text = "}",
                                            leading_trivia = {},
                                            position = vector.create(6, 20),
                                        },
                                        span_start = vector.create(5, 20),
                                        span_stop = vector.create(7, 20),
                                        entries = {},
                                        tag = "table",
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(8, 20),
                                                text = " ",
                                                span_stop = vector.create(9, 20),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(9, 20),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(11, 20),
                                        text = "empty_table_key",
                                        trailing_trivia = {},
                                        position = vector.create(11, 20),
                                        quote_style = "double",
                                        span_stop = vector.create(28, 20),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(10, 20),
                                                text = " ",
                                                span_stop = vector.create(11, 20),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(28, 20),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(17, 19),
                                                text = "\n",
                                                span_stop = vector.create(0, 20),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 20),
                                                text = "    ",
                                                span_stop = vector.create(4, 20),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 20),
                                    },
                                },
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(19, 21),
                                    },
                                    key = {
                                        attributes = {},
                                        body = {
                                            open_parens = {
                                                trailing_trivia = {},
                                                text = "(",
                                                leading_trivia = {},
                                                position = vector.create(13, 21),
                                            },
                                            parameters = {},
                                            body = {
                                                span_start = vector.create(15, 21),
                                                span_stop = vector.create(16, 21),
                                                statements = {},
                                                tag = "block",
                                            },
                                            end_keyword = {
                                                trailing_trivia = {},
                                                text = "end",
                                                leading_trivia = {
                                                    {
                                                        span_start = vector.create(15, 21),
                                                        text = " ",
                                                        span_stop = vector.create(16, 21),
                                                        tag = "whitespace",
                                                    },
                                                },
                                                position = vector.create(16, 21),
                                            },
                                            close_parens = {
                                                trailing_trivia = {},
                                                text = ")",
                                                leading_trivia = {},
                                                position = vector.create(14, 21),
                                            },
                                        },
                                        span_start = vector.create(5, 21),
                                        span_stop = vector.create(19, 21),
                                        function_keyword = {
                                            trailing_trivia = {},
                                            text = "function",
                                            leading_trivia = {},
                                            position = vector.create(5, 21),
                                        },
                                        tag = "function",
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(20, 21),
                                                text = " ",
                                                span_stop = vector.create(21, 21),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(21, 21),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(23, 21),
                                        text = "function_key",
                                        trailing_trivia = {},
                                        position = vector.create(23, 21),
                                        quote_style = "double",
                                        span_stop = vector.create(37, 21),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(22, 21),
                                                text = " ",
                                                span_stop = vector.create(23, 21),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(37, 21),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(29, 20),
                                                text = "\n",
                                                span_stop = vector.create(0, 21),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 21),
                                                text = "    ",
                                                span_stop = vector.create(4, 21),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 21),
                                    },
                                },
                                {
                                    indexer_close = {
                                        trailing_trivia = {},
                                        text = "]",
                                        leading_trivia = {},
                                        position = vector.create(25, 22),
                                    },
                                    key = {
                                        self = false,
                                        arg_span_start = vector.create(19, 22),
                                        arg_span_stop = vector.create(25, 22),
                                        span_start = vector.create(5, 22),
                                        func = {
                                            index = {
                                                trailing_trivia = {},
                                                text = "create",
                                                leading_trivia = {},
                                                position = vector.create(12, 22),
                                                span_start = vector.create(12, 22),
                                                span_stop = vector.create(18, 22),
                                            },
                                            accessor = {
                                                trailing_trivia = {},
                                                text = ".",
                                                leading_trivia = {},
                                                position = vector.create(11, 22),
                                            },
                                            span_start = vector.create(5, 22),
                                            span_stop = vector.create(18, 22),
                                            expression = {
                                                span_start = vector.create(5, 22),
                                                span_stop = vector.create(11, 22),
                                                name = {
                                                    trailing_trivia = {},
                                                    text = "vector",
                                                    leading_trivia = {},
                                                    position = vector.create(5, 22),
                                                },
                                                tag = "global",
                                            },
                                            tag = "indexname",
                                        },
                                        arguments = {
                                            {
                                                node = {
                                                    value = 1,
                                                    span_stop = vector.create(20, 22),
                                                    tag = "number",
                                                    position = vector.create(19, 22),
                                                    span_start = vector.create(19, 22),
                                                    text = "1",
                                                    leading_trivia = {},
                                                    trailing_trivia = {},
                                                },
                                                separator = {
                                                    trailing_trivia = {},
                                                    text = ",",
                                                    leading_trivia = {},
                                                    position = vector.create(20, 22),
                                                },
                                            },
                                            {
                                                node = {
                                                    value = 2,
                                                    span_stop = vector.create(22, 22),
                                                    tag = "number",
                                                    position = vector.create(21, 22),
                                                    span_start = vector.create(21, 22),
                                                    text = "2",
                                                    leading_trivia = {},
                                                    trailing_trivia = {},
                                                },
                                                separator = {
                                                    trailing_trivia = {},
                                                    text = ",",
                                                    leading_trivia = {},
                                                    position = vector.create(22, 22),
                                                },
                                            },
                                            {
                                                node = {
                                                    value = 3,
                                                    span_stop = vector.create(24, 22),
                                                    tag = "number",
                                                    position = vector.create(23, 22),
                                                    span_start = vector.create(23, 22),
                                                    text = "3",
                                                    leading_trivia = {},
                                                    trailing_trivia = {},
                                                },
                                            },
                                        },
                                        close_parens = {
                                            trailing_trivia = {},
                                            text = ")",
                                            leading_trivia = {},
                                            position = vector.create(24, 22),
                                        },
                                        span_stop = vector.create(25, 22),
                                        open_parens = {
                                            trailing_trivia = {},
                                            text = "(",
                                            leading_trivia = {},
                                            position = vector.create(18, 22),
                                        },
                                        tag = "call",
                                    },
                                    equals = {
                                        trailing_trivia = {},
                                        text = "=",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(26, 22),
                                                text = " ",
                                                span_stop = vector.create(27, 22),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(27, 22),
                                    },
                                    value = {
                                        block_depth = 0,
                                        span_start = vector.create(29, 22),
                                        text = "vector_key",
                                        trailing_trivia = {},
                                        position = vector.create(29, 22),
                                        quote_style = "double",
                                        span_stop = vector.create(41, 22),
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(28, 22),
                                                text = " ",
                                                span_stop = vector.create(29, 22),
                                                tag = "whitespace",
                                            },
                                        },
                                        tag = "string",
                                    },
                                    kind = "general",
                                    separator = {
                                        trailing_trivia = {},
                                        text = ",",
                                        leading_trivia = {},
                                        position = vector.create(41, 22),
                                    },
                                    indexer_open = {
                                        trailing_trivia = {},
                                        text = "[",
                                        leading_trivia = {
                                            {
                                                span_start = vector.create(38, 21),
                                                text = "\n",
                                                span_stop = vector.create(0, 22),
                                                tag = "whitespace",
                                            },
                                            {
                                                span_start = vector.create(0, 22),
                                                text = "    ",
                                                span_stop = vector.create(4, 22),
                                                tag = "whitespace",
                                            },
                                        },
                                        position = vector.create(4, 22),
                                    },
                                },
                            },
                            tag = "table",
                        },
                    },
                },
                equals = {
                    trailing_trivia = {},
                    text = "=",
                    leading_trivia = {
                        {
                            span_start = vector.create(13, 19),
                            text = " ",
                            span_stop = vector.create(14, 19),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(14, 19),
                },
                span_start = vector.create(0, 19),
                span_stop = vector.create(1, 23),
                local_keyword = {
                    trailing_trivia = {},
                    text = "local",
                    leading_trivia = {
                        {
                            span_start = vector.create(1, 17),
                            text = "\n",
                            span_stop = vector.create(0, 18),
                            tag = "whitespace",
                        },
                        {
                            span_start = vector.create(0, 18),
                            text = "\n",
                            span_stop = vector.create(0, 19),
                            tag = "whitespace",
                        },
                    },
                    position = vector.create(0, 19),
                },
                tag = "local",
            },
        },
        tag = "block",
    },
    hotcomments = {},
}]]