--!strict
local TEMP_DIR = _G.__test_tempdir::string;

local sqlite = zune.sqlite;
local testing = zune.testing;
local task = zune.task;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("SQLite", function()
    test("Open/Close (Memory)", function()
        do
            local db = sqlite.open();
            db:close();
        end
        do
            local db = sqlite.open(":memory:");
            db:close();
        end
        do
            local db = sqlite.open(":MEMORY:");
            db:close();
        end
    end)

    test("Open/Close (File)", function()
        local db = sqlite.open(`{TEMP_DIR}/test.db`);
        db:close();
    end)

    test("Insert", function()
        local db = sqlite.open();

        expect(db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)")).toBe(expect.similar({
            last_insert_row_id = 0,
            changes = 0,
        }));

        do
            local query = db:query("INSERT INTO users VALUES (:id, :age)");

            expect(query:run({
                [":id"] = "a",
                [":age"] = 25,
            })).toBe(expect.similar({
                last_insert_row_id = 1,
                changes = 1,
            }));
            expect(query:run({
                [":id"] = "b",
                [":age"] = 27,
            })).toBe(expect.similar({
                last_insert_row_id = 2,
                changes = 1,
            }));
            expect(query:run({
                [":id"] = "c",
            })).toBe(expect.similar({
                last_insert_row_id = 3,
                changes = 1,
            }));
        end

        do
            local query = db:query("SELECT id, age FROM users");
            expect(query:all()).toBe(expect.similar({
                { id = "a", age = 25 },
                { id = "b", age = 27 },
                { id = "c", age = nil },
            }));
        end

        db:close();
    end);

    test("Transaction", function()
        local db = sqlite.open();

        expect(db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)")).toBe(expect.similar({
            last_insert_row_id = 0,
            changes = 0,
        }));
        local insert_query = db:query("INSERT INTO users VALUES (:id, :age)");
        local select_query = db:query("SELECT id, age FROM users");

        local insert = db:transaction(function(args: {any})
            local err = #args == 2 or #args == 5;
            local async = #args == 4 or #args == 5;
            for i, arg in args do
                if (async) then
                    task.wait(0.1);
                end
                insert_query:run(arg);
                if (err and i == 2) then
                    error("Oops")
                end
            end
            return args;
        end)

        local input_args_0 = {
            {
                [":id"] = "a",
                [":age"] = 25,
            },
            {
                [":id"] = "b",
                [":age"] = 27,
            },
            {
                [":id"] = "c",
            }
        };
        local res_0 = {insert(input_args_0)};
        expect(#res_0).toBe(1);
        expect(res_0[1]).toBe(expect.type("table"));
        expect(res_0[1]).toBe(input_args_0);

        expect(select_query:all()).toBe(expect.similar({
            { id = "a", age = 25 },
            { id = "b", age = 27 },
            { id = "c", age = nil },
        }));

        do
            local ok, err = pcall(insert, {
                {
                    [":id"] = "d",
                    [":age"] = 28,
                },
                {
                    [":id"] = "e",
                }
            })
            expect(ok).toBe(false);
            expect(err:find("Oops", 1, true) ~= nil).toBeTruthy();
        end

        expect(select_query:all()).toBe(expect.similar({
            { id = "a", age = 25 },
            { id = "b", age = 27 },
            { id = "c", age = nil },
        }));


        local input_args_1 = {
            {
                [":id"] = "d",
            },
            {
                [":id"] = "e",
            },
            {
                [":id"] = "f",
            },
            {
                [":id"] = "g",
            }
        };
        local res_1 = {insert(input_args_1)};
        expect(#res_1).toBe(1);
        expect(res_1[1]).toBe(expect.type("table"));
        expect(res_1[1]).toBe(input_args_1);

        expect(select_query:all()).toBe(expect.similar({
            { id = "a", age = 25 },
            { id = "b", age = 27 },
            { id = "c", age = nil },
            { id = "d", age = nil },
            { id = "e", age = nil },
            { id = "f", age = nil },
            { id = "g", age = nil },
        }));

        local ok, err = pcall(insert, {
            {
                [":id"] = "h",
            },
            {
                [":id"] = "i",
            },
            {
                [":id"] = "j",
            },
            {
                [":id"] = "k",
            },
            {
                [":id"] = "l",
            }
        })
        expect(ok).toBe(false);
        expect(err:find("Oops", 1, true)).toBeTruthy();

        expect(select_query:all()).toBe(expect.similar({
            { id = "a", age = 25 },
            { id = "b", age = 27 },
            { id = "c", age = nil },
            { id = "d", age = nil },
            { id = "e", age = nil },
            { id = "f", age = nil },
            { id = "g", age = nil },
        }));

        db:close();
    end);

    test("Count", function()
        local db = sqlite.open();

        expect(db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)")).toBe(expect.similar({
            last_insert_row_id = 0,
            changes = 0,
        }));
        expect(db:exec(`INSERT INTO users VALUES("a", 25)`)).toBe(expect.similar({
            last_insert_row_id = 1,
            changes = 1,
        }));
        expect(db:exec(`INSERT INTO users VALUES("b", 27)`)).toBe(expect.similar({
            last_insert_row_id = 2,
            changes = 1,
        }));
        expect(db:exec(`INSERT INTO users VALUES("c", NULL)`)).toBe(expect.similar({
            last_insert_row_id = 3,
            changes = 1,
        }));

        do
            local query = db:query("SELECT age FROM users");
            expect(query:get()).toBe(expect.similar({
                age = 25,
            }));
        end

        do
            local query = db:query("SELECT count(*) as count FROM users");
            expect(query:get()).toBe(expect.similar({
                count = 3,
            }));
        end

        db:close();
    end);

    test("Example", function()
        local db = sqlite.open();

        db:exec("CREATE TABLE users(id TEXT PRIMARY KEY, age FLOAT)");

        do
            local query = db:query("INSERT INTO users VALUES (:id, :age)");
            expect(query:run({
                [":id"] = "a",
                [":age"] = 21,
            })).toBe(expect.similar({
                last_insert_row_id = 1,
                changes = 1,
            }));
            expect(query:run({
                [":id"] = "b",
                [":age"] = 20,
            })).toBe(expect.similar({
                last_insert_row_id = 2,
                changes = 1,
            }));
            expect(query:run({
                [":id"] = "c",
            })).toBe(expect.similar({
                last_insert_row_id = 3,
                changes = 1,
            }));
            expect(query:run({
                [":id"] = "d",
            })).toBe(expect.similar({
                last_insert_row_id = 4,
                changes = 1,
            }));
        end

        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:get({
                [":min"] = 0,
            })).toBe(expect.similar({
                id = "a",
                age = 21,
            }));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:all({
                [":min"] = 0,
            })).toBe(expect.similar({
                { id = "a", age = 21 },
                { id = "b", age = 20 },
            }));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:all({
                [":min"] = 21,
            })).toBe(expect.similar({
                { id = "a", age = 21 },
            }));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age >= :min")
            expect(query:all({
                [":min"] = 22,
            })).toBe(expect.similar({}));
        end
        do
            local query = db:query("SELECT * FROM users WHERE age IS NULL")
            expect(query:all()).toBe(expect.similar({
                { id = "c", age = nil },
                { id = "d", age = nil },
            }));
        end

        db:close();
    end)
end)
