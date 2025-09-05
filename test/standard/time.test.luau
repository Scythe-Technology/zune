--!strict
local time = zune.time;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("time", function()
    describe("Date", function()
        test("Now", function()
            local date = time.date.now();

            expect({
                timestamp = date.timestamp,
                timestamp_millis = date.timestamp_millis,
            }).toBe(expect.similar({
                timestamp = expect.type("number"),
                timestamp_millis = expect.type("number"),
            }));
        end)

        describe("parse", function()
            test("GMT", function()
                local date = time.date.parse("04 Dec 1995 00:12:00 GMT");
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818035920,
                    timestamp_millis = 818035920000,
                }));
            end)
            test("EST", function()
                local date = time.date.parse("04 Dec 1995 00:12:00 EST");
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818053920,
                    timestamp_millis = 818053920000,
                }));
            end)
            test("GMT Long", function()
                local date = time.date.parse("Mon, 04 Dec 1995 00:12:00 GMT");
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818035920,
                    timestamp_millis = 818035920000,
                }));
            end)
            test("EST Long", function()
                local date = time.date.parse("Mon, 04 Dec 1995 00:12:00 EST");
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818053920,
                    timestamp_millis = 818053920000,
                }));
            end)
            test("ISO8601 UTC", function()
                local date = time.date.parse("1995-12-04T00:12:00Z");
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818035920,
                    timestamp_millis = 818035920000,
                }));
            end)
        end)

        test("fromIsoDate", function()
            local date = time.date.fromIsoDate("1995-12-04T00:12:00Z");

            expect({
                timestamp = date.timestamp,
                timestamp_millis = date.timestamp_millis,
            }).toBe(expect.similar({
                timestamp = 818035920,
                timestamp_millis = 818035920000,
            }));
        end)

        test("toLocalTime", function()
            local date = time.date.fromUnixTimestamp(818035920);

            expect(date:toLocalTime()).toBe(expect.similar({
                year = 1995,
                month = 12,
                day = expect.type("number"),
                hour = expect.type("number"),
                minute = expect.type("number"),
                second = 0,
                millisecond = 0,
            }));
        end)

        test("toUniversalTime", function()
            local date = time.date.fromUnixTimestamp(818035920);

            expect(date:toUniversalTime()).toBe(expect.similar({
                year = 1995,
                month = 12,
                day = 4,
                hour = 0,
                minute = 12,
                second = 0,
                millisecond = 0,
            }));

            local now = time.date.now();

            expect(now:toUniversalTime()).toBe(expect.similar({
                year = expect.type("number"),
                month = expect.type("number"),
                day = expect.type("number"),
                hour = expect.type("number"),
                minute = expect.type("number"),
                second = expect.type("number"),
                millisecond = expect.type("number"),
            }));
        end)

        describe("Format", function()
            test("toIsoDate", function()
                local date = time.date.fromUnixTimestamp(818035920);

                expect(date:toIsoDate()).toBe("1995-12-04T00:12:00Z");
            end)
            test("formatLocalTime", function()
                local date = time.date.fromUnixTimestamp(818035920);

                expect(date:formatLocalTime("%Y-%m-%d %H:%M:%S")).toBe(expect.type("string"));
            end)
            test("formatUniversalTime", function()
                local date = time.date.fromUnixTimestamp(818035920);

                expect(date:formatUniversalTime("%Y-%m-%d %H:%M:%S")).toBe("1995-12-04 00:12:00");
                expect(date:formatUniversalTime("%Y-%m-%d %H:%M:%S %:z")).toBe("1995-12-04 00:12:00 +00:00");
                expect(date:formatUniversalTime("%T")).toBe("1995-12-04T00:12:00Z");
            end)
        end)

        describe("Unix Timestamp", function()
            test("Seconds", function()
                local date = time.date.fromUnixTimestamp(818035920);
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818035920,
                    timestamp_millis = 818035920000,
                }));
            end)
            test("Milliseconds", function()
                local date = time.date.fromUnixTimestampMillis(818035920000);
        
                expect({
                    timestamp = date.timestamp,
                    timestamp_millis = date.timestamp_millis,
                }).toBe(expect.similar({
                    timestamp = 818035920,
                    timestamp_millis = 818035920000,
                }));
            end)
        end)
    end)
    test("Instant", function()
        expect(time.instant.now()).toBe(expect.type("buffer"));
    end)
    test("timestamp", function()
        expect(time.timestamp()).toBeGreaterThan(0);
        expect(time.timestampMillis()).toBeGreaterThan(0);
    end)
end)
