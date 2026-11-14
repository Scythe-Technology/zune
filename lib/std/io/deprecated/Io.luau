--!strict

export type Writable = {
    write: (self: Writable, value: string | buffer) -> (),
    writei8: (self: Writable, value: number) -> (),
    writeu8: (self: Writable, value: number) -> (),
    writei16: (self: Writable, value: number) -> (),
    writeu16: (self: Writable, value: number) -> (),
    writei32: (self: Writable, value: number) -> (),
    writeu32: (self: Writable, value: number) -> (),
    writef32: (self: Writable, value: number) -> (),
    writef64: (self: Writable, value: number) -> (),
}

export type Readable = {
    read: & ((self: Readable, amount: number?, bytes: true?) -> buffer)
        & ((self: Readable, amount: number?, bytes: false) -> string),
    readi8: (self: Readable) -> number,
    readu8: (self: Readable) -> number,
    readi16: (self: Readable) -> number,
    readu16: (self: Readable) -> number,
    readi32: (self: Readable) -> number,
    readu32: (self: Readable) -> number,
    readf32: (self: Readable) -> number,
    readf64: (self: Readable) -> number,
}

return nil
