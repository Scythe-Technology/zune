local a = 1 -- hello
--[[ @result {
    lines = 1,
    line_offsets = {0},
    root = {
        tag = "block",
        statements = {
            {
                tag = "local",
                variables = {
                    {
                        node = {
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
        },
        span_start = vector.zero,
        span_stop = vector.create(20, 0),
    },
    eof = {
        tag = "eof",
        text = "",
        position = vector.create(20, 0),
        trailing_trivia = {},
        leading_trivia = {
            {
                span_start = vector.create(12, 0),
                span_stop = vector.create(20, 0),
                text = "-- hello",
                tag = "comment",
            },
        },
    },
    hotcomments = {}
}]]