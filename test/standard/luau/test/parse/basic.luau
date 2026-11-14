local a = 1 -- hello
const b = 1 -- hello
--[[ @result {
    lines = 2,
    line_offsets = {0, 21},
    root = {
        tag = "block",
        statements = {
            {
                tag = "local",
                variables = {
                    {
                        node = {
                            is_exported = false,
                            is_const = false,
                            name = {
                                text = "a",
                                position = vector.create(6, 0),
                                trailing_trivia = {},
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 0),
                                        span_stop = vector.create(6, 0),
                                        text = " ",
                                        tag = "whitespace",
                                    },
                                },
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            tag = "number",
                            text = "1",
                            value = 1,
                            position = vector.create(10, 0),
                            span_start = vector.create(10, 0),
                            span_stop = vector.create(11, 0),
                            trailing_trivia = {
                                {
                                    span_start = vector.create(11, 0),
                                    span_stop = vector.create(12, 0),
                                    text = " ",
                                    tag = "whitespace",
                                },
                                {
                                    span_start = vector.create(12, 0),
                                    span_stop = vector.create(20, 0),
                                    text = "-- hello",
                                    tag = "comment",
                                },
                            },
                            leading_trivia = {
                                {
                                    span_start = vector.create(9, 0),
                                    span_stop = vector.create(10, 0),
                                    text = " ",
                                    tag = "whitespace",
                                },
                            },
                        },
                    },
                },
                equals = {
                    text = "=",
                    position = vector.create(8, 0),
                    trailing_trivia = {},
                    leading_trivia = {
                        {
                            span_start = vector.create(7, 0),
                            span_stop = vector.create(8, 0),
                            text = " ",
                            tag = "whitespace",
                        },
                    },
                },
                span_start = vector.create(0, 0),
                span_stop = vector.create(11, 0),
                local_keyword = {
                    text = "local",
                    position = vector.create(0, 0),
                    trailing_trivia = {},
                    leading_trivia = {},
                },
            },
            {
                tag = "local",
                variables = {
                    {
                        node = {
                            is_exported = false,
                            is_const = true,
                            name = {
                                text = "b",
                                position = vector.create(6, 1),
                                trailing_trivia = {},
                                leading_trivia = {
                                    {
                                        span_start = vector.create(5, 1),
                                        span_stop = vector.create(6, 1),
                                        text = " ",
                                        tag = "whitespace",
                                    },
                                },
                            },
                        },
                    },
                },
                values = {
                    {
                        node = {
                            tag = "number",
                            text = "1",
                            value = 1,
                            position = vector.create(10, 1),
                            span_start = vector.create(10, 1),
                            span_stop = vector.create(11, 1),
                            trailing_trivia = {
                                {
                                    span_start = vector.create(11, 1),
                                    span_stop = vector.create(12, 1),
                                    text = " ",
                                    tag = "whitespace",
                                },
                            },
                            leading_trivia = {
                                {
                                    span_start = vector.create(9, 1),
                                    span_stop = vector.create(10, 1),
                                    text = " ",
                                    tag = "whitespace",
                                },
                            },
                        },
                    },
                },
                equals = {
                    text = "=",
                    position = vector.create(8, 1),
                    trailing_trivia = {},
                    leading_trivia = {
                        {
                            span_start = vector.create(7, 1),
                            span_stop = vector.create(8, 1),
                            text = " ",
                            tag = "whitespace",
                        },
                    },
                },
                span_start = vector.create(0, 1),
                span_stop = vector.create(11, 1),
                const_keyword = {
                    text = "const",
                    position = vector.create(0, 1),
                    trailing_trivia = {},
                    leading_trivia = {
                        {
                            span_start = vector.create(20, 0),
                            span_stop = vector.create(0, 1),
                            text = "\n",
                            tag = "whitespace",
                        }
                    },
                },
            },
        },
        span_start = vector.zero,
        span_stop = vector.create(20, 1),
    },
    eof = {
        tag = "eof",
        text = "",
        position = vector.create(20, 1),
        trailing_trivia = {},
        leading_trivia = {
            {
                span_start = vector.create(12, 1),
                span_stop = vector.create(20, 1),
                text = "-- hello",
                tag = "comment",
            },
        },
    },
    hotcomments = {}
}]]