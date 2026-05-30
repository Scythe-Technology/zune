--!native
--!unsafe
-- space
--!unknown
--[[ @result {
    root = {
        tag = "block",
        span_start = vector.zero,
        span_stop = vector.create(10, 3),
        statements = {},
    },
    eof = {
        tag = "eof",
        text = "",
        position = vector.create(10, 3),
        trailing_trivia = {},
        leading_trivia = {
            {
                span_start = vector.zero,
                span_stop = vector.create(9, 0),
                text = "--!native",
                tag = "comment",
            },
            {
                span_start = vector.create(9, 0),
                span_stop = vector.create(0, 1),
                text = "\n",
                tag = "whitespace",
            },
            {
                span_start = vector.create(0, 1),
                span_stop = vector.create(9, 1),
                text = "--!unsafe",
                tag = "comment",
            },
            {
                span_start = vector.create(9, 1),
                span_stop = vector.create(0, 2),
                text = "\n",
                tag = "whitespace",
            },
            {
                span_start = vector.create(0, 2),
                span_stop = vector.create(8, 2),
                text = "-- space",
                tag = "comment",
            },
            {
                span_start = vector.create(8, 2),
                span_stop = vector.create(0, 3),
                text = "\n",
                tag = "whitespace",
            },
            {
                span_start = vector.create(0, 3),
                span_stop = vector.create(10, 3),
                text = "--!unknown",
                tag = "comment",
            },
        },
    },
    lines = 4,
    line_offsets = {0, 10, 20, 29},
    hotcomments = {
        {
            header = true,
            content = "native",
            span_start = vector.zero,
            span_stop = vector.create(9, 0),
        },
        {
            header = true,
            content = "unsafe",
            span_start = vector.create(0, 1),
            span_stop = vector.create(9, 1),
        },
        {
            header = true,
            content = "unknown",
            span_start = vector.create(0, 3),
            span_stop = vector.create(10, 3),
        }
    },
}]]